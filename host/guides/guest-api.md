# Guest API

These modules run **inside the guest VM**. They ship in the runtime's
`kettlecorn_guest` application; adding the host Hex package to a project
does not make them available on the host.

The **host** is your Elixir or Rust application. The **guest** is the OTP system
in Wasmtime. The **runtime** contains the native launcher, WebAssembly emulators,
and the guest's OTP, Elixir, and library files. A **cooked application** is a
compiled Mix application and its dependencies, packaged for that guest.

For Elixir examples, see [Working with guest VMs](../notebooks/working-with-guests.livemd)
and [Use cases](../notebooks/use-cases.livemd). For Rust, see
[Hello World](https://github.com/mjrusso/kettlecorn/tree/main/examples/rust/hello-world)
for basic embedding,
[Device Monitor](https://github.com/mjrusso/kettlecorn/tree/main/examples/rust/device-monitor)
for stateful plugins and host callbacks, and
[Pulse Field](https://github.com/mjrusso/kettlecorn/tree/main/examples/rust/pulse-field)
for a graphical application driven by Elixir scripts.

The host functions are documented in `Kettlecorn` for Elixir and the
[Rust API reference](https://docs.rs/kettlecorn) for Rust.

## Messages to the host

`Kettlecorn.Host.send(term)` sends a guest term and returns `:ok`, or
`{:error, :frame_too_large}` if it fails the [frame size check](#frame-size-checks).

### Elixir host

With `owner: pid` set when starting the VM, the owner receives:

```elixir
{:kettlecorn, vm, {:message, term}}
```

The host decodes `term` as untrusted data through `Kettlecorn.ETF`. Delivery
has a bounded outstanding budget with host acknowledgments; see
[output and messages](sandbox.md#output-and-messages).

In the other direction, `Kettlecorn.send/4` delivers `{:wasm, payload}` to a
guest process, addressed by its registered name or a `Kettlecorn.Pid`
received from that VM.

### Rust host

`Vm::subscribe` receives future guest messages as `Value` instances. To receive
messages sent during boot, set `VmOptions::events` to a broadcast sender and
subscribe before starting the VM. A slow receiver gets a lag count when
messages have been overwritten; Rust delivery has no owner acknowledgments.

Use `Vm::call` or `Vm::cast` to send requests to registered guest processes.
These invoke the guest process through `Kettlecorn.Proxy`; they do not send
the `{:wasm, payload}` messages used by the Elixir host's `Kettlecorn.send/4`.

## Host calls

`Kettlecorn.Host.call(name, args, opts)` asks the host to perform
an operation. `name` is a string, `args` defaults to `%{}`, and `opts` defaults
to `[]`. `args` must be a map. The `:timeout` option is in milliseconds and
defaults to 5000; it also accepts `:infinity`. An unanswered call returns
`{:error, :timeout}`. A request that fails the
[frame size check](#frame-size-checks) returns `{:error, :frame_too_large}`
before sending.

### Elixir host

The guest waits while the owner handles:

```elixir
{:kettlecorn, vm, {:host_call, reply_to, name, args}}
```

The owner checks the name and arguments, then calls
`Kettlecorn.reply(vm, reply_to, result)`. `result` must be `{:ok, value}` or
`{:error, binary_reason}`. The guest receives that tuple unchanged.
With no VM owner configured, the host replies `{:error, "no host handler"}`.

`Kettlecorn.reply/3` queues a reply without confirming delivery.

### Rust host

Register async functions with `VmOptions::register` before starting the VM.
The function receives the argument map as a `Value` and returns
`Result<Value, String>`. The guest receives `Ok(value)` as `{:ok, value}`
or `Err(reason)` as `{:error, reason}`, with the reason encoded as a binary.
An unregistered name returns `{:error, "unknown host function"}`.

`VmOptions::host_call_timeout` sets the timeout for waiting on an async
callback, independently of the guest's `:timeout`. It cannot interrupt
blocking work. The first poll runs inline with VM transport; blocking there
stalls transport and can return a successful result after the timeout.
Use Tokio's blocking executor for blocking work. A callback timeout returns
a binary error reason.
Excess calls can time out if the client's rejection queue is full. See
[guest callbacks](architecture.md#guest-callbacks) for capacity limits.

### Reply decoding

The guest decodes host payloads without creating atoms. A reply containing
an atom absent from the guest is rejected and can cause the call to time
out. Prefer strings for application-defined names and error reasons.

Under `kettlecorn-run`, there is no host application to handle these events:
`Kettlecorn.Host.send/1` is a no-op and host calls time out.

## Frame size checks

When a host advertises a frame limit, `send/1` and `call/3` estimate the
encoded frame size before sending. The estimate is conservative and can
reject a term whose actual encoding would fit. The check also rejects
closures and native records because it cannot traverse their contents.
Rejected requests return `{:error, :frame_too_large}`.

The Rust client advertises an 8 MiB limit. See the
[protocol specification](https://github.com/mjrusso/kettlecorn/blob/main/PROTOCOL.md)
for frame limits and oversized-reply behavior.

## HTTP access

Start a VM with `http: true` in Elixir, set `VmOptions::http` to `true` in
Rust, or use `kettlecorn-run --http`, to enable
`Kettlecorn.HTTP`. Wasmtime makes these requests through `wasi:http` and
verifies TLS with its compiled Mozilla root CA list. The `:cacerts` option
does not change these roots. This grant permits any reachable destination;
see [network grants](sandbox.md#network-grants).

`Kettlecorn.HTTP.available?()` returns whether HTTP is enabled.

### Buffered requests

`Kettlecorn.HTTP.request(method, url, opts)` reads the whole response.
`opts` defaults to `[]`:

```elixir
{:ok, %{status: 200, headers: headers, body: body}} =
  Kettlecorn.HTTP.request(:get, "https://example.com/")
```

`method` is an atom or string; `url` is a string or `URI`. The result is
`{:ok, %{status: integer, headers: [{name, value}], body: binary}}` or
`{:error, reason}`. Errors include `:unsupported` without the HTTP grant,
`:invalid_url`, and transport failures such as `:connection_refused`.
The response body is held in guest memory.

| Option | Value | Default |
|---|---|---|
| `:headers` | List of `{name, value}` string pairs | `[]` |
| `:body` | Request body as iodata | No body |
| `:connect_timeout` | Connection timeout in milliseconds | `30000` |
| `:receive_timeout` | Maximum wait for the response head and for each body read, in milliseconds | `15000` |

Both timeout options accept `:default` or integer milliseconds from `0` through
`18_446_744_073_709`. `:default` selects the defaults above; zero requests an
immediate timeout. `:infinity` returns `{:error, :unsupported_timeout}` before
sending a request because wasi:http cannot disable timeouts. Other values raise
`ArgumentError`.

The receive timeout is per read. Use a VM lifetime limit to bound the whole
request. The direct HTTP API returns headers and body bytes; Req provides
redirect handling and decompression.

### Streaming responses

`Kettlecorn.HTTP.stream(method, url, acc, fun, opts)` uses the same
request options, with `opts` defaulting to `[]`. It calls `fun.(event, acc)`
with these events in order:

1. `{:status, status}`
2. `{:headers, headers}`
3. `{:data, chunk}` for each body chunk

The callback returns `{:cont, acc}` to continue or `{:halt, acc}` to stop.
The function returns `{:ok, acc}` on completion or an early halt, and
`{:error, reason, acc}` on a transport failure, with the accumulator from
before that failure. The body handle is closed on completion, early halt,
or a callback exception; callback exceptions propagate.

This guest example counts response bytes without retaining the body:

```elixir
Kettlecorn.HTTP.stream(:get, "https://example.com/", 0, fn
  {:data, chunk}, bytes -> {:cont, bytes + byte_size(chunk)}
  _event, bytes -> {:cont, bytes}
end)
```

## Req adapter

Req ships in the runtime. With `http: true`, the guest installs
`Kettlecorn.HTTP.ReqAdapter` as Req's default adapter:

```elixir
Req.get!("https://example.com/").body
```

See [HTTP and Req](running-applications.md#http-and-req) for grant selection,
permission errors, certificates, and adapter overrides.

Req's `:receive_timeout` and `connect_options: [timeout: value]` follow the
timeout rules above. With `:infinity`, `Req.get/2` returns
`{:error, %Req.TransportError{reason: :unsupported_timeout}}`; `Req.get!/2`
raises that exception.

The HTTP adapter supports `:into` with a callback function or a collectable.
It does not support `into: :self`. Request bodies supplied as enumerables are
collected before sending. Transport errors become `Req.TransportError`
exceptions. Collectables receive `:done` on success and `:halt` on transport
errors or exceptions; exceptions propagate after cleanup.

The implementation and source docstrings are in
[`guest/lib/kettlecorn/host.ex`](https://github.com/mjrusso/kettlecorn/blob/main/guest/lib/kettlecorn/host.ex)
and [`guest/lib/kettlecorn/http.ex`](https://github.com/mjrusso/kettlecorn/blob/main/guest/lib/kettlecorn/http.ex).
