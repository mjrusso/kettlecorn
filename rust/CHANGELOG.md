# Changelog

## Unreleased

* **Breaking:** install a runtime that supports protocol version 2.
* **Breaking:** `Vm::shutdown` returns a `Shutdown` containing the final
  stats and the result. Replace `vm.shutdown().await?` with
  `vm.shutdown().await.result?`.
* Add `Vm::stats`, which reports fuel consumed (when `max_fuel` is set) and
  linear memory.
* Add `VmOptions::preload`. `Preload::On` loads every module on the code path
  while the VM boots and sends the names of modules loaded on demand
  afterwards to `VmOptions::late_loads`; `Preload::Strict` stops the VM on
  such a load.
* **Breaking:** Update `EvalOptions` struct literals with
  `max_reductions: None` or `..Default::default()`. `Evaluation::reductions`
  reports the charged count. When an evaluation exceeds the limit,
  `Evaluation::result` holds a `ScriptError` with kind `reductions`.
* A guest timeout or caller exit drops the host callback's future and
  releases its `max_host_calls` slot.
* **Breaking:** a host call to an unregistered name returns
  `{:error, "no host handler"}` instead of
  `{:error, "unknown host function"}`, the same reply as the Elixir host.
* Launcher processes share cached compiled code. The first start after
  upgrading recompiles the runtime.
* Add `Runtime::install_from_archive`, which installs a release archive
  already on disk into the cache, verified against the same checksum as a
  download, for hosts without network access.
* **Breaking:** `VmOptions::network` and `VmOptions::http` are a
  `NetworkAccess` instead of a `bool`: `Denied`, `Any`, or
  `Only(NetworkRules)`, which limits the grant to the listed host names,
  addresses, address ranges and ports. `NetworkRules::new` returns `None` for
  an empty list. Replace `true` with `NetworkAccess::Any`.

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
