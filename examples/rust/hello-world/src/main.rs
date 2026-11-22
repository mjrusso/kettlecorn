use anyhow::{Context, Result};
use kettlecorn::{EvalOptions, Runtime, VmOptions};

#[tokio::main(flavor = "current_thread")]
async fn main() -> Result<()> {
    let directory = std::env::args_os()
        .nth(1)
        .context("pass the Kettlecorn runtime directory")?;
    let runtime = Runtime::load(directory)?;
    let vm = runtime.start(VmOptions::default()).await?;

    let evaluation = vm
        .eval(r#"IO.puts("Hello from Elixir")"#, EvalOptions::default())
        .await;
    let shutdown = vm.shutdown().await;
    let evaluation = evaluation?;
    print!("{}", evaluation.output);
    evaluation.result?;
    Ok(shutdown.result?)
}
