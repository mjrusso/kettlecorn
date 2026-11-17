![Kettlecorn logo](assets/kettlecorn.png)

[![Hex][kettlecorn-hex-badge]][kettlecorn-hex] [![Docs][docs-badge]][kettlecorn-docs]

# Kettlecorn

***This is your BEAM on WASI.***

Kettlecorn runs untrusted Elixir and Erlang in a WebAssembly sandbox.
Use it to isolate user code, plugins, or whole Mix applications.

> [!WARNING]
>
> Kettlecorn is experimental. It enables Wasmtime's [component-model
> threading](https://docs.wasmtime.dev/stability-wasm-proposals.html#component-model-proposals),
> an unfinished feature that Wasmtime leaves off by default.
>
> Bugs in Kettlecorn or its dependencies may compromise isolation. Set finite
> `max_fuel` and `max_lifetime` limits for untrusted workloads. These constrain
> guest execution; host memory and disk use need separate controls. Review [the
> sandbox's limits and network grants](host/guides/sandbox.md).

Each VM runs OTP 29 and Elixir 1.20 under [Wasmtime](https://wasmtime.dev),
in its own process with a private filesystem. Network access is off by default.
Set `max_memory` to cap guest memory, `max_fuel` to limit execution, and
`max_lifetime` to bound elapsed time. Fuel is measured roughly in WebAssembly
instructions; fuel and lifetime limits cover startup and all evaluations.

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

Here, `"value"` is the returned list, `"inspected"` is its text representation,
and `"output"` is captured stdout.

Use Kettlecorn from your Elixir application or run scripts and IEx with
`kettlecorn-run`. To run a Mix application in the sandbox, package it with
[`mix kettlecorn.cook`](host/guides/running-applications.md#cooking-mix-applications).

## Getting started

### In an Elixir application

Requires Elixir 1.20 or later, on x86_64 or ARM64 Linux or Apple silicon macOS.
Add the Hex dependency:

```elixir
{:kettlecorn, "~> 0.1"}
```

Fetch the dependency and install the runtime:

```sh
mix deps.get
mix kettlecorn.install
```

The runtime includes Wasmtime; no separate installation is needed.
See the [package documentation](host/README.md) for the API and deployment.

### In Livebook

[![Run in Livebook](https://livebook.dev/badge/v1/blue.svg)](https://livebook.dev/run?url=https%3A%2F%2Fgithub.com%2Fmjrusso%2Fkettlecorn%2Fblob%2Fmain%2Fhost%2Fnotebooks%2Fgetting-started.livemd)

Start with [Getting started](host/notebooks/getting-started.livemd), then
[Working with guest VMs](host/notebooks/working-with-guests.livemd). Both
install the published package and runtime. The remaining notebooks are
independent:

* [Use cases](host/notebooks/use-cases.livemd): user code, plugins, and submission tests.
* [Network access](host/notebooks/network.livemd): sockets, HTTP, and denied operations.
* [Validating guest data](host/notebooks/guest-data.livemd): constructors and nested results.

### With Nix

From a checkout, with Nix flakes enabled and the
[binary cache configured](host/guides/development.md#binary-cache):

```sh
nix run .#kettlecorn-run -- examples/01_hello.exs one two
```

For IEx, run `nix run .#iex`. See the [examples](examples/README.md)
for scripts and Mix applications.

## Documentation

| Guide | Covers |
|---|---|
| [Sandbox and resource limits](host/guides/sandbox.md) | Isolation, fuel, memory, output, disk use, and network grants |
| [Running applications](host/guides/running-applications.md) | Runtime archives, cooking Mix apps, deployment, HTTP, and IEx |
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
