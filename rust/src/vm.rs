mod transport;

use crate::engine::{
    Cancellation, CompilationCache, ExecutionOutcome, GuestOptions, RootOptions, Usage,
    streams::Streams,
};
use crate::protocol::{self, Value};
use crate::{Error, NetworkAccess, Preload, Runtime};
use anyhow::{Context, Result, anyhow, bail};
use std::collections::{BTreeMap, HashMap};
use std::fmt;
use std::future::Future;
use std::num::{NonZeroU64, NonZeroUsize};
use std::path::PathBuf;
use std::pin::Pin;
use std::sync::Arc;
use std::time::Duration;
use tokio::io::{AsyncReadExt, DuplexStream};
use tokio::sync::{Semaphore, broadcast, mpsc, oneshot};
use tokio::task::JoinHandle;
use tokio::time::Instant;
use wasmtime_wasi::cli::AsyncStdoutStream;

type HostResult = Result<Value, String>;
type HostFuture = Pin<Box<dyn Future<Output = HostResult> + Send>>;
type HostFunction = Arc<dyn Fn(Value) -> HostFuture + Send + Sync>;
const REPLY_MARGIN_MS: u32 = 1000;
const DEFAULT_TIMEOUT: Duration = Duration::from_secs(5);
const STREAM_BYTES: usize = 64 * 1024;
const DRAIN_TIMEOUT: Duration = Duration::from_secs(1);

/// Guest configuration, limits, and host callbacks for [`Runtime::start`].
/// Create with [`VmOptions::default`] and set the public fields before starting a VM.
pub struct VmOptions {
    /// Maximum wait for preparation, private-root copying, and guest boot. Defaults to 60 seconds.
    /// Expiry does not interrupt blocking preparation already in progress.
    pub boot_timeout: Duration,
    /// WebAssembly linear memory limit in bytes. Defaults to 512 MiB; `None` removes the limit.
    /// This does not cap the Rust application's total memory use.
    pub max_memory: Option<usize>,
    /// Execution fuel shared by guest startup and all requests. Defaults to no limit.
    pub max_fuel: Option<u64>,
    /// Guest lifetime, starting after preparation and private-root copying. Defaults to no limit.
    pub max_lifetime: Option<Duration>,
    /// Socket and DNS access: [`NetworkAccess::Any`] reaches any destination, including
    /// loopback, private, and cloud metadata addresses, and [`NetworkAccess::Only`] the
    /// destinations its [`NetworkRule`](crate::NetworkRule)s allow. A `public` rule allows
    /// public addresses only.
    /// Defaults to [`NetworkAccess::Denied`]. Host CA certificates are not copied into the guest.
    pub network: NetworkAccess,
    /// Outgoing HTTP through WASI, with the same choices as `network`; `public` rules are not
    /// supported. Defaults to [`NetworkAccess::Denied`]; requires the `http` Cargo feature.
    pub http: NetworkAccess,
    /// Cooked Mix bundle copied into the guest at `/app`. Defaults to none.
    pub app_dir: Option<PathBuf>,
    /// Timeout for waiting on an async Rust callback. Defaults to five seconds.
    /// Independent of the guest's host-call timeout. It cannot interrupt blocking work.
    /// The first poll runs inline with VM transport; blocking there stalls transport
    /// and can return a successful result after the timeout. Use Tokio's blocking
    /// executor for blocking work.
    pub host_call_timeout: Duration,
    /// Time to write an outbound frame once selected for delivery.
    /// Must be positive. Defaults to five seconds.
    /// An earlier request deadline takes precedence. Expiry while sending a host reply,
    /// or after any part of a frame has been written, closes the VM.
    pub frame_write_timeout: Duration,
    /// Maximum in-flight requests to the guest, including queued writes. Defaults to 16.
    /// A written request can retain its slot after the caller stops waiting.
    pub max_pending_requests: NonZeroUsize,
    /// Maximum calls from the guest, including replies waiting to be written. Defaults to four.
    /// Excess calls get an error while the rejection queue has room and can time out when it fills.
    pub max_host_calls: NonZeroUsize,
    /// Broadcast sender for `Kettlecorn.Host.send/1` messages. Subscribe to
    /// the sender before `Runtime::start` to receive messages sent during boot.
    /// The broadcast channel's capacity controls how many messages it retains.
    /// When omitted, the VM uses an internal broadcast channel with capacity 16.
    pub events: Option<broadcast::Sender<Value>>,
    /// Receives guest stdout outside eval capture. Without a sender, stdout is discarded.
    /// Full channels discard chunks.
    pub stdout: Option<mpsc::Sender<Vec<u8>>>,
    /// Receives guest stderr and Kettlecorn diagnostics, including during boot.
    /// Without a sender, stderr is discarded. Full channels discard chunks.
    pub stderr: Option<mpsc::Sender<Vec<u8>>>,
    /// Selects a preload mode. Defaults to [`Preload::Off`].
    pub preload: Preload,
    /// Receives the name of each module, such as `"Elixir.Mod"`, that the guest
    /// loads on demand after preload. Without a sender, each one is reported as a
    /// stderr diagnostic. Full channels discard names. The guest can send these
    /// events itself, so treat them as guest data.
    pub late_loads: Option<mpsc::Sender<String>>,
    functions: HashMap<String, HostFunction>,
}

impl Default for VmOptions {
    fn default() -> Self {
        Self {
            boot_timeout: Duration::from_secs(60),
            max_memory: Some(512 * 1024 * 1024),
            max_fuel: None,
            max_lifetime: None,
            network: NetworkAccess::Denied,
            http: NetworkAccess::Denied,
            app_dir: None,
            host_call_timeout: DEFAULT_TIMEOUT,
            frame_write_timeout: Duration::from_secs(5),
            max_pending_requests: NonZeroUsize::new(16).unwrap(),
            max_host_calls: NonZeroUsize::new(4).unwrap(),
            events: None,
            stdout: None,
            stderr: None,
            preload: Preload::Off,
            late_loads: None,
            functions: HashMap::new(),
        }
    }
}

impl VmOptions {
    /// Registers an async function callable through `Kettlecorn.Host.call/3`.
    /// Arguments arrive as a [`Value::Map`]. Success returns `{:ok, value}` to the guest;
    /// an error string returns `{:error, binary_reason}`. Registering a name again replaces it.
    /// Blocking work should use Tokio's blocking executor.
    pub fn register<F, Fut>(&mut self, name: impl Into<String>, function: F)
    where
        F: Fn(Value) -> Fut + Send + Sync + 'static,
        Fut: Future<Output = HostResult> + Send + 'static,
    {
        self.functions
            .insert(name.into(), Arc::new(move |args| Box::pin(function(args))));
    }
}

/// Source language for [`Vm::eval`]. Elixir is the default.
#[derive(Clone, Copy, Debug, Default)]
pub enum Language {
    #[default]
    Elixir,
    Erlang,
}

/// Source language, guest limits, and bindings for one evaluation.
pub struct EvalOptions {
    /// Defaults to [`Language::Elixir`].
    pub language: Language,
    /// Guest evaluation timeout, including formatting and result traversal. Defaults to five seconds.
    /// Proxy and host reply deadlines include additional margins. Durations must fit in
    /// `u32` milliseconds with room for those margins; sub-millisecond precision is truncated.
    pub timeout: Duration,
    /// Initial variables, keyed by name. Defaults to an empty map.
    pub binding: BTreeMap<String, Value>,
    /// Reductions the evaluation and the processes it spawns may use before the guest stops
    /// them with a `reductions` [`ScriptError`]. [`Vm::eval`] rejects limits above `i64::MAX` with
    /// [`Error::InvalidRequest`]. `None`, the default, sets no limit.
    /// [`Evaluation::reductions`] describes how they are counted.
    pub max_reductions: Option<NonZeroU64>,
}

impl Default for EvalOptions {
    fn default() -> Self {
        Self {
            language: Language::Elixir,
            timeout: DEFAULT_TIMEOUT,
            binding: BTreeMap::new(),
            max_reductions: None,
        }
    }
}

/// Captured stdout and a script result. Transport failures use the outer [`Error`] instead.
#[derive(Debug)]
pub struct Evaluation {
    /// Captured stdout, including on a script error. Stderr is delivered separately.
    pub output: String,
    /// Whether captured stdout exceeded the guest's capture limit.
    pub output_truncated: bool,
    /// Reductions charged to the evaluation, its descendants, and its output
    /// callbacks before the budget closed. The count includes the charge that
    /// exceeded the limit. A timeout can end accounting before the evaluation
    /// process exits.
    pub reductions: u64,
    /// The evaluated value or the script's error, with captured output retained in this object.
    pub result: Result<EvalValue, ScriptError>,
}

/// Successful evaluation result in text and, when supported, structured form.
#[derive(Debug)]
pub struct EvalValue {
    /// The guest's text representation, retained when the structured value is omitted.
    pub inspected: String,
    /// The result as plain data when supported by [`Value`] and within evaluation limits.
    /// Functions, PIDs, ports, references, and improper lists are omitted. Size and nesting
    /// limits can also omit this field while preserving inspected text and captured stdout.
    pub value: Option<Value>,
}

/// A guest evaluation error, distinct from transport and VM failures.
#[derive(Debug)]
pub struct ScriptError {
    /// Guest error category, such as `error`, `exit`, `throw`, `timeout`, or `reductions`.
    pub kind: String,
    /// Error text formatted by the guest evaluator.
    pub message: String,
}

impl fmt::Display for ScriptError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(formatter, "{}: {}", self.kind, self.message)
    }
}

impl std::error::Error for ScriptError {}

/// What [`Vm::shutdown`] returns.
#[derive(Debug)]
#[must_use = "`result` reports execution and cleanup failures"]
#[non_exhaustive]
pub struct Shutdown {
    /// The VM's final stats, also when `result` is an error.
    pub stats: Stats,
    /// An error if the guest had already stopped, for example by running out
    /// of fuel, or if cleaning up its private root failed.
    pub result: Result<(), Error>,
}

/// Resources a VM has used, from [`Vm::stats`] or, final, from [`Vm::shutdown`].
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
#[non_exhaustive]
pub struct Stats {
    /// Fuel consumed since the VM started, including boot. Updated when the guest
    /// calls into the host and on every 10 ms epoch tick while it runs. `None`
    /// without [`VmOptions::max_fuel`]: fuel is metered only when it is limited.
    pub fuel_consumed: Option<u64>,
    /// Bytes of WebAssembly linear memory allocated. Linear memory does not shrink.
    /// The VM's compiled code and Wasmtime's own allocations are not included.
    pub memory: usize,
}

/// A running Kettlecorn VM.
///
/// A VM allocates up to `u32::MAX` request IDs for evals, calls, and casts.
/// Request IDs are never reused. Host replies do not consume these IDs. When the
/// IDs run out, further requests return [`Error::RequestIdsExhausted`].
/// Start a new VM to submit more requests.
pub struct Vm {
    client: transport::Client,
    task: JoinHandle<Result<()>>,
    cancel: Cancellation,
    usage: Arc<Usage>,
    metered: bool,
}

impl Runtime {
    /// Prepares the Wasmtime component on Tokio's blocking executor.
    ///
    /// VMs started from this runtime or its clones reuse the prepared
    /// component when `http` matches and both configurations either set or
    /// omit `max_fuel`.
    /// Dropping the future can leave preparation running to completion.
    pub async fn warm_up(&self, options: &VmOptions) -> Result<(), Error> {
        let runtime = self.clone();
        let http = crate::engine::HttpAccess::try_from(options.http.clone())
            .map_err(Error::InvalidOptions)?
            .granted();
        let fuel = options.max_fuel.is_some();
        tokio::task::spawn_blocking(move || {
            runtime
                .prepare_variant(http, fuel, &CompilationCache::default(), None)
                .map(|_| ())
        })
        .await
        .context("join runtime preparation")
        .flatten()
        .map_err(Error::Preparation)
    }

    /// Starts a VM with a fresh private root and waits for its applications to boot.
    /// Call on a Tokio runtime with I/O and time enabled.
    /// Execution runs as a Tokio task without a dedicated OS thread. Dropping the
    /// returned [`Vm`] cancels it; [`Vm::shutdown`] also waits for cleanup.
    pub async fn start(&self, mut options: VmOptions) -> Result<Vm, Error> {
        if options.frame_write_timeout.is_zero() {
            return Err(Error::InvalidOptions(anyhow!(
                "frame_write_timeout must be positive"
            )));
        }
        if Instant::now()
            .checked_add(options.frame_write_timeout)
            .is_none()
        {
            return Err(Error::InvalidOptions(anyhow!(
                "frame_write_timeout exceeds the clock range"
            )));
        }
        let max_requests = Semaphore::MAX_PERMITS.min(u32::MAX as usize);
        if options.max_pending_requests.get() > max_requests {
            return Err(Error::InvalidOptions(anyhow!(
                "max_pending_requests exceeds {max_requests}"
            )));
        }
        let http = crate::engine::HttpAccess::try_from(std::mem::take(&mut options.http))
            .map_err(Error::InvalidOptions)?;
        if options.max_host_calls.get() > Semaphore::MAX_PERMITS {
            return Err(Error::InvalidOptions(anyhow!(
                "max_host_calls exceeds {}",
                Semaphore::MAX_PERMITS
            )));
        }
        tokio::time::timeout(options.boot_timeout, self.start_vm(options, http))
            .await
            .map_err(|_| Error::BootDeadline)?
            .map_err(Error::Boot)
    }

    async fn start_vm(&self, options: VmOptions, http: crate::engine::HttpAccess) -> Result<Vm> {
        let runtime = self.clone();
        let usage = Arc::<Usage>::default();
        let metered = options.max_fuel.is_some();
        let guest_usage = usage.clone();
        let (root, guest, prepared) = tokio::task::spawn_blocking(move || {
            let root = tempfile::tempdir().context("create private VM directory")?;
            let guest = GuestOptions {
                max_memory: options.max_memory,
                max_fuel: options.max_fuel,
                max_lifetime: options.max_lifetime,
                network: options.network,
                http,
                env: [(
                    "KETTLECORN_MAX_GUEST_FRAME_BYTES".into(),
                    protocol::MAX_FRAME_BYTES.to_string(),
                )]
                .into(),
                usage: guest_usage,
                preload: options.preload,
                ..GuestOptions::new(root.path().join("root"))
            };
            runtime.populate_root(
                &guest.root,
                &RootOptions {
                    app: options.app_dir,
                    ..RootOptions::default()
                },
            )?;
            let prepared = runtime.prepare(&guest)?;
            Ok::<_, anyhow::Error>((root, guest, prepared))
        })
        .await??;

        let (mut streams, peer) = Streams::memory(NonZeroUsize::new(STREAM_BYTES).unwrap());
        let stdout = options.stdout;
        let stderr = options.stderr;
        let raw_stderr = stderr.as_ref().map(|_| {
            let (reader, writer) = tokio::io::duplex(STREAM_BYTES);
            streams.stderr = Box::new(AsyncStdoutStream::new(STREAM_BYTES, writer));
            reader
        });
        let (client, inbox) =
            transport::Client::new(options.max_pending_requests.get(), options.events);
        let (accepting, ready) = oneshot::channel();
        let cancel = Cancellation::default();
        let stop = cancel.clone();
        let callbacks = transport::Callbacks {
            functions: options.functions,
            deadline: options.host_call_timeout,
            capacity: options.max_host_calls.get(),
        };
        let task = tokio::spawn(async move {
            // The transport and its pending callbacks end before root cleanup.
            let result = {
                let mut relay = tokio::spawn(relay_stderr(raw_stderr, stderr.clone()));
                let (exit, exited) = oneshot::channel();
                let transport = transport::run(
                    peer,
                    inbox,
                    accepting,
                    callbacks,
                    options.frame_write_timeout,
                    transport::Output {
                        stdout,
                        stderr,
                        late_loads: options.late_loads,
                    },
                    exited,
                );
                tokio::pin!(transport);
                let result = tokio::select! {
                    biased;
                    _ = stop.cancelled() => Ok(()),
                    outcome = prepared.run(guest, streams, stop.clone()) => {
                        // The guest's last frames and stderr can still be buffered.
                        let _ = exit.send(());
                        // A frame the transport has read is kept even if stderr is still draining.
                        let deadline = Instant::now() + DRAIN_TIMEOUT;
                        let drained = tokio::time::timeout_at(deadline, &mut transport).await;
                        let _ = tokio::time::timeout_at(deadline, &mut relay).await;
                        Err(exit_error(outcome, drained.unwrap_or(Ok(()))))
                    }
                    result = &mut transport => result,
                };
                relay.abort();
                result
            };
            let cleanup = tokio::task::spawn_blocking(move || root.close()).await;
            result.and_then(|()| Ok(cleanup??))
        });
        let mut vm = Vm {
            client,
            task,
            cancel,
            usage,
            metered,
        };
        if ready.await.is_err() {
            let error = vm
                .join()
                .await
                .err()
                .unwrap_or_else(|| anyhow!("guest is stopped"));
            return Err(error);
        }
        Ok(vm)
    }
}

impl Vm {
    /// Evaluates code with the supplied bindings. A script error appears in
    /// `Evaluation::result` alongside captured output. A proxy or transport
    /// failure returns `Error`.
    pub async fn eval(&self, code: &str, options: EvalOptions) -> Result<Evaluation, Error> {
        let timeout = timeout_ms(options.timeout)?;
        let proxy_timeout = timeout
            .checked_add(REPLY_MARGIN_MS)
            .context("evaluation timeout exceeds the guest limit")
            .map_err(Error::InvalidRequest)?;
        let language = match options.language {
            Language::Elixir => "elixir",
            Language::Erlang => "erlang",
        };
        let binding = options
            .binding
            .into_iter()
            .map(|(name, value)| (Value::from(name), value));
        let max_reductions = match options.max_reductions {
            Some(limit) if i64::try_from(limit.get()).is_err() => {
                return Err(Error::InvalidRequest(anyhow!(
                    "max_reductions exceeds the guest limit"
                )));
            }
            Some(limit) => Value::Integer(limit.get().into()),
            None => Value::atom("infinity"),
        };
        let value = Value::Tuple(vec![
            Value::atom("eval"),
            Value::binary(code),
            Value::map([
                (Value::binary("timeout_ms"), Value::Integer(timeout.into())),
                (Value::binary("max_reductions"), max_reductions),
                (
                    Value::binary("finish_timeout_ms"),
                    Value::Integer((REPLY_MARGIN_MS / 2).into()),
                ),
                (Value::binary("binding"), Value::map(binding)),
                (Value::binary("language"), Value::binary(language)),
                (
                    Value::binary("value_limits"),
                    protocol::evaluation_value_limits(),
                ),
            ]),
        ]);
        let value = self
            .proxy_call("kettlecorn_evaluator", value, proxy_timeout)
            .await?;
        evaluation(value).map_err(Error::Protocol)
    }

    /// Calls a registered guest process with a five-second guest timeout.
    pub async fn call(&self, name: &str, request: Value) -> Result<Value, Error> {
        self.call_with_timeout(name, request, DEFAULT_TIMEOUT).await
    }

    /// Calls a registered guest process with the supplied guest timeout.
    /// The host waits an additional reply margin. Durations are truncated to milliseconds
    /// and must fit in `u32` milliseconds; the default [`Vm::call`] timeout is five seconds.
    pub async fn call_with_timeout(
        &self,
        name: &str,
        request: Value,
        timeout: Duration,
    ) -> Result<Value, Error> {
        self.proxy_call(name, request, timeout_ms(timeout)?).await
    }

    async fn proxy_call(&self, name: &str, request: Value, timeout: u32) -> Result<Value, Error> {
        let budget = Duration::from_millis(u64::from(timeout) + u64::from(REPLY_MARGIN_MS));
        let reply = self
            .client
            .request(Instant::now() + budget, budget, false, |id| {
                protocol::call(id, name, request, timeout)
            })
            .await?;
        let (status, result) = reply.into_pair().map_err(Error::Protocol)?;
        match status.as_atom() {
            Some("ok") => Ok(result),
            Some("error") if result.as_atom() == Some("timeout") => Err(Error::Deadline),
            Some("error") => Err(Error::GuestCall(result)),
            _ => Err(Error::Protocol(anyhow!("invalid proxy reply"))),
        }
    }

    /// Waits for delivery to the guest proxy. The proxy forwards the cast
    /// if the target is registered and discards it otherwise.
    pub async fn cast(&self, name: &str, request: Value) -> Result<(), Error> {
        self.client
            .request(
                Instant::now() + DEFAULT_TIMEOUT,
                DEFAULT_TIMEOUT,
                true,
                |id| protocol::cast(id, name, request),
            )
            .await
            .map(|_| ())
    }

    /// Receives future `Kettlecorn.Host.send/1` events. A lagging receiver
    /// gets `broadcast::error::RecvError::Lagged` with the number it missed.
    pub fn subscribe(&self) -> broadcast::Receiver<Value> {
        self.client.subscribe()
    }

    /// Reports the fuel and memory the VM has used so far.
    pub fn stats(&self) -> Stats {
        Stats {
            fuel_consumed: self.metered.then(|| self.usage.fuel()),
            memory: self.usage.memory(),
        }
    }

    /// Cancels the guest, waits for execution and private-root cleanup, and
    /// returns the VM's final stats with the result.
    pub async fn shutdown(mut self) -> Shutdown {
        self.client.close();
        self.cancel.cancel();
        let result = self.join().await.map_err(Error::Execution);
        Shutdown {
            stats: self.stats(),
            result,
        }
    }

    async fn join(&mut self) -> Result<()> {
        (&mut self.task).await?
    }
}

impl Drop for Vm {
    fn drop(&mut self) {
        self.client.close();
        self.cancel.cancel();
    }
}

/// A terminal frame read while draining, such as a fatal error, explains the
/// exit better than the execution outcome, as it does when read before exit.
fn exit_error(outcome: ExecutionOutcome, drained: Result<()>) -> anyhow::Error {
    match (drained, outcome) {
        (Err(error), _) => error,
        (Ok(()), ExecutionOutcome::Failed { error }) => error.context("guest execution failed"),
        (Ok(()), other) => anyhow!("guest stopped: {other:?}"),
    }
}

async fn relay_stderr(stream: Option<DuplexStream>, sender: Option<mpsc::Sender<Vec<u8>>>) {
    if let (Some(mut stream), Some(sender)) = (stream, sender) {
        let mut buffer = [0; 8192];
        while let Ok(size @ 1..) = stream.read(&mut buffer).await {
            let _ = sender.try_send(buffer[..size].to_vec());
        }
    }
}

fn timeout_ms(timeout: Duration) -> Result<u32, Error> {
    u32::try_from(timeout.as_millis())
        .context("timeout exceeds the guest limit")
        .map_err(Error::InvalidRequest)
}

fn evaluation(value: Value) -> Result<Evaluation> {
    let (status, result) = value.into_pair()?;
    let Value::Map(mut fields) = result else {
        bail!("invalid evaluation result");
    };
    let output = text(&mut fields, "output")?;
    let output_truncated = fields
        .remove(&Value::binary("output_truncated"))
        .as_ref()
        .and_then(Value::as_atom)
        == Some("true");
    let reductions = match fields.remove(&Value::binary("reductions")) {
        Some(Value::Integer(reductions)) => u64::try_from(&reductions).ok(),
        _ => None,
    }
    .context("missing or invalid evaluation field reductions")?;
    let result = match status.as_atom() {
        Some("ok") => Ok(EvalValue {
            inspected: text(&mut fields, "inspected")?,
            value: fields.remove(&Value::binary("value")),
        }),
        Some("error") => Err(ScriptError {
            kind: text(&mut fields, "kind")?,
            message: text(&mut fields, "message")?,
        }),
        _ => bail!("invalid evaluation status"),
    };
    Ok(Evaluation {
        output,
        output_truncated,
        reductions,
        result,
    })
}

fn text(fields: &mut BTreeMap<Value, Value>, key: &str) -> Result<String> {
    fields
        .remove(&Value::binary(key))
        .and_then(Value::into_string)
        .with_context(|| format!("missing or invalid evaluation field {key}"))
}
