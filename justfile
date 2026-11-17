# Kettlecorn tasks. Run inside `nix develop` (or prefix with
# `nix develop -c`): Erlang, Elixir, Rust and just come from the flake.

# Resolve the working tree's runtime only in recipes that use it.
runtime := 'KETTLECORN_RUNTIME=$(nix build .#runtime --no-link --print-out-paths) || exit; export KETTLECORN_RUNTIME'

default:
    @just --list

# Build the runtime (emulators + guest root) into ./result.
build:
    nix build .#runtime

# Run an Elixir script in the sandbox, e.g. `just run examples/01_hello.exs`.
run *args:
    nix run .#kettlecorn-run -- {{args}}

# Interactive IEx in the sandbox (line editing, history, completion).
iex *args:
    nix run .#iex -- {{args}}

# An IEx session with the host library, ready to start VMs.
dev:
    {{runtime}} && cd host && iex -S mix

test: test-stdio test-host

test-host:
    {{runtime}} && cd host && mix test --exclude examples

test-stdio:
    python3 c/test/stdio_test.py

# Rust/Nix/Elixir formatting, unused dependencies, Credo and Reach. Needs `just deps`.
lint:
    cargo fmt --manifest-path launcher/Cargo.toml -- --check
    nixpkgs-fmt --check flake.nix nix/*.nix
    cd host && mix format --check-formatted && mix format --check-formatted $(find ../guest/lib -name '*.ex')
    cd host && mix deps.unlock --check-unused && mix credo && mix reach.check --arch
    cmp LICENSE host/LICENSE  # the Hex package carries a copy

# Clippy, Elixir compilation with warnings as errors, Dialyzer and compile-time cycles.
typecheck:
    cargo clippy --manifest-path launcher/Cargo.toml --all-targets -- -D warnings
    cd host && mix compile --force --warnings-as-errors
    cd host && mix dialyzer --format short
    cd host && mix xref graph --format cycles --label compile-connected --fail-above 0

format:
    nixpkgs-fmt flake.nix nix/*.nix
    cd host && mix format && mix format $(find ../guest/lib -name '*.ex')

# The runtime release archive (as the release workflow builds it), into ./release.
release-archive:
    nix build .#release -o release

# Record every published platform archive checksum in the Hex package.
release-checksums version:
    #!/usr/bin/env bash
    set -euo pipefail
    tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
    for target in x86_64-linux aarch64-linux aarch64-darwin; do
      name="kettlecorn-runtime-{{version}}-$target.tar.gz"
      base="https://github.com/mjrusso/kettlecorn/releases/download/v{{version}}"
      curl -fsSL -o "$tmp/$name" "$base/$name"
      curl -fsSL -o "$tmp/$name.sha256" "$base/$name.sha256"
      (cd "$tmp" && sha256sum -c "$name.sha256")
    done
    (cd "$tmp" && sha256sum *.tar.gz) | tee host/priv/checksums.txt

# Needs a cache write token configured with `cachix authtoken <TOKEN>`;
# see host/guides/development.md, "Binary cache".
# Builds the checks, the release archive and the dev shell; uploads them to Cachix.
cache-push:
    cachix watch-exec kettlecorn -- sh -c 'nix flake check --accept-flake-config && nix build --accept-flake-config --no-link .#release && nix develop --accept-flake-config -c true'

# Install Hex, fetch host development dependencies, and build the runtime.
deps:
    cd host && mix local.hex --if-missing --force && mix deps.get
    nix build .#runtime --no-link

# After editing guest/hex/mix.exs: refresh mix.lock and the fetchMixDeps hash.
update-guest-deps:
    #!/usr/bin/env bash
    set -euo pipefail
    (cd guest/hex && export MIX_HOME=$PWD/.mix && mix local.hex --force --if-missing && mix deps.get && rm -rf .mix deps _build)
    old=$(sed -n 's#.*hash = "\(sha256-[^"]*\)";#\1#p' nix/guest-deps.nix)
    sed -i "s#hash = \"$old\";#hash = \"\";#" nix/guest-deps.nix
    # The build fails on the empty hash and prints the right one.
    hash=$(nix build .#guestDeps.mixFodDeps --no-link 2>&1 | sed -n 's/.*got: *//p' || true)
    if [[ -z "$hash" ]]; then
      sed -i "s#hash = \"\";#hash = \"$old\";#" nix/guest-deps.nix
      echo "update-guest-deps: no hash from nix build .#guestDeps.mixFodDeps; restored the old one" >&2
      exit 1
    fi
    sed -i "s#hash = \"\";#hash = \"$hash\";#" nix/guest-deps.nix
    echo "fetchMixDeps hash: $hash"
