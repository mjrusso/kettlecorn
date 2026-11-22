# OTP patches

[`nix/otp.nix`](../nix/otp.nix) applies these patches in order after
[Popcorn's patch stack](https://github.com/software-mansion/popcorn/tree/main/popcorn/patches)
(`0001`–`0014`). `0101` installs the shared platform and build hooks.
Feature patches depend on those hooks and must not depend on changes
introduced by another feature patch.

## Patch stack

| Patch | What it does |
|---|---|
| [`0101-wasi-platform`](otp/0101-wasi-platform.patch) | Installs the platform header and Makefile hooks, shares browser/WASI restrictions through `KETTLECORN_WASM`, and calls the halt helper. |
| [`0102-cooperative-threads`](otp/0102-cooperative-threads.patch) | Adds cooperative scheduler yields and uses mutex spinlocks for WASI threads. |
| [`0103-stdio-bridge`](otp/0103-stdio-bridge.patch) | Connects the wasm NIF and `prim_tty` to the stdio bridge. See [`PROTOCOL.md`](../PROTOCOL.md). |
| [`0104-sockets-dns`](otp/0104-sockets-dns.patch) | Restores inet sockets and sets the guest hostname to `localhost` without opening a UDP socket at boot. |
| [`0106-terminal`](otp/0106-terminal.patch) | Enables `prim_tty` raw mode without terminfo for IEx line editing, history, and completion. |
| [`0107-late-load`](otp/0107-late-load.patch) | Reports successful on-demand module loads and lets the CLI flush reports before exit. |

## OTP integration

Kettlecorn's emulator code lives in [`c/`](../c). The patches add platform
guards, compile-time settings, and calls into that code. `nix/otp.nix`
copies these integration files into OTP:

| Source | OTP destination |
|---|---|
| `c/nif/*` | `erts/emulator/nifs/common/` |
| `c/include/kettlecorn_platform.h` | `erts/include/internal/` |
| `c/otp/kettlecorn.mk` | `erts/emulator/kettlecorn.mk` |
| `c/otp/wasm.erl` | `erts/preloaded/src/wasm.erl` |
| `c/otp/inet_gethost_native.erl` | `lib/kernel/src/inet_gethost_native.erl` |

The Makefile fragment lists the WASI objects and emulator flags. For WASI
and the native bootstrap, `wasm_nif.c` includes `kettlecorn_wasm_nif.c`;
the browser uses Popcorn's implementation. The copied `wasm.erl` declares
the NIFs and defines their envelopes. HTTP NIF registration lives there
and in `c/nif/kettlecorn_wasm_nif.c`.

Kettlecorn's Erlang patches target WASI. See the
[architecture guide](../host/guides/architecture.md#otp-patches) for native
bootstrap constraints.

## Updating patches

`nix/otp.nix` checks the replaced Erlang files against SHA-256 hashes after
applying Popcorn's patches. When an upstream file changes or moves, review
the replacement before updating its expected hash.

Generate patches from commits in a clean OTP checkout:

1. Apply Popcorn's diffs with `git apply`, then Kettlecorn's patches with `git am`.
2. Edit the affected commits.
3. Regenerate them with `git format-patch` using
   `--zero-commit -N --no-stat --no-signature`.

Keep complete replacements and Kettlecorn's runtime logic in `c/`.
Retain license headers when moving OTP code. OTP and Popcorn are licensed
under Apache-2.0; see [`THIRD_PARTY_NOTICES.md`](../THIRD_PARTY_NOTICES.md).
