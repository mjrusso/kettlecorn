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
| `network: true` | `network: NetworkAccess::Any` | `--network` | Socket and DNS permissions |
| `http: true` | `http: NetworkAccess::Any` | `--http` | HTTP linker, runs `beam-http.wasm` |

Both APIs default to a 512 MiB WebAssembly memory limit. Fuel and lifetime
limits default to `:infinity` in Elixir and `None` in Rust. Rust durations
use `std::time::Duration`; Elixir lifetime values are milliseconds. The CLI
sets no resource limits unless you pass the corresponding options.

Set finite `max_fuel` and `max_lifetime` limits for untrusted workloads;
fuel limits guest execution, not the number of bytes delivered to the host.

## Measuring resource use

`Kettlecorn.stats/1` and `Vm::stats` report allocated WebAssembly linear
memory in bytes. When you set `max_fuel`, they also report fuel consumed
since the VM started, including boot. Fuel updates when the guest calls
into the host and at 10 ms intervals while it runs. After an `eval` or
`call` receives its reply, the sample includes the work up to that reply.

`Kettlecorn.stats/1` also reports the launcher process's resident set size
as `rss`, on Linux only; it is `nil` on macOS. When a VM with an `:owner`
stops, the owner receives `{:kettlecorn, vm, {:stopped, stats}}` once, with
the final fuel and memory and `rss: nil`, including after a timeout or
running out of fuel. If the launcher exits without reporting stats, the
event is `{:stopped, nil}`. This event needs no acknowledgement.

In Rust, `Vm::shutdown` returns a `Shutdown` with the final `stats` and a
`result` that can report a guest exit or a cleanup failure.

## Preloading modules

An on-demand module load can change when atoms enter the table, which
can affect iteration order in maps with atom keys. With `preload: true`
(`Preload::On` in Rust, `--preload on` on the CLI), the VM loads modules
on the boot-time code path in name order, skipping modules already
loaded. This includes the cooked app. A module's `on_load` callback can
load another module before its turn. A preload failure aborts boot.
See the [performance guide](performance.md) for startup costs.

After preload, the code server reports each module it loads on demand from
the code path, for example from a directory the guest added. The owner
receives `{:kettlecorn, vm, {:late_load, "Elixir.Mod"}}`, which it
acknowledges like other events; without an owner, the host logs a warning.
In Rust, names go to `VmOptions::late_loads` when configured, or to
`VmOptions::stderr` when configured. Reports are dropped when the channel
is full. `kettlecorn-run` writes to stderr.
`preload: :strict` (`Preload::Strict`, `--preload strict`) also
writes the module's name to guest stderr and stops the VM with exit
status 1.

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
`Kettlecorn.HTTP` is unavailable. **`network: true` and `http: true` allow any
reachable destination,** including internal services, `127.0.0.1`, and cloud
metadata endpoints. `[allow: [:public]]` (`--network-allow public` and
`--http-allow public` for `kettlecorn-run`; a `public` rule in Rust) allows
public addresses only, which excludes loopback, private, link-local
(including the `169.254.169.254` metadata address), and other
special-purpose ranges.
Use the [allowlist rules below](#network-allowlists) to restrict
destinations by host, address, or port. To let guests request specific
operations from the host, use [host calls](guest-api.md#host-calls).
Apply OS network restrictions to the launcher process for Elixir and CLI
VMs, and to the application process for embedded Rust VMs.

### Network allowlists

`network: [allow: rules]` and `http: [allow: rules]` grant access to the listed
destinations only (`NetworkAccess::Only` in Rust; `--network-allow RULE` and
`--http-allow RULE`, repeated, for `kettlecorn-run`). Write each rule as a
string, or use `:public` in Elixir.

| Rule | Allows |
|---|---|
| `api.example.com` | that host name |
| `*.example.com` | its subdomains, not `example.com` itself |
| `10.1.2.3`, `10.0.0.0/8` | an IPv4 address or range |
| `[fd00::1]`, `[fd00::/8]` | an IPv6 address or range |
| `public` (`:public` in Elixir) | any public address |

Add `:port` to allow one port, for example `api.example.com:443` or
`public:443`. An allowlist must have at least one rule. Rules are case
insensitive. The launcher compares IPv4-mapped IPv6 rules and destinations
as IPv4 addresses. For example, `[::ffff:10.0.0.1]` matches `10.0.0.1`.

`public` is an IPv4 address outside the loopback, private, link-local,
shared, documentation, benchmarking, multicast, and reserved ranges, or an
IPv6 address in `2000::/3` outside the IETF protocol assignment
(`2001::/23`), documentation, and 6to4 ranges. The IPv6 check is by prefix,
not by allocation: unallocated and IANA-reserved space inside `2000::/3`,
such as `3000::/4`, counts as public. An address in the NAT64 prefix
`64:ff9b::/96` is judged by its embedded IPv4 address; other IPv6 space,
including the local-use translation prefix, isn't public. A public
address can still route to an internal service on the host's network.

#### Sockets

A hostname rule permits connections to the addresses returned by its
lookup, on the rule's ports. The guest can look up names matched by a rule.
With a `public` rule it can look up any name. The launcher checks
`/etc/hosts` and then uses the host resolver with an absolute name, so host
search domains never expand a rule for `db` to `db.corp.example`.

An address rule can permit a destination without a lookup. A hostname
rule can permit a private address if the name resolves to it. A hostname
lookup returns only addresses permitted by the rules or recorded for that
name's allowed ports. The launcher returns a literal address unchanged
and checks access when the guest uses the socket.

The VM retains up to 4,096 address and port pairs from lookups for its
lifetime. An address allowed on every port counts once. Pairs already
permitted by an address rule take no space. At the limit, additional pairs
gain no permission.

Socket allowlists deny listening and accepting connections. A denied
connection or lookup returns `:eacces`. The guest resolves its own name,
`localhost`, to `127.0.0.1` without a lookup. Connecting still requires
permission for that address and port.

#### HTTP

The HTTP launcher checks the URL host and port before sending each request.

| URL host | What permits the request | Proxy use |
|---|---|---|
| Literal IP address | An address rule matches the IP and port. | Uses the configured proxy if one applies. |
| Hostname that matches a name rule | The name rule matches the host and port. The rule trusts the name's resolution, including private results. | Uses the configured proxy if one applies. |
| Other hostname | The launcher resolves the name and connects only to IP addresses permitted by an address rule on that port. | Requires a direct connection. |

The launcher resolves hostnames as absolute names for direct requests
with an allowlist. If a hostname needs an address rule and a proxy
applies, add the hostname to `NO_PROXY` so the launcher can resolve and
check its addresses.

A request without a matching rule fails with `:http_request_denied`. If a
direct lookup returns addresses and the address rules exclude all of them,
the request fails with `:destination_ip_prohibited`. IPv6 URL hosts with
a zone index, such as `[fe80::1%25eth0]`, fail with
`:http_request_uri_invalid`, including without an allowlist. When a client
follows a redirect, the new request is checked again.

### Proxies

**HTTP grant.** The launcher reads proxy settings from its environment
when the VM starts. An embedded Rust VM reads its application's process
environment.

| Variable | Applies to |
|---|---|
| `http_proxy` or `HTTP_PROXY` | Requests to `http://` URLs |
| `https_proxy` or `HTTPS_PROXY` | Requests to `https://` URLs |
| `no_proxy` or `NO_PROXY` | Direct connections to comma-separated hostnames, domains, or IP addresses |

The first nonblank value wins, with lowercase checked first. Entries such
as `.example.com` match the domain and its subdomains. Use `*` to bypass
proxies for all requests. Loopback IP addresses, `localhost`, and
subdomains of `localhost` always use direct connections.

The proxy address must use `http://` or omit the scheme, even when set in
`HTTPS_PROXY`. The launcher sends credentials from the proxy URL as
`Proxy-Authorization`. For HTTPS requests, it opens a `CONNECT`
tunnel and verifies the origin's TLS certificate through it. See
[network allowlists](#network-allowlists) for requests that require a
direct connection.

**Sockets grant.** Configure the proxy in the guest HTTP client. With Req,
use `connect_options: [proxy: {:http, "proxy.internal", 3128, []}]`.
Pass the address through `:env` if it varies. List the proxy's address
and port in the socket allowlist. The proxy must enforce any rules for
the destinations reached through it.

See [HTTP and Req](running-applications.md#http-and-req) for how the grants
select Req's adapter, and which CA certificates each uses. With the Elixir
API's sockets grant, the guest gets a copy of the host's CA certificates
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

To compare reduction counts for single-process evaluations, start fresh VMs
with the same code and runtime and send each VM the same requests in order.
Preloading reduces variation from on-demand loads. Wall-clock timeouts and
external inputs can affect how much work completes.

## Controlled inputs

Record the requests in order. For each host call, record its name,
arguments, and reply. Capture any other inputs the guest reads. Replay
those inputs in a fresh VM with the same code, runtime version, and
configuration.

Read the clock on the host and record the value with the request or
reply. For random draws, record a seed and pass it to the guest. Use
`:rand`'s explicit-state functions to carry the generator state between draws:

```elixir
{:ok, seed} = Kettlecorn.Host.call("seed")
state = :rand.seed_s(:exsss, seed)
{first, state} = :rand.uniform_s(6, state)
{second, _state} = :rand.uniform_s(6, state)
```

At each host call, match its name and arguments against the next recorded
call before returning the recorded reply. Check that the replay used
every reply and produced the expected results. Guest timers, concurrent
processes, and reads from external services can change those results.

The Dune example restricts clock reads and draws random numbers from a
supplied seed. The Lua example supplies the receipt time and code with
each request. See the
[cooked examples](https://github.com/mjrusso/kettlecorn/blob/main/examples/README.md#cooked-apps).

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
