# Changelog

## Unreleased

* **Breaking:** protocol version 2. The library refuses earlier runtimes:
  install the matching runtime with `mix kettlecorn.install` and cook
  applications again.
* The guest drops a host-call reply that arrives after the call timed out
  or its caller exited. An owner's late reply used to reach the caller's
  mailbox as `{:wasm, {token, result}}`; it still does for a call made
  before the guest's applications start, such as from an `@on_load`
  callback during preload, or while the guest's host-call process restarts.
  A call returns `{:error, :interrupted}` if that process stops while the
  call waits.
* `Kettlecorn.ETF.to_json/1` converts decoded guest values to JSON-shaped
  data, and returns an error for pids, references, ports, invalid UTF-8,
  improper lists and keys that collide.
* `Kettlecorn.stats/1` reports fuel use, linear memory, and launcher RSS
  on Linux.
* Owners receive `{:kettlecorn, vm, {:stopped, stats}}` when a VM stops.
  The event contains final fuel and memory, or `nil` if the launcher
  exited without reporting them.
* `preload: true` loads the boot-time code path in a fixed order and
  reports later on-demand loads to the owner as `{:late_load, module}`
  events. `preload: :strict` also stops the VM on a late load.
  The CLI supports `--preload on|strict` and reports late loads on stderr.
* `Kettlecorn.eval/3` accepts `max_reductions` and reports charged
  reductions in evaluation replies. An evaluation that exceeds the
  limit fails with `"kind" => "reductions"`.
* Answer guest host calls with named functions (`:handlers`) or a stateful
  `Kettlecorn.HostHandler` (`:handler`). `:max_host_calls` defaults to four
  and includes pending cancellations.
* A guest timeout or caller exit cancels its host call. Owners handling
  calls manually receive `{:kettlecorn, vm, {:host_call_cancel, reply_to}}`.
* Launcher processes share cached compiled code, reducing memory per VM.
  The first start after upgrading recompiles the runtime.
* `mix kettlecorn.install --archive PATH` (`Kettlecorn.Install.runtime/1`'s
  `:archive`) installs a release archive already on disk, verified against
  the same checksum as a download, for hosts without network access.
* `network: [allow: rules]` and `http: [allow: rules]` limit the grants to
  the listed host names, addresses, address ranges and ports; `:public`
  allows public addresses. For HTTP, hostname requests allowed by resolved
  address require a direct connection. `kettlecorn-run` takes
  `--network-allow` and `--http-allow`.
* Runtime downloads use Mint and support `http://` proxies configured
  through `https_proxy` or `HTTPS_PROXY` for HTTPS downloads, and
  `http_proxy` or `HTTP_PROXY` for HTTP mirrors. Loopback hosts and entries
  in `no_proxy` or `NO_PROXY` are reached directly.
* The HTTP grant sends guest requests through the proxy in the
  launcher's environment.
* Remove VM private directories faster on shutdown and log cleanup failures.

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
