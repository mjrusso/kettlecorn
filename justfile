# Kettlecorn tasks. Run inside `nix develop` (or prefix with
# `nix develop -c`): Erlang, Elixir, Rust and just come from the flake.

default:
    @just --list

test: test-stdio

test-stdio:
    python3 c/test/stdio_test.py
