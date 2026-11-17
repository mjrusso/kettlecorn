# wasi:http client

[`kettlecorn_http.c`](kettlecorn_http.c) implements a blocking HTTP client over
`wasi:http/client@0.3.0` (WASIp3). The emulator's
[`wasm` NIF](../nif/kettlecorn_http_nif.c) exposes it through `wasm:http_send/8`,
`http_read/2`, and `http_close/1` for `Kettlecorn.HTTP`.

The client waits on component-model waitable sets. Waiting suspends only
the calling cooperative thread; other BEAM threads can run.

Timeouts cross the NIF boundary as `default`, a non-negative integer in
milliseconds, or `infinity`. The client applies 30-second connect and 15-second
receive defaults. Finite values include zero and must fit in a WASI `u64`
duration after conversion to nanoseconds. The receive timeout applies to the
response head and each gap between body chunks. WASI HTTP cannot disable these
timeouts, so `infinity` returns `unsupported_timeout` before sending a request.

## Bindings and linking

[`nix/toolchain.nix`](../../nix/toolchain.nix) generates the C bindings
(`http_nif.c`, `http_nif.h`, and `http_nif_component_type.o`) with `wit-bindgen c`
from [`world.wit`](world.wit) and the WIT files in the pinned Wasmtime source.

The component type object carries the world's type information and is linked
into `beam-http.wasm` only. The plain `beam.wasm` does not import `wasi:http`
and runs without HTTP interfaces linked by the launcher.

## Header ownership

The NIF supplies request headers through an iterator. The client builds a
WIT descriptor array that borrows the NIF's binary data until the send returns.
Response header bytes are borrowed during a visitor callback, where the NIF
copies them into Erlang binaries. The client frees the WIT header list before
returning the body handle. The client and NIF report allocation failures as
`out_of_memory`.
