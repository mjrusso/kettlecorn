# Changelog

## 0.3.0

### Upgrading

* Protocol version 2 requires a matching runtime. Install it with
  `mix kettlecorn.install` or update your runtime bundle, then cook your
  applications again.
* Guest HTTP requests now honor the launcher's
  [proxy settings](guides/sandbox.md#proxies). Review them if you rely on
  direct connections. When a hostname is allowed by its resolved address,
  the launcher must connect directly.
* `mix kettlecorn.cook` now finds and validates the configured or cached
  runtime even without `--runtime`. An invalid or incompatible runtime
  blocks cooking. See [runtime selection](guides/running-applications.md#cooking-mix-applications).

### New capabilities

* Restrict sockets or HTTP to specific hostnames, IP addresses, ranges,
  and ports with `network: [allow: rules]` or `http: [allow: rules]`.
  The CLI accepts `--network-allow` and `--http-allow`. See
  [network allowlists](guides/sandbox.md#network-allowlists).
* Handle guest calls with named functions (`:handlers`) or a stateful
  `Kettlecorn.HostHandler` (`:handler`). The default limit is four pending
  calls per VM. When the guest cancels a call, Kettlecorn stops that call's
  function task or notifies the stateful handler if the reply was deferred.
  Owners who reply manually receive `{:kettlecorn, vm, {:host_call_cancel, reply_to}}`.
  See
  [host calls](guides/guest-api.md#host-calls).
* Set `max_reductions` in `Kettlecorn.eval/3` to limit work per evaluation.
  Replies report charged reductions even without a limit. If the evaluation
  exceeds its limit, the error map has `"kind" => "reductions"` and the VM
  can continue running.
* Load modules at boot with `preload: true`. The owner receives
  `{:kettlecorn, vm, {:late_load, module}}` for subsequent on-demand loads.
  Use `preload: :strict` to stop the VM on such a load. The CLI accepts
  `--preload on` or `--preload strict` and reports late loads on stderr.
* Read live linear memory, fuel use when metered, and launcher RSS on Linux
  with `Kettlecorn.stats/1`. Owners receive final stats in
  `{:kettlecorn, vm, {:stopped, stats}}`. If the launcher exits without
  reporting stats, the event carries `nil`.
* Convert decoded guest values for JSON encoding with
  `Kettlecorn.ETF.to_json/1`. It rejects unsupported values and map keys
  that convert to the same string.

### Runtime and tooling

* Install offline with `mix kettlecorn.install --archive PATH` or the
  `:archive` option to `Kettlecorn.Install.runtime/1`. Runtime downloads
  now honor [environment proxy settings](guides/running-applications.md#runtime-downloads).
* Launcher processes share cached compiled code, reducing memory per VM.
  Each component in the old cache is compiled again on first use.
* VM shutdown removes private directories faster and logs cleanup failures.

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
