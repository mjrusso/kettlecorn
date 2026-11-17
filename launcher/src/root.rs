use anyhow::{Context, Result, ensure};
use std::collections::HashSet;
use std::fs;
use std::os::unix::fs::{DirBuilderExt, MetadataExt, PermissionsExt};
use std::path::{Component, Path, PathBuf};

#[derive(Default)]
pub struct RootOptions {
    pub app: Option<PathBuf>,
    pub certificates: Option<PathBuf>,
    pub directories: Vec<(PathBuf, PathBuf)>,
    pub files: Vec<(PathBuf, PathBuf)>,
}

pub(crate) fn populate(
    source: &Path,
    root: &Path,
    options: &RootOptions,
    certificate_path: Option<&str>,
) -> Result<()> {
    fs::DirBuilder::new()
        .mode(0o700)
        .create(root)
        .with_context(|| format!("create private root {}", root.display()))?;
    let result = (|| {
        copy_contents(source, root, &mut HashSet::new())?;
        if let Some(app) = &options.app {
            copy_directory(app, &root.join("app"), &mut HashSet::new())?;
        }
        for (source, destination) in &options.directories {
            copy_directory(source, &guest_path(root, destination)?, &mut HashSet::new())?;
        }
        for (source, destination) in &options.files {
            copy_file(source, &guest_path(root, destination)?)?;
        }
        if let Some(certificates) = &options.certificates {
            let path = certificate_path.context("runtime does not define KETTLECORN_CACERTFILE")?;
            copy_file(certificates, &guest_path(root, Path::new(path))?)?;
        }
        Ok(())
    })();
    if result.is_err() {
        let _ = fs::remove_dir_all(root);
    }
    result
}

fn guest_path(root: &Path, path: &Path) -> Result<PathBuf> {
    ensure!(
        path.is_absolute(),
        "guest destination must be absolute: {}",
        path.display()
    );
    let mut destination = root.to_path_buf();
    for component in path.components() {
        match component {
            Component::RootDir => {}
            Component::Normal(name) => destination.push(name),
            _ => anyhow::bail!("invalid guest destination: {}", path.display()),
        }
    }
    ensure!(
        destination != root,
        "guest destination cannot replace the root"
    );
    Ok(destination)
}

fn copy_directory(
    source: &Path,
    destination: &Path,
    ancestors: &mut HashSet<PathBuf>,
) -> Result<()> {
    let metadata = fs::metadata(source).with_context(|| format!("read {}", source.display()))?;
    ensure!(metadata.is_dir(), "not a directory: {}", source.display());
    fs::create_dir_all(destination)?;
    fs::set_permissions(
        destination,
        fs::Permissions::from_mode(metadata.permissions().mode() & 0o777 | 0o700),
    )?;
    copy_contents(source, destination, ancestors)
}

fn copy_contents(
    source: &Path,
    destination: &Path,
    ancestors: &mut HashSet<PathBuf>,
) -> Result<()> {
    let canonical = source
        .canonicalize()
        .with_context(|| format!("read {}", source.display()))?;
    ensure!(
        !destination.canonicalize()?.starts_with(&canonical),
        "cannot copy a directory into itself: {}",
        source.display()
    );
    ensure!(
        ancestors.insert(canonical.clone()),
        "directory symlink cycle: {}",
        source.display()
    );
    let result = (|| {
        for entry in fs::read_dir(&canonical)? {
            let entry = entry?;
            let target = destination.join(entry.file_name());
            let metadata = fs::metadata(entry.path())?;
            if metadata.is_dir() {
                copy_directory(&entry.path(), &target, ancestors)?;
            } else {
                copy_file(&entry.path(), &target)?;
            }
        }
        Ok(())
    })();
    ancestors.remove(&canonical);
    result
}

fn copy_file(source: &Path, destination: &Path) -> Result<()> {
    let metadata = fs::metadata(source).with_context(|| format!("read {}", source.display()))?;
    ensure!(
        metadata.is_file(),
        "not a regular file: {}",
        source.display()
    );
    if let Ok(target) = fs::metadata(destination) {
        ensure!(
            metadata.dev() != target.dev() || metadata.ino() != target.ino(),
            "cannot copy a file onto itself: {}",
            source.display()
        );
    }
    if let Some(parent) = destination.parent() {
        fs::create_dir_all(parent)?;
    }
    fs::copy(source, destination)
        .with_context(|| format!("copy {} to {}", source.display(), destination.display()))?;
    fs::set_permissions(
        destination,
        fs::Permissions::from_mode(metadata.permissions().mode() & 0o777 | 0o200),
    )?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::symlink;

    #[test]
    fn assembles_writable_copies_with_app_code_files_and_selected_certificates() {
        let base = tempfile::tempdir().unwrap();
        let source = base.path().join("runtime");
        fs::create_dir(&source).unwrap();
        let shared = base.path().join("shared");
        fs::create_dir(&shared).unwrap();
        fs::write(shared.join("module.beam"), "runtime").unwrap();
        fs::set_permissions(
            shared.join("module.beam"),
            fs::Permissions::from_mode(0o444),
        )
        .unwrap();
        symlink(&shared, source.join("lib")).unwrap();
        fs::create_dir(source.join("app")).unwrap();
        fs::write(source.join("app/app"), "old entrypoint").unwrap();
        let app = base.path().join("app");
        fs::create_dir(&app).unwrap();
        fs::write(app.join("app"), "entrypoint").unwrap();
        let script = base.path().join("script.exs");
        fs::write(&script, "IO.puts(:ok)").unwrap();
        let certs = base.path().join("selected.pem");
        fs::write(&certs, "selected certificates").unwrap();
        fs::set_permissions(&source, fs::Permissions::from_mode(0o555)).unwrap();
        let root = base.path().join("root");
        populate(
            &source,
            &root,
            &RootOptions {
                app: Some(app),
                certificates: Some(certs),
                directories: vec![(shared.clone(), PathBuf::from("/code/0"))],
                files: vec![(script, PathBuf::from("/work/script.exs"))],
            },
            Some("/custom/trust/roots.pem"),
        )
        .unwrap();
        assert_eq!(fs::read(root.join("app/app")).unwrap(), b"entrypoint");
        assert_eq!(
            fs::read(root.join("code/0/module.beam")).unwrap(),
            b"runtime"
        );
        assert_eq!(
            fs::read(root.join("work/script.exs")).unwrap(),
            b"IO.puts(:ok)"
        );
        assert_eq!(
            fs::read(root.join("custom/trust/roots.pem")).unwrap(),
            b"selected certificates"
        );
        assert!(
            !fs::symlink_metadata(root.join("lib"))
                .unwrap()
                .file_type()
                .is_symlink()
        );
        assert_eq!(
            fs::metadata(&root).unwrap().permissions().mode() & 0o777,
            0o700
        );
        fs::write(root.join("lib/module.beam"), "private").unwrap();
        assert_eq!(fs::read(shared.join("module.beam")).unwrap(), b"runtime");
        assert_eq!(
            fs::metadata(shared.join("module.beam"))
                .unwrap()
                .permissions()
                .mode()
                & 0o777,
            0o444
        );
        assert_eq!(
            fs::metadata(&source).unwrap().permissions().mode() & 0o777,
            0o555
        );
        fs::set_permissions(&source, fs::Permissions::from_mode(0o700)).unwrap();
    }

    #[test]
    fn failures_remove_partial_roots_and_preserve_existing_destinations() {
        let base = tempfile::tempdir().unwrap();
        let source = base.path().join("runtime");
        fs::create_dir(&source).unwrap();
        fs::write(source.join("copied"), "runtime").unwrap();
        let root = base.path().join("root");
        let options = RootOptions {
            app: Some(base.path().join("missing")),
            ..RootOptions::default()
        };
        assert!(populate(&source, &root, &options, None).is_err());
        assert!(!root.exists());
        fs::create_dir(&root).unwrap();
        fs::write(root.join("keep"), "original").unwrap();
        assert!(populate(&source, &root, &RootOptions::default(), None).is_err());
        assert_eq!(fs::read(root.join("keep")).unwrap(), b"original");
    }

    #[test]
    fn rejects_escaping_destinations_and_directory_cycles() {
        let base = tempfile::tempdir().unwrap();
        let source = base.path().join("runtime");
        fs::create_dir(&source).unwrap();
        let input = base.path().join("cert.pem");
        fs::write(&input, "certificates").unwrap();
        let options = RootOptions {
            certificates: Some(input),
            ..RootOptions::default()
        };
        let root = base.path().join("root");
        assert!(populate(&source, &root, &options, Some("/../escaped")).is_err());
        assert!(!root.exists());
        assert!(!base.path().join("escaped").exists());
        symlink(&source, source.join("cycle")).unwrap();
        assert!(populate(&source, &root, &RootOptions::default(), None).is_err());
        assert!(!root.exists());
        fs::remove_file(source.join("cycle")).unwrap();
        assert!(
            populate(
                &source,
                &source.join("child"),
                &RootOptions::default(),
                None
            )
            .is_err()
        );
        assert!(!source.join("child").exists());
    }
}
