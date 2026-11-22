mod cache;
#[cfg(test)]
mod embedding_tests;
mod installed;
mod root;
mod runtime;
pub(crate) mod streams;
mod usage;

pub(crate) use cache::CompilationCache;
pub(crate) use root::RootOptions;
pub(crate) use runtime::GuestOptions;
#[cfg(any(feature = "cli", test))]
pub(crate) use runtime::Mode;
pub use runtime::Runtime;
pub(crate) use tokio_util::sync::CancellationToken as Cancellation;
pub(crate) use usage::Usage;

use anyhow::Result;
use std::path::Path;
use std::sync::{
    Arc,
    atomic::{AtomicBool, Ordering},
};
use std::time::{Duration, Instant};
use usage::Limits;
use wasmtime::component::{Component, Linker, ResourceTable};
use wasmtime::{CallHook, Config, Engine, Store, StoreLimitsBuilder, Trap, UpdateDeadline};
use wasmtime_wasi::p3::bindings::Command;
use wasmtime_wasi::{I32Exit, WasiCtx, WasiCtxView, WasiView};

pub(crate) const WASMTIME_VERSION: &str = env!("KETTLECORN_WASMTIME_VERSION");

#[derive(Debug, serde::Serialize)]
#[serde(tag = "outcome", rename_all = "snake_case")]
pub(crate) enum ExecutionOutcome {
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
pub(crate) struct PreparedRuntime {
    runtime: Runtime,
    compiled: Arc<Compiled>,
}

struct State {
    ctx: WasiCtx,
    table: ResourceTable,
    limits: Limits,
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
    pub(crate) fn prepare(&self, options: &GuestOptions) -> Result<PreparedRuntime> {
        self.validate(options)?;
        self.prepare_variant(
            options.http,
            options.max_fuel.is_some(),
            &options.cache,
            Some(&options.root),
        )
    }

    pub(crate) fn prepare_variant(
        &self,
        http: bool,
        fuel: bool,
        cache: &CompilationCache,
        guest_root: Option<&Path>,
    ) -> Result<PreparedRuntime> {
        #[cfg(not(feature = "http"))]
        if http {
            anyhow::bail!("this launcher was built without HTTP support");
        }
        let index = usize::from(http) * 2 + usize::from(fuel);
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
            let component = cache.compile(&engine.engine, &self.component(http), guest_root)?;
            preparation.components[index] = Some(Arc::new(Compiled {
                engine,
                component,
                http,
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
    pub(crate) async fn run(
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
            .map(|duration| {
                Instant::now()
                    .checked_add(duration)
                    .ok_or_else(|| anyhow::anyhow!("guest lifetime is too large"))
            })
            .transpose()?;
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
                limits: Limits::new(limits.build(), options.usage.clone()),
                #[cfg(feature = "http")]
                http: wasmtime_wasi_http::WasiHttpCtx::new(),
            },
        );
        store.limiter(|state| &mut state.limits);
        let budget = options.max_fuel;
        if let Some(budget) = budget {
            store.set_fuel(budget)?;
        }
        // Usage changes only while WebAssembly runs, and a running guest
        // waits only in host calls, so sampling there keeps it current.
        let usage = options.usage.clone();
        store.call_hook(move |store, transition| {
            if matches!(transition, CallHook::CallingHost) {
                usage.sample(budget, store);
            }
            Ok(())
        });
        let stopped = cancel.clone();
        store.epoch_deadline_callback(move |_| {
            if stopped.is_cancelled() || deadline.is_some_and(|end| Instant::now() >= end) {
                return Err(Trap::Interrupt.into());
            }
            Ok(UpdateDeadline::Yield(1))
        });
        store.set_epoch_deadline(1);
        let usage = options.usage.clone();
        let execution = async {
            let command = Command::instantiate_async(&mut store, component, &linker).await?;
            usage.instantiated();
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
            _ = expiration(deadline.map(Into::into)) => Ok(ExecutionOutcome::Timeout),
            result = execution => result,
        };
        options.usage.sample(options.max_fuel, &store);
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

pub(crate) async fn expiration(deadline: Option<tokio::time::Instant>) {
    match deadline {
        Some(end) => tokio::time::sleep_until(end).await,
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
    fn explicit_load_ignores_release_metadata() -> anyhow::Result<()> {
        let (base, _, _) = fixture();
        let runtime = base.path().join("runtime");
        let path = runtime.join("manifest.json");
        let mut manifest: serde_json::Value = serde_json::from_slice(&fs::read(&path)?)?;
        manifest["kettlecorn"] = serde_json::json!(false);
        manifest["platform"] = serde_json::json!({ "custom": true });
        fs::write(path, serde_json::to_vec(&manifest)?)?;
        Runtime::load(runtime)?;
        Ok(())
    }

    #[test]
    fn load_rejects_an_incompatible_protocol() {
        let directory = tempfile::tempdir().unwrap();
        let manifest = serde_json::json!({
            "protocol": 0,
            "tested_with": {"wasmtime": WASMTIME_VERSION},
        });
        fs::write(directory.path().join("manifest.json"), manifest.to_string()).unwrap();
        let error = Runtime::load(directory.path()).err().unwrap();
        assert!(error.to_string().contains("runtime protocol"));
    }

    #[tokio::test]
    async fn start_rejects_a_zero_frame_write_timeout() {
        let (_base, runtime, _) = fixture();
        let mut options = crate::VmOptions::default();
        options.frame_write_timeout = std::time::Duration::ZERO;
        assert!(matches!(
            runtime.start(options).await,
            Err(crate::Error::InvalidOptions(error))
                if error.to_string().contains("frame_write_timeout")
        ));
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

    #[tokio::test]
    async fn concurrent_warmups_prepare_variants_without_a_guest_root() {
        let (base, runtime, options) = fixture();
        fs::remove_dir(&options.root).unwrap();
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
        let mut warmups = tokio::task::JoinSet::new();
        for variant in &variants {
            for _ in 0..4 {
                let runtime = runtime.clone();
                let mut options = crate::VmOptions::default();
                options.http = variant.http;
                options.max_fuel = variant.max_fuel;
                warmups.spawn(async move { runtime.warm_up(&options).await });
            }
        }
        while let Some(result) = warmups.join_next().await {
            result.unwrap().unwrap();
        }
        assert!(!options.root.exists());
        fs::create_dir(&options.root).unwrap();
        for module in ["beam.wasm", "beam-http.wasm"] {
            fs::remove_file(base.path().join("runtime").join(module)).unwrap();
        }
        for variant in variants {
            assert!(runtime.clone().prepare(&variant).is_ok());
        }
        assert!(!base.path().join("cache").exists());
    }
}
