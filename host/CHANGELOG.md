# Changelog

## 0.1.0 (unreleased)

Initial experimental release:

* Evaluate Elixir and Erlang in isolated WebAssembly VMs with configurable
  memory, execution, lifetime, and message limits.
* Call guest GenServers, exchange messages, and expose selected host operations.
* Cook Mix applications and run scripts or IEx with optional socket and HTTP access.
* Run guest code with `mix kettlecorn.run`.
* Install platform runtimes for Linux x86_64/ARM64 and Apple silicon macOS.

Component-model threading is experimental. See the sandbox guide before running
untrusted workloads.
