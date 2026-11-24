use super::{
    CompilationCache, NetworkAccess, Preparation, RootOptions, Usage, WASMTIME_VERSION, root,
};
use crate::Error;
use anyhow::{Context, Result, bail, ensure};
use serde::Deserialize;
use std::collections::BTreeMap;
use std::env;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::Duration;

pub(super) const RELEASE_VERSION: &str = env!("CARGO_PKG_VERSION");

#[derive(Clone, Debug)]
pub(crate) enum Mode {
    Boot,
    #[cfg(any(feature = "cli", test))]
    Cli {
        iex: bool,
        args: Vec<String>,
    },
}

/// How the VM preloads modules at boot and handles later on-demand loads.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
#[non_exhaustive]
pub enum Preload {
    /// Use OTP's default loading behavior.
    #[default]
    Off,
    /// Load modules on the boot-time code path in name order, skipping those
    /// already loaded. A preload failure aborts boot. Report later on-demand loads.
    On,
    /// Preload as in `On` and stop the VM on a later on-demand load.
    Strict,
}

#[derive(Clone, Debug)]
pub(crate) struct GuestOptions {
    pub root: PathBuf,
    pub framed: bool,
    pub mode: Mode,
    pub max_memory: Option<usize>,
    pub max_fuel: Option<u64>,
    pub max_lifetime: Option<Duration>,
    pub network: NetworkAccess,
    pub http: NetworkAccess,
    pub schedulers: usize,
    pub env: BTreeMap<String, String>,
    pub apps: Vec<String>,
    pub preload: Preload,
    pub code_paths: Vec<String>,
    pub emulator_flags: Vec<String>,
    /// Persistent cache used by `Runtime::prepare`, never by execution.
    pub cache: CompilationCache,
    /// Permit synchronous filesystem operations. Keep false when polling on a
    /// UI thread or when cancellation must interrupt pending filesystem I/O.
    pub blocking_filesystem: bool,
    /// Counters the execution updates while it runs.
    pub usage: Arc<Usage>,
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
            network: NetworkAccess::Denied,
            http: NetworkAccess::Denied,
            schedulers: 1,
            env: BTreeMap::new(),
            apps: Vec::new(),
            preload: Preload::Off,
            code_paths: Vec::new(),
            emulator_flags: Vec::new(),
            cache: CompilationCache::default(),
            blocking_filesystem: false,
            usage: Arc::default(),
        }
    }
}

/// A loaded runtime directory with shared engine and component preparation across clones.
#[derive(Clone)]
pub struct Runtime {
    directory: PathBuf,
    pub(super) preparation: Arc<Mutex<Preparation>>,
    launch: Launch,
}

#[derive(Clone)]
struct Launch {
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

enum LoadSource {
    Explicit,
    Release,
}
#[derive(Deserialize)]
struct Tested {
    wasmtime: String,
}

impl Manifest {
    fn check_protocol(&self) -> Result<()> {
        ensure!(
            self.protocol == crate::protocol::VERSION,
            "runtime protocol {} does not match {}",
            self.protocol,
            crate::protocol::VERSION
        );
        Ok(())
    }

    fn check_engine(self) -> Result<(), Error> {
        if self.tested_with.wasmtime == WASMTIME_VERSION {
            Ok(())
        } else {
            Err(Error::IncompatibleEngine {
                required: self.tested_with.wasmtime,
                embedded: WASMTIME_VERSION,
            })
        }
    }
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
            self.launch
                .env
                .get("KETTLECORN_CACERTFILE")
                .map(String::as_str),
        )
    }

    /// Loads a bundled or locally built runtime, resolving its directory's symlinks.
    /// Checks the protocol and exact Wasmtime version, then reads the launch configuration.
    /// This is synchronous and does not download, copy, compile, or boot the runtime.
    ///
    /// Unlike [`Runtime::find`]'s cache lookup, explicit loading does not require the
    /// runtime's release version or platform metadata to match this crate. A Wasmtime
    /// mismatch returns [`Error::IncompatibleEngine`]; invalid manifest or launch files
    /// return [`Error::InvalidRuntime`].
    pub fn load(directory: impl AsRef<Path>) -> Result<Self, Error> {
        Self::load_from(directory.as_ref(), LoadSource::Explicit)
    }

    pub(super) fn load_release(directory: &Path) -> Result<Self, Error> {
        Self::load_from(directory, LoadSource::Release)
    }

    fn load_from(directory: &Path, source: LoadSource) -> Result<Self, Error> {
        let invalid = |error: anyhow::Error| {
            Error::InvalidRuntime(error.context(format!("load runtime at {}", directory.display())))
        };
        let read = || {
            let root = directory.canonicalize().context("runtime directory")?;
            let json = std::fs::read(root.join("manifest.json")).context("read manifest.json")?;
            let (manifest, release) = match source {
                LoadSource::Explicit => {
                    serde_json::from_slice(&json).map(|manifest| (manifest, None))
                }
                LoadSource::Release => serde_json::from_slice(&json)
                    .map(|ReleaseManifest { manifest, identity }| (manifest, Some(identity))),
            }
            .context("parse manifest.json")?;
            Ok((root, manifest, release))
        };
        let (root, manifest, release) = read().map_err(invalid)?;
        manifest.check_protocol().map_err(invalid)?;
        if let Some(identity) = &release {
            identity.check().map_err(invalid)?;
        }
        manifest.check_engine()?;
        let launch = Launch::read(&root).map_err(invalid)?;
        if release.is_some() {
            check_release_layout(&root, &launch).map_err(invalid)?;
        }
        Ok(Self {
            directory: root,
            launch,
            preparation: Arc::default(),
        })
    }

    pub(crate) fn component(&self, http: bool) -> PathBuf {
        self.directory.join(if http {
            &self.launch.http_module
        } else {
            &self.launch.module
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
        let mut env = self.launch.env.clone();
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
            self.component(options.http.granted())
                .to_string_lossy()
                .into_owned(),
            "-S".into(),
            format!("{0}:{0}", options.schedulers),
        ];
        args.extend(self.launch.emulator.clone());
        args.extend(options.emulator_flags.clone());
        args.push("--".into());
        args.extend(self.launch.init.clone());
        for path in &options.code_paths {
            args.extend(["-pa".into(), path.clone()]);
        }
        args.push("-kettlecorn_apps".into());
        args.extend(options.apps.clone());
        if options.network.granted() {
            args.push("-kettlecorn_network".into());
        }
        match options.preload {
            Preload::Off => {}
            Preload::On => args.extend(["-kettlecorn_preload".into(), "on".into()]),
            Preload::Strict => args.extend(["-kettlecorn_preload".into(), "strict".into()]),
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
    pub(crate) fn wasmtime_command(&self, options: &GuestOptions) -> anyhow::Result<Vec<String>> {
        anyhow::ensure!(
            options.network.rules().is_none() && options.http.rules().is_none(),
            "the Wasmtime command can't express network allowlists"
        );
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
        if options.network.granted() {
            args.extend(
                ["-S", "inherit-network=y", "-S", "allow-ip-name-lookup=y"].map(str::to_owned),
            );
        }
        if options.http.granted() {
            args.extend(["-S", "http=y"].map(str::to_owned));
        }
        args.extend(["--dir".into(), format!("{}::/", options.root.display())]);
        for (name, value) in self.environment(options) {
            args.extend(["--env".into(), format!("{name}={value}")]);
        }
        args.extend(self.arguments(options));
        Ok(args)
    }
}

#[derive(Deserialize)]
struct ReleaseManifest {
    #[serde(flatten)]
    manifest: Manifest,
    #[serde(flatten)]
    identity: ReleaseIdentity,
}

#[derive(Deserialize)]
struct ReleaseIdentity {
    kettlecorn: String,
    platform: String,
    #[serde(rename = "otp")]
    _otp: String,
    #[serde(rename = "elixir")]
    _elixir: String,
    #[serde(rename = "imports")]
    _imports: serde_json::Map<String, serde_json::Value>,
}

impl ReleaseIdentity {
    fn check(&self) -> Result<()> {
        ensure!(
            self.kettlecorn == RELEASE_VERSION,
            "expected Kettlecorn runtime version {RELEASE_VERSION}, found {}",
            self.kettlecorn
        );
        let platform = release_platform()?;
        ensure!(
            self.platform == platform,
            "expected runtime for {platform}, found {}",
            self.platform
        );
        Ok(())
    }
}

fn check_release_layout(directory: &Path, launch: &Launch) -> Result<()> {
    ensure!(
        directory
            .join("root")
            .metadata()
            .context("read runtime root/")?
            .is_dir(),
        "runtime root/ must be a directory"
    );
    for name in ["bin/kettlecorn-launch", "bin/kettlecorn-run"] {
        let metadata = directory
            .join(name)
            .metadata()
            .with_context(|| format!("read {name}"))?;
        ensure!(
            metadata.is_file() && metadata.permissions().mode() & 0o111 != 0,
            "missing executable {name}"
        );
    }
    for module in [&launch.module, &launch.http_module] {
        let path = Path::new(module);
        ensure!(
            !module.contains(['\r', '\n']) && path.file_name() == Some(path.as_os_str()),
            "invalid runtime emulator name {module:?}"
        );
        let metadata = directory
            .join(path)
            .metadata()
            .with_context(|| format!("read emulator {module}"))?;
        ensure!(
            metadata.is_file(),
            "runtime emulator {module} must be a file"
        );
    }
    Ok(())
}

pub(super) fn release_platform() -> Result<&'static str> {
    match (env::consts::ARCH, env::consts::OS) {
        ("x86_64", "linux") => Ok("x86_64-linux"),
        ("aarch64", "linux") => Ok("aarch64-linux"),
        ("aarch64", "macos") => Ok("aarch64-darwin"),
        (arch, os) => bail!("no Kettlecorn runtime release for {arch}-{os}"),
    }
}

impl Launch {
    fn read(directory: &Path) -> Result<Self> {
        let launch = directory.join("launch");
        let module = |name| -> Result<String> {
            Ok(std::fs::read_to_string(launch.join(name))
                .with_context(|| format!("read launch/{name}"))?
                .trim()
                .to_owned())
        };
        let env = lines(&launch.join("env"))?
            .into_iter()
            .map(|entry| {
                let (name, value) = entry
                    .split_once('=')
                    .context("invalid runtime environment")?;
                Ok((name.to_owned(), value.to_owned()))
            })
            .collect::<Result<_>>()?;
        let emulator = lines(&launch.join("emulator-args"))?;
        let init = lines(&launch.join("init-args"))?;
        let module_name = module("module")?;
        let http_module = module("http-module")?;
        Ok(Self {
            emulator,
            init,
            env,
            module: module_name,
            http_module,
        })
    }
}

fn lines(path: &Path) -> Result<Vec<String>> {
    Ok(std::fs::read_to_string(path)?
        .lines()
        .filter(|line| !line.is_empty())
        .map(str::to_owned)
        .collect())
}
