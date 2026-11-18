# Development

Run commands from the repository root. The Nix flake provides the compiler,
Erlang, Elixir, Rust, Wasmtime, and the check tools; use its development shell.

## Binary cache

The flake declares the public [kettlecorn Cachix cache](https://kettlecorn.cachix.org)
for prebuilt OTP. Nix uses it when you accept the flake's settings:
pass `--accept-flake-config`, or answer yes when prompted.

The `just` recipes omit that flag. To enable the cache in your Nix
configuration, run `cachix use kettlecorn` once as a trusted user, or with
sudo on a multi-user install.

Without the cache, the first build compiles LLVM's compiler-rt builtins,
wasi-libc, OpenSSL, and OTP (a native bootstrap, then the cross build).
LLVM, Erlang, Elixir, and Wasmtime come from the NixOS binary cache.

Changes to `patches/otp/`, C build inputs, `nix/otp.nix`, `nix/toolchain.nix`,
or pinned inputs can rebuild OTP. The compatibility build includes C sources
in `c/src/`, headers in `c/include/`, and the HTTP client's C, header, and WIT
files. C documentation and native tests are excluded from that source set;
OTP integration files have separate inputs in `nix/otp.nix`.

## Setup

Use Nix with flakes enabled. Accept the flake's cache settings before
`just deps` starts the runtime build:

```sh
nix develop --accept-flake-config
just deps
```

The shell keeps Mix and Hex in `.nix-mix/` and `.nix-hex/` under the directory
it was entered from, so enter it from the repository root. `just deps`
installs Hex, fetches the host library's development dependencies, and
builds the runtime.

```sh
nix build .#runtime                         # runtime in ./result
nix run .#kettlecorn-run -- examples/01_hello.exs one two
nix run .#iex                              # IEx in the guest
just example counter                      # IEx with a cooked application
```

Run `just` for the available tasks. The [examples](https://github.com/mjrusso/kettlecorn/blob/main/examples/README.md)
include scripts and cooked applications.

Python and Fish are used by development checks.

## Repository layout

```text
flake.nix, flake.lock  pinned inputs and build outputs
justfile               contributor tasks
nix/                   build stages
patches/otp/           OTP hooks applied after Popcorn's patches
c/                     emulator compatibility code, NIFs, and OTP replacements
guest/                 guest application and Hex dependency definitions
host/                  host library, tests, guides, and notebooks
launcher/              Rust execution library and native launcher
bin/kettlecorn-run     script and IEx entrypoint
tests/cli/             CLI integration tests
examples/              scripts and cooked Mix applications
PROTOCOL.md            host, guest, and launcher contracts
AGENTS.md              coding-agent instructions and invariants
RELEASING.md           runtime and Hex release procedure
LICENSE                Apache-2.0; third-party components have separate notices
```

## Checks

Inside the development shell:

```sh
just lint typecheck
just notebooks
just test
nix flake check
just docs
```

`lint` checks Rust, Nix and Elixir formatting, unused dependencies, Credo with
ExSlop and ExDNA, and the host's architecture rules. `typecheck` compiles
Elixir with warnings as errors, runs Clippy and Dialyzer, and rejects
compile-time cycles. Use `just format` for Nix and Elixir, and
`cargo fmt --manifest-path launcher/Cargo.toml` for Rust.

`just notebooks` runs each notebook's cells against the local runtime. It
skips the two setup cells that install the published package and runtime.

`just test` runs the native C stdio regression tests (`just test-stdio`),
the core host tests (`just test-host`), and the cooked-app tests
(`just test-apps`). `test-apps` builds the projects under `examples/apps/`
with the real `mix kettlecorn.cook` task, sets `KETTLECORN_EXAMPLES` to
`_kettlecorn/examples/`, runs `apps_test.exs`, and checks both `kettlecorn-run`
and `mix kettlecorn.run` with cooked apps. Kettlecorn is a path dependency
marked `runtime: false` in each example, so the tasks are available without
packaging the host library into the guest.
Adding an example requires its project directory and tests; no flake entry or
dependency hash is needed.

Runtime-dependent recipes build the working tree's runtime and set
`KETTLECORN_RUNTIME` to its path, overriding any exported value. The example
build loop passes that path to its cooking helper. Listing recipes, linting,
and formatting do not build the runtime.

`nix flake check` runs the native C stdio tests, host tests and notebook cells
in the Nix sandbox, excluding example app tests. It also checks the CLI
(scripts, `-e`, and IEx) and the [generated versions table](#pinned-versions).
`nix/cli-tests.nix` runs the executable test harnesses in `tests/cli/`.
The CLI and host checks include the platform's `ps` package in their sandbox
inputs to verify process cleanup on Linux and macOS.
CI runs `just test-apps` outside the sandbox on Linux and macOS. Core host tests,
native stdio tests, and notebooks run once per OS in `nix flake check`.

`just docs` builds ExDoc into `host/doc/`, rejects documentation warnings,
and checks local HTML links and fragments. It runs in CI on Linux.

CI is [`.github/workflows/kettlecorn.yml`](https://github.com/mjrusso/kettlecorn/blob/main/.github/workflows/kettlecorn.yml):
`nix flake check` and `just test-apps` on Linux and macOS, and `just lint typecheck docs`
on Linux, on every push and pull request.

See [AGENTS.md](https://github.com/mjrusso/kettlecorn/blob/main/AGENTS.md)
for code invariants and required validation when changing the project, and
[RELEASING.md](https://github.com/mjrusso/kettlecorn/blob/main/RELEASING.md) for publishing the runtime and Hex package.

See [performance](performance.md) for local benchmark commands.

## Build stages

The flake pins six inputs: nixpkgs, flake-utils, **Popcorn** (its main
branch, locked to a commit), **OTP** (its major release must match
nixpkgs' host Erlang, which the flake checks), **Elixir** (a release tag) and
**wasi-libc** (a commit with cooperative-thread support).
Each stage is a separately cached derivation (`nix build .#<name>`):

| Package | File | What it is |
|---|---|---|
| `resourceDir` | `nix/toolchain.nix` | clang's resource dir plus compiler-rt builtins for `wasm32-wasip3`, built with the thread-context libcalls that cooperative threads need |
| `sysroot` | `nix/toolchain.nix` | wasi-libc built with `ENABLE_COOP_THREADS` |
| `compat` | `nix/toolchain.nix` | POSIX stubs, stdio framing, sockets glue, and the `wasi:http` client; `wit-bindgen` generates HTTP bindings from the pinned Wasmtime WIT files |
| `cc` | `nix/toolchain.nix` | `wasi-cc`, the compiler driver OTP's configure and make use |
| `openssl` | `nix/openssl.nix` | static OpenSSL 3.5 (nixpkgs' source) |
| `otp` | `nix/otp.nix` | Popcorn's patches + [Kettlecorn's](https://github.com/mjrusso/kettlecorn/blob/main/patches/README.md), native bootstrap, cross build: `beam.wasm`, `beam-http.wasm`, kernel/stdlib/compiler/crypto/asn1/public_key/ssl |
| `guestDeps` | `nix/guest-deps.nix` | Req and its dependencies from Hex ([`guest/hex/mix.lock`](https://github.com/mjrusso/kettlecorn/blob/main/guest/hex/mix.lock), `fetchMixDeps`) |
| `launcher` | `nix/launcher.nix` | locked Rust execution library and binary; static musl on Linux, native on Apple silicon |
| `runtime` (default) | `nix/runtime.nix` | the native launcher and CLI, emulators and guest file system root: OTP and Elixir apps, Hex packages, the `kettlecorn_guest` app |
| `kettlecorn-run` (`apps.default`) | `flake.nix` | wraps the runtime's `bin/kettlecorn-run` with host tools on PATH; the script finds its runtime relative to its installed location; `apps.iex` adds `--iex` |

The toolchain uses nixpkgs' **unwrapped clang 23**, the first release with
component-model threading, plus lld, `wasm-component-ld`, `wit-bindgen`,
and `wasm-tools`. Clang invokes `wasm-component-ld` to link a WASIp3
component. The wasi-libc build uses these tools without downloading others.

`nix/otp.nix` copies the Erlang replacements and Makefile fragment in `c/otp/`
into OTP after applying the patches. It also copies `c/nif/` and the platform
header. Preloaded modules have checked-in BEAM files, so the build recompiles
`wasm`, `erl_init`, and `prim_inet` before building the native bootstrap.
Keep Kettlecorn runtime logic in `c/`; the patches provide its OTP hooks.
See [patch maintenance](https://github.com/mjrusso/kettlecorn/blob/main/patches/README.md)
for the file destinations and patch dependencies.

`host/VERSION` supplies the Hex package, runtime manifest, and shipped guest
application versions. Internal build derivations use the stable `unversioned`
label so release bumps do not invalidate the toolchain or dependency caches.

## Maintainer tasks

### Pinned versions

LLVM is selected in `nix/toolchain.nix` and OpenSSL in `nix/openssl.nix`.
The runtime licenses and generated versions table use those selections.

Everything is pinned: flake inputs in `flake.lock`, the rest by the pinned
nixpkgs. Elixir comes from the `elixir` flake input (an Elixir release tag),
built with nixpkgs' Elixir builder. The same Elixir compiles the guest code
(Elixir's own applications, Req, cooked apps) and runs the host library. The
guest's OTP comes from the `otp` input, and its major release must match the
host Erlang's.

<!-- versions: generated by `just docs-versions`; `nix flake check` fails when it's out of date -->
| Component | Version | From |
|---|---|---|
| Erlang/OTP (guest) | 29.1.2 | flake input `otp` |
| Erlang/OTP (host side) | 29.1.2 | nixpkgs (`beamMinimal29Packages`) |
| Elixir | 1.20.5 | flake input `elixir` |
| Popcorn | `55e87e7` (2026-11-10) | flake input `popcorn` (main) |
| wasi-libc | `c3a02dc` (2026-11-10) | flake input `wasi-libc` |
| wasmtime | 50.0.0 | nixpkgs |
| Rust (launcher) | 1.99.1 | nixpkgs |
| LLVM (clang, lld, compiler-rt) | 23.1.3 | nixpkgs |
| OpenSSL | 3.5.9 | nixpkgs |
| Req | 0.7.5 | `guest/hex/mix.lock` |
| nixpkgs | `f4a03c0` (2026-11-07) | flake input `nixpkgs` (nixos-unstable) |
<!-- /versions -->

`just update-elixir` moves to the latest Elixir release, `just update-popcorn`
to Popcorn's latest commit, and `just update` updates every input. Each one
rewrites this table; run `nix flake check` afterwards, because a new Popcorn
or OTP can make a patch stop applying.

### Mix dependency hashes

After changing `guest/hex/mix.exs`, run `just update-guest-deps` to refresh
its lockfile and fixed-output hash. The recipe only updates guest
dependencies. After changing host dependencies, run `mix deps.get` from
`host/` and refresh the host test hash with the procedure below.

Each `fetchMixDeps` hash must match its project's dependencies:

| Dependencies | Hash location | Build target |
|---|---|---|
| Guest Hex packages | `nix/guest-deps.nix` | `.#guestDeps.mixFodDeps` |
| Host test dependencies | `nix/host-tests.nix` | `.#checks.<system>.host-tests.mixFodDeps` |

To refresh any of these manually:

1. Fetch the project's dependencies to update its `mix.lock`.
2. Set its hash to `""` and run `nix build <target> --no-link` from the
   repository root. Use your Nix system, such as `x86_64-linux`, for `<system>`.
3. Copy the hash from the expected mismatch's `got:` line. If the build
   fails for another reason, restore the previous hash and fix that failure.
4. Run `nix build --rebuild <target> --no-link` to verify the new hash.

An unchanged hash can reuse a cached output locally even when the project's
dependencies changed. Rebuilding the fixed-output target catches that
mismatch before CI. Example apps built with `just build-examples` use Mix
directly and do not have fixed-output hashes.

### Maintaining the binary cache

Uploading requires a write token from the maintainer. Never commit it.
Store it only in:

- your local Cachix configuration, using `cachix authtoken <TOKEN>` (Cachix
  is in the dev shell). `just cache-push` builds the checks, release archive,
  and dev shell, then uploads what the cache lacks;
- the GitHub repository secret `CACHIX_AUTH_TOKEN`. The workflows use it
  to upload their builds. Without it, as in pull requests from forks,
  they only download.

CI builds and uploads x86_64 Linux, ARM Linux and Apple silicon macOS. Use
`just cache-push` to fill the cache before CI runs.

## Native launcher

`nix build .#launcher` builds the locked Rust package. Linux uses a static musl
binary; macOS builds natively for Apple silicon and uses the system libiconv.
The macOS build rewrites the library path and signs the launcher after fixup so
release archives run without Nix. `nix flake check` runs cache
unit tests and the library's in-process guest tests, in addition to the host
suite. For a local Rust test run, set `KETTLECORN_TEST_RUNTIME` to a built runtime
and run `cargo test --release --manifest-path launcher/Cargo.toml`.

See [Rust execution API](architecture.md#rust-execution-api) for preparation,
execution, and cancellation contracts.

For optional debugging with the Wasmtime CLI, prepare a private writable root
and ask the launcher to print the equivalent command. Install the version in
`launch/engine-version` yourself for this diagnostic path:

```sh
runtime=$(nix build .#runtime --no-link --print-out-paths)
root=$(mktemp -d)
cp -RL "$runtime/root/." "$root/"
chmod -R u+w "$root"
"$runtime/bin/kettlecorn-launch" --runtime "$runtime" --root "$root" \
  --print-wasmtime-command -- -e 'IO.puts("hello")'
# Run the printed command, then remove the private root:
rm -rf "$root"
```

The printed command is for manual debugging. It does not provide the native
launcher's port-close cancellation.
