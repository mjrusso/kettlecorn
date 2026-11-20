#[cfg(feature = "installer")]
mod install;

use super::runtime::RELEASE_VERSION;
use crate::{Error, Runtime};
use anyhow::{Context, Result, bail};
use std::env;
use std::io::ErrorKind;
use std::path::{Component, Path, PathBuf};

impl Runtime {
    /// Loads the runtime in `KETTLECORN_RUNTIME` or the matching release from the user cache
    /// shared with `mix kettlecorn.install`. This synchronous lookup never downloads a runtime.
    /// Returns [`Error::RuntimeNotFound`] if the cache entry is absent. An invalid override
    /// returns an error without trying the cache. Cached releases must match this crate's
    /// version and host platform.
    pub fn find() -> Result<Self, Error> {
        if let Some(path) = env::var_os("KETTLECORN_RUNTIME").filter(|path| !path.is_empty()) {
            return Self::load(path);
        }
        find_cached(&installed_dir().map_err(Error::InvalidRuntime)?)
    }
}

fn find_cached(directory: &Path) -> Result<Runtime, Error> {
    match directory.symlink_metadata() {
        Ok(_) => {}
        Err(error) if error.kind() == ErrorKind::NotFound => {
            return Err(Error::RuntimeNotFound(directory.to_owned()));
        }
        Err(error) => {
            return Err(Error::InvalidRuntime(
                anyhow::Error::from(error).context("inspect runtime cache entry"),
            ));
        }
    }
    Runtime::load_release(directory)
}

fn installed_dir() -> Result<PathBuf> {
    let home = || env::home_dir().context("locate user home directory");
    let cache = match env::consts::OS {
        "linux" => match env::var_os("XDG_CACHE_HOME").filter(|path| !path.is_empty()) {
            Some(path) => PathBuf::from(path),
            None => home()?.join(".cache"),
        },
        "macos" => home()?.join("Library/Caches"),
        os => bail!("no Kettlecorn runtime cache location for {os}"),
    };
    let cache = match cache.strip_prefix("~") {
        Ok(rest) => home()?.join(rest),
        Err(_) => cache,
    };
    let mut normalized = PathBuf::new();
    for component in std::path::absolute(cache)?.components() {
        if component == Component::ParentDir {
            normalized.pop();
        } else {
            normalized.push(component);
        }
    }
    Ok(normalized.join(format!("kettlecorn/runtime-{RELEASE_VERSION}")))
}
