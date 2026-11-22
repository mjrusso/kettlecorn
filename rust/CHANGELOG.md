# Changelog

## Unreleased

* **Breaking:** `Vm::shutdown` returns a `Shutdown` with the final resource
  stats and a `result`. Replace `vm.shutdown().await?` with
  `vm.shutdown().await.result?`.
* Add `Vm::stats`, which reports fuel consumed (when `max_fuel` is set) and
  linear memory.

## 0.2.0

Initial experimental Rust release:

* Run untrusted Elixir and Erlang in WebAssembly VMs inside a Rust application.
* Give each VM a private filesystem and configurable memory, execution, and
  lifetime limits. Network access is off by default.
* Evaluate code and capture its result and stdout.
* Call guest GenServers, exchange messages, and expose async Rust functions
  to the guest.
* Prepare the runtime before starting VMs with `Runtime::warm_up`.
* Find an installed runtime with `Runtime::find`, using `KETTLECORN_RUNTIME`
  or the versioned user cache. Enable the `installer` feature to download and
  verify a release with `Runtime::install`.
* Enable the native launcher with the `cli` Cargo feature.
* Add Hello World, Device Monitor, and Pulse Field examples covering basic
  embedding, stateful plugins, and a graphical Elixir-scripted simulation.
