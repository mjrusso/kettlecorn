use anyhow::{Context, Result, bail, ensure};
use kettlecorn::{Error, EvalOptions, Runtime, Value, VmOptions};
use std::env;
use std::path::Path;
use std::process::Command;

fn main() -> Result<()> {
    match env::args().nth(1).as_deref() {
        None => smoke(),
        Some("install-and-boot") => {
            ensure!(
                matches!(Runtime::find(), Err(Error::RuntimeNotFound(_))),
                "expected an empty runtime cache"
            );
            Runtime::install()?;
            boot(Runtime::find()?)
        }
        Some("boot") => boot(Runtime::find()?),
        Some(argument) => bail!("unknown release smoke action: {argument}"),
    }
}

fn smoke() -> Result<()> {
    ensure!(cfg!(target_os = "linux"), "run release-smoke-rust on Linux");
    let caches = tempfile::tempdir().context("create isolated runtime caches")?;
    let executable = env::current_exe()?;
    let host = Path::new(env!("CARGO_MANIFEST_DIR")).join("../host");

    let rust_cache = caches.path().join("rust");
    run(
        Command::new(&executable).arg("install-and-boot"),
        &rust_cache,
    )?;
    run(
        Command::new("mix").current_dir(&host).args([
            "run",
            "-e",
            "{:ok, _runtime} = Kettlecorn.Runtime.find([])",
        ]),
        &rust_cache,
    )?;

    let elixir_cache = caches.path().join("elixir");
    run(
        Command::new("mix")
            .current_dir(&host)
            .arg("kettlecorn.install"),
        &elixir_cache,
    )?;
    run(Command::new(executable).arg("boot"), &elixir_cache)
}

fn run(command: &mut Command, cache: &Path) -> Result<()> {
    command
        .env_remove("KETTLECORN_RUNTIME")
        .env("XDG_CACHE_HOME", cache);
    let status = command
        .status()
        .with_context(|| format!("run {command:?}"))?;
    ensure!(status.success(), "{command:?} exited with {status}");
    Ok(())
}

fn boot(runtime: Runtime) -> Result<()> {
    tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()?
        .block_on(async {
            let options = VmOptions::default();
            runtime.warm_up(&options).await?;
            let vm = runtime.start(options).await?;
            let evaluation = vm.eval("2 + 2", EvalOptions::default()).await?;
            assert_eq!(evaluation.result?.value, Some(Value::from(4_i64)));
            vm.shutdown().await?;
            Ok(())
        })
}
