# Performance

Starting a VM copies the runtime root and boots OTP. A cold component cache
also requires compilation. Reuse a running VM for repeated evaluations;
give mutually untrusted tenants separate VMs. See
[compilation cache](sandbox.md#compilation-cache) for cache configuration and
trust requirements.

## Local benchmarks

From the repository root, inside `nix develop`:

```sh
just bench-startup
just bench-workloads
just bench-rust
```

`just bench` runs all three suites. `BENCH_TIME` sets seconds per scenario for
the Elixir benchmarks. `BENCH_SAMPLES` sets how many calls the Rust benchmark
measures per operation per round.

```sh
BENCH_TIME=30 just bench
```

The suites print results to the terminal. Keep benchmark results outside the
source tree.

### Startup

`host/bench/startup.exs` measures VM start and stop with a warm cache and
with compilation caching disabled. It also covers `Kettlecorn.run/2`,
concurrent VM starts, the script CLI, and native `elixir -e` as a baseline.
Startup includes root copying and guest boot.

### Workloads

`host/bench/workloads.exs` measures message round trips, GenServer calls,
evaluation, and programs compiled on both sides. Compiled guest programs use
the BEAM interpreter in WebAssembly; native programs use the host JIT.
Source evaluation uses `erl_eval` on both sides. Guest timings include the
host/guest round trip.

### Rust embedding

```sh
just bench-rust
BENCH_SAMPLES=100 just bench-rust
```

The Rust suite runs an optimized build with the default VM settings. Each
startup scenario uses a fresh process and a temporary compilation cache. The
first process compiles the component, and a second starts with that disk
cache populated. The suite also measures another VM on the same `Runtime`
and times `Runtime::warm_up` separately from `Runtime::start`.

For dispatch, `Vm::call` and `Vm::eval` alternate on one running VM and
send the same GenServer request. The suite reports minimum, median, and
95th-percentile latency for each of three rounds. `BENCH_SAMPLES` sets the sample
count per operation per round and defaults to 2,000.
The suite also reports mean guest-to-host round-trip time per call. It times
one `Vm::eval` that makes 10,000 calls to a Rust callback and divides the
elapsed time by 10,000.
