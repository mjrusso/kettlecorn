use anyhow::{Context, Result, bail, ensure};
use kettlecorn::{EvalOptions, Runtime, Value, Vm, VmOptions};
use std::num::NonZeroUsize;
use std::path::Path;
use std::process::Command;
use std::sync::Arc;
use std::time::{Duration, Instant};
use tokio::sync::Notify;

const ROUNDS: usize = 3;
const WARMUP_PAIRS: usize = 100;
const HOST_CALLS: u32 = 10_000;
const SETUP: &str = r#"
defmodule DispatchBench do
  use GenServer
  def init(:ok), do: {:ok, :ok}
  def handle_call({:add, value}, _from, state), do: {:reply, value + 1, state}

  def host_calls(0), do: :ok
  def host_calls(count) do
    {:ok, :pong} = Kettlecorn.Host.call("ping")
    host_calls(count - 1)
  end
end
{:ok, _} = GenServer.start(DispatchBench, :ok, name: DispatchBench)
"#;
const EVAL: &str = "GenServer.call(DispatchBench, {:add, 41})";
const VMS: usize = 8;
const IDLE_SECONDS: usize = 30;
const WAIT: &str = r#"
spawn(fn -> Kettlecorn.Host.call("wait", %{}, timeout: :infinity) end)
:ok
"#;

#[tokio::main(flavor = "current_thread")]
async fn main() -> Result<()> {
    let path = std::env::var_os("KETTLECORN_RUNTIME")
        .context("set KETTLECORN_RUNTIME or run just bench-rust")?;
    match std::env::args().nth(1).as_deref() {
        None | Some("--bench") => run_suite(),
        Some("startup") => startup(&Runtime::load(path)?, false).await,
        Some("warm-up") => startup(&Runtime::load(path)?, true).await,
        Some("dispatch") => dispatch(&Runtime::load(path)?).await,
        Some("usage") => usage(&Runtime::load(path)?).await,
        Some(mode) => bail!("unknown embedding benchmark mode: {mode}"),
    }
}

fn samples() -> Result<usize> {
    positive("BENCH_SAMPLES", 2000)
}

fn positive(name: &str, default: usize) -> Result<usize> {
    match std::env::var(name) {
        Ok(value) => Ok(value
            .parse::<NonZeroUsize>()
            .with_context(|| format!("{name} must be a positive integer"))?
            .get()),
        Err(std::env::VarError::NotPresent) => Ok(default),
        Err(error) => Err(error).with_context(|| format!("read {name}")),
    }
}

fn run_suite() -> Result<()> {
    samples()?;
    positive("BENCH_VMS", VMS)?;
    positive("BENCH_IDLE_SECONDS", IDLE_SECONDS)?;
    let executable = std::env::current_exe()?;
    let caches = tempfile::tempdir().context("create temporary compilation caches")?;
    for round in 1..=ROUNDS {
        let scenarios = if round % 2 == 0 {
            ["warm-up", "startup"]
        } else {
            ["startup", "warm-up"]
        };
        for scenario in scenarios {
            let cache = caches.path().join(format!("{round}-{scenario}"));
            println!("Round {round} / {scenario} / cold disk cache");
            run_child(&executable, scenario, &cache)?;
            println!("Round {round} / {scenario} / warm disk cache");
            run_child(&executable, scenario, &cache)?;
        }
    }

    let cache = caches.path().join(format!("{ROUNDS}-startup"));
    println!("Dispatch on one running VM");
    run_child(&executable, "dispatch", &cache)?;
    println!("Fuel and memory");
    run_child(&executable, "usage", &cache)
}

fn run_child(executable: &Path, scenario: &str, cache: &Path) -> Result<()> {
    let status = Command::new(executable)
        .arg(scenario)
        .env("XDG_CACHE_HOME", cache)
        .status()
        .with_context(|| format!("run {scenario} in a fresh process"))?;
    ensure!(
        status.success(),
        "{scenario} benchmark exited with {status}"
    );
    Ok(())
}

async fn startup(runtime: &Runtime, warm_up: bool) -> Result<()> {
    let options = VmOptions::default();
    let total = Instant::now();
    if warm_up {
        runtime.warm_up(&options).await?;
    }
    let before = Instant::now();
    let vm = runtime.start(options).await?;
    let started = Instant::now();
    if warm_up {
        println!("  Runtime::warm_up    {:8.1} ms", millis(before - total));
    }
    println!("  Runtime::start      {:8.1} ms", millis(started - before));
    if warm_up {
        println!("  total               {:8.1} ms", millis(started - total));
    }
    vm.shutdown().await.result?;

    if !warm_up {
        let before = Instant::now();
        let vm = runtime.start(VmOptions::default()).await?;
        println!("  start, same Runtime {:8.1} ms", millis(before.elapsed()));
        vm.shutdown().await.result?;
    }
    Ok(())
}

fn millis(time: Duration) -> f64 {
    time.as_secs_f64() * 1_000.0
}

async fn dispatch(runtime: &Runtime) -> Result<()> {
    let count = samples()?;
    let mut options = VmOptions::default();
    options.register("ping", |_| async { Ok(Value::atom("pong")) });
    let vm = runtime.start(options).await?;
    vm.eval(SETUP, EvalOptions::default()).await?.result?;
    for _ in 0..WARMUP_PAIRS {
        named(&vm).await?;
        evaluated(&vm).await?;
    }

    for round in 1..=ROUNDS {
        let mut calls = Vec::with_capacity(count);
        let mut evals = Vec::with_capacity(count);
        for sample in 0..count {
            if sample % 2 == 0 {
                calls.push(named(&vm).await?);
                evals.push(evaluated(&vm).await?);
            } else {
                evals.push(evaluated(&vm).await?);
                calls.push(named(&vm).await?);
            }
        }
        println!("Round {round} / {count} samples per operation");
        summarize("Vm::call", &mut calls);
        summarize("Vm::eval", &mut evals);
    }

    println!("Host callback in a guest loop");
    let source = format!("DispatchBench.host_calls({HOST_CALLS})");
    for round in 1..=ROUNDS {
        let options = EvalOptions {
            timeout: Duration::from_secs(60),
            ..EvalOptions::default()
        };
        let before = Instant::now();
        vm.eval(&source, options).await?.result?;
        let micros = before.elapsed().as_secs_f64() * 1_000_000.0 / f64::from(HOST_CALLS);
        println!("  round {round} / {HOST_CALLS} calls   mean {micros:7.1} µs");
    }
    vm.shutdown().await.result?;
    Ok(())
}

async fn named(vm: &Vm) -> Result<Duration> {
    let before = Instant::now();
    let reply = vm
        .call(
            "Elixir.DispatchBench",
            Value::Tuple(vec![Value::atom("add"), Value::from(41)]),
        )
        .await?;
    let elapsed = before.elapsed();
    ensure!(
        reply == Value::from(42),
        "unexpected named call result: {reply:?}"
    );
    Ok(elapsed)
}

async fn evaluated(vm: &Vm) -> Result<Duration> {
    let before = Instant::now();
    let reply = vm.eval(EVAL, EvalOptions::default()).await?;
    let elapsed = before.elapsed();
    let result = reply.result?.value;
    ensure!(
        result == Some(Value::from(42)),
        "unexpected eval result: {result:?}"
    );
    Ok(elapsed)
}

fn summarize(label: &str, samples: &mut [Duration]) {
    samples.sort_unstable();
    let count = samples.len();
    let micros = |time: Duration| time.as_secs_f64() * 1_000_000.0;
    let median = (micros(samples[(count - 1) / 2]) + micros(samples[count / 2])) / 2.0;
    println!(
        "  {label:<9} min {:>7.1} µs   median {:>7.1} µs   p95 {:>7.1} µs",
        micros(samples[0]),
        median,
        micros(samples[count - 1 - count / 20]),
    );
}

async fn usage(runtime: &Runtime) -> Result<()> {
    let waiting = Arc::new(Notify::new());
    let metered = || {
        let mut options = VmOptions::default();
        options.max_fuel = Some(u64::MAX);
        options.host_call_timeout = Duration::from_secs(86_400);
        let waiting = waiting.clone();
        options.register("wait", move |_| {
            waiting.notify_one();
            std::future::pending()
        });
        options
    };
    runtime.warm_up(&metered()).await?;

    let count = positive("BENCH_VMS", VMS)?;
    let before = Memory::read();
    let mut vms = Vec::with_capacity(count);
    vms.push(runtime.start(metered()).await?);
    // Sample the first VM before starting the others, while it has run only its boot.
    let stats = vms[0].stats();
    for _ in 1..count {
        vms.push(runtime.start(metered()).await?);
    }
    println!(
        "  boot fuel           {:>8.1} M",
        stats.fuel_consumed.unwrap_or_default() as f64 / 1e6
    );
    println!(
        "  linear memory       {:>8.1} MiB",
        mib(stats.memory as u64)
    );
    match (before, Memory::read()) {
        (Some(before), Some(after)) => {
            let per_vm =
                |bytes: u64, earlier: u64| mib(bytes.saturating_sub(earlier)) / count as f64;
            println!(
                "  per idle VM ({count} VMs) rss {:.1} MiB   private {:.1} MiB   pss {:.1} MiB",
                per_vm(after.rss, before.rss),
                per_vm(after.private, before.private),
                per_vm(after.pss, before.pss),
            );
        }
        _ => println!("  per idle VM: /proc/self/smaps_rollup is unavailable"),
    }
    for vm in vms.drain(1..) {
        vm.shutdown().await.result?;
    }

    let vm = vms.pop().context("no VM")?;
    vm.eval(WAIT, EvalOptions::default()).await?.result?;
    tokio::time::timeout(Duration::from_secs(30), waiting.notified())
        .await
        .context("the guest did not call the wait callback within 30 s")?;
    let seconds = positive("BENCH_IDLE_SECONDS", IDLE_SECONDS)?;
    let start = vm.stats().fuel_consumed.unwrap_or_default();
    tokio::time::sleep(Duration::from_secs(seconds as u64)).await;
    let used = vm.stats().fuel_consumed.unwrap_or_default() - start;
    println!(
        "  blocked on a host call for {seconds} s: {used} fuel ({:.1} M per hour)",
        used as f64 * 3600.0 / seconds as f64 / 1e6
    );
    vm.shutdown().await.result?;
    Ok(())
}

fn mib(bytes: u64) -> f64 {
    bytes as f64 / (1024.0 * 1024.0)
}

/// Process memory from Linux's `/proc/self/smaps_rollup`, in bytes.
struct Memory {
    rss: u64,
    private: u64,
    pss: u64,
}

impl Memory {
    fn read() -> Option<Self> {
        let text = std::fs::read_to_string("/proc/self/smaps_rollup").ok()?;
        let field = |name: &str| -> u64 {
            text.lines()
                .filter_map(|line| line.strip_prefix(name)?.strip_prefix(':'))
                .filter_map(|rest| rest.split_whitespace().next()?.parse::<u64>().ok())
                .sum::<u64>()
                * 1024
        };
        Some(Self {
            rss: field("Rss"),
            private: field("Private_Clean") + field("Private_Dirty"),
            pss: field("Pss"),
        })
    }
}
