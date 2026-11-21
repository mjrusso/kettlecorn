![Kettlecorn logo](site/assets/kettlecorn.png)

[![Hex][kettlecorn-hex-badge]][kettlecorn-hex] [![HexDocs][docs-badge]][kettlecorn-docs]
[![crates.io][kettlecorn-crate-badge]][kettlecorn-crate] [![Rust docs][rust-docs-badge]][kettlecorn-rust-docs]

# Kettlecorn

***This is your BEAM on WASI.***

Kettlecorn runs untrusted Elixir and Erlang in a WebAssembly sandbox.
Use it from Elixir or Rust to isolate user code, plugins, or whole Mix
applications.

> [!WARNING]
>
> Kettlecorn is experimental. It enables Wasmtime's [component-model
> threading](https://docs.wasmtime.dev/stability-wasm-proposals.html#component-model-proposals),
> an unfinished feature that Wasmtime leaves off by default.
>
> Bugs in Kettlecorn or its dependencies may compromise isolation. Set finite
> `max_fuel` and `max_lifetime` limits for untrusted workloads, and apply separate
> controls to host memory and disk use. See [sandbox limits and network
> grants](host/guides/sandbox.md).

Each VM runs OTP 29 and Elixir 1.20 in [Wasmtime](https://wasmtime.dev) with a
private filesystem. The Elixir API and CLI run VMs in separate launcher
processes. The Rust crate runs VMs inside your application process.

VMs retain modules, processes, and state across evaluations. Start supervised
processes, call guest GenServers, exchange messages, and expose selected
host operations.

Network access is off by default. Set `max_memory` to cap guest memory,
`max_fuel` to limit execution, and `max_lifetime` to bound elapsed time. Fuel
is measured roughly in WebAssembly instructions; fuel and lifetime limits
cover guest startup and all evaluations.

## Getting started

### In an Elixir application

Requires Elixir 1.20 or later on x86_64 or ARM64 Linux, or Apple silicon macOS.
Add Kettlecorn to your Mix dependencies:

```elixir
{:kettlecorn, "~> 0.2"}
```

Fetch the dependency and install the runtime:

```sh
mix deps.get
mix kettlecorn.install
```

The runtime bundles Wasmtime. Start a VM and evaluate code:

```elixir
{:ok, vm} = Kettlecorn.start_link(max_fuel: 50_000_000_000, max_lifetime: 30_000)

Kettlecorn.eval(vm, ~S|IO.puts("hi"); Enum.map(1..3, fn n -> {n, n * n} end)|)
#=> {:ok, %{
#     "value" => [{1, 1}, {2, 4}, {3, 9}],
#     "inspected" => "[{1, 1}, {2, 4}, {3, 9}]",
#     "output" => "hi\n"
#   }}

Kettlecorn.stop(vm)
```

Here, `"value"` is the result, `"inspected"` is its text representation, and
`"output"` is captured stdout.

From your Mix project, run an `.exs` script directly in the sandbox:

```sh
mix kettlecorn.run script.exs arg1 arg2
```

See [CLI installation and usage](host/guides/running-applications.md#command-line)
for expressions, IEx, and runtime selection.

To run a Mix application in the sandbox, use `mix kettlecorn.cook` to bundle
its compiled code and dependencies. See
[cooking and running Mix applications](host/guides/running-applications.md#cooking-mix-applications)
for packaging and launch instructions.

See the [package documentation](host/README.md) for the API and deployment.

### In a Rust application

Add `kettlecorn` with its optional runtime installer:

```sh
cargo add kettlecorn --features installer
```

Call `Runtime::install()` from synchronous code to download and verify the
matching runtime, or reuse one already installed. After installation, load
the runtime with `Runtime::find` and use the async API from Tokio:

```rust
use kettlecorn::{EvalOptions, Runtime, VmOptions};

let runtime = Runtime::find()?;
let mut options = VmOptions::default();
options.max_fuel = Some(50_000_000_000);
options.max_lifetime = Some(std::time::Duration::from_secs(30));
let vm = runtime.start(options).await?;
let evaluation = vm.eval("Enum.sum(1..10)", EvalOptions::default()).await;
vm.shutdown().await?;
println!("{}", evaluation?.result?.inspected);
```

The [Rust quickstart](rust/README.md#quickstart) includes a complete program
and dependencies. Running guest code requires no host Elixir installation.
See [runtime setup and deployment](rust/README.md#runtime-setup-and-deployment)
for bundled runtimes and offline discovery, and the
[API documentation][kettlecorn-rust-docs] for reference.

### In Livebook

[![Run in Livebook](https://livebook.dev/badge/v1/blue.svg)](https://livebook.dev/run?url=https%3A%2F%2Fgithub.com%2Fmjrusso%2Fkettlecorn%2Fblob%2Fmain%2Fhost%2Fnotebooks%2Fgetting-started.livemd)

Start with [Getting started](host/notebooks/getting-started.livemd), then
[Working with guest VMs](host/notebooks/working-with-guests.livemd). Both
install the package and runtime. The other notebooks run independently:

* [Use cases](host/notebooks/use-cases.livemd): user code, plugins, and submission tests.
* [Network access](host/notebooks/network.livemd): sockets, HTTP, and denied operations.
* [Validating guest data](host/notebooks/guest-data.livemd): constructors and nested results.

### Standalone command line

To use `kettlecorn-run` without a host Elixir installation, download a
[runtime archive](https://github.com/mjrusso/kettlecorn/releases) and follow
the [CLI installation guide](host/guides/running-applications.md#command-line).

### With Nix

From a checkout, with Nix flakes enabled and the
[binary cache configured](host/guides/development.md#binary-cache):

```sh
nix run .#kettlecorn-run -- examples/01_hello.exs one two
```

## Examples

The [examples guide](examples/README.md) includes scripts, cooked Mix apps,
and instructions for these Rust projects:

| Example | Demonstrates |
|---|---|
| [Hello World](examples/README.md#hello-world) | Start a VM, evaluate Elixir, and shut down |
| [Device Monitor](examples/README.md#device-monitor) | Stateful Elixir plugins, guest GenServer calls, and async Rust callbacks |
| [Pulse Field](examples/README.md#pulse-field) | A native graphical application driven by Elixir scripts, with process and message visualization |

## Documentation

| Guide | Covers |
|---|---|
| [Sandbox and resource limits](host/guides/sandbox.md) | Isolation, fuel, memory, output, disk use, and network grants |
| [Running applications](host/guides/running-applications.md) | CLI installation and usage, cooking Mix apps, deployment, HTTP, and IEx |
| [Guest API](host/guides/guest-api.md) | Guest messages, host calls, HTTP requests, and streaming |
| [Architecture](host/guides/architecture.md) | Host and guest processes, threads, OTP patches, framing, and Popcorn |
| [Development](host/guides/development.md) | Nix setup, binary cache, build stages, checks, and pinned versions |
| [Performance](host/guides/performance.md) | Startup behavior and local benchmark instructions |

The [internals notebook](host/notebooks/internals.livemd) examines the
implementation. The [Lua notebook](host/notebooks/lua.livemd) compares
embedding Lua in the host BEAM with running it inside Kettlecorn.

## Contributing

See [Development](host/guides/development.md) for setup and checks,
and [RELEASING.md](RELEASING.md) for publishing. Report bugs with
reproduction steps in [GitHub Issues](https://github.com/mjrusso/kettlecorn/issues).

## Attribution

Kettlecorn is built on, and named after,
[Popcorn](https://github.com/software-mansion/popcorn) by
[Software Mansion](https://swmansion.com). Popcorn runs Elixir and Erlang
in the browser; Kettlecorn adapts its OTP patches for WASI. See
[how Kettlecorn uses Popcorn](host/guides/architecture.md#popcorn).
Kettlecorn is not affiliated with Popcorn or Software Mansion.

## License

Kettlecorn is licensed under the [Apache License 2.0](LICENSE). Third-party
components keep their own licenses: see
[`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md).

Copyright (c) 2026, [Michael Russo](https://mjrusso.com).

[kettlecorn-hex-badge]: https://img.shields.io/hexpm/v/kettlecorn.svg
[kettlecorn-hex]: https://hex.pm/packages/kettlecorn
[docs-badge]: https://img.shields.io/badge/HexDocs-docs-blue.svg
[kettlecorn-docs]: https://hexdocs.pm/kettlecorn/
[kettlecorn-crate-badge]: https://img.shields.io/crates/v/kettlecorn.svg
[kettlecorn-crate]: https://crates.io/crates/kettlecorn
[rust-docs-badge]: https://img.shields.io/badge/docs.rs-docs-blue.svg
[kettlecorn-rust-docs]: https://docs.rs/kettlecorn
