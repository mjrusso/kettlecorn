use crate::unix::open_at;
use anyhow::Result;
use sha2::{Digest, Sha256};
use std::fs::{self, File, OpenOptions};
use std::hash::{Hash, Hasher};
use std::io::{Read, Write};
use std::os::fd::AsRawFd;
use std::os::unix::fs::{DirBuilderExt, MetadataExt, OpenOptionsExt};
use std::path::{Path, PathBuf};
use wasmtime::Engine;
use wasmtime::component::Component;

const MAGIC: &[u8] = b"KETTLECORN-CACHE-1\n";
const MAX_BYTES: u64 = 256 * 1024 * 1024;

#[derive(Clone, Debug)]
pub enum CompilationCache {
    Disabled,
    Directory(PathBuf),
}

impl Default for CompilationCache {
    fn default() -> Self {
        let base = std::env::var_os("XDG_CACHE_HOME")
            .map(PathBuf::from)
            .or_else(|| {
                std::env::var_os("HOME").map(|home| {
                    if cfg!(target_os = "macos") {
                        PathBuf::from(home).join("Library/Caches")
                    } else {
                        PathBuf::from(home).join(".cache")
                    }
                })
            });
        match base {
            Some(base) => Self::Directory(base.join("kettlecorn/components")),
            None => Self::Disabled,
        }
    }
}

impl CompilationCache {
    pub(crate) fn compile(
        &self,
        engine: &Engine,
        source: &Path,
        guest_root: Option<&Path>,
    ) -> Result<Component> {
        let wasm = fs::read(source)?;
        let directory = match self {
            Self::Directory(path) => trusted_directory(path, guest_root).ok(),
            Self::Disabled => None,
        };
        let Some(directory) = directory else {
            return Ok(Component::new(engine, &wasm)?);
        };
        let mut compatibility = std::collections::hash_map::DefaultHasher::new();
        engine
            .precompile_compatibility_hash()
            .hash(&mut compatibility);
        let name = format!(
            "{:x}-{:x}.cwasm",
            Sha256::digest(&wasm),
            compatibility.finish()
        );
        evict(&directory);
        if let Ok(component) = load(engine, &directory, &name) {
            return Ok(component);
        }
        let component = Component::new(engine, &wasm)?;
        if let Ok(bytes) = component.serialize() {
            let _ = save(&directory, &name, &bytes);
            evict(&directory);
        }
        Ok(component)
    }
}

fn trusted_directory(path: &Path, guest_root: Option<&Path>) -> Result<File> {
    let guest_root = guest_root.map(Path::canonicalize).transpose()?;
    if let Some(root) = &guest_root {
        let ancestor = path
            .ancestors()
            .find(|path| path.exists())
            .ok_or_else(|| anyhow::anyhow!("cache has no existing parent"))?;
        anyhow::ensure!(
            !ancestor.canonicalize()?.starts_with(root),
            "cache is guest-writable"
        );
    }
    fs::DirBuilder::new()
        .recursive(true)
        .mode(0o700)
        .create(path)?;
    if let Some(root) = &guest_root {
        anyhow::ensure!(
            !path.canonicalize()?.starts_with(root),
            "cache is guest-writable"
        );
    }
    let directory = OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC)
        .open(path)?;
    check_private(&directory.metadata()?)?;
    Ok(directory)
}

fn check_private(metadata: &fs::Metadata) -> Result<()> {
    anyhow::ensure!(
        metadata.uid() == unsafe { libc::geteuid() } && metadata.mode() & 0o077 == 0,
        "cache must be private and owned by the current user"
    );
    Ok(())
}

fn load(engine: &Engine, directory: &File, name: &str) -> Result<Component> {
    let mut file = open_at(directory, name, libc::O_RDONLY | libc::O_NONBLOCK)?;
    let metadata = file.metadata()?;
    check_private(&metadata)?;
    anyhow::ensure!(
        metadata.is_file() && metadata.len() <= MAX_BYTES,
        "invalid cache file"
    );
    let mut bytes = Vec::new();
    file.read_to_end(&mut bytes)?;
    anyhow::ensure!(
        bytes.len() >= MAGIC.len() + 32 && bytes.starts_with(MAGIC),
        "invalid cache header"
    );
    let (digest, code) = bytes[MAGIC.len()..].split_at(32);
    anyhow::ensure!(&Sha256::digest(code)[..] == digest, "corrupt cache entry");
    // This private, non-symlink file contains host-generated code. The digest
    // detects accidental corruption; it does not authenticate same-user writes.
    Ok(unsafe { Component::deserialize(engine, code)? })
}

fn save(directory: &File, name: &str, code: &[u8]) -> Result<()> {
    let suffix = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)?
        .as_nanos();
    let temporary = format!(".{name}.{}.{suffix}.tmp", std::process::id());
    let result = (|| -> Result<()> {
        let mut file = open_at(
            directory,
            &temporary,
            libc::O_WRONLY | libc::O_CREAT | libc::O_EXCL,
        )?;
        file.write_all(MAGIC)?;
        file.write_all(&Sha256::digest(code))?;
        file.write_all(code)?;
        file.sync_all()?;
        let from = std::ffi::CString::new(temporary.as_str())?;
        let to = std::ffi::CString::new(name)?;
        let result = unsafe {
            libc::renameat(
                directory.as_raw_fd(),
                from.as_ptr(),
                directory.as_raw_fd(),
                to.as_ptr(),
            )
        };
        anyhow::ensure!(result == 0, "cache publication failed");
        Ok(())
    })();
    let temporary = std::ffi::CString::new(temporary)?;
    unsafe {
        libc::unlinkat(directory.as_raw_fd(), temporary.as_ptr(), 0);
    }
    result
}

fn evict(directory: &File) {
    // Directory iteration stays anchored to the validated descriptor, even if
    // its original path is replaced while another VM starts.
    let duplicate = unsafe { libc::dup(directory.as_raw_fd()) };
    if duplicate < 0 {
        return;
    }
    let dir = unsafe { libc::fdopendir(duplicate) };
    if dir.is_null() {
        unsafe {
            libc::close(duplicate);
        }
        return;
    }
    unsafe {
        libc::rewinddir(dir);
    }
    let mut entries = Vec::new();
    loop {
        let entry = unsafe { libc::readdir(dir) };
        if entry.is_null() {
            break;
        }
        let name = unsafe { std::ffi::CStr::from_ptr((*entry).d_name.as_ptr()) }
            .to_string_lossy()
            .into_owned();
        if !name.ends_with(".cwasm") && !(name.starts_with('.') && name.ends_with(".tmp")) {
            continue;
        }
        if let Ok(file) = open_at(directory, &name, libc::O_RDONLY | libc::O_NONBLOCK)
            && let Ok(metadata) = file.metadata()
            && metadata.is_file()
            && check_private(&metadata).is_ok()
        {
            entries.push((metadata.modified().ok(), metadata.len(), name));
        }
    }
    unsafe {
        libc::closedir(dir);
    }
    entries.sort();
    let mut size: u64 = entries.iter().map(|(_, size, _)| size).sum();
    for (_, bytes, name) in entries {
        if size <= MAX_BYTES {
            break;
        }
        if let Ok(name) = std::ffi::CString::new(name) {
            unsafe {
                libc::unlinkat(directory.as_raw_fd(), name.as_ptr(), 0);
            }
            size = size.saturating_sub(bytes);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::PermissionsExt;

    fn fixture() -> (tempfile::TempDir, Engine, PathBuf, PathBuf) {
        let base = tempfile::tempdir().unwrap();
        let source = base.path().join("empty.wasm");
        fs::write(&source, b"\0asm\x0d\0\x01\0").unwrap();
        let root = base.path().join("root");
        fs::create_dir(&root).unwrap();
        (base, super::super::engine(false).unwrap(), source, root)
    }

    #[test]
    fn corrupt_and_incompatible_entries_are_recompiled() {
        let (base, engine, source, root) = fixture();
        let directory = base.path().join("cache");
        let cache = CompilationCache::Directory(directory.clone());
        cache.compile(&engine, &source, Some(&root)).unwrap();
        let entry = fs::read_dir(&directory)
            .unwrap()
            .next()
            .unwrap()
            .unwrap()
            .path();
        fs::write(&entry, b"corrupt").unwrap();
        cache.compile(&engine, &source, Some(&root)).unwrap();
        let private = trusted_directory(&directory, Some(&root)).unwrap();
        let name = entry.file_name().unwrap().to_str().unwrap();
        let other = Component::new(
            &super::super::engine(true).unwrap(),
            fs::read(&source).unwrap(),
        )
        .unwrap()
        .serialize()
        .unwrap();
        save(&private, name, &other).unwrap();
        cache.compile(&engine, &source, Some(&root)).unwrap();
        load(&engine, &private, name).unwrap();
    }

    #[test]
    fn unsafe_unwritable_and_guest_directories_fall_back_without_repairs() {
        let (base, engine, source, root) = fixture();
        for mode in [0o777, 0o500] {
            let directory = base.path().join(format!("cache-{mode}"));
            fs::create_dir(&directory).unwrap();
            fs::set_permissions(&directory, fs::Permissions::from_mode(mode)).unwrap();
            CompilationCache::Directory(directory.clone())
                .compile(&engine, &source, Some(&root))
                .unwrap();
            assert_eq!(fs::metadata(&directory).unwrap().mode() & 0o777, mode);
            assert_eq!(fs::read_dir(&directory).unwrap().count(), 0);
        }
        let inside = root.join("cache");
        CompilationCache::Directory(inside.clone())
            .compile(&engine, &source, Some(&root))
            .unwrap();
        assert!(!inside.exists());
        CompilationCache::Directory(PathBuf::from("/"))
            .compile(&engine, &source, Some(&root))
            .unwrap();
        let link = base.path().join("link");
        std::os::unix::fs::symlink(&root, &link).unwrap();
        CompilationCache::Directory(link.join("cache"))
            .compile(&engine, &source, Some(&root))
            .unwrap();
        assert!(!inside.exists());
    }

    #[test]
    fn eviction_removes_old_entries_to_bound_disk_use() {
        let (base, _engine, _source, root) = fixture();
        let directory = trusted_directory(&base.path().join("cache"), Some(&root)).unwrap();
        evict(&directory);
        let old = open_at(&directory, "old.cwasm", libc::O_CREAT | libc::O_WRONLY).unwrap();
        old.set_len(MAX_BYTES).unwrap();
        old.set_modified(std::time::SystemTime::UNIX_EPOCH).unwrap();
        open_at(&directory, "recent.cwasm", libc::O_CREAT | libc::O_WRONLY)
            .unwrap()
            .write_all(b"new")
            .unwrap();
        evict(&directory);
        assert!(!base.path().join("cache/old.cwasm").exists());
        assert!(base.path().join("cache/recent.cwasm").exists());
    }

    #[test]
    fn concurrent_first_use_publishes_complete_files() {
        let (base, engine, source, root) = fixture();
        let directory = base.path().join("cache");
        std::thread::scope(|scope| {
            for _ in 0..8 {
                let cache = CompilationCache::Directory(directory.clone());
                let engine = &engine;
                let source = &source;
                let root = &root;
                scope.spawn(move || {
                    cache.compile(engine, source, Some(root)).unwrap();
                });
            }
        });
        let private = trusted_directory(&directory, Some(&root)).unwrap();
        for entry in fs::read_dir(&directory).unwrap() {
            let entry = entry.unwrap();
            load(&engine, &private, entry.file_name().to_str().unwrap()).unwrap();
        }
    }
}
