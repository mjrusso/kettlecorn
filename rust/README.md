# Kettlecorn

Kettlecorn lets Rust applications run untrusted Elixir and Erlang in a
WebAssembly sandbox. Evaluate code, call guest GenServers, and expose async
Rust functions to the guest.

The crate embeds Wasmtime in your application process. Each VM has a private
filesystem, and network access is off by default.

It uses the same guest runtime as [Kettlecorn's Elixir package](https://hex.pm/packages/kettlecorn).
Running guest code requires no host Elixir installation.

```sh
cargo add kettlecorn
```

Download and extract the runtime archive for your platform. Use the GitHub
release that matches the resolved crate version.. [GitHub releases](https://github.com/mjrusso/kettlecorn/releases)

Pass the extracted runtime directory to `Runtime::load`, call
`Runtime::start` from a Tokio runtime to boot a VM, and use `Vm::eval` to run
guest code.
[API documentation](https://docs.rs/kettlecorn)
