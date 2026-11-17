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

test: test-stdio

test-stdio:
    python3 c/test/stdio_test.py

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
