# Performance

Starting a VM copies the guest filesystem and boots OTP. The launcher
compiles the emulator on a cache miss. Reuse a VM for repeated evaluations
from the same tenant. Give mutually untrusted tenants separate VMs. See
[compilation cache](sandbox.md#compilation-cache) for cache configuration and
trust requirements.

## Local benchmarks

From the repository root, inside `nix develop`:

```sh
just bench-startup
just bench-workloads
just bench-memory
just bench-rust
```

`just bench` runs all four suites. `BENCH_TIME` sets seconds per scenario for
the startup and workload benchmarks.

```sh
BENCH_TIME=30 just bench
```

The suites print results to the terminal. Keep benchmark results outside the
source tree.

### Startup

`host/bench/startup.exs` measures VM start and stop with a warm cache, with
compilation caching disabled, and with `preload: true`. It also measures
`Kettlecorn.run/2`, concurrent VM starts, and the script CLI. Native
`elixir -e` serves as the baseline.
Startup includes root copying and guest boot.

### Workloads

`host/bench/workloads.exs` measures message round trips, GenServer calls,
evaluation, and programs compiled on both sides. Compiled guest programs use
the BEAM interpreter in WebAssembly; native programs use the host JIT.
Source evaluation uses `erl_eval` on both sides. Guest timings include the
host/guest round trip.

### Memory

`host/bench/memory.exs` starts `BENCH_VMS` VMs (default 8) and reports the
mean resident set size (RSS), private memory, and proportional set size
(PSS) per launcher process. PSS divides shared pages among the processes
that map them. This benchmark requires Linux with `/proc/<pid>/smaps_rollup`.

### Rust embedding

```sh
just bench-rust
BENCH_SAMPLES=100 just bench-rust
```

The Rust suite runs an optimized build. It compares startup with an empty
disk cache, startup in a second process using that cache, and startup of
another VM on the same `Runtime`. It times `Runtime::warm_up` separately
from `Runtime::start`.

For dispatch, `Vm::call` and `Vm::eval` alternate on one running VM and
send the same GenServer request. The suite reports minimum, median, and
95th-percentile latency for each of three rounds. `BENCH_SAMPLES` sets the sample
count per operation per round and defaults to 2,000.
The callback benchmark reports the mean time per call over 10,000 calls in
one `Vm::eval`. The timing includes the guest loop and evaluation overhead.

After `Runtime::warm_up`, the usage benchmark starts `BENCH_VMS` metered VMs.
It reports boot fuel and linear memory for the first VM and, on Linux, the
increase in process RSS, private memory, and PSS per idle VM. It then measures
fuel used while one VM waits on a host call for `BENCH_IDLE_SECONDS` (default 30).
