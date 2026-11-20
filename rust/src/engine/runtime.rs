use super::{CompilationCache, Preparation, RootOptions, WASMTIME_VERSION, root};
use anyhow::{Context, Result, ensure};
use serde::Deserialize;
use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::Duration;

#[derive(Clone, Debug)]
pub(crate) enum Mode {
    Boot,
    #[cfg(any(feature = "cli", test))]
    Cli {
        iex: bool,
        args: Vec<String>,
    },
}

#[derive(Clone, Debug)]
pub(crate) struct GuestOptions {
    pub root: PathBuf,
    pub framed: bool,
    pub mode: Mode,
    pub max_memory: Option<usize>,
    pub max_fuel: Option<u64>,
    pub max_lifetime: Option<Duration>,
    pub network: bool,
    pub http: bool,
    pub schedulers: usize,
    pub env: BTreeMap<String, String>,
    pub apps: Vec<String>,
    pub code_paths: Vec<String>,
    pub emulator_flags: Vec<String>,
    /// Persistent cache used by `Runtime::prepare`, never by execution.
    pub cache: CompilationCache,
    /// Permit synchronous filesystem operations. Keep false when polling on a
    /// UI thread or when cancellation must interrupt pending filesystem I/O.
    pub blocking_filesystem: bool,
}

impl GuestOptions {
    pub fn new(root: impl Into<PathBuf>) -> Self {
        Self {
            root: root.into(),
            framed: true,
            mode: Mode::Boot,
            max_memory: None,
            max_fuel: None,
            max_lifetime: None,
            network: false,
            http: false,
            schedulers: 1,
            env: BTreeMap::new(),
            apps: Vec::new(),
            code_paths: Vec::new(),
            emulator_flags: Vec::new(),
            cache: CompilationCache::default(),
            blocking_filesystem: false,
        }
    }
}

#[derive(Clone)]
pub struct Runtime {
    directory: PathBuf,
    pub(super) preparation: Arc<Mutex<Preparation>>,
    emulator: Vec<String>,
    init: Vec<String>,
    env: BTreeMap<String, String>,
    module: String,
    http_module: String,
}

#[derive(Deserialize)]
struct Manifest {
    protocol: u32,
    tested_with: Tested,
}
#[derive(Deserialize)]
struct Tested {
    wasmtime: String,
}

impl Runtime {
    /// Populates a new private root. Sources are dereferenced and copies are
    /// writable; failures remove the new root without changing the sources.
    pub(crate) fn populate_root(&self, root: &Path, options: &RootOptions) -> Result<()> {
        let parent = root
            .parent()
            .filter(|path| !path.as_os_str().is_empty())
            .unwrap_or(Path::new("."));
        let root = parent
            .canonicalize()?
            .join(root.file_name().context("root must name a new directory")?);
        ensure!(
            !root.starts_with(&self.directory),
            "private root must be outside the runtime"
        );
        root::populate(
            &self.directory.join("root"),
            &root,
            options,
            self.env.get("KETTLECORN_CACERTFILE").map(String::as_str),
        )
    }

    pub fn load(directory: impl AsRef<Path>) -> Result<Self, crate::Error> {
        Self::load_runtime(directory.as_ref()).map_err(crate::Error::InvalidRuntime)
    }

    fn load_runtime(directory: &Path) -> Result<Self> {
        let directory = directory.canonicalize().context("runtime directory")?;
        let manifest: Manifest =
            serde_json::from_slice(&std::fs::read(directory.join("manifest.json"))?)?;
        ensure!(
            manifest.tested_with.wasmtime == WASMTIME_VERSION,
            "runtime requires Wasmtime {}, launcher embeds {}",
            manifest.tested_with.wasmtime,
            WASMTIME_VERSION
        );
        ensure!(
            manifest.protocol == crate::protocol::VERSION,
            "runtime protocol {} does not match {}",
            manifest.protocol,
            crate::protocol::VERSION
        );
        let launch = directory.join("launch");
        let env = lines(&launch.join("env"))?
            .into_iter()
            .map(|entry| {
                let (name, value) = entry
                    .split_once('=')
                    .context("invalid runtime environment")?;
                Ok((name.to_owned(), value.to_owned()))
            })
            .collect::<Result<_>>()?;
        Ok(Self {
            emulator: lines(&launch.join("emulator-args"))?,
            init: lines(&launch.join("init-args"))?,
            env,
            module: std::fs::read_to_string(launch.join("module"))?
                .trim()
                .to_owned(),
            http_module: std::fs::read_to_string(launch.join("http-module"))?
                .trim()
                .to_owned(),
            directory,
            preparation: Arc::default(),
        })
    }

    pub(crate) fn component(&self, http: bool) -> PathBuf {
        self.directory.join(if http {
            &self.http_module
        } else {
            &self.module
        })
    }

    pub(crate) fn validate(&self, options: &GuestOptions) -> Result<()> {
        ensure!(options.root.is_dir(), "guest root does not exist");
        ensure!(options.schedulers > 0, "at least one scheduler is required");
        let root = options.root.canonicalize()?;
        ensure!(
            !root.starts_with(&self.directory),
            "guest root must be a writable copy outside the runtime"
        );
        Ok(())
    }

    pub(crate) fn environment(&self, options: &GuestOptions) -> Vec<(String, String)> {
        let mut env = self.env.clone();
        env.extend(options.env.clone());
        if options.framed {
            env.insert("KETTLECORN_FRAMED".into(), "1".into());
        } else {
            env.remove("KETTLECORN_FRAMED");
        }
        env.into_iter().collect()
    }

    pub(crate) fn arguments(&self, options: &GuestOptions) -> Vec<String> {
        let mut args = vec![
            self.component(options.http).to_string_lossy().into_owned(),
            "-S".into(),
            format!("{0}:{0}", options.schedulers),
        ];
        args.extend(self.emulator.clone());
        args.extend(options.emulator_flags.clone());
        args.push("--".into());
        args.extend(self.init.clone());
        for path in &options.code_paths {
            args.extend(["-pa".into(), path.clone()]);
        }
        args.push("-kettlecorn_apps".into());
        args.extend(options.apps.clone());
        if options.network {
            args.push("-kettlecorn_network".into());
        }
        match &options.mode {
            #[cfg(any(feature = "cli", test))]
            Mode::Cli {
                iex: true,
                args: extra,
            } => {
                args.extend(
                    [
                        "-user",
                        "elixir",
                        "-extra",
                        "--no-halt",
                        "+iex",
                        "-e",
                        "Kettlecorn.Boot.start()",
                    ]
                    .map(str::to_owned),
                );
                if extra.first().is_some_and(|arg| !arg.starts_with('-')) {
                    args.push("-r".into());
                }
                args.extend(extra.clone());
            }
            #[cfg(any(feature = "cli", test))]
            Mode::Cli {
                iex: false,
                args: extra,
            } if !extra.is_empty() => {
                args.extend(["-run", "Elixir.Kettlecorn.Boot", "cli", "-extra"].map(str::to_owned));
                args.extend(extra.clone());
            }
            _ => {
                args.extend(["-run", "Elixir.Kettlecorn.Boot", "start"].map(str::to_owned));
            }
        }
        args
    }

    /// Arguments for optional manual debugging with the matching Wasmtime CLI.
    #[cfg(feature = "cli")]
    pub(crate) fn wasmtime_command(&self, options: &GuestOptions) -> Vec<String> {
        let mut args = vec![
            "wasmtime".into(),
            "run".into(),
            "-W".into(),
            "component-model-async=y,component-model-threading=y".into(),
            "-S".into(),
            "p3=y".into(),
        ];
        if let Some(memory) = options.max_memory {
            args.extend(["-W".into(), format!("max-memory-size={memory}")]);
        }
        if let Some(fuel) = options.max_fuel {
            args.extend(["-W".into(), format!("fuel={fuel}")]);
        }
        if let Some(timeout) = options.max_lifetime {
            args.extend(["-W".into(), format!("timeout={}ms", timeout.as_millis())]);
        }
        if options.network {
            args.extend(
                ["-S", "inherit-network=y", "-S", "allow-ip-name-lookup=y"].map(str::to_owned),
            );
        }
        if options.http {
            args.extend(["-S", "http=y"].map(str::to_owned));
        }
        args.extend(["--dir".into(), format!("{}::/", options.root.display())]);
        for (name, value) in self.environment(options) {
            args.extend(["--env".into(), format!("{name}={value}")]);
        }
        args.extend(self.arguments(options));
        args
    }
}

fn lines(path: &Path) -> Result<Vec<String>> {
    Ok(std::fs::read_to_string(path)?
        .lines()
        .filter(|line| !line.is_empty())
        .map(str::to_owned)
        .collect())
}
