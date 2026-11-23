# Releasing

A release has three parts with the same version:

- **Platform runtime archives** `kettlecorn-runtime-<version>-<system>.tar.gz`,
  attached to GitHub release `v<version>` for `x86_64-linux`, `aarch64-linux`
  and `aarch64-darwin`. Each holds the emulators, guest root, manifest,
  licenses, native `bin/kettlecorn-launch` and Bash `bin/kettlecorn-run`.
  Linux launchers are static musl binaries; Python and Wasmtime are not required.
- **The Hex package** `kettlecorn` (from `host/`): the host library,
  `mix kettlecorn.cook` and `mix kettlecorn.install`. It doesn't contain the
  runtime. `mix kettlecorn.install` downloads the archive and checks it
  against the SHA-256 in the package's `priv/checksums.txt`.
- **The Rust crate** `kettlecorn` (from `rust/`), published to crates.io.
  Rust applications use the runtime archive from the GitHub release with
  the same version. The optional `installer` feature verifies it against
  `rust/checksums.txt`.

Keep `host/VERSION` and the crate version in `rust/Cargo.toml` in sync.
The runtime's `manifest.json` records the version,
along with the protocol version (`host/PROTOCOL_VERSION`). The library refuses
a runtime with another protocol version. Bump the protocol version for any
incompatible change to frames, envelopes, guest events, or proxy messages
(`PROTOCOL.md`). Also bump it for incompatible changes to the contract
between launchers and `Kettlecorn.Boot`, including Boot's arguments and a
cooked app's `/app` layout.

Run release commands in `nix develop` from the repository root unless a step
specifies another directory.

## Steps

1. **Prepare.** Set the version in `host/VERSION` and `rust/Cargo.toml`.
   Refresh the lockfiles in `rust/` and `examples/rust/*/`. Add a `## <version>`
   entry to `host/CHANGELOG.md` and `rust/CHANGELOG.md`. If the major or minor
   version changed, update the dependency snippets in the root and package
   READMEs, `examples/README.md`, `host/guides/`, the Mix task examples, and
   every `Mix.install` cell in `host/notebooks/*.livemd`.
   Run `just docs-versions`. `nix flake check` and `just lint typecheck docs` must
   pass. Commit and push `main`.

2. **Tag and push.**

   ```sh
   git tag v<version>
   git push origin v<version>
   ```

   The tag starts the `kettlecorn` workflow. Its `release` job waits for
   `nix flake check` and `just test-apps` on Linux and macOS, plus the
   Linux checks job for lint, typecheck, docs, and Rust tests. It then checks
   that the tag matches `host/VERSION`, builds each platform archive natively
   (`nix build .#release`), and publishes
   the GitHub release only after all archives and their `.sha256` files exist. Check the release:
   `gh release view v<version>`.

3. **Record the checksum.**

   ```sh
   just release-checksums <version>
   ```

   This downloads all three platform archives, verifies their published
   `.sha256` files, and writes their SHA-256s to `host/priv/checksums.txt` and
   `rust/checksums.txt`. Commit both files and push `main` before publishing
   either package. A local `just release-archive` builds the current platform's
   archive. Native macOS outputs must be built on macOS.

4. **Verify both packages before publishing.** From a clean checkout of the
   checksum commit, run these checks at the repository root on Linux:

   ```sh
   just release-smoke-rust
   cargo publish --locked --dry-run --manifest-path rust/Cargo.toml --features installer
   ```

   The smoke recipe first requires both packages to have matching SHA-256
   entries for this version on x86_64 Linux, AArch64 Linux, and AArch64 macOS.
   Run `just check-release-checksums` to check coverage on its own.
   The smoke check downloads and verifies the published archive with both
   installers in fresh caches, verifies discovery across the Rust and Elixir APIs,
   and boots each installation from Rust. On Linux, also check installation
   from a file without network access:

   ```sh
   version=$(cat host/VERSION)
   archive="kettlecorn-runtime-$version-$(uname -m)-linux.tar.gz"
   curl -fsSLO "https://github.com/mjrusso/kettlecorn/releases/download/v$version/$archive"
   just release-smoke-offline "$archive"
   ```

   The recipe uses fresh caches and runs both installers in a network
   namespace. Each installer verifies the archive against its bundled
   checksum. The host must allow `unshare --net --map-root-user`.
   Then check the Hex package from `host/`:

   ```sh
   mix docs --warnings-as-errors
   python3 scripts/check_doc_links.py doc
   mix hex.build
   ```

   `mix hex.build` lists the package's files: `lib`, `priv/checksums.txt`,
   `mix.exs`, `VERSION`, `PROTOCOL_VERSION`, `README.md`, `CHANGELOG.md`, `LICENSE`,
   `.formatter.exs`, the notebooks in `notebooks/`, and the guides in `guides/`.
   Check the generated documentation's navigation and links before publishing.

   Test the extracted runtime archive on each target platform. On Linux,
   also boot it in a minimal non-Nix container without Python or Wasmtime.

5. **Publish to Hex.** Authenticate with `mix hex.user auth` once per machine,
   then, from `host/`:

   ```sh
   mix hex.publish
   ```

   HexDocs links the source to the tag, so publish after pushing it.

6. **Publish to crates.io.** Use the checkout verified in step 4.
   Authenticate with `cargo login` if needed, then publish from the repository root.

   ```sh
   cargo publish --locked --manifest-path rust/Cargo.toml
   ```

7. **Check the notebooks.** Outside the checkout, open each notebook in
   `host/notebooks` in Livebook and run it: its setup cells install the
   published package and the released runtime.

## Wasmtime updates

When a Wasmtime release fixes a security issue, follow the
[Wasmtime update procedure](host/guides/development.md#pinned-versions),
release Kettlecorn, and identify the security fix in the CHANGELOG. Users of
`mix kettlecorn.install` receive the fix through that release.
