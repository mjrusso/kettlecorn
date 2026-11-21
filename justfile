# Kettlecorn tasks. Run inside `nix develop` (or prefix with
# `nix develop -c`): Erlang, Elixir, Rust and just come from the flake.

# Resolve the working tree's runtime only in recipes that use it.
runtime := 'KETTLECORN_RUNTIME=$(nix build .#runtime --no-link --print-out-paths) || exit; export KETTLECORN_RUNTIME'
extra_elixir := '../examples/apps/*/mix.exs $(find ../examples/rust -name target -prune -o -name "*.exs" -print) $(find ../guest/lib -name "*.ex")'
release_targets := 'x86_64-linux aarch64-linux aarch64-darwin'

default:
    @just --list

# Build the runtime (emulators + guest root) into ./result.
build:
    nix build .#runtime

# Run an Elixir script in the sandbox, e.g. `just run examples/01_hello.exs`.
run *args:
    nix run .#kettlecorn-run -- {{args}}

# Run example scripts except 06_network.exs, which needs a server.
examples:
    nix run .#kettlecorn-run -- examples/01_hello.exs one two
    nix run .#kettlecorn-run -- examples/02_processes.exs
    nix run .#kettlecorn-run -- examples/03_genserver.exs
    printf 'the fox and the dog\nthe end\n' | nix run .#kettlecorn-run -- examples/04_stdin.exs
    -nix run .#kettlecorn-run -- --timeout 2s examples/05_runaway.exs

# Interactive IEx in the sandbox (line editing, history, completion).
iex *args:
    nix run .#iex -- {{args}}

# Build all cooked example apps used by the host tests.
build-examples:
    #!/usr/bin/env bash
    set -euo pipefail
    {{runtime}}
    for project in examples/apps/*/mix.exs; do
      just _cook-example "$(basename "$(dirname "$project")")" "$KETTLECORN_RUNTIME"
    done

cook-example name:
    #!/usr/bin/env bash
    set -euo pipefail
    {{runtime}}
    just _cook-example {{quote(name)}} "$KETTLECORN_RUNTIME"

_cook-example name runtime_path:
    #!/usr/bin/env bash
    set -euo pipefail
    task_root=$PWD
    export KETTLECORN_RUNTIME={{quote(runtime_path)}}
    cd "examples/apps/"{{quote(name)}}
    MIX_ENV=prod mix deps.get --only prod
    MIX_ENV=prod mix kettlecorn.cook --out "$task_root/_kettlecorn/examples/"{{quote(name)}}

[positional-arguments]
example name *args="--iex": (cook-example name)
    #!/usr/bin/env bash
    set -euo pipefail
    task_example=$1
    shift
    nix run .#kettlecorn-run -- --app "_kettlecorn/examples/$task_example" "$@"

# The host-library demo: eval, GenServer calls, messages, host calls, limits.
demo:
    {{runtime}} && cd host && mix run ../examples/host_demo.exs

# Evaluate a greeting in an embedded VM.
rust-hello-world:
    @{{runtime}} && cargo run --quiet --locked --manifest-path examples/rust/hello-world/Cargo.toml --target-dir rust/target -- "$KETTLECORN_RUNTIME"

# Run the Rust device monitor with its bundled telemetry and plugins.
device-monitor:
    @bundle=$(nix build .#rust-device-monitor --no-link --print-out-paths) && \
      "$bundle/bin/device-monitor" "$bundle/telemetry.jsonl" \
        "$bundle/plugins/sustained_heat.exs" "$bundle/plugins/rapid_rise.exs"

# Open Pulse Field with a preset or an Elixir script path.
pulse-field setup="cover":
    #!/usr/bin/env bash
    set -euo pipefail
    case {{quote(setup)}} in
      -h|--help) ;;
      *) {{runtime}} ;;
    esac
    if [ -n "${PULSE_FIELD_LIBRARIES:-}" ]; then
      export LD_LIBRARY_PATH="$PULSE_FIELD_LIBRARIES${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
    fi
    cargo run --quiet --locked --manifest-path examples/rust/pulse-field/Cargo.toml --target-dir rust/target -- "${KETTLECORN_RUNTIME:-}" {{quote(setup)}}

# An IEx session with the host library, ready to start VMs.
dev:
    {{runtime}} && cd host && iex -S mix

# All local tests: native stdio, core host tests, and cooked applications.
test: test-stdio test-host test-apps

test-host:
    {{runtime}} && cd host && mix test --exclude examples

# CI runs these after nix flake check has covered the core tests and notebooks.
test-apps: build-examples
    #!/usr/bin/env bash
    set -euo pipefail
    {{runtime}}
    export KETTLECORN_EXAMPLES="$PWD/_kettlecorn/examples"
    (cd host && mix test test/apps_test.exs)
    bash bin/kettlecorn-run --app "$KETTLECORN_EXAMPLES/csv_stats" -e 'CsvStats.report()' | grep -E '^  east +948.00$'
    echo 'Counter.increment()' | bash bin/kettlecorn-run --app "$KETTLECORN_EXAMPLES/counter" --iex | grep -F 'iex(1)> 11'
    (cd host && MIX_ENV=test mix kettlecorn.run --app "$KETTLECORN_EXAMPLES/csv_stats" -e 'CsvStats.report()') | grep -E '^  east +948.00$'

test-stdio:
    python3 c/test/stdio_test.py

test-rust-examples: test-pulse-field

test-pulse-field:
    {{runtime}} && KETTLECORN_TEST_RUNTIME="$KETTLECORN_RUNTIME" cargo test --locked --manifest-path examples/rust/pulse-field/Cargo.toml --target-dir rust/target

# Runs every notebook's cells (host/notebooks) against the runtime.
notebooks:
    {{runtime}} && cd host && for nb in notebooks/*.livemd; do mix run scripts/livebook_test.exs "$nb" || exit 1; done

# Run the local verification suite. Needs `just deps`.
check: flake-check ci

[private]
ci: lint typecheck docs test-apps test-rust-examples

# Run the flake's sandboxed checks.
flake-check:
    nix flake check -L

# Rust/Nix/Elixir formatting, unused dependencies, Credo and Reach. Needs `just deps`.
lint:
    cargo fmt --manifest-path rust/Cargo.toml -- --check
    for manifest in examples/rust/*/Cargo.toml; do cargo fmt --manifest-path "$manifest" -- --check || exit; done
    nixpkgs-fmt --check flake.nix nix/*.nix
    cd host && mix format --check-formatted && mix format --check-formatted {{extra_elixir}}
    cd host && mix deps.unlock --check-unused && mix credo && mix reach.check --arch
    cmp LICENSE host/LICENSE  # the Hex package carries a copy
    cmp host/priv/checksums.txt rust/checksums.txt

# Clippy, Elixir compilation with warnings as errors, Dialyzer and compile-time cycles.
typecheck:
    cargo clippy --manifest-path rust/Cargo.toml --features cli,installer --all-targets -- -D warnings
    for manifest in examples/rust/*/Cargo.toml; do cargo clippy --manifest-path "$manifest" --locked --target-dir rust/target --all-targets -- -D warnings || exit; done
    cd host && mix compile --force --warnings-as-errors
    cd host && mix dialyzer --format short
    cd host && mix xref graph --format cycles --label compile-connected --fail-above 0

format:
    nixpkgs-fmt flake.nix nix/*.nix
    cd host && mix format && mix format {{extra_elixir}}

# Benchmark startup and workloads (BENCH_TIME sets seconds per scenario).
bench: bench-startup bench-workloads bench-rust

bench-startup:
    {{runtime}} && cd host && MIX_ENV=bench mix run bench/startup.exs

bench-workloads:
    {{runtime}} && cd host && MIX_ENV=bench mix run bench/workloads.exs

# Benchmark the Rust embedding API in an optimized build.
bench-rust:
    {{runtime}} && cargo bench --locked --no-default-features --manifest-path rust/Cargo.toml --bench embedding

# The host library's documentation (ExDoc), into host/doc.
docs:
    cd host && mix docs --warnings-as-errors
    python3 host/scripts/check_doc_links.py host/doc

# The runtime release archive (as the release workflow builds it), into ./release.
release-archive:
    nix build .#release -o release

# Record the same release checksums in both language packages.
release-checksums version:
    #!/usr/bin/env bash
    set -euo pipefail
    tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
    version={{quote(version)}}
    for target in {{release_targets}}; do
      name="kettlecorn-runtime-$version-$target.tar.gz"
      base="https://github.com/mjrusso/kettlecorn/releases/download/v$version"
      curl -fsSL -o "$tmp/$name" "$base/$name"
      curl -fsSL -o "$tmp/$name.sha256" "$base/$name.sha256"
      (cd "$tmp" && sha256sum -c "$name.sha256")
    done
    (cd "$tmp" && sha256sum *.tar.gz) | tee host/priv/checksums.txt rust/checksums.txt

check-release-checksums:
    #!/usr/bin/env bash
    set -euo pipefail
    version=$(cat host/VERSION)
    crate_version=$(python3 -c 'import sys, tomllib; print(tomllib.load(sys.stdin.buffer)["package"]["version"])' < rust/Cargo.toml)
    if [[ "$version" != "$crate_version" ]]; then
      echo "Package versions differ: Hex $version, Cargo $crate_version" >&2
      exit 1
    fi
    cmp host/priv/checksums.txt rust/checksums.txt
    for target in {{release_targets}}; do
      name="kettlecorn-runtime-$version-$target.tar.gz"
      if ! awk -v name="$name" '
        $2 == name {
          count++
          valid = length($1) == 64 && $1 ~ /^[0-9a-f]+$/ && $0 == ($1 "  " name)
        }
        END { exit !(count == 1 && valid) }
      ' rust/checksums.txt; then
        echo "Expected exactly one valid SHA-256 for $name in both packages." >&2
        exit 1
      fi
    done

# Verify that the Rust and Elixir installers share the published runtime cache.
release-smoke-rust: check-release-checksums
    cargo run --locked --manifest-path rust/Cargo.toml --features installer --example release-install-smoke

test-runtime-cache archive:
    #!/usr/bin/env bash
    set -euo pipefail
    archive=$(realpath {{quote(archive)}})
    if [[ ! -f "$archive" ]]; then
      echo "Runtime archive does not exist: $archive" >&2
      exit 1
    fi
    export KETTLECORN_TEST_RUNTIME_ARCHIVE="$archive"
    cache=$(mktemp -d)
    trap 'rm -rf "$cache"' EXIT
    cache=$(cd "$cache" && pwd -P)
    unset KETTLECORN_RUNTIME XDG_CACHE_HOME
    mkdir "$cache/home"
    if [[ $(uname -s) == Linux ]]; then
      mkdir -p "$cache/other/child"
      ln -s "$cache/other/child" "$cache/link"
      export XDG_CACHE_HOME="$cache/link/../cache"
      cache_parent="$cache/cache"
    else
      cache_parent="$cache/home/Library/Caches"
    fi
    mkdir -p "$(dirname "$cache_parent")" "$cache/original-cache"
    ln -s "$cache/original-cache" "$cache_parent"
    export KETTLECORN_TEST_CACHE_PARENT="$cache_parent"
    export CARGO_HOME="${CARGO_HOME:-$HOME/.cargo}"
    env HOME="$cache/home" KETTLECORN_TEST_CACHE_HANDOFF="$cache" \
      cargo test --locked --manifest-path rust/Cargo.toml --features installer --lib
    if [[ ! -f "$cache/complete" ]]; then
      echo 'The offline cache handoff did not complete.' >&2
      exit 1
    fi

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

# Update pinned flake inputs and regenerate the versions table.
update:
    nix flake update
    just docs-versions

# Update Popcorn to its latest commit; run nix flake check afterward.
update-popcorn:
    nix flake update popcorn
    just docs-versions

# Update Elixir to the latest stable release; a new minor needs its Nix builder.
update-elixir:
    #!/usr/bin/env bash
    set -euo pipefail
    latest=$(git ls-remote --tags --refs https://github.com/elixir-lang/elixir 'v*' \
      | sed 's#.*refs/tags/##' | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | sort -V | tail -1)
    sed -i -E "s#github:elixir-lang/elixir/v[0-9.]+#github:elixir-lang/elixir/${latest}#" flake.nix
    nix flake lock
    just docs-versions
    echo "Elixir ${latest}"

# Updates the development guide's generated versions table.
docs-versions:
    #!/usr/bin/env bash
    set -euo pipefail
    guide=host/guides/development.md
    table=$(nix build .#versions --no-link --print-out-paths)
    awk -v table="$table" '
      /^<!-- versions/ { while ((getline line < table) > 0) print line; skip = 1; next }
      /^<!-- \/versions -->/ { skip = 0; next }
      !skip
    ' "$guide" > "$guide.new"
    mv "$guide.new" "$guide"
