# Host ⇄ VM stdio protocol

Protocol version 2.
Runtimes and libraries with different protocol versions cannot be used together.

The guest exchanges frames over its stdin and stdout. The native launcher
transports guest output to the host over a private local socket.
Set `KETTLECORN_FRAMED=1` in the guest environment to enable framing.
Without it, stdout and stderr are raw, stdin supplies guest input, and
bridge messages are dropped. To run a script without framing:

```bash
echo world | nix run .#kettlecorn-run -- -e 'IO.puts("hello " <> IO.gets(""))'
```

Bridge failures write a diagnostic to stderr in unframed mode and a `fatal`
frame in framed mode, then exit unsuccessfully. Read and allocation failures
do not become guest stdin EOF.

The launcher reads the runtime's `launch/` files for the guest environment
and emulator arguments. [`nix/runtime.nix`](nix/runtime.nix) defines those
files; the host launcher additionally forces `KETTLECORN_FRAMED=1`.

## Framing

Every frame, in both directions, uses this layout:

```
length:u32 (big endian, counts the type byte and the payload) | type:u8 | payload
```

This matches Erlang's `{:packet, 4}` framing, with a type byte before the
payload. The VM sends a `fatal` frame and exits if a host frame exceeds
64 MiB or is cut short. It also exits when stdin is closed. The Elixir host
splits the stream into frames itself so it can enforce `:max_message_size`
(default 64 MiB) before allocating a guest frame.

The embedded Rust client accepts guest frames up to 8 MiB. For frames larger
than 8 MiB and up to 64 MiB, it reads and discards the remaining bytes in
fixed-size chunks, then continues with the next frame. Truncated frames
and lengths above 64 MiB stop the session. The Rust client sets
`KETTLECORN_MAX_GUEST_FRAME_BYTES` so guest code can check the limit. The
limit counts the type byte and payload.

## Native launcher output transport

Host VMs pass `--output-socket PATH` to the native launcher. The path is in a
private mode-0700 host directory outside the guest root. The launcher listens
there and writes one zero byte to its process stdout when the listener is ready.
The host connects before guest execution starts. Port stdin still carries host
frames; port closure still cancels execution.

Socket output consists of `length:u32` (big endian) followed by at most 65,536
bytes of guest output. These transport records can split guest frames. The
host enforces the record size with `packet_size` and requests one record at a
time with `active: :once`, re-arming only after frame processing. At most one
65,536-byte record awaits processing in the VM mailbox, independently of owner
event budgets and whether an owner exists. Partial guest frames remain subject
to `:max_message_size`.

The host drains socket output through EOF before reporting the launcher's exit
status. The script CLI uses raw stdio without this socket transport. Runtimes
with another protocol version are rejected.

## VM → host

| type | name          | payload                                                     |
|------|---------------|-------------------------------------------------------------|
| 1    | `stdout`      | bytes the guest wrote to fd 1 (console output)              |
| 2    | `stderr`      | bytes the guest wrote to fd 2                               |
| 3    | `message`     | external term format (ETF), see below                       |
| 4    | `fatal`       | UTF-8 text; the VM is about to exit (e.g. out of memory)    |
| 5    | `send_result` | `id:u32 status:u8` answering a `send` frame                 |

All writes to fd 1 and 2 are wrapped into frames by the compat layer
(`c/src/framing.c`, reached through linker `--wrap`), including `IO.puts`,
logger output, and ERTS diagnostics. This keeps console output separate
from protocol data.

`c/src/framing.c` owns the C frame reader and writer, including the input
length limit and output policy for unframed mode. The bridge handles frame
payloads and message delivery.

`message` frames carry the ETF envelope
`%{type: :vm_message, data: term}`, produced by `:wasm.send/1`
(`Kettlecorn.Host.send/1`). A host call,
`Kettlecorn.Host.call(name, args)` (`:wasm.host_call/3`), sends
`%{type: :host_call, name: name, args: args, reply_to: binary}`;
the host answers by sending `{:ok, value}` or `{:error, reason}` to the
pid target `reply_to`. The guest returns the result tuple unchanged, or
`{:error, :timeout}` if no reply is delivered before the call's timeout.
Host error reasons are binaries, so the guest can distinguish host errors
from its own `{:error, :timeout}`.

`Kettlecorn.reply/3` queues the reply without confirming delivery. A reply
containing an atom absent from the guest's atom table is rejected; the
host receives no delivery error, and the guest call can time out.

The Rust client reads routing fields independently of the argument value.
If it can locate the argument term's boundary and read a valid reply token,
it can reject an undecodable argument with a binary error reason. If the
rejection queue is full, the guest call can time out.

With an advertised frame limit, `Kettlecorn.Host.send/1` and
`Kettlecorn.Host.call/3` return `{:error, :frame_too_large}` locally when
an upper bound on the encoded envelope, plus the frame type byte, exceeds
the frame limit. This size check can reject a term whose actual encoding would fit.
When a limit is advertised, closures and native records are rejected with
`{:error, :frame_too_large}` because the size check cannot traverse their contents.

Kettlecorn events use a separate envelope,
`%{type: :kettlecorn, event: event, ...}`, sent with `:wasm.send_envelope/1`
(`Kettlecorn.Event`), so the host never looks inside a `vm_message`
for them:

| `event` | fields | sent by |
|---|---|---|
| `:boot_ready` | `embedded_api` | `Kettlecorn.Boot`, once the applications have started |
| `:boot_failed` | | `Kettlecorn.Boot`; the reason goes to stderr and the VM exits |
| `:proxy_reply` | `id`, `result` | `Kettlecorn.Proxy`, answering a call (see below) |
| `:late_load` | `module` (binary) | `Kettlecorn.Preload`, when the code server loads a module on demand after preload |

The Rust client requires `embedded_api: 1` in `:boot_ready`. Version 1
supports evaluation value limits. When a proxy reply exceeds the advertised
frame limit, the proxy sends `{:error, :frame_too_large}` with the original
request ID. The Elixir host and CLI check the shared protocol version.

Guest envelopes use atom keys (`wasm.erl` builds them). The host uses string
keys for proxy requests and evaluation options because
the guest decodes them without creating atoms. User payloads may contain
atoms already loaded in the guest. The host drops unknown envelope types.

Treat every guest frame as untrusted. Guest code can put arbitrary bytes
into a message frame and forge events from `Kettlecorn.Boot` or
`Kettlecorn.Proxy`. The host decodes them with `Kettlecorn.ETF`, never with
`binary_to_term/1`, and treats an event's contents as data from the guest,
like any reply. A map whose `:__struct__` is an atom arrives as a
`Kettlecorn.Struct`, not as a struct of that module.

`send_result` status: 0 delivered, 1 no such process, 2 the payload could not
be decoded (malformed, or it contains atoms that don't exist in the guest:
payloads are decoded with `ERL_NIF_BIN2TERM_SAFE`), 3 unknown target kind,
4 malformed frame.

## host → VM

| type | name    | payload                                                           |
|------|---------|-------------------------------------------------------------------|
| 16   | `send`  | `id:u32 kind:u8 name_len:u32 name payload_etf`                    |
| 17   | `stdin` | bytes appended to the guest's standard input                      |
| 19   | `stdin_eof` | no payload; reads get `:eof` after queued bytes are consumed |

`send` delivers `{:wasm, payload}` to a guest process. `kind` 0 addresses a
registered name encoded as UTF-8; lookup uses only existing atoms. `kind` 1
addresses a pid: `name` is the ETF of a pid or a `{pid, token}` tuple.
For the tuple form, the delivered message is `{:wasm, {token, payload}}`;
this routes host-call replies. The VM answers every `send` with a
`send_result` frame carrying the same `id`.
The Rust client sends host-call replies with ID 0 and ignores their
`send_result` frames. Other requests use IDs from 1 through `u32::MAX`
without reuse. Once those IDs are used, start a new VM to issue more requests.

Guest PID handles on the host include the originating VM PID. They cannot be
used with another VM; that identity is host metadata and is not sent on the wire.

`kind` 2 addresses a registered name and delivers `{:wasm, {id, payload}}`,
using the enclosing send frame's ID. Calls and casts use this kind to reach
`Kettlecorn.Proxy` (`:kettlecorn_proxy`). A call's payload is:

```elixir
%{"kind" => "call", "target" => name, "request" => term, "proxy_timeout_ms" => ms}
```

The proxy answers with a `:proxy_reply` event carrying the same `id` and a
`result` of `{:ok, reply}` or
`{:error, :noproc | :timeout | :frame_too_large | {:exit, inspected_reason}}`.

The proxy passes `proxy_timeout_ms` directly to `GenServer.call/3`. An
evaluation calls the target `kettlecorn_evaluator` with:

```elixir
{:eval, code, %{
  "timeout_ms" => evaluation_ms,
  "finish_timeout_ms" => finish_ms,
  "binding" => binding,
  "language" => "elixir", # or "erlang"
  "max_reductions" => limit # 1..2^63-1, or :infinity (the default)
}}
```

An evaluation reply includes `"reductions"`, the reductions charged to
the evaluation, its descendants, and output callbacks before the budget
closes. On timeout, the evaluator closes the budget after requesting
termination. When a charge exceeds the limit, the count includes that
charge and the evaluation fails with `"kind" => "reductions"`. Requests
rejected before evaluation receive a `badarg` reply without the count.

The Elixir and Rust clients both use a reply margin of 1,000 ms. For a
finite timeout `t` and reply margin `m`, the budgets in milliseconds are:

| Request | Evaluation | Capture finish | Proxy call | Host deadline |
|---|---|---|---|---|
| Call | | | `t` | `t + m` |
| Evaluation | `t` | `div(m, 2)` | `t + m` | `t + 2*m` |

On the Elixir host, an infinite timeout keeps the evaluation, proxy and host
deadlines infinite. Capture finish remains bounded. The evaluator's timeout
covers evaluation, formatting and result traversal. `finish_timeout_ms`
bounds collecting captured output and acknowledging forwarding. A timeout
or capture failure starts teardown. Descendant cleanup can continue
after the reply; the coordinator kills remaining capture processes at its
cleanup deadline. The proxy and host deadlines bound the caller's wait.
The guest receives these budgets and has no mirrored margin constants.

An evaluator request may also specify `"value_limits" => {terms, depth, bytes}`.
The evaluator includes `"value"` only if the structured result fits the
term and depth limits and the evaluation reply, including captured output,
fits the byte limit. If the evaluator omits `"value"`, it still returns
the inspected result and captured output, which can exceed that byte limit.
Clients should leave room for the enclosing proxy reply and event frame
when choosing these limits.

The C bridge routes the enclosing `send` frame and decodes its ETF payload;
it does not interpret the proxy or evaluation timeout fields.

A cast has no proxy reply. The Rust client waits for the send result that
confirms delivery to the proxy. A cast uses this payload.

```elixir
%{"kind" => "cast", "target" => name, "request" => term}
```

Unread stdin never blocks delivery of other host frames. See the
[architecture guide](host/guides/architecture.md#framed-stdio) for details.

## Cooked applications

`/app/kettlecorn.json` records `protocol` (an integer), `otp` (the compiler's
OTP major release string), and `elixir` (its exact version string). The map
must contain exactly these three fields with matching values. The host checks
the original bundle against the runtime manifest before copying.
`Kettlecorn.Boot` checks the copied metadata inside the guest before adding
cooked code paths or loading configuration.
The guest's runtime manifest is available at `/manifest.json`.

## Native root population

Both entrypoints run `kettlecorn-launch --prepare-root --runtime DIR --root NEW`
before execution. The native operation copies `runtime/root`, dereferences
source symlinks, and makes copies writable. It refuses existing destinations or
roots inside the runtime and removes newly created roots on failure.

`--app-dir DIR` overlays the cooked bundle at `/app`. `--certificates FILE`
installs the selected PEM bytes at the runtime's `KETTLECORN_CACERTFILE` path.
Elixir selects host certificates; the shell discovers its host bundle. Neither
entrypoint reads launch configuration to find the guest certificate location.
`--copy-dir SOURCE GUEST_PATH` and `--copy-file SOURCE GUEST_PATH` stage extra
code and scripts at declared absolute guest paths. Destinations cannot escape
the private root. Root population starts no engine or guest.

## Launcher stats

With `--stats PATH`, the launcher creates `PATH` (mode 0600) before the guest
starts and maps it. Host VMs put it in the private VM directory, outside the
guest root. The file holds three little-endian `u64` words:

| Offset | Value |
|---|---|
| 0 | fuel consumed, including boot; 0 unless `--fuel` is set |
| 8 | linear memory in bytes |
| 16 | checksum: `mix(fuel ^ mix(memory))` |

`mix` is the SplitMix64 finalizer, with wrapping 64-bit arithmetic:

```text
z = (z ^ (z >> 30)) * 0xbf58476d1ce4e5b9
z = (z ^ (z >> 27)) * 0x94d049bb133111eb
z ^ (z >> 31)
```

For fuel 123 and memory 456, the checksum is `0x2481f22f5c03602e`. A new file
is all zeros, which is a valid record.

The launcher updates the file when the guest calls the host, on every epoch
tick while it runs, and when the execution ends. Memory growth appears once
Wasmtime has allocated it. The termination record carries the final values.
Updates can be continuous, so readers read the 24 bytes in one read and
accept the values when the checksum matches, retrying otherwise.

## Launcher termination

After dropping the guest, the native launcher atomically publishes a UTF-8 JSON
object at `<stderr>.stopped`. The file is outside the guest root. Its publication
also confirms that cleanup may remove the private root. The object has one of
these shapes:

```json
{"outcome":"exited","code":0}
{"outcome":"cancelled"}
{"outcome":"timeout"}
{"outcome":"out_of_fuel"}
{"outcome":"failed"}
```

Every record also has `"memory"`, the guest's final linear memory in bytes,
and, when `--fuel` is set, `"fuel_consumed"`, the final fuel count:

```json
{"outcome":"out_of_fuel","fuel_consumed":1000000000,"memory":67108864}
```

`exited` carries the guest exit code (or a launcher argument/signal exit code).
`cancelled` confirms cancellation through the input port. Both exit code zero
and cancellation map to `:normal` on the host. Timeout and fuel exhaustion map
to `:timeout` and `:out_of_fuel`. Other exits and failures retain diagnostics in
`{:exit_status, code, stderr_prefix}`. If the record is missing or invalid, the
host uses the process exit status; stderr never determines the outcome. Guest
fatal frames retain priority over launcher outcomes.

Unexpected traps and setup errors produce `failed`, with diagnostics written to
stderr. Only the first 4096 diagnostic bytes are retained by the host. The Rust
library returns `ExecutionOutcome`, including the original error for `Failed`;
it classifies Wasmtime fuel and interruption traps by type.
