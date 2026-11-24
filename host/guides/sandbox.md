# Sandbox and resource limits

Each VM gets a private, writable copy of the runtime's `root/` mounted at
`/` (the source runtime is never written). It gets only the
environment variables Kettlecorn passes, and stdio. The guest cannot start
OS processes or load native code. These guest restrictions apply to both
host APIs and the CLI. The Elixir host and CLI run VMs in separate launcher
processes; Rust embeds VMs in the application process.

Wasmtime enforces these limits and grants:

| Elixir option (`Kettlecorn.start_link/1`) | Rust field (`VmOptions`) | `kettlecorn-run` | Enforcement |
|---|---|---|---|
| `max_memory: bytes` | `max_memory: Some(bytes)` | `--max-memory` | WebAssembly linear memory limit |
| `max_lifetime: ms` | `max_lifetime: Some(duration)` | `--timeout 2s` | Epoch interruption and a deadline |
| `max_fuel: n` | `max_fuel: Some(n)` | `--fuel` | Execution budget, roughly WebAssembly instructions |
| `network: true` | `network: true` | `--network` | Socket and DNS permissions |
| `http: true` | `http: true` | `--http` | HTTP linker, runs `beam-http.wasm` |

Both APIs default to a 512 MiB WebAssembly memory limit. Fuel and lifetime
limits default to `:infinity` in Elixir and `None` in Rust. Rust durations
use `std::time::Duration`; Elixir lifetime values are milliseconds. The CLI
sets no resource limits unless you pass the corresponding options.

Set finite `max_fuel` and `max_lifetime` limits for untrusted workloads;
fuel limits guest execution, not the number of bytes delivered to the host.

## Measuring resource use

`Kettlecorn.stats/1` and `Vm::stats` report the fuel a VM has consumed since
it started, including boot, and its WebAssembly linear memory. Fuel is
reported only when `max_fuel` is set. The count is updated when the guest
calls the host and on every 10 ms epoch tick while it runs, and it covers
the work up to the reply of a completed `eval` or `call`. Linear memory
never shrinks, so it is the most the guest has needed.

`Kettlecorn.stats/1` also reports the launcher process's resident set size
as `rss`, on Linux only; it is `nil` on macOS. When a VM with an `:owner`
stops, the owner receives `{:kettlecorn, vm, {:stopped, stats}}` once, with
the final fuel and memory and `rss: nil`, including after a timeout or
running out of fuel. If the launcher exits without reporting stats, the
event is `{:stopped, nil}`. This event needs no acknowledgement.

In Rust, `Vm::shutdown` returns a `Shutdown` with the final `stats` and a
`result`, which is an error if the guest had already stopped.

## Preloading modules

OTP loads a module the first time code calls it. Which modules a VM has
loaded, and the order of its atom table, then depend on what the guest ran
first. On this runtime, the order in which atoms enter the table can
affect map iteration, including `Map.keys/1` on a map with atom keys.
With `preload: true` (`VmOptions::preload = Preload::On` in Rust,
`--preload on` for the launcher and `kettlecorn-run`), the VM loads modules from
its boot-time code path, including the cooked app's, in a fixed order.
Preloading adds to startup time. The [performance guide](performance.md)
shows how to measure it.

After preload, the code server reports each module it loads on demand from
the code path, for example from a directory the guest added. The owner
receives `{:kettlecorn, vm, {:late_load, "Elixir.Mod"}}`, which it
acknowledges like other events; without an owner, the host logs a warning.
In Rust, names go to `VmOptions::late_loads` when configured, or to
`VmOptions::stderr` when configured. Reports are dropped when the channel
is full. `kettlecorn-run` writes to stderr.
`preload: :strict` (`Preload::Strict`, `--preload strict`) also
writes the module's name to the guest's stderr and stops the VM with exit
status 1. Use it in tests.

Binaries loaded with `:code.load_binary/3`, such as modules that evaluated
code defines, and explicit `:code.load_file/1` calls are not reported. The
guest can send `late_load` events itself or stop the reporting process, so
treat late-load reports as guest data, not as an enforcement mechanism.

The [Dune example](https://github.com/mjrusso/kettlecorn/blob/main/examples/README.md#appsdune)
combines strict preload with restrictions on calls that read the clock,
use implicit random state, or observe other processes.

## Reusing VMs

Give mutually untrusted tenants separate VMs. Modules, processes, ETS
tables, application configuration, and files persist between evaluations.
A new evaluation process does not reset the VM. In Elixir, use
`Kettlecorn.run/2` for an evaluation in a fresh VM. In Rust, start a new VM
and call `Vm::shutdown` when finished.

## Managing VM lifetime

### Elixir processes

Choose the relationship between the VM and the Elixir process that uses it:

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

The VM also monitors callers of `eval/3`, `call/4`, and `send/4`. Caller exit
releases request tracking and capacity, even for an infinite timeout. It does
not cancel guest work already submitted. Use `stop_with` or stop the VM to
end that work when the caller leaves.

### Rust tasks

`Runtime::start` returns a `Vm` backed by a Tokio task. Dropping the `Vm`
requests cancellation. `Vm::shutdown` cancels execution and waits for the
task and private-filesystem cleanup to finish.

Dropping an individual request future skips a write that has not started;
it does not cancel guest work already submitted. A written request can keep
its capacity slot after the caller stops waiting. See
[request delivery](architecture.md#request-delivery) for deadlines and accounting.

`VmOptions::boot_timeout` bounds preparation and boot. `max_lifetime` starts
with guest execution, after runtime preparation and filesystem copying.

## Output and messages

The following capture, owner, and queue rules describe the Elixir host.
Rust delivery is described under [Rust output and requests](#rust-output-and-requests).

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
`acknowledge(vm, count)` releases a batch in delivery order. The final
`{:stopped, stats}` event needs no acknowledgement.

Stopping a VM leaves already-delivered events in the owner's mailbox. The
byte budget charges retained input and estimated heap space. Acknowledging
an event removes it from accounting, so consume its data before acknowledging.

### Input and pending requests

Host input has a fixed queue budget. Unanswered `eval/3`, `call/4`, and
`send/4` requests have a separate `max_pending_requests` limit, including
requests already transmitted. Replies, deadlines, and caller exits release
request capacity. Request rejection leaves the VM running.

| Budget | Default | When exceeded |
|---|---|---|
| `max_pending_events` | 1,024 unacknowledged events | Stops the VM with `:event_queue_full` |
| `max_pending_event_bytes` | 64 MiB of estimated retained data | Stops the VM with `:event_queue_full` |
| Input queue (fixed) | 1,024 frames or 64 MiB plus a frame-length prefix, in addition to the port buffer | Stops the VM with `:input_queue_full` |
| `max_pending_requests` | 1,024 unanswered requests | Returns `{:error, :request_queue_full}` before transmission |
| `output_limit` | 1 MiB | Discards additional console buffer data; owner delivery has separate budgets |
| `max_message_size` | 64 MiB | An oversized frame stops the VM; a term exceeding the decoding budget is dropped |

VM termination fails pending requests with `{:error, {:vm_down, reason}}`.
Use OS-level limits on the host BEAM process for a hard memory cap. See
[host transport](architecture.md#elixir-host-transport) for queueing and framing details.

### Rust output and requests

`Vm::eval` returns captured stdout in `Evaluation::output`, including on a
script error. Console stdout and stderr use the optional bounded channels
in `VmOptions::stdout` and `VmOptions::stderr`; full channels drop chunks.
Guest messages use a broadcast channel. Slow receivers get a lag count
when messages are overwritten, and do not acknowledge events.

Rust defaults to 16 pending requests to the guest and four host calls from
the guest. `VmOptions::max_pending_requests` and `VmOptions::max_host_calls`
control those limits. Requests wait for capacity within their deadline;
host-call overload can produce an error reply or a guest timeout. These
budgets are separate from the Elixir host's defaults above. See
[Rust request delivery](architecture.md#request-delivery) and
[guest callbacks](architecture.md#guest-callbacks) for details.

## Disk use

Guest writes have no disk quota. Put `instances_dir` on a size-limited
filesystem to prevent guests from filling the host's disk. Rust VMs create
their private filesystems under the system temporary directory; put that
directory on a size-limited filesystem when disk use must be bounded.

## Network grants

Without either grant, socket and DNS operations are denied and
`Kettlecorn.HTTP` is unavailable. **The grants allow any reachable destination:**
Kettlecorn has no destination allowlist, so a granted VM can reach internal
services, `127.0.0.1`, and cloud metadata endpoints. Expose selected operations
as host calls through `Kettlecorn.Host.call/3`. An Elixir host answers them
with `:handlers`, a `:handler` or its owner (see
[host calls](guest-api.md#host-calls)); a Rust host uses functions
registered with `VmOptions::register`. OS-level network confinement applies to the launcher
for Elixir/CLI VMs and to the application process for embedded Rust VMs.

See [HTTP and Req](running-applications.md#http-and-req) for how the grants
select Req's adapter, and which CA certificates each uses. With the Elixir
API's `network: true`, the guest gets a copy of the host's CA certificates
unless `:cacerts` says otherwise. They're public, but they tell the guest
which private CAs the host trusts.

The CLI selects a host CA bundle for its sockets grant. Embedded Rust VMs
leave guest CA configuration to the application. In all execution modes,
the HTTP sender uses the bundled Mozilla root certificates. See
[CA certificates](architecture.md#ca-certificates).

## Evaluation timeouts

`Kettlecorn.eval/3` also takes a `:timeout` (default 5000 milliseconds), which kills
the evaluation and attempts to kill its descendants while keeping the VM.
Guest code can disable descendant tracing; use whole-VM limits to bound it.

Rust's `EvalOptions::timeout` sets the guest evaluation timeout and defaults
to five seconds. Both APIs derive additional proxy and reply deadlines;
see the [protocol specification](https://github.com/mjrusso/kettlecorn/blob/main/PROTOCOL.md#host--vm).

## Evaluation reduction limits

Pass `max_reductions: n` to `Kettlecorn.eval/3`, or set
`EvalOptions::max_reductions` in Rust. The guest charges the evaluation,
its descendants, and its output callbacks to the same budget. The maximum
limit is 2^63 - 1. When a charge takes the total above the limit, the
evaluation fails with kind `reductions` and the VM stays up. The scheduler
charges work in slices, so the reported count can exceed the limit.

The count covers work charged before the budget closes. If the budget was
exceeded, the scheduler kills other charged processes when they next
account for reductions. The evaluator also attempts to kill descendants,
as it does on timeout. Fuel and `max_lifetime` still apply to the whole VM.

Reduction counts can be repeatable for single-process evaluations that
start from the same state, receive the same inputs, and run the same code
on the same runtime. The state includes the code the VM has loaded.
On-demand loading can change the measured reduction count. Compare counts from evaluations that
follow the same earlier evaluations on a fresh VM, or use `preload: true`.
Wall-clock timeouts and external state can also affect how much work
completes.

## Controlled inputs

To replay a run, start a fresh VM with the same code, runtime version, and
configuration. Record the requests, their order, and the replies to
guest host calls. Include any other input the program reads. Earlier
requests can change the state that later requests see.

Read the clock on the host and record the value with the request or
reply. For random draws, record a seed and pass it to the guest. Use
`:rand`'s explicit-state functions to carry the generator state between draws:

```elixir
{:ok, seed} = Kettlecorn.Host.call("seed")
{roll, state} = :rand.uniform_s(6, :rand.seed_s(:exsss, seed))
```

Send the recorded requests in order. At each host call, compare its name
and arguments with the next recorded call before returning the recorded
reply. At the end, check that every reply was used and compare the
results. Wall-clock timers and inputs collected inside the guest can
change a replay. The
[Dune example](https://github.com/mjrusso/kettlecorn/blob/main/examples/README.md#appsdune)
restricts selected clock and random functions and draws from a supplied
seed. Its example documentation also describes the cost of Dune's
reduction polling. The
[Lua example](https://github.com/mjrusso/kettlecorn/blob/main/examples/README.md#appslua)
takes the receipt time and code in each request.

## Process isolation

### Elixir host and CLI

Each VM runs in its own launcher process. A launcher crash ends that VM
without crashing the host BEAM, though a link can propagate the exit to its
caller. Stopping the VM cancels execution even when guest input or output is
stalled. The host removes the private root after confirming launcher shutdown;
if confirmation fails, it retains the directory and logs an error.

The memory cap covers WebAssembly linear memory. Use OS limits for total RSS,
and namespaces, seccomp, or cgroups when the launcher needs additional
confinement. Guest execution uses one OS thread at a time; compilation and WASI operations
can use helper threads. See [VM lifecycle](architecture.md#elixir-vm-lifecycle) for
root preparation, cancellation, and termination records.

### Rust host

Rust VMs execute as Tokio tasks inside the application process. WebAssembly
memory and capability restrictions still apply. There is no per-VM OS
process; OS-level resource limits apply to the whole Rust application.
`Vm::shutdown` waits for execution and private-filesystem cleanup.
See [Threads](architecture.md#threads) for scheduling and parallelism.

## Compilation cache

The shared Rust engine caches native compiled components under
`$XDG_CACHE_HOME/kettlecorn/components`, or `~/.cache/kettlecorn/components` on
Linux and `~/Library/Caches/kettlecorn/components` on macOS. The directory must
be owned by the current user and have no group or other permissions. Entries
must also be private regular files. Symlinks and directories inside the guest
root are refused. The guest receives no access to the cache.

Native artifacts are executable host code. Any process running as your
user can replace them. Launchers map verified artifacts so VMs using the
same component share its compiled code. Editing or truncating a mapped
file can crash VMs using it. The first use of a component from the old
cache format recompiles it.

After publishing a new artifact, the launcher tries to bring the cache
back to 256 MiB by evicting old entries. Active mappings remain valid
after eviction. If the cache is unavailable or the component is too
large to cache, the VM can still compile and run it.

In Elixir, use `compile_cache: false` to disable caching or `cache_dir: path`
to choose a private directory. `bin/kettlecorn-launch` accepts `--no-cache`
and `--cache-dir`. The Rust public API uses the default cache location.
The first use compiles in memory and populates the cache; release archives ship
portable `.wasm`, since native artifacts also depend on CPU and engine settings.

The [Rust execution API](architecture.md#rust-execution-api) also retains
prepared components in memory for in-process embedding.

## Compatibility

* Each guest executes on one OS thread at a time; more BEAM schedulers add
  no parallelism within a VM.
* No distribution, `:inets` or `:ssh` in the guest.
* Release targets are `x86_64-linux`, `aarch64-linux` and `aarch64-darwin`
  (Apple silicon). Intel macOS (`x86_64-darwin`) is not supported.
* VM startup and execution need only the platform runtime. Cooking requires
  the POSIX `cp` tool; the script CLI requires Bash.
