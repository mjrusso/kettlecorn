# Kettlecorn

Kettlecorn runs untrusted Elixir and Erlang in a WebAssembly sandbox.
Use it from your Elixir application to evaluate code, call guest GenServers,
or run whole Mix applications.

Kettlecorn also provides a [Rust crate](https://github.com/mjrusso/kettlecorn/blob/main/rust/README.md)
for in-process embedding. Both APIs use the same runtime archives and
versioned installation cache.

With the Elixir API, each VM runs OTP 29 and Elixir 1.20 in a separate
[Wasmtime](https://wasmtime.dev) process with a private filesystem.
Guests cannot start OS processes or load native code. Network access is off
by default, and WebAssembly linear memory is capped at 512 MiB. Execution
and lifetime limits are opt-in.

> #### Experimental software {: .warning}
>
> Kettlecorn is experimental. It enables Wasmtime's
> [component-model threading](https://docs.wasmtime.dev/stability-wasm-proposals.html#component-model-proposals),
> an unfinished feature that Wasmtime leaves off by default.
>
> Bugs in Kettlecorn or its dependencies may compromise isolation. Set
> finite `max_fuel` and `max_lifetime` limits for untrusted workloads.
> These constrain guest execution; host memory and disk use need separate
> controls. Review [the sandbox's limits and network grants](guides/sandbox.md).

## Installation

Requires Elixir 1.20 or later on x86_64 or ARM64 Linux or Apple silicon macOS.

```elixir
def deps do
  [{:kettlecorn, "~> 0.2"}]
end
```

Fetch the dependency and install the platform runtime:

```console
$ mix deps.get
$ mix kettlecorn.install
```

The runtime bundles its native launcher and Wasmtime engine; no separate
Wasmtime installation is needed. The installer verifies the archive's SHA-256.
See `mix help kettlecorn.install` for installation options.

## Usage

```elixir
{:ok, vm} = Kettlecorn.start_link(max_fuel: 50_000_000_000, max_lifetime: 30_000)

Kettlecorn.eval(vm, ~S"""
IO.puts("This is your BEAM on WASI.")

transactions = [{101, 1_500}, {102, 2_000}, {101, -500}]

Enum.reduce(transactions, %{}, fn {account_id, cents}, totals ->
  Map.update(totals, account_id, cents, &(&1 + cents))
end)
""")
#=> {:ok, %{
#     "value" => %{101 => 1000, 102 => 2000},
#     "inspected" => "%{101 => 1000, 102 => 2000}",
#     "output" => "This is your BEAM on WASI.\n"
#   }}

Kettlecorn.stop(vm)
```

### Evaluation results

| Field | Contains |
|---|---|
| `"value"` | The result as plain data, within the evaluator's traversal limit. Omitted for other results. |
| `"inspected"` | The result's text representation. |
| `"output"` | Captured standard output. |

Writes to stderr go to the VM's console output, available through owner events
and `Kettlecorn.take_output/1`.

### VM limits and lifetime

The example sets two limits for the whole VM:

| Option | Limits |
|---|---|
| `max_fuel` | Total execution budget, measured roughly in WebAssembly instructions. |
| `max_lifetime: 30_000` | Lifetime of 30 seconds. |

Both include startup and apply across all evaluations in that VM. Use
`Kettlecorn.stats(vm)` to read fuel and memory while it runs. To cap a single
evaluation, pass `max_reductions: n` to `Kettlecorn.eval/3`.

`start_link/1` links the VM to its caller: a resource limit or guest crash can
terminate that caller. `Kettlecorn.run/2` starts a fresh VM, evaluates code
once, and stops it afterward. See
[Managing VM lifetime](guides/sandbox.md#managing-vm-lifetime) for unlinked VMs
and caller cleanup.

Reuse a VM for repeated evaluations from the same tenant. Give mutually
untrusted tenants separate VMs: modules, processes, and files persist
between evaluations. See [VM reuse](guides/sandbox.md#reusing-vms).

### Erlang use

Pass `language: :erlang` to `Kettlecorn.eval/3` for expressions or module source.

### Guest events

With `owner: pid`, consume guest events and call `Kettlecorn.acknowledge(vm)`
after each one. The final `{:stopped, stats}` event needs no acknowledgement.
Exceeding the unacknowledged event count or byte budget stops
the VM. See [sandbox and resource limits](guides/sandbox.md) for delivery
budgets and host memory and disk controls.

## Command line

In a Mix project with the `kettlecorn` dependency and an installed runtime:

```sh
mix kettlecorn.run script.exs arg1 arg2
```

See the [CLI guide](guides/running-applications.md#command-line) for installation,
expressions, IEx, and runtime selection.

`mix kettlecorn.eval 'Enum.sum(1..10)'` uses the host evaluation API and
prints the inspected result. Pass `--erlang` to evaluate Erlang.

## Mix applications

`mix kettlecorn.cook` packages a Mix application and its dependencies for
the guest. Start it with `Kettlecorn.start_link(app: dir)`.

Cooking compiles code and evaluates configuration on the host, outside
the guest sandbox. Cook trusted projects and dependencies, or isolate
the build separately. See [Cooking Mix applications](guides/running-applications.md#cooking-mix-applications).

Compile guest `.beam` files with the runtime's OTP major release and
**exact Elixir version**, recorded in its `manifest.json`. This also applies
to dependencies loaded through `code_paths`.

## Configuration and deployment

The runtime is separate from the Hex package; include it in your deployment.
The installer defaults to your user cache directory. `Kettlecorn.Runtime`
documents discovery and configuration, including `KETTLECORN_RUNTIME`.

[Running applications](guides/running-applications.md) covers deployment in
images and Mix releases. Its
[troubleshooting section](guides/running-applications.md#troubleshooting)
covers runtime discovery, rejected payloads, and VM failures.
[Guest API](guides/guest-api.md) documents the modules available inside the VM.

## Learn the API

API reference:

* `Kettlecorn` - evaluate code, call and cast to guest GenServers, exchange
  messages, and answer host calls.
* `Kettlecorn.start_link/1` - start a VM and configure boot and event delivery.
* `Kettlecorn.Sandbox` - resource limits, network grants, guest code, and caching.

[![Run in Livebook](https://livebook.dev/badge/v1/blue.svg)](https://livebook.dev/run?url=https%3A%2F%2Fgithub.com%2Fmjrusso%2Fkettlecorn%2Fblob%2Fmain%2Fhost%2Fnotebooks%2Fgetting-started.livemd)

Start with [Getting started](notebooks/getting-started.livemd), then
[Working with guest VMs](notebooks/working-with-guests.livemd). Both
install the published package and runtime. The remaining notebooks are
independent:

* [Use cases](notebooks/use-cases.livemd): user code, plugins, and submission tests.
* [Network access](notebooks/network.livemd): sockets, HTTP, and denied operations.
* [Validating guest data](notebooks/guest-data.livemd): constructors and nested results.

[Lua](notebooks/lua.livemd) compares host embedding with guest execution;
[Internals](notebooks/internals.livemd) examines the implementation.
See [Architecture](guides/architecture.md), [Development](guides/development.md),
and [Performance](guides/performance.md) for implementation details and benchmarks.

Kettlecorn builds on [Popcorn](https://github.com/software-mansion/popcorn),
which runs Elixir and Erlang in the browser. See the
[architecture guide](guides/architecture.md#popcorn) for the relationship.

## License

Apache-2.0. The runtime contains third-party components under their own
licenses; it ships them in `licenses/`.
