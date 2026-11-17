# Sandbox and resource limits

Each VM gets a private, writable copy of the runtime's `root/` mounted at
`/` (the source runtime is never written). It gets only the
environment variables Kettlecorn passes, and stdio. The guest cannot start
OS processes or load native code. Wasmtime enforces the limits:

| Option (`Kettlecorn.start_link/1`) | `kettlecorn-run` | Wasmtime |
|---|---|---|
| `max_memory: bytes` (default 512 MiB) | `--max-memory` | `StoreLimits` |
| `max_lifetime: ms` | `--timeout 2s` | epoch interruption and a deadline |
| `max_fuel: n` (CPU budget, ~instructions) | `--fuel` | fuel |
| `network: true`: TCP/UDP, DNS, TLS | `--network` | inherited network and DNS |
| `http: true`: outgoing HTTP via `wasi:http` | `--http` | HTTP linker, runs `beam-http.wasm` |

The CLI sets no resource limits unless you pass the corresponding options.

Set finite `max_fuel` and `max_lifetime` limits for untrusted workloads;
both default to `:infinity` in the host API. Fuel limits guest execution,
not the number of bytes delivered to the host.

## Reusing VMs

Give mutually untrusted tenants separate VMs. Modules, processes, ETS
tables, application configuration, and files persist between evaluations.
A new evaluation process does not reset the VM. Use `Kettlecorn.run/2`
for an evaluation in a fresh VM, or stop a tenant's VM before replacing it.

## Managing VM lifetime

Choose the relationship between the VM and the host process that uses it:

| API or option | Lifetime behavior |
|---|---|
| `Kettlecorn.run/2` | Starts an unlinked VM for one evaluation and stops it afterward, including if its caller exits. |
| `Kettlecorn.start_link/1` | Links the VM to its caller. An abnormal VM exit, including a resource limit, can terminate the caller. |
| `Kettlecorn.start/1` | Starts an unlinked VM. Monitor it to receive termination notifications. |
| `stop_with: pid` | Stops the VM when that process exits. This applies to linked and unlinked VMs. |

For a VM used by one host worker, start it unlinked and tie its lifetime to
that worker. Stop it when the work is complete:

```elixir
{:ok, vm} = Kettlecorn.start(
  stop_with: self(),
  max_fuel: 50_000_000_000,
  max_lifetime: 30_000
)
monitor = Process.monitor(vm)

try do
  Kettlecorn.eval(vm, "Enum.sum(1..10)")
after
  Kettlecorn.stop(vm)
  Process.demonitor(monitor, [:flush])
end
```

While running, the worker can handle `{:DOWN, monitor, :process, vm, reason}`
from its monitor. A linked worker instead needs to handle exits or be prepared
to restart when the VM fails. These links are host process relationships;
GenServers running inside the guest have their own supervision tree.

## Output and messages

### Captured and console output

`Kettlecorn.eval/3` captures standard output in its result's `"output"` field.
Writes to stderr bypass evaluation capture and go to the VM's console output.
`Kettlecorn.take_output/1` returns and clears a buffer combining console stdout
and stderr without stream labels; it excludes standard output captured by an
evaluation. With an `:owner`, console output also arrives as `{:stdout, data}`
and `{:stderr, data}` events.

Normal guest exits drain queued console output within the remaining lifetime
budget. Timeout, cancellation, fuel exhaustion, and failure discard queued
output; final diagnostics may be incomplete.

### Owner events

If you set `owner: pid`, handle its guest output, messages and host calls,
then call `Kettlecorn.acknowledge(vm)` for each handled event. The event shape
is `{:kettlecorn, vm, event}`. Only that owner can acknowledge its events;
`acknowledge(vm, count)` releases a batch in delivery order.

Stopping a VM leaves already-delivered events in the owner's mailbox. The
byte budget charges retained input and estimated heap space. Acknowledging
an event removes it from accounting, so consume its data before acknowledging.

### Input queue

Host input has a fixed queue budget. Overflow stops the VM; shutdown discards
queued input.

| Budget | Default | When exceeded |
|---|---|---|
| `max_pending_events` | 1,024 unacknowledged events | Stops the VM with `:event_queue_full` |
| `max_pending_event_bytes` | 64 MiB of estimated retained data | Stops the VM with `:event_queue_full` |
| Input queue (fixed) | 1,024 frames or 64 MiB plus a frame-length prefix, in addition to the port buffer | Stops the VM with `:input_queue_full` |
| `output_limit` | 1 MiB | Discards additional console buffer data; owner delivery has separate budgets |
| `max_message_size` | 64 MiB | An oversized frame stops the VM; a term exceeding the decoding budget is dropped |

VM termination fails pending requests with `{:error, {:vm_down, reason}}`.
Use OS-level limits on the host BEAM process for a hard memory cap. See
[host transport](architecture.md#host-transport) for queueing and framing details.

## Disk use

Guest writes have no disk quota. Put `instances_dir` on a size-limited
filesystem to prevent guests from filling the host's disk.

## Network grants

Without either grant, socket and DNS operations are denied and
`Kettlecorn.HTTP` is unavailable. **The grants allow any reachable destination:**
Kettlecorn has no destination allowlist, so a granted VM can reach internal
services, `127.0.0.1`, and cloud metadata endpoints. Expose selected operations
as host calls (`Kettlecorn.Host.call/3`, answered with `Kettlecorn.reply/3`),
or confine the launcher process at the OS level.

See [HTTP and Req](running-applications.md#http-and-req) for how the grants
select Req's adapter, and which CA certificates each uses. With
`network: true`, the guest gets a copy of the host's CA certificates
unless `:cacerts` says otherwise. They're public, but they tell the guest
which private CAs the host trusts.

## Evaluation timeouts

`Kettlecorn.eval/3` also takes a `:timeout` (default 5000 milliseconds), which kills
the evaluation and attempts to kill its descendants while keeping the VM.
Guest code can disable descendant tracing; use whole-VM limits to bound it.

## Process isolation

Each VM runs in its own launcher process. A launcher crash ends that VM
without crashing the host BEAM, though a link can propagate the exit to its
caller. Stopping the VM cancels execution even when guest input or output is
stalled. The host removes the private root after confirming launcher shutdown;
if confirmation fails, it retains the directory and logs an error.

The memory cap covers WebAssembly linear memory. Use OS limits for total RSS,
and namespaces, seccomp, or cgroups when the launcher needs additional
confinement. Guest execution uses one OS thread; compilation and WASI operations
can use helper threads. See [VM lifecycle](architecture.md#vm-lifecycle) for
root preparation, cancellation, and termination records.

## Compilation cache

The launcher caches native compiled components under
`$XDG_CACHE_HOME/kettlecorn/components`, or `~/.cache/kettlecorn/components` on
Linux and `~/Library/Caches/kettlecorn/components` on macOS. The directory must
be owned by the current user and have no group or other permissions. Entries
must also be private regular files. Symlinks and directories inside the guest
root are refused. The guest receives no access to the cache.

Native artifacts are executable host code. Treat this cache like installed
binaries; another process running as your user can replace them. A stored digest
detects accidental corruption, and the key includes both the component digest
and engine compatibility hash. Writes use temporary files and atomic rename.
Cache failures fall back to compilation. Old entries are evicted to keep the
cache at 256 MiB; active loaded components remain valid after eviction.

Use `compile_cache: false` to disable caching or `cache_dir: path` to choose a
private directory. `bin/kettlecorn-launch` accepts `--no-cache` and `--cache-dir`.
The first use compiles in memory and populates the cache; release archives ship
portable `.wasm`, since native artifacts also depend on CPU and engine settings.

The [Rust execution API](architecture.md#rust-execution-api) also retains
prepared components in memory for in-process embedding.

## Compatibility

* Guest execution uses one OS thread; CPU-heavy guests use one core.
* No distribution, `:inets` or `:ssh` in the guest.
* Release targets are `x86_64-linux`, `aarch64-linux` and `aarch64-darwin`
  (Apple silicon). Intel macOS (`x86_64-darwin`) is not supported.
* VM startup and execution need only the platform runtime. Cooking requires
  the POSIX `cp` tool; the script CLI requires Bash.
