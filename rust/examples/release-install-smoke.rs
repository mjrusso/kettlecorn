use anyhow::{Context, Result, bail, ensure};
use kettlecorn::{Error, EvalOptions, Runtime, Value, VmOptions};
use std::env;
use std::path::{Path, PathBuf};
use std::process::Command;

// With `--archive PATH`, both installers install that file instead of
// downloading; `just release-smoke-offline` runs it without network access.
fn main() -> Result<()> {
    let args: Vec<String> = env::args().skip(1).collect();
    match args.iter().map(String::as_str).collect::<Vec<_>>()[..] {
        [] => smoke(None),
        ["--archive", archive] => smoke(Some(Path::new(archive).canonicalize()?)),
        ["install-and-boot", ref archive @ ..] => {
            ensure!(
                matches!(Runtime::find(), Err(Error::RuntimeNotFound(_))),
                "expected an empty runtime cache"
            );
            match archive {
                [] => Runtime::install()?,
                [archive] => Runtime::install_from_archive(archive)?,
                _ => bail!("install-and-boot takes at most an archive path"),
            };
            boot(Runtime::find()?)
        }
        ["boot"] => boot(Runtime::find()?),
        _ => bail!("unknown release smoke arguments: {args:?}"),
    }
}

fn smoke(archive: Option<PathBuf>) -> Result<()> {
    ensure!(
        cfg!(target_os = "linux"),
        "run the release smoke checks on Linux"
    );
    let caches = tempfile::tempdir().context("create isolated runtime caches")?;
    let executable = env::current_exe()?;
    let host = Path::new(env!("CARGO_MANIFEST_DIR")).join("../host");

    let rust_cache = caches.path().join("rust");
    run(
        Command::new(&executable)
            .arg("install-and-boot")
            .args(&archive),
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
    let mut install = Command::new("mix");
    install.current_dir(&host).arg("kettlecorn.install");
    if let Some(archive) = &archive {
        install.arg("--archive").arg(archive);
    }
    run(&mut install, &elixir_cache)?;
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
            vm.shutdown().await.result?;
            Ok(())
        })
}
