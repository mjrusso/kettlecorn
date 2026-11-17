//! Internal, unstable execution API for Kettlecorn runtimes.
//!
//! Load a [`Runtime`] and call [`Runtime::prepare`] on a caller-owned blocking
//! executor. Preparation is synchronous and serialized across clones of that
//! runtime; it retains up to two engines and four HTTP/fuel component variants.
//! Reuse the returned [`PreparedRuntime`] for executions on a Tokio runtime with
//! I/O and time enabled. Execution never submits compilation work.
//!
//! Each execution needs a fresh private writable root and owns its store and
//! cancellation state. Dropping its future releases the store. Shared engines
//! yield at epoch checkpoints, approximately every 10 ms; supplied streams must
//! implement nonblocking polling. The library installs no process-wide signal
//! handlers or terminal settings and transports bytes without interpreting ETF
//! or protocol frames.

mod cache;
mod root;
mod runtime;
pub mod streams;
mod unix;

pub use cache::CompilationCache;
pub use root::RootOptions;
pub use runtime::{GuestOptions, Mode, Runtime};
pub use tokio_util::sync::CancellationToken as Cancellation;

use anyhow::Result;
use std::sync::{
    Arc,
    atomic::{AtomicBool, Ordering},
};
use std::time::{Duration, Instant};
use wasmtime::component::{Component, Linker, ResourceTable};
use wasmtime::{Config, Engine, Store, StoreLimits, StoreLimitsBuilder, Trap, UpdateDeadline};
use wasmtime_wasi::p3::bindings::Command;
use wasmtime_wasi::{I32Exit, WasiCtx, WasiCtxView, WasiView};

pub const WASMTIME_VERSION: &str = "50.0.0";

#[derive(Debug, serde::Serialize)]
#[serde(tag = "outcome", rename_all = "snake_case")]
pub enum ExecutionOutcome {
    Exited {
        code: i32,
    },
    Cancelled,
    Timeout,
    OutOfFuel,
    Failed {
        #[serde(skip)]
        error: anyhow::Error,
    },
}

struct EpochClock(Arc<AtomicBool>);

impl EpochClock {
    fn start(engine: Engine) -> Self {
        let finished = Arc::new(AtomicBool::new(false));
        let flag = finished.clone();
        std::thread::spawn(move || {
            while !flag.load(Ordering::Acquire) {
                std::thread::sleep(Duration::from_millis(10));
                engine.increment_epoch();
            }
        });
        Self(finished)
    }
}

impl Drop for EpochClock {
    fn drop(&mut self) {
        self.0.store(true, Ordering::Release);
    }
}

struct EngineState {
    engine: Engine,
    fuel: bool,
    _clock: EpochClock,
}

struct Compiled {
    engine: Arc<EngineState>,
    component: Component,
    http: bool,
}

#[derive(Default)]
pub(crate) struct Preparation {
    engines: [Option<Arc<EngineState>>; 2],
    components: [Option<Arc<Compiled>>; 4],
}

#[derive(Clone)]
pub struct PreparedRuntime {
    runtime: Runtime,
    compiled: Arc<Compiled>,
}

struct State {
    ctx: WasiCtx,
    table: ResourceTable,
    limits: StoreLimits,
    #[cfg(feature = "http")]
    http: wasmtime_wasi_http::WasiHttpCtx,
}

impl WasiView for State {
    fn ctx(&mut self) -> WasiCtxView<'_> {
        WasiCtxView {
            ctx: &mut self.ctx,
            table: &mut self.table,
        }
    }
}

#[cfg(feature = "http")]
impl wasmtime_wasi_http::WasiHttpView for State {
    fn http(&mut self) -> wasmtime_wasi_http::WasiHttpCtxView<'_> {
        wasmtime_wasi_http::WasiHttpCtxView {
            ctx: &mut self.http,
            table: &mut self.table,
            hooks: wasmtime_wasi_http::default_hooks(),
        }
    }
}

fn engine(fuel: bool) -> Result<Engine> {
    let mut config = Config::new();
    config
        .wasm_component_model_async(true)
        .wasm_component_model_threading(true)
        .cranelift_opt_level(wasmtime::OptLevel::Speed)
        .parallel_compilation(true)
        .epoch_interruption(true)
        .consume_fuel(fuel);
    Ok(Engine::new(&config)?)
}

impl Runtime {
    /// Compiles the HTTP/fuel variant selected by `options`, or reuses its
    /// prepared component. This blocks the caller; clones share one compilation
    /// lock and retain the compiled variants until the runtime is dropped.
    pub fn prepare(&self, options: &GuestOptions) -> Result<PreparedRuntime> {
        self.validate(options)?;
        #[cfg(not(feature = "http"))]
        if options.http {
            anyhow::bail!("this launcher was built without HTTP support");
        }
        let fuel = options.max_fuel.is_some();
        let index = usize::from(options.http) * 2 + usize::from(fuel);
        let mut preparation = self
            .preparation
            .lock()
            .map_err(|_| anyhow::anyhow!("runtime preparation panicked"))?;
        if preparation.components[index].is_none() {
            let engine_index = usize::from(fuel);
            if preparation.engines[engine_index].is_none() {
                let engine = engine(fuel)?;
                let clock = EpochClock::start(engine.clone());
                preparation.engines[engine_index] = Some(Arc::new(EngineState {
                    engine,
                    fuel,
                    _clock: clock,
                }));
            }
            let engine = preparation.engines[engine_index].as_ref().unwrap().clone();
            let component = options.cache.compile(
                &engine.engine,
                &self.component(options.http),
                &options.root,
            )?;
            preparation.components[index] = Some(Arc::new(Compiled {
                engine,
                component,
                http: options.http,
            }));
        }
        Ok(PreparedRuntime {
            runtime: self.clone(),
            compiled: preparation.components[index].as_ref().unwrap().clone(),
        })
    }
}

impl PreparedRuntime {
    /// Runs one guest with this prepared HTTP/fuel configuration. Limits,
    /// streams, root, and cancellation belong to this execution. The cache is
    /// used only by preparation; running does not access component source files.
    pub async fn run(
        &self,
        options: GuestOptions,
        streams: streams::Streams,
        cancel: Cancellation,
    ) -> ExecutionOutcome {
        self.execute(options, streams, cancel)
            .await
            .unwrap_or_else(|error| ExecutionOutcome::Failed { error })
    }

    async fn execute(
        &self,
        options: GuestOptions,
        streams: streams::Streams,
        cancel: Cancellation,
    ) -> Result<ExecutionOutcome> {
        if cancel.is_cancelled() {
            return Ok(ExecutionOutcome::Cancelled);
        }
        self.runtime.validate(&options)?;
        anyhow::ensure!(
            options.http == self.compiled.http
                && options.max_fuel.is_some() == self.compiled.engine.fuel,
            "HTTP/fuel configuration differs from the prepared runtime"
        );
        let deadline = options
            .max_lifetime
            .map(|duration| Instant::now() + duration);
        let engine = &self.compiled.engine.engine;
        let component = &self.compiled.component;
        let mut linker = Linker::<State>::new(engine);
        wasmtime_wasi::p3::add_to_linker(&mut linker)?;
        #[cfg(feature = "http")]
        if options.http {
            wasmtime_wasi_http::p3::add_to_linker(&mut linker)?;
        }

        let mut builder = WasiCtx::builder();
        builder
            .stdin(streams.stdin)
            .stdout(streams.stdout)
            .stderr(streams.stderr)
            .envs(&self.runtime.environment(&options))
            .args(&self.runtime.arguments(&options))
            .allow_blocking_current_thread(options.blocking_filesystem);
        builder.preopened_dir(&options.root, "/", wasmtime_wasi::FsPerms::ReadWrite)?;
        if options.network {
            builder
                .inherit_network()
                .allow_tcp(true)
                .allow_udp(true)
                .allow_ip_name_lookup(true);
        }
        let mut limits = StoreLimitsBuilder::new();
        if let Some(bytes) = options.max_memory {
            limits = limits.memory_size(bytes);
        }
        let mut store = Store::new(
            engine,
            State {
                ctx: builder.build(),
                table: ResourceTable::new(),
                limits: limits.build(),
                #[cfg(feature = "http")]
                http: wasmtime_wasi_http::WasiHttpCtx::new(),
            },
        );
        store.limiter(|state| &mut state.limits);
        if let Some(fuel) = options.max_fuel {
            store.set_fuel(fuel)?;
        }
        let stopped = cancel.clone();
        store.epoch_deadline_callback(move |_| {
            if stopped.is_cancelled() || deadline.is_some_and(|end| Instant::now() >= end) {
                return Err(Trap::Interrupt.into());
            }
            Ok(UpdateDeadline::Yield(1))
        });
        store.set_epoch_deadline(1);
        let execution = async {
            let command = Command::instantiate_async(&mut store, component, &linker).await?;
            let result = store
                .run_concurrent(async move |store| command.wasi_cli_run().call_run(store).await)
                .await??;
            Ok::<_, anyhow::Error>(ExecutionOutcome::Exited {
                code: if result.is_ok() { 0 } else { 1 },
            })
        };
        let result = tokio::select! {
            biased;
            _ = cancel.cancelled() => Ok(ExecutionOutcome::Cancelled),
            _ = expiration(deadline) => Ok(ExecutionOutcome::Timeout),
            result = execution => result,
        };
        match result {
            Err(_) if cancel.is_cancelled() => Ok(ExecutionOutcome::Cancelled),
            Err(error) => match error.downcast_ref::<Trap>() {
                Some(Trap::OutOfFuel) => Ok(ExecutionOutcome::OutOfFuel),
                Some(Trap::Interrupt) if deadline.is_some_and(|end| Instant::now() >= end) => {
                    Ok(ExecutionOutcome::Timeout)
                }
                _ => error
                    .downcast::<I32Exit>()
                    .map(|exit| ExecutionOutcome::Exited { code: exit.0 }),
            },
            other => other,
        }
    }
}

async fn expiration(deadline: Option<Instant>) {
    match deadline {
        Some(end) => tokio::time::sleep_until(end.into()).await,
        None => std::future::pending::<()>().await,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;

    fn fixture() -> (tempfile::TempDir, Runtime, GuestOptions) {
        let base = tempfile::tempdir().unwrap();
        let directory = base.path().join("runtime");
        let launch = directory.join("launch");
        fs::create_dir_all(&launch).unwrap();
        fs::write(
            directory.join("manifest.json"),
            serde_json::json!({
                "protocol": 1,
                "otp": "29",
                "elixir": "1.20.5",
                "tested_with": {"wasmtime": WASMTIME_VERSION},
            })
            .to_string(),
        )
        .unwrap();
        for name in ["env", "emulator-args", "init-args"] {
            fs::write(launch.join(name), "").unwrap();
        }
        for (name, module) in [("module", "beam.wasm"), ("http-module", "beam-http.wasm")] {
            fs::write(launch.join(name), module).unwrap();
            fs::write(directory.join(module), b"\0asm\x0d\0\x01\0").unwrap();
        }
        let root = base.path().join("root");
        fs::create_dir(&root).unwrap();
        let mut options = GuestOptions::new(root);
        options.cache = CompilationCache::Directory(base.path().join("cache"));
        (base, Runtime::load(directory).unwrap(), options)
    }

    #[test]
    fn already_cancelled_execution_does_not_compile() {
        let (base, runtime, options) = fixture();
        let prepared = runtime.prepare(&options).unwrap();
        fs::remove_dir_all(base.path().join("cache")).unwrap();
        let cancel = Cancellation::default();
        cancel.cancel();
        let executor = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .unwrap();
        for _ in 0..64 {
            let (streams, _peer) =
                streams::Streams::memory(std::num::NonZeroUsize::new(64).unwrap());
            assert!(matches!(
                executor.block_on(prepared.run(options.clone(), streams, cancel.clone())),
                ExecutionOutcome::Cancelled
            ));
        }
        drop(executor);
        assert!(!base.path().join("cache").exists());
    }

    #[test]
    fn cloned_runtimes_reuse_prepared_variants_without_source_or_disk_cache() {
        let (base, runtime, options) = fixture();
        let mut variants = Vec::new();
        for http in [false, true] {
            if http && !cfg!(feature = "http") {
                continue;
            }
            for fuel in [false, true] {
                let mut variant = options.clone();
                variant.http = http;
                variant.max_fuel = fuel.then_some(1);
                variants.push(variant);
            }
        }
        std::thread::scope(|scope| {
            for variant in &variants {
                for _ in 0..4 {
                    let runtime = runtime.clone();
                    scope.spawn(move || runtime.prepare(variant).unwrap());
                }
            }
        });
        fs::remove_dir_all(base.path().join("cache")).unwrap();
        for module in ["beam.wasm", "beam-http.wasm"] {
            fs::remove_file(base.path().join("runtime").join(module)).unwrap();
        }
        for variant in variants {
            assert!(runtime.clone().prepare(&variant).is_ok());
        }
        assert!(!base.path().join("cache").exists());
    }
}
