use anyhow::{Context, Result, bail, ensure};
use kettlecorn::{EvalOptions, Runtime, Value, Vm, VmOptions};
use std::num::NonZeroUsize;
use std::path::Path;
use std::process::Command;
use std::time::{Duration, Instant};

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

#[tokio::main(flavor = "current_thread")]
async fn main() -> Result<()> {
    let path = std::env::var_os("KETTLECORN_RUNTIME")
        .context("set KETTLECORN_RUNTIME or run just bench-rust")?;
    match std::env::args().nth(1).as_deref() {
        None | Some("--bench") => run_suite(),
        Some("startup") => startup(&Runtime::load(path)?, false).await,
        Some("warm-up") => startup(&Runtime::load(path)?, true).await,
        Some("dispatch") => dispatch(&Runtime::load(path)?).await,
        Some(mode) => bail!("unknown embedding benchmark mode: {mode}"),
    }
}

fn samples() -> Result<usize> {
    match std::env::var("BENCH_SAMPLES") {
        Ok(value) => Ok(value
            .parse::<NonZeroUsize>()
            .context("BENCH_SAMPLES must be a positive integer")?
            .get()),
        Err(std::env::VarError::NotPresent) => Ok(2000),
        Err(error) => Err(error).context("read BENCH_SAMPLES"),
    }
}

fn run_suite() -> Result<()> {
    samples()?;
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

    println!("Dispatch on one running VM");
    run_child(
        &executable,
        "dispatch",
        &caches.path().join(format!("{ROUNDS}-startup")),
    )
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
