# Running applications

Start with the [package installation instructions](../README.md#installation).
Read [sandbox and resource limits](sandbox.md) before running untrusted code.

## Command line

`kettlecorn-run` runs scripts, expressions, cooked applications, and IEx in a
guest VM. It is included in every runtime. Each invocation uses a private
writable copy of the guest filesystem, which is deleted when the command exits.

### Install and invoke

In a Mix project with the `kettlecorn` dependency:

```sh
mix deps.get
mix kettlecorn.install
mix kettlecorn.run -e 'IO.puts(Enum.sum(1..10))'
```

`mix kettlecorn.run` runs scripts and expressions through the runtime's `kettlecorn-run`.
It uses `--runtime DIR`, `KETTLECORN_RUNTIME`, `config :kettlecorn, :runtime`,
then the default installation directory. A missing runtime produces an error
asking you to run `mix kettlecorn.install`; the task does not download one.
Put an explicit `--runtime DIR` first in the Mix form so the task can find
that runtime's CLI before the CLI itself parses the remaining arguments.
It preserves standard input, output, and error, and exit status.
If the host Mix process exits, its CLI child stops and removes the private guest root.
It does not cook or start the host project's application. Supply `--app DIR`
to start a cooked application in the guest.

With `--iex`, the task validates the runtime, prints a shell-quoted standalone
command, and exits without starting a guest:

```sh
mix kettlecorn.run --iex
mix kettlecorn.run --app _kettlecorn --iex
```

Run the printed command in the same working directory to start IEx with
Ctrl+C handling and live terminal resizing. The command includes the resolved
runtime and all supplied arguments, including resource limits and script paths.
`mix kettlecorn.run --iex --help` displays CLI help.

For standalone use, download `kettlecorn-runtime-<version>-<system>.tar.gz`
from [GitHub Releases](https://github.com/mjrusso/kettlecorn/releases).
Choose the platform suffix:

| Platform | Suffix |
|---|---|
| x86_64 Linux | `x86_64-linux` |
| ARM64 Linux | `aarch64-linux` |
| Apple silicon macOS | `aarch64-darwin` |

Extract the archive and add its `bin` directory to your PATH. For example,
on x86_64 Linux:

```sh
tar -xzf kettlecorn-runtime-0.1.0-x86_64-linux.tar.gz
export PATH="$PWD/kettlecorn-runtime-0.1.0-x86_64-linux/bin:$PATH"
kettlecorn-run --help
```

The standalone command requires Bash. OTP, Elixir, and Wasmtime are bundled;
no Mix project or host Elixir installation is needed. Keep the extracted
directory together: the script locates the runtime relative to itself.
`--runtime DIR` or `KETTLECORN_RUNTIME` overrides that location.

From a repository checkout with Nix flakes enabled and the
[binary cache configured](development.md#binary-cache), use
`nix run .#kettlecorn-run -- ARGS`. To install the command on your PATH, run
`nix profile install .#kettlecorn-run`.

### Scripts, expressions, and IEx

Run these commands with the standalone CLI:

```sh
kettlecorn-run script.exs arg1 arg2
kettlecorn-run -e 'IO.puts(Enum.sum(1..10))'
kettlecorn-run --iex
kettlecorn-run --iex script.exs
kettlecorn-run --app _kettlecorn --iex
```

For scripts and expressions, `mix kettlecorn.run` accepts the same arguments.

Put launcher options before the script path or `-e CODE`. Arguments after
the script path become `System.argv()` in the guest. The script is copied to
`/work/<name>`; other files beside it on the host are not copied. Package
dependencies and files in a [cooked application](#cooking-mix-applications).
Standard input can be piped to scripts or IEx. With `--iex script.exs`, the
script runs before the first prompt.

Expressions run with `-e` print only what the code writes. To print the
inspected result through the host evaluation API, use
`mix kettlecorn.eval 'Enum.sum(1..10)'`; it also supports `--erlang`.

### Limits and network access

The CLI has no memory, fuel, or lifetime limit unless you supply one:

```sh
kettlecorn-run --max-memory 536870912 --fuel 50000000000 --timeout 30s script.exs
```

`kettlecorn-run --help` is the authoritative list of options and their defaults.

Network and HTTP grants default to off. Each grant allows any reachable
destination. See [sandbox and resource limits](sandbox.md) and
[HTTP and Req](#http-and-req) for grant and certificate behavior.

For debugging with the Wasmtime CLI, see the development guide's
[equivalent-command instructions](development.md#native-launcher).

## Cooking Mix applications

A cooked application is a compiled Mix project and its dependencies,
packaged for the guest.

Cooking runs on the host, outside the guest sandbox. Mix project code,
dependencies, compiler hooks, and configuration can execute code with the
build user's permissions. Cook only trusted projects, or isolate dependency
fetching and building separately when accepting untrusted projects.
Kettlecorn's runtime isolation applies when the cooked application runs
in a guest.

Cooking requires the POSIX `cp` tool. Add Kettlecorn to the project for the
cooking task:

```elixir
{:kettlecorn, "~> 0.1", runtime: false}
```

Use the runtime's OTP major release and exact Elixir version to compile
it. The [pinned versions](development.md#pinned-versions) list the repository's
compiler versions; an installed runtime records its own in `manifest.json`.
From your Mix project, fetch dependencies, install into an explicit runtime
directory, and cook:

```sh
mix deps.get
mix kettlecorn.install --dir .kettlecorn-runtime
MIX_ENV=prod mix kettlecorn.cook --runtime .kettlecorn-runtime
```

Runtime installations and cooked bundles are symlinks to directories under
`<destination>.versions/`. Add both the links and their target directories to
`.gitignore`:

```gitignore
.kettlecorn-runtime
.kettlecorn-runtime.versions/
_kettlecorn
_kettlecorn.versions/
```

The cook writes `_kettlecorn` by default. Passing `--runtime` checks that
dependencies absent from the bundle are present in that runtime. The `runtime: false`
dependency keeps the host library out of the guest bundle.

### Bundle compatibility

Cooking writes `kettlecorn.json` with the compiler's OTP major, exact Elixir
version, and protocol version. Supplying `--runtime` validates the runtime
and compiler before replacing the bundle symlink. The host checks bundles
before copying them.
Guest boot validates the copied metadata for both host VMs and the CLI before
loading cooked code. Extra metadata fields are rejected too. Rebuild bundles
after upgrading the protocol or compiler.

See [published directories](architecture.md#published-directories) for atomic
replacement, retained generations, and migration of an existing ordinary
directory. To make a standalone copy, dereference the symlinks (`cp -RL`).

## Running the cooked application

Run the launcher from the installed runtime:

```sh
.kettlecorn-runtime/bin/kettlecorn-run --app _kettlecorn --iex
```

This starts your application before entering IEx. Omit `--iex` to keep the
application running, like `mix run --no-halt`. Add `-e 'CODE'` or a script
path to run code after startup and exit when it completes.

From a separate host program that depends on Kettlecorn, use the same bundle
and runtime paths (relative to that program's working directory):

```elixir
{:ok, vm} =
  Kettlecorn.start_link(
    runtime: ".kettlecorn-runtime",
    app: "_kettlecorn",
    max_fuel: 50_000_000_000,
    max_lifetime: 30_000
  )

Kettlecorn.eval(vm, "Application.started_applications()")
Kettlecorn.stop(vm)
```

The bundle is copied to the guest's `/app`. Its applications come first on
the code path, replacing runtime copies with the same name. The guest loads
configuration and starts the entrypoint before reporting that it has booted.
Registered GenServers are reachable through `Kettlecorn.call/4`.

The repository's [cooked examples](https://github.com/mjrusso/kettlecorn/blob/main/examples/README.md#cooked-apps)
run with `just example counter`, `just example csv_stats -e 'CsvStats.report()'`,
and `just example lua` inside `nix develop`. These recipes build with Mix
and write cooked apps under `_kettlecorn/examples/`.

The [Lua notebook](../notebooks/lua.livemd) shows how to load a compiled
dependency directly with `code_paths`.

### Bundle layout and configuration

```text
_kettlecorn/kettlecorn.json  protocol and compiler compatibility
_kettlecorn/app              the entrypoint application's name
_kettlecorn/sys.config       configuration read from config/config.exs
_kettlecorn/lib/<app>/       ebin/ and priv/ of the app and its dependencies
```

`Kettlecorn.Cook` warns about native code in `priv/`, which cannot load in
the guest. Configuration is read at cook time; the guest does not evaluate
`config/runtime.exs`.

## Deploying

`mix kettlecorn.install` downloads the runtime separately from the Hex
package. Include the runtime in your deployment. Install it with `--dir`;
the installer selects the host platform and includes its native launcher.
Point the library at that directory. Install separately for each target platform.

In a Docker image, install in the build stage and dereference the symlink
to create a standalone runtime directory:

```dockerfile
# build stage, after mix deps.get
RUN mix kettlecorn.install --dir /tmp/kettlecorn \
    && cp -RL /tmp/kettlecorn /opt/kettlecorn

# final stage
COPY --from=build /opt/kettlecorn /opt/kettlecorn
ENV KETTLECORN_RUNTIME=/opt/kettlecorn
```

Or install into your application's `priv/`, so that `mix release` includes it:

```console
$ mix kettlecorn.install --dir priv/kettlecorn
```

Ignore both `priv/kettlecorn` and `priv/kettlecorn.versions/` in Git. The
symlink and its target directories must travel together in the release.

```elixir
# config/runtime.exs
config :kettlecorn, runtime: Application.app_dir(:my_app, "priv/kettlecorn")
```

The runtime can be read-only: each VM uses a private writable copy of the
guest files. The launcher caches compiled components in a private per-user
directory; see [compilation cache](sandbox.md#compilation-cache).
Start and stop a VM as the deployment user to warm it before serving requests.

## Troubleshooting

| Symptom | Cause and action |
|---|---|
| No runtime found | Run `mix kettlecorn.install`, or set `KETTLECORN_RUNTIME` to an installed runtime. `Kettlecorn.Runtime.dir/1` documents discovery order. |
| Incompatible runtime or cooked bundle | Match the library's protocol version, and rebuild guest code with the runtime's OTP major and exact Elixir version from `manifest.json`. |
| `:bad_payload` when sending a binding or message | The guest rejects atoms it has not loaded. Use string keys and labels, or load the guest module defining those atoms first. |
| A host call times out after a reply | Replies also reject atoms absent from the guest. Use strings for application-defined names and error reasons; `reply/3` does not confirm delivery. |
| Evaluation has `"inspected"` but no `"value"` | The result contains unsupported terms, such as a function or pid, or exceeds the evaluator's traversal limit. Return bounded plain data or send a guest pid through `Kettlecorn.Host.send/1`. |
| Missing stderr in `"output"` | Evaluation capture contains standard output. Read console output with `take_output/1`, or configure an owner for separate stdout/stderr events. |
| `:request_queue_full` | The unanswered request limit was reached; this request was not sent. Bound host concurrency or adjust `max_pending_requests`. |
| VM stops with `:event_queue_full` | Consume owner events and acknowledge each after handling it. Adjust event budgets only when the owner can keep up. |
| `:unsupported_timeout` from HTTP | The HTTP adapter cannot disable timeouts. Replace `:infinity` with `:default` or finite milliseconds; Req wraps this reason in `Req.TransportError`. |
| Caller exits but guest work continues | Caller monitoring releases host tracking. Use `stop_with: caller` or stop the VM to cancel its work. |
| VM stops or its caller exits | Inspect `{:vm_down, reason}` or the monitor notification. Resource limits stop the whole VM, and links propagate abnormal exits. See [Managing VM lifetime](sandbox.md#managing-vm-lifetime). |

## Optional features

### HTTP and Req

Req ships in the guest. Its default adapter depends on the grants:

| VM started with | `Req.get!/2` goes through |
|---|---|
| `http: true` | `Kettlecorn.HTTP.ReqAdapter` over `wasi:http` (the guest app installs it as Req's default adapter) |
| `network: true` | Req's usual Finch/Mint, over `wasi:sockets` |
| neither | `%Req.TransportError{reason: :eacces}` |

Use `http: true` for HTTP access without granting raw sockets.

With `http: true`, Wasmtime verifies HTTPS servers with Mozilla's root CA
list compiled into its `webpki-roots` dependency. The `:cacerts` option does
not change these roots. With `network: true`, the guest verifies them itself, with
the CA certificates the VM is started with: by default the host's
(`:public_key.cacerts_get/0` on the host). `:cacerts` replaces them with a
PEM file or a list of DER certificates:

```elixir
{:ok, vm} =
  Kettlecorn.start_link(
    network: true,
    cacerts: "/etc/my-company/ca.pem",
    max_fuel: 50_000_000_000,
    max_lifetime: 30_000
  )

Kettlecorn.stop(vm)
```

`kettlecorn-run --network` passes `$SSL_CERT_FILE`, else the host's
bundle from a standard location, unless `--cacertfile FILE` names
another. In the guest, `:public_key.cacerts_get/0` returns them, and
Req and Mint use them unless a request passes its own.

With `cacerts: []`, or on a host without a trust store, the guest has no
CA certificates. `:public_key.cacerts_get/0` raises, and so does a Req HTTPS
request that doesn't pass `connect_options: [transport_opts: [cacerts: ...]]`.

See [network grants](sandbox.md#network-grants) for destination access.

### Interactive IEx

`kettlecorn-run --iex` (`nix run .#iex`) starts IEx in the guest, with line
editing, history, tab completion, and colours in a terminal. With piped
input, it reads lines and exits at the end of input. Use `--app DIR --iex`
to start a cooked application before entering the shell.

The [architecture guide](architecture.md#interactive-iex) describes terminal
handling in the guest and launcher.

## Runtime releases

A release has two parts with the same version:

* **The runtime archives** `kettlecorn-runtime-<version>-<system>.tar.gz` on
  release `v<version>`, for `x86_64-linux`, `aarch64-linux`, and `aarch64-darwin`.
  Each includes the emulators, root, manifest, licenses, `bin/kettlecorn-launch`
  and `bin/kettlecorn-run`. Linux launchers are static musl executables.
  The script CLI needs Bash.
* **The Hex package** `kettlecorn`: the library and Mix tasks. The installer
  selects the platform archive and verifies its SHA-256 against
  `priv/checksums.txt` before replacing the installation symlink.

The [runtime manifest](architecture.md#runtime-manifest) records the
protocol version, imported WASI interfaces, and tested Wasmtime version.
See [RELEASING.md](https://github.com/mjrusso/kettlecorn/blob/main/RELEASING.md)
for building and publishing the archive and Hex package.
