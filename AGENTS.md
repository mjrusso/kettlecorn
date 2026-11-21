# Agent instructions

Use direct, literal language.

## Commits

Use Conventional Commits with the area as the scope, for example
`feat(guest): add Kettlecorn.HTTP` or `fix(run): start apps before IEx`.
Scopes: `nix` (flake.nix, nix/), `otp` (patches/otp), `c` (the compat layer),
`guest` (guest/), `host` (host/), `run` (bin/kettlecorn-run), `examples`,
`docs`, `launcher` (rust/). Use `ci` for GitHub Actions and `chore` for
repository tooling. Keep each commit focused on one area.

## Development documentation

[The development guide](host/guides/development.md) describes the repository
layout, build stages, contributor setup, checks, and pinned versions.
[The architecture guide](host/guides/architecture.md) describes the host,
native launcher, guest, and OTP patches. Keep those guides current when changing
their areas.
Put new emulator code in `c/`; keep OTP patches to the hooks that call it.

## Environment

Run everything in `nix develop` (or `nix develop .#ci -c COMMAND`). The shell
keeps Mix and Hex in `.nix-mix/` and `.nix-hex/` under the directory it was
entered from: enter it from this directory. `just deps` installs Hex,
fetches the host library's dev dependencies and builds the runtime. Configure
the binary cache before building. Changes to `patches/otp/`, C build
inputs, `nix/otp.nix`, `nix/toolchain.nix`, the Wasmtime source pin in
`rust/Cargo.toml` and `flake.nix`, or pinned inputs can rebuild OTP.
The compatibility build excludes C documentation, native tests, and the OTP
integration files; `nix/otp.nix` depends on the integration files separately.

## Binary cache

Use the [development guide's cache instructions](host/guides/development.md#binary-cache).
Never commit the Cachix write token or paste it into logs or messages.

## Checks

Before finishing a change, run:

- `just lint typecheck`: formatting (Rust, Nix, host and guest Elixir),
  `mix deps.unlock --check-unused`, Credo with ExSlop and ExDNA, Reach's
  architecture check (`host/.reach.exs`), compilation with warnings as errors,
  Clippy, Dialyzer, and the compile-time cycle check.
- `just notebooks`: runs the notebooks' cells (`host/notebooks`) against the
  runtime, skipping their two setup cells. Update the notebooks when the API
  they show changes.
- `just test`: the native C stdio tests, the host library's tests against
  the runtime, and the cooked example apps.
- `nix flake check`: every build stage, Rust tests, host tests and notebook cells
  in the Nix sandbox, and the `kettlecorn-run` check (scripts, `-e`, IEx). `just test` also
  checks the CLI with cooked apps. Run `nix flake check`
  after any change to the build, native launcher, guest, `bin/kettlecorn-run`
  or examples.

Fix every failure. Keep Credo and duplication findings at zero; fix findings
rather than weakening `.credo.exs`. `just format` formats Nix and Elixir;
`cargo fmt --manifest-path rust/Cargo.toml` formats Rust. `just docs` builds
the host library's documentation (ExDoc), rejects warnings, and checks local
HTML links. Run it after documentation changes.

`host/.reach.exs` encodes invariants below as call rules: nothing calls
`binary_to_term`, only `Kettlecorn.VM` opens ports, only `Dir`, `Runtime`, and
`Mix.Tasks.Kettlecorn.Run` run external commands, only `Cook` turns strings
into atoms, and the decoders of guest output (`Kettlecorn.ETF`,
`Kettlecorn.Protocol`) do no I/O. A new caller
of one of these changes an invariant: update the rule and its comment with it.

`host/test/property_test.exs` (StreamData) checks the parsers of guest
output: they decode what OTP encodes, and never raise or create atoms on
anything else. Extend it when changing `Kettlecorn.ETF` or
`Kettlecorn.Protocol`.

`just bench` runs the benchmarks (`host/bench/startup.exs`: VM start, cold
and warm; `host/bench/workloads.exs`: round trips and programs, guest
against native). They aren't checks; run them when a change may affect
performance (the emulator flags, the protocol, `Kettlecorn.VM`). Keep benchmark
results outside the source tree. The [performance guide](host/guides/performance.md)
describes the suites and how to run them locally.

CI (`.github/workflows/kettlecorn.yml`) runs `nix flake check` and `just test-apps`
on Linux and macOS on every push and pull request. Both platforms run
`just test-runtime-cache` against a locally built release archive, including
the Rust unit tests with the `installer` feature. The Linux checks job also
runs `just lint typecheck docs` and `just test-rust-examples`.

## Invariants

- The guest is untrusted. The host decodes everything the guest sends with
  `Kettlecorn.ETF` (no new atoms, no funs, no structs of host modules), never
  with `binary_to_term/1`, and treats it as data. Structs whose module atom
  exists on the host arrive as `Kettlecorn.Struct`; unknown module atoms stay
  in ordinary maps as `{:unknown_atom, name}`.
- The guest decodes host payloads with `ERL_NIF_BIN2TERM_SAFE`: no new atoms.
- Grants default to off. A VM gets the network or HTTP only when asked
  (`network: true`, `http: true`, `--network`, `--http`). `beam.wasm` doesn't
  import `wasi:http`; only `beam-http.wasm` does.
- Private-root population is implemented in the Rust launcher and invoked by
  both entrypoints. Certificate selection stays at the host/CLI boundary;
  only native code reads the guest certificate destination from launch config.
- Each VM runs on its own writable copy of the runtime's root; the runtime
  in the Nix store is never written. Make copies writable explicitly (the
  store is read-only for non-root users).
- Rust runtime preparation owns reusable engines and compiled components, and
  serializes compilation across clones. Executions own their stores and
  cancellation state; running a guest submits no compilation work.
- Launcher output reaches the host VM through one-at-a-time socket records
  capped at 64 KiB, before decoding or owner delivery. Re-arm delivery only
  after frame processing, including when no owner is configured.
- No native code in the guest: no NIFs or ports beyond what is linked into
  the emulator. `Kettlecorn.Cook` warns about `.so` files in `priv/`.
- Guest `.beam` files are compiled with the host Erlang/Elixir from the
  flake, which must have the guest's OTP major release (the flake asserts it)
  and Elixir version.
- Guest arguments and environment are defined in `nix/runtime.nix` and written
  to the runtime's `launch/` files. The Rust library reads them for both host
  VMs and `bin/kettlecorn-run`. Engine configuration and grants are implemented
  in `rust/`. Keep the `-Mea min` emulator flag (plain `malloc`): ERTS's
  allocators fragment WebAssembly memory, and a host integration test catches
  that. Cooked applications are copied to `/app`; `Kettlecorn.Boot` loads
  their code and configuration.
- Both host programs and `bin/kettlecorn-run` start a VM's applications
  through `Kettlecorn.Boot`.
- The protocol in `PROTOCOL.md` is shared by `c/src/framing.c`, the bridge in
  `c/nif/kettlecorn_bridge.c`, the guest app and
  `host/lib/kettlecorn/protocol.ex` (the host's frames and envelopes); change
  them together and update `PROTOCOL.md`.

## Releases

`RELEASING.md` covers the GitHub runtime archives, the Hex package from
`host/`, and the crates.io package from `rust/`. The `release` job in
`.github/workflows/kettlecorn.yml` builds and publishes the runtime archives
for tag `v<version>`.
Run `just release-checksums <version>` after the archives are published to
record the same checksums in `host/priv/checksums.txt` and `rust/checksums.txt`.
Keep `host/VERSION` and the crate version in `rust/Cargo.toml` in sync. Bump
the protocol version, `host/PROTOCOL_VERSION`, for any incompatible protocol
change: the library refuses runtimes with another one.

## Pinned inputs

- Versions come from the flake inputs (Popcorn tracks main; OTP, Elixir and
  wasi-libc are pinned to a tag or commit in `flake.nix`), nixpkgs, and the
  Wasmtime dependency pin in `rust/Cargo.toml`. The
  development guide's versions table is generated (`just docs-versions`), and
  `nix flake check` fails when it's stale.
- `just update-elixir` (latest Elixir release), `just update-popcorn`
  (Popcorn's latest commit), `just update` (every input). Run
  `nix flake check` after each. A new OTP release must match the host Erlang
  in nixpkgs, and every patch must still apply.
- To update Wasmtime, edit the three exact `=` pins in `rust/Cargo.toml`,
  run `cargo update -p wasmtime` with each manifest
  (`rust/Cargo.toml` and `examples/rust/*/Cargo.toml`), refresh the
  source hash in `flake.nix`, run `just docs-versions`, then run
  `nix flake check`. Keep the version in the fetched source's name so a stale
  hash cannot reuse another release's source tree.
- After editing `guest/hex/mix.exs`, run `just update-guest-deps` to refresh
  `mix.lock` and the `fetchMixDeps` hash (it fails, restoring the old hash,
  when the build fails for another reason). A stale hash goes unnoticed
  locally, because Nix reuses the existing output for an unchanged hash,
  and fails in CI. Verify with `nix build --rebuild .#guestDeps.mixFodDeps`.
- The host tests' hash in `nix/host-tests.nix` must be refreshed after
  `host/mix.lock` or `host/mix.exs` changes (verify with
  `nix build --rebuild .#checks.x86_64-linux.host-tests.mixFodDeps`).
