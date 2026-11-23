use super::{find_cached, installed_dir};
use crate::engine::runtime::{RELEASE_VERSION, release_platform};
use crate::{Error, Runtime};
use anyhow::{Context, Result, ensure};
use flate2::read::GzDecoder;
use sha2::{Digest, Sha256};
use std::fs;
use std::io::{ErrorKind, Read, Seek, Write};
use std::os::unix::fs::symlink;
use std::path::{Path, PathBuf};
use std::time::Duration;
use ureq::tls::{RootCerts, TlsConfig};

const CHECKSUMS: &str = include_str!("../../../checksums.txt");
const RELEASES: &str = "https://github.com/mjrusso/kettlecorn/releases/download";

impl Runtime {
    /// Installs or reuses this crate version's runtime in the user cache shared with
    /// `mix kettlecorn.install`. Requires the `installer` feature.
    /// Downloads are checked against the archive SHA-256 bundled with the crate.
    /// Invalid cache entries return an error and are left in place.
    /// This method always targets the cache and does not use `KETTLECORN_RUNTIME`.
    ///
    /// This is blocking. Call it on a background thread from an async runtime or GUI.
    pub fn install() -> Result<Self, Error> {
        Self::install_with_progress(|_, _| {})
    }

    /// Installs the runtime synchronously, reporting cumulative downloaded bytes and
    /// the total byte count when available. The callback runs on the calling thread
    /// and is skipped when the cache is ready before the download starts.
    pub fn install_with_progress(progress: impl FnMut(u64, Option<u64>)) -> Result<Self, Error> {
        install(checksum, open_release, progress)
    }

    /// Installs a local release archive into the user cache. Requires the `installer` feature.
    /// If the cache already holds a compatible runtime, returns it without reading the archive.
    /// Otherwise, verifies the archive against the SHA-256 bundled for this crate version
    /// and platform.
    ///
    /// This is blocking. Call it on a background thread from an async runtime or GUI.
    pub fn install_from_archive(archive: impl AsRef<Path>) -> Result<Self, Error> {
        install_file(archive.as_ref(), checksum)
    }
}

/// The CI cache handoff passes its locally built archive's digest.
fn install_file<'a>(
    archive: &Path,
    checksum: impl FnOnce(&str) -> Result<&'a str>,
) -> Result<Runtime, Error> {
    let open = |_name: &str| {
        let file =
            fs::File::open(archive).with_context(|| format!("open {}", archive.display()))?;
        Ok((file, None))
    };
    install(checksum, open, |_, _| {})
}

/// `open` returns the archive's bytes, and their total length when the source knows it.
fn install<'a, R: Read>(
    checksum: impl FnOnce(&str) -> Result<&'a str>,
    open: impl FnOnce(&str) -> Result<(R, Option<u64>)>,
    mut progress: impl FnMut(u64, Option<u64>),
) -> Result<Runtime, Error> {
    let directory = installed_dir().map_err(Error::InstallRuntime)?;
    match find_cached(&directory) {
        Err(Error::RuntimeNotFound(_)) => {
            let platform = release_platform().map_err(Error::InstallRuntime)?;
            let name = format!("kettlecorn-runtime-{RELEASE_VERSION}-{platform}.tar.gz");
            let expected = checksum(&name).map_err(Error::InstallRuntime)?;
            let (reader, total) = open(&name).map_err(Error::InstallRuntime)?;
            install_archive(&directory, reader, expected, |bytes| progress(bytes, total))
        }
        result => result,
    }
}

fn open_release(name: &str) -> Result<(impl Read + use<>, Option<u64>)> {
    let url = format!("{RELEASES}/v{RELEASE_VERSION}/{name}");
    let config = ureq::Agent::config_builder()
        .https_only(true)
        .tls_config(
            TlsConfig::builder()
                .root_certs(RootCerts::PlatformVerifier)
                .build(),
        )
        .timeout_connect(Some(Duration::from_secs(30)))
        .timeout_global(Some(Duration::from_secs(600)))
        .build();
    let response = ureq::Agent::new_with_config(config)
        .get(&url)
        .call()
        .with_context(|| format!("download {url}"))?;
    let total = response
        .headers()
        .get(ureq::http::header::CONTENT_LENGTH)
        .and_then(|value| value.to_str().ok()?.parse().ok());
    Ok((response.into_body().into_reader(), total))
}

fn checksum(archive: &str) -> Result<&'static str> {
    CHECKSUMS
        .lines()
        .filter_map(|line| line.split_once("  "))
        .find_map(|(digest, name)| (name == archive).then_some(digest))
        .with_context(|| format!("no bundled SHA-256 for {archive}"))
}

fn install_archive(
    directory: &Path,
    reader: impl Read,
    expected: &str,
    progress: impl FnMut(u64),
) -> Result<Runtime, Error> {
    let parent = directory
        .parent()
        .context("runtime cache needs a parent")
        .map_err(Error::InstallRuntime)?;
    let (staging, entry) =
        stage_archive(parent, reader, expected, progress).map_err(Error::InstallRuntime)?;
    let runtime = Runtime::load_release(&entry).map_err(|error| match error {
        Error::InvalidRuntime(error) => Error::InstallRuntime(error),
        error => error,
    })?;
    let target = entry
        .strip_prefix(parent)
        .context("runtime generation path")
        .map_err(Error::InstallRuntime)?;
    match symlink(target, directory) {
        Ok(()) => {
            let _ = staging.keep();
            Ok(runtime)
        }
        // Another process published first: return its entry, or the reason it
        // can't be used.
        Err(error) if error.kind() == ErrorKind::AlreadyExists => find_cached(directory),
        Err(error) => Err(error)
            .context("publish runtime cache entry")
            .map_err(Error::InstallRuntime),
    }
}

fn stage_archive(
    parent: &Path,
    mut reader: impl Read,
    expected: &str,
    mut progress: impl FnMut(u64),
) -> Result<(tempfile::TempDir, PathBuf)> {
    let mut archive = tempfile::tempfile().context("create temporary archive")?;
    let mut digest = Sha256::new();
    let mut buffer = [0; 64 * 1024];
    let mut downloaded = 0;
    progress(downloaded);
    loop {
        let n = reader.read(&mut buffer).context("read archive body")?;
        if n == 0 {
            break;
        }
        archive
            .write_all(&buffer[..n])
            .context("write temporary archive")?;
        digest.update(&buffer[..n]);
        downloaded += n as u64;
        progress(downloaded);
    }
    let actual = format!("{:x}", digest.finalize());
    ensure!(actual == expected, "SHA-256 {actual}, expected {expected}");
    archive.rewind().context("rewind temporary archive")?;

    let generations = parent.join(format!("runtime-{RELEASE_VERSION}.versions"));
    fs::create_dir_all(&generations).context("create runtime generation directory")?;
    let staging = tempfile::Builder::new()
        .prefix("generation-")
        .tempdir_in(generations)?;
    tar::Archive::new(GzDecoder::new(archive))
        .unpack(staging.path())
        .context("unpack runtime archive")?;
    let mut entries = fs::read_dir(staging.path())?;
    let entry = entries.next().context("empty runtime archive")??;
    ensure!(
        entry.file_type()?.is_dir() && entries.next().is_none(),
        "runtime archive must contain one top-level directory"
    );
    Ok((staging, entry.path()))
}

#[cfg(test)]
mod tests {
    use super::*;
    use flate2::{Compression, write::GzEncoder};

    fn archive() -> Result<Vec<u8>> {
        fixture_archive(serde_json::json!({}), "beam.wasm")
    }

    fn fixture_archive(overrides: serde_json::Value, module: &str) -> Result<Vec<u8>> {
        let mut manifest = serde_json::json!({
            "kettlecorn": RELEASE_VERSION,
            "platform": release_platform()?,
            "protocol": crate::protocol::VERSION,
            "otp": "29",
            "elixir": "1.20.5",
            "imports": { "beam.wasm": [], "beam-http.wasm": [] },
            "tested_with": { "wasmtime": crate::engine::WASMTIME_VERSION },
        });
        manifest
            .as_object_mut()
            .unwrap()
            .extend(overrides.as_object().unwrap().clone());
        let manifest = manifest.to_string();
        let mut builder = tar::Builder::new(GzEncoder::new(Vec::new(), Compression::fast()));
        for (name, contents) in [
            ("manifest.json", manifest.as_str()),
            ("launch/module", module),
            ("launch/http-module", "beam-http.wasm"),
            ("launch/env", ""),
            ("launch/emulator-args", ""),
            ("launch/init-args", ""),
            ("bin/kettlecorn-launch", ""),
            ("bin/kettlecorn-run", ""),
            ("beam.wasm", ""),
            ("beam-http.wasm", ""),
            ("root/file", ""),
        ] {
            let mut header = tar::Header::new_gnu();
            header.set_mode(0o755);
            header.set_size(contents.len() as u64);
            builder.append_data(&mut header, format!("runtime/{name}"), contents.as_bytes())?;
        }
        Ok(builder.into_inner()?.finish()?)
    }

    #[test]
    fn launch_module_uses_the_same_name_for_cached_and_explicit_loads() -> Result<()> {
        let cache = tempfile::tempdir()?;
        let destination = cache.path().join("runtime");
        let bytes = fixture_archive(serde_json::json!({}), "beam.wasm \r\n")?;
        let expected = format!("{:x}", Sha256::digest(&bytes));
        let runtime = install_archive(&destination, &bytes[..], &expected, |_| {})?;
        assert!(runtime.component(false).ends_with("beam.wasm"));
        assert_eq!(
            Runtime::load(&destination)?.component(false),
            runtime.component(false)
        );
        Ok(())
    }

    #[test]
    fn rejects_an_incompatible_engine_before_publication() -> Result<()> {
        let cache = tempfile::tempdir()?;
        let destination = cache.path().join("runtime");
        let bytes = fixture_archive(
            serde_json::json!({"tested_with": {"wasmtime": "0.0.0"}}),
            "beam.wasm",
        )?;
        let expected = format!("{:x}", Sha256::digest(&bytes));
        assert!(matches!(
            install_archive(&destination, &bytes[..], &expected, |_| {}),
            Err(Error::IncompatibleEngine { .. })
        ));
        assert_eq!(
            destination.symlink_metadata().unwrap_err().kind(),
            ErrorKind::NotFound
        );
        assert_eq!(
            cache
                .path()
                .join(format!("runtime-{RELEASE_VERSION}.versions"))
                .read_dir()?
                .count(),
            0
        );

        tar::Archive::new(GzDecoder::new(&bytes[..])).unpack(cache.path())?;
        fs::remove_file(destination.join("launch/module"))?;
        assert!(matches!(
            find_cached(&destination),
            Err(Error::IncompatibleEngine { .. })
        ));
        assert!(matches!(
            Runtime::load(destination),
            Err(Error::IncompatibleEngine { .. })
        ));
        Ok(())
    }

    #[test]
    fn rejects_wrong_platform_and_malformed_layout() -> Result<()> {
        let cache = tempfile::tempdir()?;
        for (manifest, module, message) in [
            (
                serde_json::json!({"platform": "other", "tested_with": {"wasmtime": "0.0.0"}}),
                "beam.wasm",
                "expected runtime for",
            ),
            (
                serde_json::json!({}),
                "beam.wasm\nbeam-http.wasm",
                "invalid runtime emulator name",
            ),
        ] {
            let bytes = fixture_archive(manifest, module)?;
            tar::Archive::new(GzDecoder::new(&bytes[..])).unpack(cache.path())?;
            let Err(Error::InvalidRuntime(error)) = find_cached(&cache.path().join("runtime"))
            else {
                anyhow::bail!("expected invalid runtime");
            };
            assert!(format!("{error:#}").contains(message));
        }
        Ok(())
    }

    #[test]
    fn publishes_verified_generations_and_preserves_previous_readers() -> Result<()> {
        let cache = tempfile::tempdir()?;
        let directory = cache.path().join(format!("runtime-{RELEASE_VERSION}"));
        let bytes = archive()?;
        let expected = format!("{:x}", Sha256::digest(&bytes));
        let mut progress = Vec::new();
        install_archive(&directory, &bytes[..], &expected, |n| progress.push(n))?;
        assert_eq!(progress.first(), Some(&0));
        assert_eq!(progress.last(), Some(&(bytes.len() as u64)));
        assert!(fs::read_link(&directory)?.is_relative());
        let first = directory.canonicalize()?;

        let error = install_archive(&directory, &bytes[..], "bad checksum", |_| {})
            .err()
            .unwrap();
        assert!(error.to_string().contains("SHA-256"));
        assert_eq!(directory.canonicalize()?, first);

        fs::remove_file(&directory)?;
        symlink("missing", &directory)?;
        assert!(matches!(
            install_archive(&directory, &bytes[..], &expected, |_| {}),
            Err(Error::InvalidRuntime(_))
        ));
        assert_eq!(fs::read_link(&directory)?, Path::new("missing"));
        fs::remove_file(&directory)?;
        install_archive(&directory, &bytes[..], &expected, |_| {})?;
        assert_ne!(directory.canonicalize()?, first);
        find_cached(&first)?;
        find_cached(&directory)?;
        Ok(())
    }

    #[test]
    fn verified_archive_with_wrong_version_is_not_published() -> Result<()> {
        let cache = tempfile::tempdir()?;
        let directory = cache.path().join(format!("runtime-{RELEASE_VERSION}"));
        let bytes = fixture_archive(
            serde_json::json!({"kettlecorn": "0.0.0", "tested_with": {"wasmtime": "0.0.0"}}),
            "beam.wasm",
        )?;
        let expected = format!("{:x}", Sha256::digest(&bytes));
        let error = install_archive(&directory, &bytes[..], &expected, |_| {})
            .err()
            .unwrap();
        assert!(format!("{error:#}").contains("expected Kettlecorn runtime version"));
        assert_eq!(
            directory.symlink_metadata().unwrap_err().kind(),
            ErrorKind::NotFound
        );
        Ok(())
    }

    #[test]
    fn installation_reuses_a_generation_published_during_progress() -> Result<()> {
        let cache = tempfile::tempdir()?;
        let directory = cache.path().join(format!("runtime-{RELEASE_VERSION}"));
        let bytes = archive()?;
        let expected = format!("{:x}", Sha256::digest(&bytes));
        let mut winner = None;
        let outer = install_archive(&directory, &bytes[..], &expected, |downloaded| {
            if downloaded == 0 {
                winner = Some(install_archive(&directory, &bytes[..], &expected, |_| {}));
            }
        })?;
        let winner = winner.unwrap()?;
        assert_eq!(outer.component(false), winner.component(false));
        let generations = cache
            .path()
            .join(format!("runtime-{RELEASE_VERSION}.versions"));
        assert_eq!(generations.read_dir()?.count(), 1);
        Ok(())
    }

    #[test]
    fn refuses_nonreplaceable_cache_errors_before_download() -> Result<()> {
        let cache = tempfile::tempdir()?;
        let directory = cache.path().join("runtime");
        fs::create_dir(&directory)?;
        fs::write(directory.join("manifest.json"), "not JSON")?;
        let error = find_cached(&directory).err().unwrap();
        assert!(error.to_string().contains("parse manifest.json"));

        let loop_path = cache.path().join("loop");
        symlink("loop", &loop_path)?;
        let Err(Error::InvalidRuntime(error)) = find_cached(&loop_path) else {
            anyhow::bail!("expected the symlink loop error");
        };
        assert_eq!(
            error
                .downcast_ref::<std::io::Error>()
                .unwrap()
                .raw_os_error(),
            Some(libc::ELOOP)
        );
        Ok(())
    }

    #[test]
    fn a_regular_file_created_during_download_is_preserved() -> Result<()> {
        let cache = tempfile::tempdir()?;
        let directory = cache.path().join(format!("runtime-{RELEASE_VERSION}"));
        let bytes = archive()?;
        let expected = format!("{:x}", Sha256::digest(&bytes));
        let result = install_archive(&directory, &bytes[..], &expected, |downloaded| {
            if downloaded == 0 {
                fs::write(&directory, "original").unwrap();
            }
        });
        assert!(matches!(result, Err(Error::InvalidRuntime(_))));
        assert_eq!(fs::read_to_string(directory)?, "original");
        let generations = cache
            .path()
            .join(format!("runtime-{RELEASE_VERSION}.versions"));
        assert_eq!(generations.read_dir()?.count(), 0);
        Ok(())
    }

    #[test]
    fn offline_cache_handoff() -> Result<()> {
        let Some(workspace) = std::env::var_os("KETTLECORN_TEST_CACHE_HANDOFF") else {
            return Ok(());
        };
        let workspace = PathBuf::from(workspace);
        let archive = std::env::var_os("KETTLECORN_TEST_RUNTIME_ARCHIVE")
            .context("cache handoff requires a local release archive")?;
        let bytes = fs::read(&archive).context("read local release archive")?;
        let cache = workspace.join(if cfg!(target_os = "macos") {
            "home/Library/Caches"
        } else {
            "cache"
        });
        let directory = installed_dir()?;
        assert_eq!(
            directory,
            cache.join(format!("kettlecorn/runtime-{RELEASE_VERSION}"))
        );
        assert!(matches!(Runtime::find(), Err(Error::RuntimeNotFound(_))));

        let elixir = |action: &str| -> Result<()> {
            let status = std::process::Command::new("mix")
                .current_dir(Path::new(env!("CARGO_MANIFEST_DIR")).join("../host"))
                .env("MIX_ENV", "test")
                .args(["run", "../tests/runtime-cache.exs", action])
                .status()
                .with_context(|| format!("run Elixir cache handoff {action}"))?;
            ensure!(
                status.success(),
                "Elixir cache handoff {action} failed: {status}"
            );
            Ok(())
        };

        elixir("publish")?;
        Runtime::find()?;
        fs::remove_file(&directory)?;

        // The cold-cache path Runtime::install_from_archive takes, with this
        // archive's digest in place of the bundled one.
        let checksum = format!("{:x}", Sha256::digest(&bytes));
        install_file(Path::new(&archive), |_| Ok(&checksum))?;
        elixir("find")?;

        fs::write(workspace.join("complete"), [])?;
        Ok(())
    }
}
