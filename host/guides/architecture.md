# Architecture

Kettlecorn runs OTP in Wasmtime with a private copy of the runtime root for
each VM. The Elixir host and CLI start a separate launcher process per VM.
The Rust crate embeds Wasmtime in the application process and runs VMs as
Tokio tasks.

For the Elixir host, requests use port stdin and guest output returns over a
local socket:

```
 your Elixir app (host)                      Launcher process (one per VM)
┌─────────────────────────┐ stdin frames  ┌───────────────────────────────────────┐
│ Kettlecorn.VM ── Port ──┼──────────────▶│ beam.wasm (OTP 29 ERTS, a WASIp3      │
│  local output socket   │◀──────────────┼           component)                  │
│  Kettlecorn.ETF (strict │ output records│  ├ wasm NIF: stdio bridge thread      │
│  decoder for guest data)│               │  ├ Kettlecorn.Boot / Kettlecorn.Proxy │
└─────────────────────────┘               │  └ Kettlecorn.Evaluator / .Host / .HTTP│
                                          │ preopen "/" = private copy of the     │
                                          │   runtime root (OTP, Elixir, Req, ...) │
                                          └───────────────────────────────────────┘
```

## Elixir host options

Elixir host options use NimbleOptions schemas: `Kettlecorn` defines evaluation
options, `Kettlecorn.VM` defines process options, and `Kettlecorn.Sandbox`
defines limits, grants, and guest configuration. The schemas supply
validation, defaults, and option documentation.
[Kettlecorn.Options](https://github.com/mjrusso/kettlecorn/blob/main/host/lib/kettlecorn/options.ex) defines the custom
application-name and environment types and converts validation errors to
`ArgumentError` at the public boundary.

`Kettlecorn.Sandbox.new/1` resolves the platform runtime, loads the CA
certificates, and checks the cooked application path. The sandbox struct
holds these resolved values.

## Elixir VM lifecycle

`Instance.prepare/1` creates the private parent directory and passes selected
certificate bytes and staging paths to the native `--prepare-root` operation.
Rust creates a fresh mode-0700 root, dereferences source symlinks, and makes
the copies writable. It overlays the cooked app, stages extra code or scripts,
and installs certificates at the path from `launch/env`. Failed preparation
removes the partial root; preexisting destinations and runtime sources remain
intact.

`Kettlecorn.VM` then opens a port to `bin/kettlecorn-launch` and waits for
`boot_ready` under a boot deadline. OTP acknowledges startup only after the
guest's applications have started. A failed boot stops the launcher and returns
an initialization error. After preparation, `VM.init/1` owns cleanup; running
VMs use the same cleanup function when they stop.

Closing the port cancels execution, including a stalled output writer. Closing
stdin cancels framed guests even when input is backlogged; raw EOF remains guest
input for scripts. The stdin watcher explicitly requests `POLLHUP`, which macOS
requires to report closure with unread input. The launcher atomically
publishes a JSON termination record before it exits. The record identifies
exit, cancellation, timeout, fuel exhaustion, or failure, and holds the final
stats. Stderr supplies diagnostics; guest fatal frames retain priority.

Stopping has three steps, in order:

1. The host waits for shutdown. It's confirmed when the launcher has exited,
   or when the host closed the port and the termination record appeared
   within five seconds. Otherwise the shutdown is unconfirmed.
2. The host sends the owner `{:stopped, stats}`, with the record's stats, or
   `nil` when there is no record, as after an unconfirmed shutdown. The owner
   may process the event after cleanup.
3. After confirmed shutdown, the host removes the private directory. If
   shutdown is unconfirmed, it keeps the directory and logs its path.

`Kettlecorn.stop/1` returns, and the VM process exits, after step 3.

The termination record is outside the guest root. Stderr does not determine
the outcome; a missing result falls back to the process exit status.

## Elixir host transport

The launcher uses nonblocking fd streams on a current-thread Tokio runtime.
Its stdout queue holds at most two 1 MiB chunks plus the chunk being written.
For host VMs, process stdout carries a readiness byte; the host then connects
a private local socket before guest execution starts.

The launcher splits guest output into records of at most 64 KiB. The host
requests one record with `active: :once` and re-arms the socket after processing
it. At most one 64 KiB record awaits processing in the VM mailbox, including
when there is no owner. The host parses each guest frame's header once, retains
body chunks with a remaining-byte count, and assembles the body when complete.
Partial guest frames are separately bounded by `:max_message_size`. The host
drains the socket before reporting process exit.

The output socket lives in a private system-temporary directory outside the
guest root and is removed on shutdown. Long temporary paths fall back to `/tmp`
to fit Unix socket path limits. A stalled host backpressures the socket,
launcher queue, and guest.

Host input is queued within fixed count and byte budgets and sent without
suspending the VM process on a busy port. Shutdown discards queued input.
The [request registry](https://github.com/mjrusso/kettlecorn/blob/main/host/lib/kettlecorn/vm/requests.ex)
separately bounds unanswered requests, allocates IDs
for all sends, and owns caller monitors and deadline timers. Replies, deadlines,
caller exits, and VM failures release entries and their resources. Requests
above `max_pending_requests` are rejected before transmission.
The [protocol specification](https://github.com/mjrusso/kettlecorn/blob/main/PROTOCOL.md#native-launcher-output-transport)
defines the socket records; [sandbox limits](sandbox.md#output-and-messages)
document the input and owner-event budgets.

## Rust execution API

`rust/` contains the `kettlecorn` Rust crate. A native application uses
`Runtime::find` to discover a runtime or `Runtime::load` with a directory,
then starts a private VM with `Runtime::start` on Tokio. Discovery checks
`KETTLECORN_RUNTIME` before the versioned cache shared with Elixir. With the
`installer` feature, `Runtime::install` verifies the matching release
archive against the checksum shipped with the crate and publishes it to
that cache. Neither discovery nor VM startup downloads a runtime.

Both hosts validate the package version, platform, protocol, and launch
files of a cached release. Rust returns `Error::IncompatibleEngine` if the
release requires a different Wasmtime version. Elixir uses the launcher
bundled with the release.
On a blocking thread, startup copies the runtime's filesystem into a private
directory for the VM and prepares the component.
The Rust client checks the embedded API version in the guest's
`:boot_ready` event.

Guest execution and transport run in one Tokio task per VM, connected by
bounded in-memory streams. See [Threads](#threads) for scheduling and parallelism.

`Runtime::warm_up(&options)` prepares the component on a blocking thread
before a VM starts. A `Runtime` and its clones reuse the prepared component
when the HTTP setting and the presence of a fuel limit match.

### Request delivery

`Vm::eval` returns captured stdout alongside a script error or, on success,
the inspected result and an optional structured value. `Vm::call` sends a term
to a registered guest process and returns its reply. `Vm::cast` waits for
delivery to the guest proxy. The proxy forwards the cast if the target is
registered and discards it otherwise. These methods can run concurrently
with independent deadlines.

The client bounds outgoing requests by frame count and total wire bytes.
`VmOptions::max_pending_requests` limits requests to the guest, including
queued writes. One session loop tracks the queued requests, current write
offset, and requests awaiting replies. Host-call replies have their own
budget and take priority between frames.

`Error::Backpressure` means the request timed out while waiting for queue
capacity. `Error::Deadline` means delivery or the guest reply timed out.
Dropping the request future skips the write if it hasn't started.
`VmOptions::frame_write_timeout` must be positive and defaults to five
seconds. The caller's deadline can shorten it for requests. A stalled
host reply or partial frame closes the session. Once a request has been
written, it counts toward `max_pending_requests` until the guest
replies or a separate timer expires. That timer starts when the write
finishes and uses the request's full timeout budget. The request continues
to occupy a pending-request slot after the caller stops waiting.

`Vm::shutdown` cancels the VM and waits for private-root cleanup.

### Guest callbacks

Use `VmOptions::register` to register async callbacks. While a callback
awaits I/O, the client continues dispatching replies and guest events.
`VmOptions::max_host_calls` limits calls from the guest, including replies
waiting to be written. If a new call would exceed the limit or its arguments
cannot be decoded, the client can send an error when it has a valid reply
token and room in the rejection queue. If the queue is full, the guest call
can time out.

The [device monitor](https://github.com/mjrusso/kettlecorn/blob/main/examples/README.md#device-monitor)
uses named calls to dispatch events to Elixir plugins with an async Rust
callback for alerts.

### Events and output

`Vm::subscribe` receives future `Kettlecorn.Host.send/1` events. Slow
subscribers receive a lag count and can resume at the oldest retained event.
`VmOptions::events` accepts a broadcast sender. Create a receiver before
starting the VM to receive guest messages sent during boot. The channel
capacity sets how many messages it retains.

`VmOptions::stdout` forwards guest stdout outside eval capture.
`VmOptions::stderr` forwards guest and transport diagnostics, including during boot.
Both send to caller-supplied bounded channels and drop chunks when full.

### Resource use

`Vm::stats` reports fuel consumed since the VM started, including boot, and
the linear memory allocated. Fuel is metered only when `max_fuel` is set. A
call hook samples both each time the guest calls into the host, the epoch
callback samples them on every tick, and the store samples them when it is
dropped, including when cancellation drops a running execution. The
resource limiter holds an allowed memory growth until the next sample or
growth, so a growth that Wasmtime fails to allocate is never reported. The
memory figure excludes compiled code and Wasmtime's own allocations.

The launcher publishes the same counts for `Kettlecorn.stats/1` in a
mapped file in the VM's private directory (`--stats`). Its termination
record carries the final counts, which the host sends in the owner's
`{:stopped, stats}` event.

### Guest values

The Rust decoder keeps atoms as strings and supports binaries, numbers,
proper lists, tuples, and maps, with a limit of 100,000 terms and a nesting
depth of 64. Maps compare independently of insertion order, including when
used as keys. Construction and decoding keep the last value for duplicate
keys. The proxy replies to an oversized result with
`{:error, :frame_too_large}` and the original request ID. See the
[protocol specification](https://github.com/mjrusso/kettlecorn/blob/main/PROTOCOL.md)
for frame size limits and how the client handles oversized frames.

## Shared execution engine

The `cli` Cargo feature enables the `kettlecorn-launch` binary. The CLI
connects the engine to file descriptors and handles signals, terminal
dimensions, diagnostics, termination records, and process exit.

All execution modes read the guest environment and arguments from the
runtime's launch files. Embedded Rust VMs also set
`KETTLECORN_MAX_GUEST_FRAME_BYTES` to advertise the frame size limit to the guest.
`Kettlecorn.Boot.start/0` reads the applications from the `-kettlecorn_apps`
init argument and applies the cooked configuration before starting them.
Scripts and IEx invoke this boot sequence before their user code runs.

The engine's internal API separates preparation from execution.
`Runtime::prepare` is synchronous and serializes compilation across clones
of a loaded runtime. It retains up to two engines (with and without fuel
instrumentation) and four HTTP/fuel component variants. The CLI and embedded
Rust VMs submit preparation to Tokio's blocking executor.
`PreparedRuntime::run` reuses that code and owns only its store, limits, streams,
and cancellation state. The engine creates each execution's private writable
root with the internal `Runtime::populate_root` method and `RootOptions`.
The execution's HTTP and fuel instrumentation settings must match the prepared
component.

Each store checks its own cancellation and deadline in the epoch callback,
so executions can share an engine without sharing cancellation. Prepared runtimes
and their clocks remain alive across executions.
The CLI submits one preparation job for its process, with cancellation and the
lifetime deadline covering preparation, execution, and output draining. Normal
guest exits drain queued output within the remaining lifetime budget. If draining
reaches the deadline, the launcher reports a timeout. Timeout, cancellation, fuel
exhaustion, and failure discard queued output so a stalled reader cannot delay
reporting VM termination or cleanup.

## Mix task

`mix kettlecorn.run` discovers an installed runtime and invokes its
`bin/kettlecorn-run` with inherited standard I/O for scripts and expressions.
It does not start a host VM or use the framed host protocol. The task owns
the subprocess and an inherited control pipe on fd 3. When the host BEAM
exits, the pipe closes, and the script stops its child and cleans up the private root.

## Threads

Each guest executes on **one OS thread at a time**. wasi-libc's cooperative
threads make every pthread (BEAM schedulers, the aux and poll threads, the
stdio bridge) a component-model thread, and threads switch only at blocking calls or
explicit yields. ERTS assumes preemptive threads, so the patch adapts it
for `__wasi__`:

* spin loops yield (`ETHR_SPIN_BODY` is `sched_yield()`), and spinlocks are
  mutexes, since spinning on a lock held by a suspended thread never ends;
* a busy scheduler yields every 8 context switches, so the other threads,
  including the bridge that delivers host messages, get to run;
* an idle scheduler yields in `scheduler_wait` instead of busy-looping.

More schedulers add no parallelism within a VM. Rust VMs run as Tokio tasks
inside the application process and have no dedicated OS thread. On a
multithreaded Tokio runtime, a VM can move between worker threads when
rescheduled, and separate VMs can execute in parallel. On a single-threaded
runtime, the VMs share that thread with other tasks.

The Elixir host and CLI run each VM in a separate launcher process with a
current-thread Tokio runtime. Separate launcher processes can execute in
parallel. For embedded Rust VMs, runtime preparation and private-root copying
and cleanup use Tokio's blocking thread pool. Each shared engine also has a
helper thread that advances Wasmtime's epoch clock for yielding and
cancellation checks.

## OTP patches

Kettlecorn's patches follow Popcorn's stack, with one patch per theme:
the WASI platform layer, cooperative threads, the stdio bridge, sockets
and DNS, and the terminal. See the
[patch list](https://github.com/mjrusso/kettlecorn/blob/main/patches/README.md).
The platform patch includes `c/include/kettlecorn_platform.h` through OTP's
`sys.h`. It defines `KETTLECORN_WASM` for the shared browser/WASI restrictions.
WASI transport and cooperative-thread hooks use `__wasi__` guards. The native
bootstrap also needs the Kettlecorn wasm NIF implementation, selected by
`#ifndef ERTS_EMSCRIPTEN`.
One Makefile include loads `c/otp/kettlecorn.mk`, which lists the WASI objects
and emulator flags. The feature patches add these integration points:

* `wasm_nif.c` includes `c/nif/kettlecorn_wasm_nif.c` for WASI and the
  native bootstrap. It registers the stdio bridge, DNS lookup, and HTTP
  NIFs. The bridge reads host frames, resolves registered names or decodes
  guest pids, and delivers messages with `enif_send`. It queues stdin for
  `prim_tty` to read through a NIF helper. Outgoing messages and fatal errors have
  their own frame types. Loading the NIF initializes HTTP resources before
  starting the bridge; upgrading takes over those resources. Native
  bootstrap builds register only `send_raw/1`, which reports unsupported
  sends. Popcorn's browser implementation is compiled only for Emscripten.
* The copied `c/otp/wasm.erl` encodes envelopes with `term_to_binary/1` and returns host-call
  result tuples unchanged. `host_call/3` sends a `host_call` envelope with `name`,
  `args`, and `reply_to` fields. It adds `getaddrinfo/2` and `http_*` functions.
* The inet driver is compiled in and uses wasi-libc's `wasi:sockets` support.
  `prim_inet` opens sockets through that driver. The copied
  `c/otp/inet_gethost_native.erl` calls the DNS NIF directly, without a helper
  process or request server.
* `sys.c`, `erl_child_setup.c`, and `sys_uds.c` disable signals, child
  processes, and Unix domain sockets. The halt helper in `c/src/platform.c`
  waits for the exit code and calls `exit()`. The `sys_uds_*` stubs in
  `c/src/stubs.c` remain required by `sys_drivers.o` at link time.
* `ethread.h` and `erl_process.c` support [cooperative threads](#threads).
  `c/src/platform.c` owns the busy scheduler's yield counter and interval.
* `prim_tty.erl` supports raw terminal mode without terminfo
  (see [Interactive IEx](#interactive-iex)).

The native bootstrap embeds the copied `wasm` and patched preloaded modules
(`erl_init`, `prim_inet`); it only calls `wasm:on_load/0` from `wasm`. Its
kernel modules come from OTP's checked-in primary bootstrap, so the patched
kernel modules run only in the WASI runtime.

`beam.wasm` and `beam-http.wasm` link the same emulator objects. The HTTP
client symbols are weak, so the plain emulator can omit the HTTP client.
The HTTP client in `c/http/` passes response headers to a NIF callback, which
copies them into Erlang binaries. The client then frees the WIT list that owns
the header bytes; the body handle retains none of them.

The HTTP NIF carries default, finite (including zero), and infinite timeouts
as distinct values. The NIF converts finite milliseconds to WASI nanosecond
durations; the C client rejects infinity before sending. See [HTTP timeout options](guest-api.md#buffered-requests)
for the public contract.

`-fno-strict-overflow` works around ERTS's wrapping pointer arithmetic
(`ERL_BITS_EBS_FROM_REG`): without it, clang 23 folds a negative offset into
a wasm load's unsigned offset immediate, and the load traps.

## Framed stdio

During evaluation through either API, the evaluation's group leader captures
standard output for the result. Writes to stderr bypass this capture and
reach the host as console frames. The Elixir host combines console stdout and
stderr in the `Kettlecorn.take_output/1` buffer and preserves their stream
labels in owner events. Rust returns captured stdout in `Evaluation::output`
and forwards console output through `VmOptions::stdout` and `VmOptions::stderr`.

The guest reads length-prefixed frames from stdin and writes them to stdout
([`PROTOCOL.md`](https://github.com/mjrusso/kettlecorn/blob/main/PROTOCOL.md)). Each frame
is a 4-byte length, a type byte, then the payload: console output, ETF
messages, stdin data, sends with delivery results, or fatal errors. The Elixir
host's launcher transports guest output over the
[local socket](#elixir-host-transport). Embedded Rust VMs use bounded in-memory
streams for the same frames.

The linker flags `--wrap=write --wrap=writev` frame all writes to fd 1 and 2,
including `IO.puts`, logger output, and ERTS diagnostics.
Without `KETTLECORN_FRAMED=1` in the guest environment, stdio is plain,
which is how `kettlecorn-run` runs scripts. The shared engine forces framing
on for host VMs and embedded Rust VMs after merging environment variables.

The bridge queues stdin independently of message delivery. Unread stdin
cannot block host calls or other frames. `prim_tty` reads the queue through
NIF helpers and reads live terminal dimensions from the launcher's size file,
falling back to `COLUMNS` and `LINES`.

Reader registration is protected by a statically initialized pthread mutex,
so input can arrive before the TTY NIF loads. Registration retains the TTY
resource until it is replaced or unregistered. References are released outside
the mutex because destruction calls back into unregister. Reader death and
TTY destruction unregister only the matching reader or resource.

`c/src/framing.c` reads and writes frame headers and enforces the input length
limit before allocating a body. Its writer drops frames in raw mode.
`kettlecorn_fatal` reports bridge failures on stderr in raw mode and as fatal
frames in framed mode. OTP's exit hook adds only a frame; OTP itself prints
the diagnostic on stderr. Bridge read and allocation errors exit
unsuccessfully in either mode. The raw reader
queues EOF when stdin closes; closing the framed transport exits the VM.

### Guest-data decoding

The guest is untrusted, so the Elixir host decodes guest terms with
`Kettlecorn.ETF`, never `binary_to_term/1`. The decoder creates no atoms,
funs, or structs of host modules. This prevents a guest from supplying
fields to a host module's protocol implementations.

PID, port and reference encodings require atom nodes. The decoder charges the
retained input, each PID handle's copied encoding, and retained UTF-8 conversions
of Latin-1 atom names against its memory budget.

[`Kettlecorn.Protocol.decode/2`](https://github.com/mjrusso/kettlecorn/blob/main/host/lib/kettlecorn/protocol.ex) decodes frame bodies into messages, host calls,
boot events, and proxy replies under the VM's memory budget. It checks
envelopes and normalizes malformed proxy results to `{:error, {:bad_reply, value}}`.
`Kettlecorn.VM` updates the boot state, replies to pending callers, and notifies
the owner.

The Rust API uses its own ETF decoder and represents atoms as strings in
`Value::Atom`. Its supported values and decoding limits are described under
[Guest values](#guest-values).

### Elixir owner delivery

The Elixir host's owner delivery tracks outstanding event counts and
estimated retained byte sizes. Owners acknowledge events after consumption;
overflow stops the VM before delivering another event. Protocol replies and
boot events bypass owner accounting.

For Rust delivery behavior, see [Events and output](#events-and-output).

## Evaluation

### Request deadlines

The host's timeout policy derives evaluation, capture-finish, proxy and host
budgets together. Call payloads carry the proxy timeout, and evaluation
payloads carry the evaluation and capture-finish timeouts. The guest uses
those values directly; the VM schedules the host deadline without adding
another margin. See the [protocol](https://github.com/mjrusso/kettlecorn/blob/main/PROTOCOL.md#host--vm)
for the budget ordering and infinity behavior.

### Evaluation cleanup

Each evaluation coordinator monitors its output leader and descendant tracker.
Finishing uses one capture-finish deadline to collect output and acknowledge
forwarding. A timeout or failed capture process starts teardown. The coordinator
replies before descendant cleanup finishes and releases the completed
evaluation data before waiting for cleanup. It monitors cleanup for a bounded
interval before killing remaining capture processes. During forwarding,
it stays alive until the capture processes exit; the first exit bounds the wait
for the other. Tracing can be disabled or suspended by guest code, so descendant
cleanup is best effort and VM limits remain necessary.

## Req adapter selection

The shared Rust engine passes `-kettlecorn_network` when the network grant is
enabled. `Kettlecorn.Boot.network_granted?/0` reads this runtime setting;
`Kettlecorn.HTTP.available?/0` reports whether the HTTP component is linked.
`Kettlecorn.GuestApplication` selects and installs
[Req's default adapter](running-applications.md#http-and-req) during startup.
The flag is informational; Wasmtime enforces socket and DNS permissions.

## CA certificates

OTP finds a system's CA certificates by its OS type, and has no location
for WASI (`:public_key.cacerts_get/0` fails with `enotsup`). For the Elixir host
and CLI, the network grant enables native root population to write a selected
PEM bundle to the guest path in the runtime's `KETTLECORN_CACERTFILE`
(`launch/env`). `Kettlecorn.Boot` loads that file with
`:public_key.cacerts_load/1` before starting applications, so
`cacerts_get/0` returns them and Mint uses them by default. `Kettlecorn.Sandbox`
selects and encodes the host's certificates (`:cacerts`); `kettlecorn-run`
discovers the host's bundle file (`--cacertfile`). Both pass the selected file
to the native populator without reading the guest destination themselves.

Embedded Rust VMs do not import host CA certificates during startup, and
`VmOptions` has no certificate option. Enabling `network` alone does not
install a guest CA bundle.

With `wasi:http`, Wasmtime does TLS itself, with its compiled Mozilla root CA
list. The guest's CA bundle does not change those roots.

## Interactive IEx

`kettlecorn-run --iex` (`nix run .#iex`) starts IEx the way the `iex`
launcher does, with the shell as the `user` process. In a terminal it has
line editing, history, tab completion and colours:

* **In the guest,** OTP is built without termcap, so its `prim_tty` would
  fall back to a "dumb" terminal. The `0106-terminal` patch makes it assume
  an ANSI terminal on WASI, like Popcorn's `prim_tty` patch for the browser.
  Raw-mode input reads from the bridge's stdin queue without termios.
* **On the host,** WASI has no termios, so the guest can't switch the
  terminal to raw mode itself. `kettlecorn-run` sets the mode OTP would (no
  line buffering or echo, no CR/NL translation), keeps signals so Ctrl+C
  stops the VM, and restores the terminal on exit. It also passes the
  initial window size as `COLUMNS`/`LINES`. The launcher updates an open file
  inside the private root on SIGWINCH; the guest reads current dimensions there.

With piped input, IEx reads lines and exits at the end of input.

The binary handles SIGINT, SIGTERM and SIGQUIT by cancelling the guest. The
shell waits for it before restoring the terminal and removing the private root.
Terminal restoration is best effort: a failure does not prevent root cleanup
or replace the exit status.

## Runtime manifest

Every runtime's `manifest.json` records:

- its Kettlecorn version, and the OTP and Elixir versions it contains;
- the protocol version (`host/PROTOCOL_VERSION`). The Elixir library checks
  it for every VM (`Kettlecorn.Runtime.load!/1`) and refuses a runtime with a
  different protocol version;
- `imports`: the WASI interfaces each emulator imports, read from the
  components at build time. This is what a host must provide.
  `beam.wasm` has `wasi:cli`, `wasi:clocks`, `wasi:filesystem`,
  `wasi:random` and `wasi:sockets` at 0.3.2 (from wasi-libc), and
  `beam-http.wasm` adds `wasi:http` at 0.3.0 (from wasmtime's WIT files);
- `tested_with`: the Wasmtime version the checks ran against. The runtime needs
  component-model async and threading.
  The Rust crate and native launcher embed the version pinned in
  `rust/Cargo.toml`; `platform` selects its OS and CPU.

Rust's `Runtime::load` checks both the protocol version and the exact Wasmtime
version in `tested_with` before loading the runtime's launch configuration.

The runtime and the guest application's version both come from `host/VERSION`.

## Published directories

Both hosts make the cache path absolute and collapse `.` and `..` before
looking up or publishing a runtime. Symlinks in the remaining path components
are followed when accessing the cache.

Ordinary runtime installs create the cache symlink only when the destination
is absent. A competing installer reuses a valid winning generation and
removes its own. Move an invalid entry aside before retrying, or use
`mix kettlecorn.install --force` at a destination you own.

Runtime installations and cooked bundles are relative symlinks to directories
in `<destination>.versions`. Concurrent cooks can publish complete generations
to the same destination by atomically replacing the link. Cooking and forced
installation require a caller-owned destination and can overwrite any
non-directory entry there, including a regular file.
Runtime and cooked-app readers resolve the full path, including parent
symlinks, once and retain that generation. Remove inactive generations only
after all VMs and cached `Sandbox`/`Runtime` values using them have been
discarded. Move an existing ordinary directory aside before installing or
cooking to that path.

The destination and its generations can move together without breaking the
links. Exporting a standalone artifact requires dereferencing the links,
for example with `cp -RL`.

Cooked bundles include `kettlecorn.json` with their protocol, OTP major, and
exact Elixir version. Cooking uses `Runtime.load/1` when a runtime is supplied,
and rejects a mismatched compiler. The Elixir host checks the bundle before
copying it. Rust startup copies the bundle without this preliminary check.
All execution modes validate the copied bundle during guest boot before
loading its code. The Elixir host and guest boot checks reject missing or
extra metadata fields. The runtime and bundle contract use
`host/PROTOCOL_VERSION`.

## Popcorn

Kettlecorn is built on, and named after, **[Popcorn](https://github.com/software-mansion/popcorn)**
by [Software Mansion](https://swmansion.com). Popcorn runs OTP/BEAM,
compiled to WebAssembly with Emscripten, in the browser. Kettlecorn
adapts its OTP patches for WASI and server use.

The build uses the pinned `popcorn` flake input for Popcorn's OTP patch stack.
`nix/otp.nix` applies `popcorn/patches/0001`–`0014` unchanged, then
Kettlecorn's patches. Popcorn's patches remove signals, dynamic loading, OS
processes and native sockets, and add the `wasm` NIF and preloaded module
that bridge the VM to its host.

Kettlecorn's patches also modify code added by Popcorn, so they require
Popcorn's stack. The stdio bridge in `c/nif/kettlecorn_bridge.c` delivers
messages and owns stdin reader notifications. `prim_tty_nif.c` calls into it;
the browser build retains Popcorn's ring buffer and reader notifications.

The `kettlecorn_guest` application (`guest/`) provides the guest's Elixir
modules. Their Popcorn equivalents are:

| Kettlecorn | Popcorn's browser equivalent |
|---|---|
| `Kettlecorn.Boot` | `Popcorn.Boot` |
| `Kettlecorn.Host` (`send/1`, `call/3` for host calls) | `Popcorn.JS` (`send/1`, `run/3` for JavaScript) |
| `Kettlecorn.Proxy` (the host's `call`/`cast`) | `Popcorn.Proxy` |
| `Kettlecorn.HTTP` and its Req adapter, over `wasi:http` | `Popcorn.Fetch`, over the browser's `fetch()` |

Other implementations follow Popcorn's design:

* the `0106-terminal` patch follows Popcorn's `prim_tty.erl` patch for the
  browser;
* `Kettlecorn.Cook` (`mix kettlecorn.cook`) follows `mix popcorn.cook`;
* the host API (`Kettlecorn.call/4`, `cast/3`, `send/4`) mirrors Popcorn's
  JavaScript API (`popcorn.call`, `cast`, `send`).

Kettlecorn doesn't use Popcorn's Elixir package (its guest modules, packager
and tree-shaker), `popcorn_dist` (distribution over the bridge), the
JavaScript package and bundler plugins, the Emscripten build files, Local
LiveView, or the examples and docs. Apps that use Popcorn's browser APIs
need changes to run in Kettlecorn.

Popcorn is licensed under the Apache License 2.0. See
[THIRD_PARTY_NOTICES.md](https://github.com/mjrusso/kettlecorn/blob/main/THIRD_PARTY_NOTICES.md) for the other components
included in the runtime and their licenses.

The [development guide](development.md#build-stages) describes the build
stages; [PROTOCOL.md](https://github.com/mjrusso/kettlecorn/blob/main/PROTOCOL.md) specifies the frame and message formats.
