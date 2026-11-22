# Changelog

## Unreleased

* **Breaking:** protocol version 2. The library refuses earlier runtimes:
  install the matching runtime with `mix kettlecorn.install` and cook
  applications again.

* `Kettlecorn.stats/1` reports fuel use, linear memory, and launcher RSS
  on Linux.
* Owners receive `{:kettlecorn, vm, {:stopped, stats}}` when a VM stops.
  The event contains final fuel and memory, or `nil` if the launcher
  exited without reporting them.

## 0.2.0

* Support embedding VMs in Rust applications through the `kettlecorn` crate.
* Share a versioned runtime cache with Rust. Discovery checks the release
  version, and concurrent first installs reuse the first published runtime.
* `mix kettlecorn.install` preserves invalid cache entries. Move them aside
  before retrying. At a destination you own, `--force` can replace a file or
  other non-directory entry.
* Check guest messages and host calls against advertised frame limits before
  sending. The conservative size check can reject messages that would fit,
  and rejects closures and native records. Rejected requests and oversized
  proxy replies return `{:error, :frame_too_large}`.
* Omit structured evaluation values that exceed client-supplied size or
  nesting limits, while preserving inspected text and captured stdout.

## 0.1.0 (2026-11-18)

Initial experimental release:

* Evaluate Elixir and Erlang in isolated WebAssembly VMs with configurable
  memory, execution, lifetime, and message limits.
* Call guest GenServers, exchange messages, and expose selected host operations.
* Cook Mix applications and run scripts or IEx with optional socket and HTTP access.
* Run guest code with `mix kettlecorn.run`.
* Report disabled HTTP access in Req before certificate or connection setup,
  with instructions for enabling the required grant.
* Install platform runtimes for Linux x86_64/ARM64 and Apple silicon macOS.

Component-model threading is experimental. See the sandbox guide before running
untrusted workloads.
