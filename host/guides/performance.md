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
```

`just bench` runs both suites. `BENCH_TIME` sets seconds per scenario:

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

For Rust embedding, measure `Runtime::prepare` separately from repeated
`PreparedRuntime::run` calls. Preparation compiles or loads the component;
each execution reuses it and creates a fresh store.
