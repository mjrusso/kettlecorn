# Changelog

## 0.3.0

### Upgrading

* Install a runtime that supports protocol version 2. Rebuild any cooked
  apps for that runtime.
* `VmOptions::network` and `VmOptions::http` now take `NetworkAccess`.
  Replace `false` with `NetworkAccess::Denied` and `true` with
  `NetworkAccess::Any`. Use `NetworkAccess::Only(rules)` to restrict
  destinations to an allowlist.
* `Vm::shutdown` returns a `Shutdown` with final stats and the result.
  Replace `vm.shutdown().await?` with `vm.shutdown().await.result?`.
* Update `EvalOptions` struct literals with `max_reductions: None` or
  `..Default::default()`. Add `reductions` or `..` to exhaustive
  `Evaluation` patterns.
* Update checks for the unregistered host function error to match
  `"no host handler"`. The previous message was `"unknown host function"`.
* Guest HTTP requests now honor the process's proxy settings. Review them
  if you rely on direct connections. When a hostname is allowed by its
  resolved address, the launcher must connect directly.

### New capabilities

* Set `EvalOptions::max_reductions` to limit work per evaluation. Read the
  charged count from `Evaluation::reductions`. When the evaluation exceeds
  the limit, `Evaluation::result` holds a `ScriptError` with kind `reductions`.
* Read live linear memory and fuel consumed with `Vm::stats`. Fuel is
  available when `max_fuel` is set. `Vm::shutdown` returns final stats.
* Set `VmOptions::preload` to `Preload::On` to load modules at boot and
  report subsequent on-demand loads through `VmOptions::late_loads`, when
  configured. `Preload::Strict` also stops the VM on such a load.

### Runtime and tooling

* When the guest cancels a pending host call, the VM drops the callback's
  future and releases its `max_host_calls` slot.
* When guest execution ends, the embedded VM gives buffered guest frames
  and stderr up to one second to drain.
* Install offline with `Runtime::install_from_archive(path)`. On a fresh
  install it verifies the archive against the checksum bundled with the crate.
* Launcher processes share cached compiled code. Each component in the
  old cache is compiled again on first use.

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
