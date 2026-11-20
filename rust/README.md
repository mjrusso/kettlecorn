# Kettlecorn

Kettlecorn lets Rust applications run untrusted Elixir and Erlang in a
WebAssembly sandbox. Evaluate code, call guest GenServers, and expose async
Rust functions to the guest.

The crate embeds Wasmtime in your application process. Each VM has a private
filesystem, and network access is off by default.

It uses the same guest runtime as [Kettlecorn's Elixir package](https://hex.pm/packages/kettlecorn).
Running guest code requires no host Elixir installation.

```sh
cargo add kettlecorn
```

`Runtime::find()` checks `KETTLECORN_RUNTIME` and the versioned user cache
shared with `mix kettlecorn.install`. Discovery is offline. It returns
`Error::RuntimeNotFound` when there is no cache entry, and reports an error
if an explicit override cannot be loaded, using the same errors as
`Runtime::load()`. Both methods return `Error::IncompatibleEngine` for a
runtime that requires a different Wasmtime version. On Linux, the cache is under
`$XDG_CACHE_HOME` or `~/.cache`. On macOS, it is under `~/Library/Caches`.
Both platforms use `kettlecorn/runtime-<version>` within that cache.

Enable the optional `installer` feature to install a matching release from Rust.

```sh
cargo add kettlecorn --features installer
```

Call `Runtime::install()` to download the release for the crate version and
platform, verify its SHA-256 against the checksum shipped with the crate,
and publish it atomically in the cache. A cache hit reuses the installed
release. Move an invalid cache entry aside before retrying. Installation also
returns `Error::IncompatibleEngine` when the release requires another
Wasmtime version. The call blocks. Use
`Runtime::install_with_progress()` on a background thread for GUI progress.
For a bundled runtime or a local build, pass its directory to
`Runtime::load(path)`.

Call `Runtime::start` from a Tokio runtime to boot a VM and use `Vm::eval`
to run guest code.
[API documentation](https://docs.rs/kettlecorn)
