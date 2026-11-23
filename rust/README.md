# Kettlecorn

Kettlecorn lets Rust applications run untrusted Elixir and Erlang in a
WebAssembly sandbox. Evaluate code, call guest GenServers, and expose async
Rust functions to the guest.

The crate embeds Wasmtime in your application process. Each VM has a private
filesystem, and network access is off by default.

It uses the same guest runtime as [Kettlecorn's Elixir package](https://hex.pm/packages/kettlecorn).
Running guest code requires no host Elixir installation.

## Quickstart

Runtime releases support x86_64 and ARM64 Linux, and Apple silicon macOS.
In a Cargo binary project, add these dependencies:

```sh
cargo add kettlecorn --features installer
cargo add tokio --features rt,net,time
cargo add anyhow
```

Put this in `src/main.rs`:

```rust
use kettlecorn::{EvalOptions, Runtime, VmOptions};
use std::time::Duration;

fn main() -> anyhow::Result<()> {
    let runtime = Runtime::install()?;

    tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()?
        .block_on(async {
            let mut options = VmOptions::default();
            options.max_fuel = Some(50_000_000_000);
            options.max_lifetime = Some(Duration::from_secs(30));
            let vm = runtime.start(options).await?;
            let evaluation = vm
                .eval(
                    r#"IO.puts("Hello from Elixir"); Enum.sum(1..10)"#,
                    EvalOptions::default(),
                )
                .await;
            vm.shutdown().await.result?;

            let evaluation = evaluation?;
            print!("{}", evaluation.output);
            println!("{}", evaluation.result?.inspected);
            Ok(())
        })
}
```

Run `cargo run`. It downloads and verifies the matching runtime if none is
installed, or reuses the cached installation. The program prints:

```text
Hello from Elixir
55
```

`Runtime::install` blocks, so this example calls it before entering Tokio.
`Runtime::start`, `Vm::eval`, and `Vm::shutdown` are async.

Evaluation returns captured stdout and either a script error or an `EvalValue`.
The value includes its inspected text and an optional structured `Value`.
The structured value is omitted for unsupported types or results that exceed
the evaluation limits. Script errors appear in `Evaluation::result`; failures
to deliver a request or communicate with the VM return an outer `Error`.
The example waits for shutdown before propagating an evaluation error.

## Working with a VM

A VM keeps its modules, processes, and files across evaluations. Load code
once, start supervised processes, and reuse the VM for later requests.
Use separate VMs for mutually untrusted tenants.

* `Vm::eval` evaluates Elixir or Erlang with optional bindings. Set
  `EvalOptions::language` to `Language::Erlang` for Erlang code.
* `Vm::call` and `Vm::cast` send requests to registered guest processes.
  Calls return a reply; casts wait for delivery to the guest proxy.
* `Vm::subscribe` receives messages sent by `Kettlecorn.Host.send/1`.

Register async Rust functions with `VmOptions::register` before starting
the VM. Guest code calls them through `Kettlecorn.Host.call/3`. The
[Device Monitor example](https://github.com/mjrusso/kettlecorn/tree/main/examples/rust/device-monitor)
shows both guest GenServer calls and Rust callbacks.

To run a packaged Mix application, set `VmOptions::app_dir` to its cooked
bundle directory. Cooking requires a host Elixir installation matching the
runtime's Elixir version and OTP major release. See
[cooking Mix applications](https://github.com/mjrusso/kettlecorn/blob/main/host/guides/running-applications.md#cooking-mix-applications)
for the build step.

`Vm::shutdown` cancels execution, waits for the VM's private filesystem
to be removed, and returns a `Shutdown` with the VM's final `stats` and a
`result`. The result is an error if the guest had already stopped, for
example by running out of fuel. Dropping the VM requests cancellation; use
`shutdown` when you need to wait for cleanup.

```rust
let shutdown = vm.shutdown().await;
println!("Final linear memory: {} bytes", shutdown.stats.memory);
shutdown.result?;
```

Call `vm.stats()` to read counters while the VM is running.

## Runtime setup and deployment

The runtime is separate from the crate and contains OTP, Elixir, and the
guest filesystem. Include it in your deployment or install it before
starting VMs.

| Method | Use |
|---|---|
| `Runtime::install()` | Download a matching release or reuse the cached installation; requires the `installer` feature |
| `Runtime::install_from_archive(path)` | Install a release archive already on disk into the cache, for hosts without network access; requires the `installer` feature |
| `Runtime::find()` | Load a runtime from the environment or user cache without downloading |
| `Runtime::load(path)` | Load a runtime bundled with your application or built locally |

`Runtime::find` checks `KETTLECORN_RUNTIME` first, then the versioned cache
shared with `mix kettlecorn.install`. An invalid environment override returns
an error without falling back to the cache. If the cache entry is absent,
it returns `Error::RuntimeNotFound`.

On Linux, the cache is under `$XDG_CACHE_HOME` or `~/.cache`. On macOS, it is
under `~/Library/Caches`. Both use `kettlecorn/runtime-<version>` within that
directory. Cached releases must match the crate version and host platform.

The installer verifies the release archive's SHA-256 against the checksum
shipped with the crate before installing it atomically in the cache, for a
download or an archive on disk. See
[offline deployment](https://github.com/mjrusso/kettlecorn/blob/main/host/guides/running-applications.md#offline-deployment). It leaves
invalid cache entries in place; move an invalid entry aside before retrying.
`Runtime::install_with_progress` reports cumulative downloaded bytes and an
optional total byte count. Both installation methods block; call them on a
background thread from an async application or GUI.

All three loading methods require the runtime's protocol and Wasmtime
versions to match the crate. A Wasmtime mismatch returns
`Error::IncompatibleEngine`. See [runtime releases](https://github.com/mjrusso/kettlecorn/releases)
for downloadable archives.

## Execution and limits

Rust VMs run as Tokio tasks in your application process. They have no
dedicated OS thread. Each guest executes on one OS thread at a time;
separate VMs can execute in parallel on a multithreaded Tokio runtime.
The quickstart uses a single-threaded runtime. See [the architecture guide](https://github.com/mjrusso/kettlecorn/blob/main/host/guides/architecture.md#threads)
for scheduling details.

`VmOptions` defaults to a 512 MiB WebAssembly memory limit, with socket and
HTTP access disabled. Fuel and lifetime limits are opt-in; the quickstart
sets both. Set `network: true` for sockets and DNS, or `http: true` for guest
HTTP requests through WASI. The `http` Cargo feature supplies HTTP support
and is enabled by default; granting access to an individual VM is separate.

Kettlecorn uses experimental Wasmtime component-model threading. Review
[sandbox limits and network grants](https://github.com/mjrusso/kettlecorn/blob/main/host/guides/sandbox.md)
before running untrusted workloads. The memory limit covers WebAssembly
linear memory; host memory and disk use need separate controls.

Reuse a loaded `Runtime` across VMs to share prepared components. Call
`Runtime::warm_up(&options)` to prepare a component before starting the first
VM. Preparation is reused when the HTTP setting and the presence of a fuel
limit match.

### Preload and evaluation budgets

```rust
use kettlecorn::{EvalOptions, Preload, VmOptions};
use std::num::NonZeroU64;
use tokio::sync::mpsc;

let (late_loads, mut reports) = mpsc::channel(16);
let mut options = VmOptions::default();
options.preload = Preload::Strict;
options.late_loads = Some(late_loads);

let vm = runtime.start(options).await?;
let evaluation = vm.eval("Enum.sum(1..10)", EvalOptions {
    max_reductions: NonZeroU64::new(20_000),
    ..Default::default()
}).await?;
```

Read module names from `reports`. Strict mode stops the VM on an on-demand load
after preloading, including while applications start. When `late_loads` is unset, diagnostics go to a configured
`VmOptions::stderr` channel. Full channels drop reports.

`max_reductions` limits one evaluation and its descendants. Read the
charged count from `evaluation.reductions`. If a scheduler charge exceeds
the limit, `evaluation.result` holds an error with kind `reductions`.

## Examples and API reference

| Example | Demonstrates |
|---|---|
| [Hello World](https://github.com/mjrusso/kettlecorn/tree/main/examples/rust/hello-world) | Basic VM startup, evaluation, and shutdown |
| [Device Monitor](https://github.com/mjrusso/kettlecorn/tree/main/examples/rust/device-monitor) | Stateful Elixir plugins, guest GenServer calls, and async Rust callbacks |
| [Pulse Field](https://github.com/mjrusso/kettlecorn/tree/main/examples/rust/pulse-field) | A native graphical application driven by Elixir scripts |

See [example instructions](https://github.com/mjrusso/kettlecorn/blob/main/examples/README.md#rust-projects)
for running these projects, and [docs.rs](https://docs.rs/kettlecorn) for the API reference.
