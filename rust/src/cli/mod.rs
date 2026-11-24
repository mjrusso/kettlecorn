mod fd;
mod terminal;

use crate::engine::{
    Cancellation, CompilationCache, ExecutionOutcome, GuestOptions, HttpAccess, Mode,
    NetworkAccess, NetworkRules, Preload, RootOptions, Runtime, Usage, WASMTIME_VERSION,
    streams::Streams,
};
use anyhow::{Context, Result};
use clap::Parser;
use std::collections::BTreeMap;
use std::ffi::OsStr;
use std::fs::File;
use std::os::fd::AsRawFd;
use std::os::unix::ffi::OsStrExt;
use std::path::PathBuf;
use std::sync::{
    Arc,
    atomic::{AtomicBool, AtomicI32, Ordering},
};
use std::time::Duration;

#[derive(Parser)]
#[command(
    name = "kettlecorn-launcher",
    version,
    about = "Run a Kettlecorn guest with the bundled Wasmtime engine"
)]
struct Args {
    /// Platform runtime directory containing the launcher and guest files
    #[arg(long)]
    runtime: PathBuf,
    /// Private writable guest root; a new destination with --prepare-root
    #[arg(long)]
    root: PathBuf,
    /// Populate a new private guest root and exit without running a guest
    #[arg(long)]
    prepare_root: bool,
    /// Copy a cooked application into the new root at /app
    #[arg(long, requires = "prepare_root")]
    app_dir: Option<PathBuf>,
    /// Copy this PEM bundle to the runtime-defined guest certificate path
    #[arg(long, requires = "prepare_root")]
    certificates: Option<PathBuf>,
    /// Copy a host directory to an absolute guest path in the new root
    #[arg(long, num_args = 2, value_names = ["SOURCE", "GUEST_PATH"], requires = "prepare_root")]
    copy_dir: Vec<PathBuf>,
    /// Copy a host file to an absolute guest path in the new root
    #[arg(long, num_args = 2, value_names = ["SOURCE", "GUEST_PATH"], requires = "prepare_root")]
    copy_file: Vec<PathBuf>,
    /// Use the framed host protocol; closing stdin cancels the guest
    #[arg(long, conflicts_with = "iex")]
    framed: bool,
    /// Write launcher diagnostics here and termination JSON to this path with a .stopped suffix
    #[arg(long)]
    stderr: Option<PathBuf>,
    /// Create this file and keep the fuel and memory the guest has used in it
    #[arg(long)]
    stats: Option<PathBuf>,
    /// Deliver guest output over bounded records on a private Unix socket
    #[arg(long, requires = "framed")]
    output_socket: Option<PathBuf>,
    /// Maximum WebAssembly linear memory in bytes; unlimited if omitted
    #[arg(long)]
    max_memory: Option<usize>,
    /// Execution budget in Wasmtime fuel units, including guest boot; unlimited if omitted
    #[arg(long)]
    fuel: Option<u64>,
    /// Lifetime in milliseconds, including component preparation, guest boot, and output draining;
    /// unlimited if omitted
    #[arg(long)]
    lifetime_ms: Option<u64>,
    /// Lifetime as a duration such as 2s or 500ms, including component preparation, guest boot,
    /// and output draining
    #[arg(long, conflicts_with = "lifetime_ms", value_parser = humantime::parse_duration)]
    timeout: Option<Duration>,
    /// Allow TCP/UDP sockets and DNS to any reachable destination, including loopback, internal,
    /// and metadata addresses (`--network-allow public` allows public addresses only)
    #[arg(long, conflicts_with = "network_allow")]
    network: bool,
    /// Allow sockets and DNS only for this destination (repeatable): a host name,
    /// `*.domain`, an address or CIDR range (IPv6 in brackets), or `public`, with
    /// an optional `:port`
    #[arg(long, value_name = "RULE")]
    network_allow: Vec<crate::NetworkRule>,
    /// Allow outgoing HTTP to any reachable destination using compiled Mozilla roots
    #[arg(long, conflicts_with = "http_allow")]
    http: bool,
    /// Allow outgoing HTTP only to this destination (repeatable): a host name,
    /// `*.domain`, or an address or CIDR range, with an optional `:port`
    #[arg(long, value_name = "RULE")]
    http_allow: Vec<crate::NetworkRule>,
    /// Start an interactive guest IEx session
    #[arg(long)]
    iex: bool,
    /// Number of guest BEAM schedulers; all share one execution thread
    #[arg(long, default_value_t = 1)]
    schedulers: usize,
    /// Set a guest environment variable as NAME=value; may be repeated
    #[arg(long = "env", value_parser = environment)]
    env: Vec<(String, String)>,
    /// Preload modules on the boot-time code path (on), or also stop the guest
    /// on a later on-demand load (strict)
    #[arg(long, value_parser = preload)]
    preload: Option<Preload>,
    /// Start an extra application at boot; may be repeated
    #[arg(long = "app")]
    apps: Vec<String>,
    /// Add a path already inside the guest root to its code path; may be repeated
    #[arg(long = "code-path")]
    code_paths: Vec<String>,
    /// Add an emulator argument with a dash in place of erl's plus sign; may be repeated
    #[arg(long = "emulator-arg", allow_hyphen_values = true)]
    emulator_flags: Vec<String>,
    /// Compile without reading or writing the persistent component cache
    #[arg(long)]
    no_cache: bool,
    /// Use this private directory for compiled components
    #[arg(long)]
    cache_dir: Option<PathBuf>,
    /// Print a command for manual debugging with the matching Wasmtime CLI and exit
    #[arg(long)]
    print_wasmtime_command: bool,
    /// Guest Elixir arguments, such as -e CODE or a script path
    #[arg(last = true)]
    args: Vec<String>,
}

fn preload(value: &str) -> Result<Preload, String> {
    match value {
        "on" => Ok(Preload::On),
        "strict" => Ok(Preload::Strict),
        _ => Err("preload must be on or strict".into()),
    }
}

fn environment(value: &str) -> Result<(String, String), String> {
    let (name, value) = value
        .split_once('=')
        .ok_or("environment must be NAME=value")?;
    if name.is_empty() {
        return Err("empty environment name".into());
    }
    Ok((name.into(), value.into()))
}

struct Stopped {
    path: Option<PathBuf>,
    outcome: ExecutionOutcome,
    usage: Arc<Usage>,
    metered: bool,
}

/// The termination record in `PROTOCOL.md`.
#[derive(serde::Serialize)]
struct Record<'a> {
    #[serde(flatten)]
    outcome: &'a ExecutionOutcome,
    #[serde(skip_serializing_if = "Option::is_none")]
    fuel_consumed: Option<u64>,
    memory: usize,
}

impl Drop for Stopped {
    fn drop(&mut self) {
        if let Some(path) = &self.path {
            let record = Record {
                outcome: &self.outcome,
                fuel_consumed: self.metered.then(|| self.usage.fuel()),
                memory: self.usage.memory(),
            };
            let result = (|| -> Result<()> {
                let temporary = path.with_extension("tmp");
                std::fs::write(&temporary, serde_json::to_vec(&record)?)?;
                std::fs::rename(temporary, path)?;
                Ok(())
            })();
            if let Err(error) = result {
                eprintln!("publish termination result: {error:#}");
            }
        }
    }
}

struct Watcher(Arc<AtomicBool>);
impl Drop for Watcher {
    fn drop(&mut self) {
        self.0.store(true, Ordering::Release);
    }
}

fn watch_port(cancel: Cancellation) -> Watcher {
    let finished = Arc::new(AtomicBool::new(false));
    let done = finished.clone();
    std::thread::spawn(move || {
        while !done.load(Ordering::Acquire) {
            // macOS needs POLLHUP in events to watch closure with unread input.
            let mut fd = libc::pollfd {
                fd: 0,
                events: libc::POLLHUP,
                revents: 0,
            };
            let result = unsafe { libc::poll(&mut fd, 1, 100) };
            if result > 0 && fd.revents & (libc::POLLHUP | libc::POLLERR | libc::POLLNVAL) != 0 {
                cancel.cancel();
                return;
            }
        }
    });
    Watcher(finished)
}

/// The Wasmtime CLI has no HTTP proxies. The proxy settings are read only
/// with the HTTP grant, as when the VM runs.
fn check_http_proxy(
    options: &GuestOptions,
    http_proxy: impl FnOnce() -> Result<bool>,
) -> Result<()> {
    anyhow::ensure!(
        !(options.http.granted() && http_proxy()?),
        "the Wasmtime command can't send HTTP through the proxy in this environment"
    );
    Ok(())
}

fn access(any: bool, rules: Vec<crate::NetworkRule>) -> NetworkAccess {
    match (any, NetworkRules::new(rules)) {
        (true, _) => NetworkAccess::Any,
        (false, None) => NetworkAccess::Denied,
        (false, Some(rules)) => NetworkAccess::Only(rules),
    }
}

async fn execute(args: Args, usage: Arc<Usage>) -> Result<ExecutionOutcome> {
    let runtime = Runtime::load(&args.runtime)?;
    let mut options = GuestOptions::new(&args.root);
    options.usage = usage;
    options.framed = args.framed;
    options.mode = if args.framed {
        Mode::Boot
    } else {
        Mode::Cli {
            iex: args.iex,
            args: args.args,
        }
    };
    options.max_memory = args.max_memory;
    options.max_fuel = args.fuel;
    options.max_lifetime = args
        .timeout
        .or_else(|| args.lifetime_ms.map(Duration::from_millis));
    options.network = access(args.network, args.network_allow);
    options.http = HttpAccess::try_from(access(args.http, args.http_allow))?;
    options.schedulers = args.schedulers;
    options.env = args.env.into_iter().collect::<BTreeMap<_, _>>();
    options.apps = args.apps;
    options.preload = args.preload.unwrap_or_default();
    options.code_paths = args.code_paths;
    options.emulator_flags = args.emulator_flags;
    options.blocking_filesystem = options.max_lifetime.is_none();
    if args.no_cache {
        options.cache = CompilationCache::Disabled;
    } else if let Some(directory) = args.cache_dir {
        options.cache = CompilationCache::Directory(directory);
    }
    runtime.validate(&options)?;
    let terminal = if !args.framed {
        terminal::Terminal::new(&options.root)?
    } else {
        None
    };
    if let Some(terminal) = &terminal {
        options
            .env
            .insert("KETTLECORN_TTY_SIZE".into(), terminal.guest_path.clone());
    }
    if args.print_wasmtime_command {
        let command = runtime.wasmtime_command(&options)?;
        check_http_proxy(&options, crate::engine::http_proxy_configured)?;
        println!("# Wasmtime {WASMTIME_VERSION}; root must be a private writable copy");
        println!(
            "{}",
            command
                .iter()
                .map(|arg| format!("'{}'", arg.replace('\'', "'\\''")))
                .collect::<Vec<_>>()
                .join(" ")
        );
        return Ok(ExecutionOutcome::Exited { code: 0 });
    }
    let cancel = Cancellation::default();
    let _watcher = args.framed.then(|| watch_port(cancel.clone()));
    let signal_status = Arc::new(AtomicI32::new(0));
    let signal_value = signal_status.clone();
    let stopped = cancel.clone();
    let mut interrupt = tokio::signal::unix::signal(tokio::signal::unix::SignalKind::interrupt())?;
    let mut terminate = tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate())?;
    let mut quit = tokio::signal::unix::signal(tokio::signal::unix::SignalKind::quit())?;
    let mut resize = tokio::signal::unix::signal(tokio::signal::unix::SignalKind::window_change())?;
    let resizing = tokio::spawn(async move {
        while resize.recv().await.is_some() {
            if let Some(terminal) = &terminal {
                let _ = terminal.update();
            }
        }
    });
    let signals = tokio::spawn(async move {
        let status = tokio::select! {
            _ = interrupt.recv() => 130,
            _ = terminate.recv() => 143,
            _ = quit.recv() => 131,
        };
        signal_value.store(status, Ordering::Release);
        stopped.cancel();
    });
    let output = if let Some(path) = args.output_socket {
        use std::io::Write;
        let listener = tokio::net::UnixListener::bind(path)?;
        let mut ready = std::io::stdout().lock();
        ready.write_all(&[0])?;
        ready.flush()?;
        drop(ready);
        let (socket, _) = tokio::select! {
            biased;
            _ = cancel.cancelled() => return Ok(ExecutionOutcome::Cancelled),
            result = listener.accept() => result?,
        };
        Some(socket.into_std()?)
    } else {
        None
    };
    let (stdout, pump) = fd::output(
        output.as_ref().map_or(1, AsRawFd::as_raw_fd),
        output.is_some(),
    )?;
    let streams = Streams::new(fd::FdStream::new(0)?, stdout, fd::FdStream::new(2)?);
    let deadline = options
        .max_lifetime
        .map(|duration| tokio::time::Instant::now() + duration);
    let execution = async {
        if cancel.is_cancelled() {
            return Ok(ExecutionOutcome::Cancelled);
        }
        let (prepared, options) = tokio::task::spawn_blocking(move || {
            runtime
                .prepare(&options)
                .map(|prepared| (prepared, options))
        })
        .await??;
        Ok(prepared.run(options, streams, cancel.clone()).await)
    };
    let deadline = async {
        match deadline {
            Some(end) => tokio::time::sleep_until(end).await,
            None => std::future::pending::<()>().await,
        }
    };
    tokio::pin!(pump, deadline);
    let result = tokio::select! {
        biased;
        _ = cancel.cancelled() => Ok(ExecutionOutcome::Cancelled),
        _ = &mut deadline => Ok(ExecutionOutcome::Timeout),
        result = execution => result,
        ended = &mut pump => { ended?; anyhow::bail!("stdout closed before guest exit"); }
    };
    let result = match result {
        Ok(outcome @ ExecutionOutcome::Exited { .. }) => tokio::select! {
            biased;
            _ = cancel.cancelled() => Ok(ExecutionOutcome::Cancelled),
            _ = &mut deadline => Ok(ExecutionOutcome::Timeout),
            drained = &mut pump => drained.map(|()| outcome).map_err(Into::into),
        },
        other => other,
    };
    signals.abort();
    resizing.abort();
    let status = signal_status.load(Ordering::Acquire);
    if status != 0 {
        Ok(ExecutionOutcome::Exited { code: status })
    } else {
        result
    }
}

pub fn main() {
    // Establish the error sink and marker before argument validation, so a
    // malformed host invocation still confirms termination to Kettlecorn.VM.
    let raw = std::env::args_os().collect::<Vec<_>>();
    let end = raw.iter().position(|arg| arg == "--").unwrap_or(raw.len());
    let stderr = raw[..end].iter().enumerate().find_map(|(index, arg)| {
        if arg == "--stderr" {
            raw.get(index + 1).map(PathBuf::from)
        } else {
            arg.as_bytes()
                .strip_prefix(b"--stderr=")
                .map(|bytes| PathBuf::from(OsStr::from_bytes(bytes)))
        }
    });
    let mut marker = Stopped {
        path: stderr.as_ref().map(|path| {
            let mut marker = path.as_os_str().to_os_string();
            marker.push(".stopped");
            PathBuf::from(marker)
        }),
        outcome: ExecutionOutcome::Failed {
            error: anyhow::anyhow!("launcher did not complete"),
        },
        usage: Arc::default(),
        metered: false,
    };
    let result = (|| -> Result<ExecutionOutcome> {
        if let Some(path) = &stderr {
            let file = File::create(path).context("stderr file")?;
            if unsafe { libc::dup2(file.as_raw_fd(), 2) } < 0 {
                return Err(std::io::Error::last_os_error().into());
            }
        }
        let args = match Args::try_parse_from(raw) {
            Ok(args) => args,
            Err(error) => {
                let status = error.exit_code();
                error.print()?;
                return Ok(ExecutionOutcome::Exited { code: status });
            }
        };
        if args.prepare_root {
            let root_options = RootOptions {
                app: args.app_dir,
                certificates: args.certificates,
                directories: args
                    .copy_dir
                    .as_chunks::<2>()
                    .0
                    .iter()
                    .map(|pair| (pair[0].clone(), pair[1].clone()))
                    .collect(),
                files: args
                    .copy_file
                    .as_chunks::<2>()
                    .0
                    .iter()
                    .map(|pair| (pair[0].clone(), pair[1].clone()))
                    .collect(),
            };
            Runtime::load(&args.runtime)?.populate_root(&args.root, &root_options)?;
            return Ok(ExecutionOutcome::Exited { code: 0 });
        }
        if let Some(path) = &args.stats {
            marker.usage = Arc::new(Usage::published(path)?);
        }
        marker.metered = args.fuel.is_some();
        let _stdio_flags = fd::StatusFlags::capture(&[0, 1, 2])?;
        let runtime = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()?;
        let result = runtime.block_on(execute(args, marker.usage.clone()));
        // Cold compilation is blocking work; port closure must not wait for it.
        runtime.shutdown_background();
        result
    })();
    marker.outcome = result.unwrap_or_else(|error| ExecutionOutcome::Failed { error });
    let status = match &marker.outcome {
        ExecutionOutcome::Exited { code } => *code,
        ExecutionOutcome::Cancelled => 0,
        ExecutionOutcome::Timeout => {
            eprintln!("guest execution timed out");
            1
        }
        ExecutionOutcome::OutOfFuel => {
            eprintln!("guest exhausted its fuel");
            1
        }
        ExecutionOutcome::Failed { error } => {
            eprintln!("{error:#}");
            1
        }
    };
    drop(marker);
    std::process::exit(status);
}

#[cfg(test)]
mod tests {
    #[test]
    fn the_wasmtime_command_refuses_an_http_proxy() {
        use super::{GuestOptions, HttpAccess, NetworkAccess, check_http_proxy as check};
        let mut options = GuestOptions::new("/root");
        options.http = HttpAccess::try_from(NetworkAccess::Any).unwrap();
        assert!(check(&options, || Ok(false)).is_ok());
        assert!(check(&options, || Ok(true)).is_err());
        // Without the grant, the proxy settings aren't read, even if invalid.
        options.http = HttpAccess::default();
        assert!(check(&options, || anyhow::bail!("invalid HTTP proxy")).is_ok());
    }

    use super::*;

    #[test]
    fn termination_records_carry_final_usage() {
        let record = |outcome, fuel_consumed| {
            serde_json::to_string(&Record {
                outcome: &outcome,
                fuel_consumed,
                memory: 65_536,
            })
            .unwrap()
        };
        assert_eq!(
            record(ExecutionOutcome::OutOfFuel, Some(1_000)),
            r#"{"outcome":"out_of_fuel","fuel_consumed":1000,"memory":65536}"#
        );
        assert_eq!(
            record(ExecutionOutcome::Exited { code: 3 }, None),
            r#"{"outcome":"exited","code":3,"memory":65536}"#
        );
    }
}
