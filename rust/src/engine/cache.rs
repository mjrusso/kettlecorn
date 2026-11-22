use crate::unix::open_at;
use anyhow::Result;
use sha2::{Digest, Sha256};
use std::fs::{self, File, OpenOptions};
use std::hash::{Hash, Hasher};
use std::io::{Read, Seek, Write};
use std::os::fd::AsRawFd;
use std::os::unix::fs::{DirBuilderExt, MetadataExt, OpenOptionsExt};
use std::path::{Path, PathBuf};
use wasmtime::Engine;
use wasmtime::component::Component;

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
        let mut source = File::open(source)?;
        let directory = match self {
            Self::Directory(path) => trusted_directory(path, guest_root).ok(),
            Self::Disabled => None,
        };
        let Some(directory) = directory else {
            return Ok(Component::new(engine, read(&mut source)?)?);
        };
        let mut compatibility = std::collections::hash_map::DefaultHasher::new();
        engine
            .precompile_compatibility_hash()
            .hash(&mut compatibility);
        let compatibility = format!("{:x}", compatibility.finish());
        let key = format!("{}-{compatibility}", digest(&mut source)?);
        if let Some(component) = load(engine, &directory, &key) {
            return Ok(component);
        }
        source.rewind()?;
        let source = read(&mut source)?;
        // Key the entry by the bytes compiled: the file may have changed since
        // it was hashed above.
        let key = format!("{:x}-{compatibility}", Sha256::digest(&source));
        let component = Component::new(engine, &source)?;
        if let Ok(bytes) = component.serialize()
            && save(&directory, &key, &bytes).is_ok()
        {
            evict(&directory);
            // Map the published entry, as on a hit, so this process shares its pages.
            if let Some(mapped) = load(engine, &directory, &key) {
                return Ok(mapped);
            }
        }
        Ok(component)
    }
}

fn read(file: &mut File) -> Result<Vec<u8>> {
    let mut bytes = Vec::new();
    file.read_to_end(&mut bytes)?;
    Ok(bytes)
}

/// Hex SHA-256 of the rest of `file`, read in pieces to avoid holding a copy.
fn digest(file: &mut File) -> Result<String> {
    let mut hasher = Sha256::new();
    std::io::copy(file, &mut hasher)?;
    Ok(format!("{:x}", hasher.finalize()))
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

// Publish the immutable artifact before replacing its .entry pointer.
// Serialize publication and removal under the same per-key lock.
fn load(engine: &Engine, directory: &File, key: &str) -> Option<Component> {
    let file = artifact(directory, key, &pointer(directory, key).ok()?).ok()?;
    // This private, non-symlink file contains host-generated code. The digest
    // detects accidental corruption; it does not authenticate same-user writes.
    // Mapping the verified descriptor lets processes share the code's pages;
    // removing the entry later doesn't change this file.
    unsafe { Component::deserialize_file(engine, format!("/dev/fd/{}", file.as_raw_fd())) }.ok()
}

fn pointer(directory: &File, key: &str) -> Result<String> {
    let mut digest = String::new();
    private_file(directory, &format!("{key}.entry"))?
        .take(64)
        .read_to_string(&mut digest)?;
    anyhow::ensure!(
        digest.len() == 64 && digest.bytes().all(|byte| byte.is_ascii_hexdigit()),
        "invalid cache entry"
    );
    Ok(digest)
}

fn artifact_name(key: &str, digest: &str) -> String {
    format!("{key}.{digest}.cwasm")
}

fn artifact(directory: &File, key: &str, expected: &str) -> Result<File> {
    let mut file = private_file(directory, &artifact_name(key, expected))?;
    anyhow::ensure!(file.metadata()?.len() <= MAX_BYTES, "cache entry too large");
    anyhow::ensure!(digest(&mut file)? == expected, "corrupt cache entry");
    Ok(file)
}

fn private_file(directory: &File, name: &str) -> Result<File> {
    let file = open_at(directory, name, libc::O_RDONLY | libc::O_NONBLOCK)?;
    let metadata = file.metadata()?;
    check_private(&metadata)?;
    anyhow::ensure!(metadata.is_file(), "invalid cache file");
    Ok(file)
}

fn save(directory: &File, key: &str, code: &[u8]) -> Result<()> {
    anyhow::ensure!(code.len() as u64 <= MAX_BYTES, "cache entry too large");
    let suffix = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)?
        .as_nanos();
    let staged = |name: &str| format!(".{name}.{}.{suffix}.tmp", std::process::id());
    let code_digest = format!("{:x}", Sha256::digest(code));
    let (artifact_name, entry_name) = (artifact_name(key, &code_digest), format!("{key}.entry"));
    let (staged_artifact, staged_entry) = (staged(&artifact_name), staged(&entry_name));
    let result = (|| -> Result<()> {
        stage(directory, &staged_artifact, code)?;
        stage(directory, &staged_entry, code_digest.as_bytes())?;
        let _lock = KeyLock::acquire(directory, key)?;
        let previous = pointer(directory, key).ok();
        // An intact artifact stays, so launchers that mapped it keep sharing
        // its pages with new ones.
        if artifact(directory, key, &code_digest).is_err() {
            rename(directory, &staged_artifact, &artifact_name)?;
        }
        if previous.as_deref() != Some(code_digest.as_str()) {
            rename(directory, &staged_entry, &entry_name)?;
        }
        if let Some(previous) = previous.filter(|previous| *previous != code_digest) {
            unlink(directory, &self::artifact_name(key, &previous));
        }
        Ok(())
    })();
    unlink(directory, &staged_artifact);
    unlink(directory, &staged_entry);
    result
}

fn stage(directory: &File, name: &str, contents: &[u8]) -> Result<()> {
    let mut file = open_at(
        directory,
        name,
        libc::O_WRONLY | libc::O_CREAT | libc::O_EXCL,
    )?;
    file.write_all(contents)?;
    file.sync_all()?;
    Ok(())
}

fn rename(directory: &File, from: &str, to: &str) -> Result<()> {
    let from = std::ffi::CString::new(from)?;
    let to = std::ffi::CString::new(to)?;
    let renamed = unsafe {
        libc::renameat(
            directory.as_raw_fd(),
            from.as_ptr(),
            directory.as_raw_fd(),
            to.as_ptr(),
        )
    };
    anyhow::ensure!(renamed == 0, "cache publication failed");
    Ok(())
}

/// An exclusive `flock` on `<key>.lock`, released when dropped.
struct KeyLock {
    _file: File,
}

impl KeyLock {
    fn acquire(directory: &File, key: &str) -> Result<Self> {
        let name = format!("{key}.lock");
        loop {
            let file = open_at(directory, &name, libc::O_RDONLY | libc::O_CREAT)?;
            if unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX) } != 0 {
                return Err(std::io::Error::last_os_error().into());
            }
            // Eviction removes the lock file with its entry. A lock on a
            // removed file excludes no one, so lock the current one.
            let locked = file.metadata()?;
            if let Ok(current) =
                open_at(directory, &name, libc::O_RDONLY).and_then(|current| current.metadata())
                && (current.dev(), current.ino()) == (locked.dev(), locked.ino())
            {
                return Ok(Self { _file: file });
            }
        }
    }
}

/// Entry names, read through the validated descriptor, so listing stays
/// anchored to it even if its original path is replaced while another VM starts.
fn names(directory: &File) -> Vec<String> {
    let duplicate = unsafe { libc::dup(directory.as_raw_fd()) };
    if duplicate < 0 {
        return Vec::new();
    }
    let dir = unsafe { libc::fdopendir(duplicate) };
    if dir.is_null() {
        unsafe {
            libc::close(duplicate);
        }
        return Vec::new();
    }
    unsafe {
        libc::rewinddir(dir);
    }
    let mut names = Vec::new();
    loop {
        let entry = unsafe { libc::readdir(dir) };
        if entry.is_null() {
            break;
        }
        names.push(
            unsafe { std::ffi::CStr::from_ptr((*entry).d_name.as_ptr()) }
                .to_string_lossy()
                .into_owned(),
        );
    }
    unsafe {
        libc::closedir(dir);
    }
    names
}

const ABANDONED_STAGING: std::time::Duration = std::time::Duration::from_secs(3600);

/// Removes the oldest entries beyond the size budget, and abandoned staged
/// files and artifacts. Staged files and artifacts no entry points to don't
/// count toward the budget: a writer may still be filling or publishing one.
/// One sweep runs at a time; overlapping sweeps would each free the space
/// the budget requires. A launcher that finds a sweep running skips its own.
fn evict(directory: &File) {
    let Ok(sweep) = open_at(directory, "evict.lock", libc::O_RDONLY | libc::O_CREAT) else {
        return;
    };
    if unsafe { libc::flock(sweep.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) } != 0 {
        return;
    }
    let mut pointed = std::collections::HashMap::new();
    let mut artifacts = std::collections::HashMap::new();
    let mut removals = Vec::new();
    for name in names(directory) {
        if let Some(key) = name.strip_suffix(".entry") {
            if let Ok(digest) = pointer(directory, key) {
                pointed.insert(key.to_owned(), digest);
            }
            continue;
        }
        if name.starts_with('.') && name.ends_with(".tmp") {
            if abandoned(directory, &name) {
                unlink(directory, &name);
            }
            continue;
        }
        let Some(stem) = name.strip_suffix(".cwasm") else {
            continue;
        };
        let Ok(metadata) = private_file(directory, &name).and_then(|file| Ok(file.metadata()?))
        else {
            continue;
        };
        let stat = (metadata.modified().ok(), metadata.len());
        match stem.rsplit_once('.') {
            Some((key, digest)) => {
                artifacts.insert((key.to_owned(), digest.to_owned()), stat);
            }
            // Earlier releases stored each entry as `<key>.cwasm`.
            None => removals.push((stat.0, stat.1, Removal::Legacy(name))),
        }
    }
    for (key, digest) in artifacts.keys() {
        if pointed.get(key) != Some(digest) && abandoned(directory, &artifact_name(key, digest)) {
            remove_orphan(directory, key, digest);
        }
    }
    for (key, digest) in pointed {
        if let Some(&(modified, bytes)) = artifacts.get(&(key.clone(), digest.clone())) {
            removals.push((modified, bytes, Removal::Entry { key, digest }));
        }
    }
    removals.sort();
    let mut size: u64 = removals.iter().map(|(_, bytes, _)| bytes).sum();
    for (_, bytes, removal) in removals {
        if size <= MAX_BYTES {
            break;
        }
        if removal.apply(directory) {
            size = size.saturating_sub(bytes);
        }
    }
}

#[derive(PartialEq, Eq, PartialOrd, Ord)]
enum Removal {
    Entry { key: String, digest: String },
    Legacy(String),
}

impl Removal {
    fn apply(&self, directory: &File) -> bool {
        match self {
            Self::Legacy(name) => unlink(directory, name),
            Self::Entry { key, digest } => {
                let Ok(_lock) = KeyLock::acquire(directory, key) else {
                    return false;
                };
                // A publisher may have replaced the entry since it was inspected.
                if pointer(directory, key).ok().as_deref() != Some(digest.as_str()) {
                    return false;
                }
                unlink(directory, &format!("{key}.entry"));
                let removed = unlink(directory, &artifact_name(key, digest));
                unlink(directory, &format!("{key}.lock"));
                removed
            }
        }
    }
}

/// Removes an artifact its key's entry didn't point to when inspected,
/// unless a publisher has since reused it.
fn remove_orphan(directory: &File, key: &str, digest: &str) {
    let Ok(_lock) = KeyLock::acquire(directory, key) else {
        return;
    };
    let current = pointer(directory, key).ok();
    if current.as_deref() != Some(digest) {
        unlink(directory, &artifact_name(key, digest));
        if current.is_none() {
            unlink(directory, &format!("{key}.lock"));
        }
    }
}

// Give publishers a grace period before eviction considers their files orphaned.
fn abandoned(directory: &File, name: &str) -> bool {
    private_file(directory, name)
        .and_then(|file| Ok(file.metadata()?.modified()?))
        .ok()
        .and_then(|modified| modified.elapsed().ok())
        .is_some_and(|age| age > ABANDONED_STAGING)
}

fn unlink(directory: &File, name: &str) -> bool {
    std::ffi::CString::new(name)
        .is_ok_and(|name| unsafe { libc::unlinkat(directory.as_raw_fd(), name.as_ptr(), 0) } == 0)
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
        let [key] = &keys(&directory)[..] else {
            panic!("expected one entry");
        };
        let private = trusted_directory(&directory, Some(&root)).unwrap();
        let artifact = directory.join(artifact_name(key, &pointer(&private, key).unwrap()));
        fs::write(&artifact, b"corrupt").unwrap();
        assert!(load(&engine, &private, key).is_none());
        cache.compile(&engine, &source, Some(&root)).unwrap();
        assert!(load(&engine, &private, key).is_some());

        let other = Component::new(
            &super::super::engine(true).unwrap(),
            fs::read(&source).unwrap(),
        )
        .unwrap()
        .serialize()
        .unwrap();
        save(&private, key, &other).unwrap();
        assert!(load(&engine, &private, key).is_none());
        assert!(!artifact.exists(), "a replaced artifact is removed");
        cache.compile(&engine, &source, Some(&root)).unwrap();
        assert!(load(&engine, &private, key).is_some());
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
        let path = base.path().join("cache");
        let directory = trusted_directory(&path, Some(&root)).unwrap();
        evict(&directory);
        // Larger than an entry can be, so loading rejects it.
        let old = entry(&directory, "old", "a", MAX_BYTES + 1);
        old.set_modified(std::time::SystemTime::UNIX_EPOCH).unwrap();
        // An earlier release's entry.
        let legacy = open_at(&directory, "legacy.cwasm", libc::O_CREAT | libc::O_WRONLY).unwrap();
        legacy.set_len(MAX_BYTES).unwrap();
        legacy
            .set_modified(std::time::SystemTime::UNIX_EPOCH + std::time::Duration::from_secs(1))
            .unwrap();
        // Another key's artifact with the same contents is its own file.
        entry(&directory, "recent", "a", 3);
        let staging = open_at(&directory, ".staging.tmp", libc::O_CREAT | libc::O_WRONLY).unwrap();
        staging.set_len(MAX_BYTES).unwrap();
        let orphan = artifact_name("gone", &"c".repeat(64));
        for name in [".abandoned.tmp", &orphan] {
            open_at(&directory, name, libc::O_CREAT | libc::O_WRONLY)
                .unwrap()
                .set_modified(std::time::SystemTime::UNIX_EPOCH)
                .unwrap();
        }
        evict(&directory);
        for name in [
            "old.entry",
            "old.lock",
            &artifact_name("old", &"a".repeat(64)),
            "legacy.cwasm",
        ] {
            assert!(!path.join(name).exists(), "{name}");
        }
        assert!(path.join(".staging.tmp").exists());
        assert!(!path.join(".abandoned.tmp").exists());
        assert!(!path.join(orphan).exists());
        assert!(!path.join("gone.lock").exists());
        assert!(path.join("recent.entry").exists());
        assert!(path.join(artifact_name("recent", &"a".repeat(64))).exists());
    }

    #[test]
    fn eviction_keeps_an_entry_replaced_after_it_was_inspected() {
        let (base, _engine, _source, root) = fixture();
        let path = base.path().join("cache");
        let directory = trusted_directory(&path, Some(&root)).unwrap();
        // Older than the replacement, so eviction removes it in either order.
        entry(&directory, "filler", "f", MAX_BYTES)
            .set_modified(std::time::SystemTime::UNIX_EPOCH + std::time::Duration::from_secs(1))
            .unwrap();
        let old = entry(&directory, "key", "a", 3);
        old.set_modified(std::time::SystemTime::UNIX_EPOCH).unwrap();
        // Hold the key's lock so eviction waits after inspecting the entry,
        // then replace the entry before releasing it.
        let lock = KeyLock::acquire(&directory, "key").unwrap();
        std::thread::scope(|scope| {
            let eviction = scope.spawn(|| evict(&directory));
            std::thread::sleep(std::time::Duration::from_millis(200));
            entry(&directory, "key", "d", 3);
            drop(lock);
            eviction.join().unwrap();
        });
        assert_eq!(pointer(&directory, "key").unwrap(), "d".repeat(64));
        assert!(path.join(artifact_name("key", &"d".repeat(64))).exists());
    }

    #[test]
    fn eviction_skips_while_another_sweep_runs() {
        let (base, _engine, _source, root) = fixture();
        let path = base.path().join("cache");
        let directory = trusted_directory(&path, Some(&root)).unwrap();
        entry(&directory, "key", "a", MAX_BYTES + 1);
        let sweep = open_at(&directory, "evict.lock", libc::O_RDONLY | libc::O_CREAT).unwrap();
        assert_eq!(unsafe { libc::flock(sweep.as_raw_fd(), libc::LOCK_EX) }, 0);
        evict(&directory);
        assert!(path.join("key.entry").exists());
        drop(sweep);
        evict(&directory);
        assert!(!path.join("key.entry").exists());
    }

    #[test]
    fn orphan_cleanup_keeps_an_artifact_published_after_it_was_inspected() {
        let (base, _engine, _source, root) = fixture();
        let path = base.path().join("cache");
        let directory = trusted_directory(&path, Some(&root)).unwrap();
        let digest = "a".repeat(64);
        let name = artifact_name("key", &digest);
        open_at(&directory, &name, libc::O_CREAT | libc::O_WRONLY)
            .unwrap()
            .set_modified(std::time::SystemTime::UNIX_EPOCH)
            .unwrap();
        // Hold the key's lock so eviction waits after classifying the
        // artifact as abandoned, then publish an entry that reuses it.
        let lock = KeyLock::acquire(&directory, "key").unwrap();
        std::thread::scope(|scope| {
            let eviction = scope.spawn(|| evict(&directory));
            std::thread::sleep(std::time::Duration::from_millis(200));
            open_at(&directory, "key.entry", libc::O_CREAT | libc::O_WRONLY)
                .unwrap()
                .write_all(digest.as_bytes())
                .unwrap();
            drop(lock);
            eviction.join().unwrap();
        });
        assert!(path.join(name).exists());
    }

    /// Writes an entry for `key` pointing to an artifact of `bytes` zero
    /// bytes, named by `digest` repeated, without checking its contents.
    fn entry(directory: &File, key: &str, digest: &str, bytes: u64) -> File {
        let digest = digest.repeat(64);
        open_at(
            directory,
            &format!("{key}.entry"),
            libc::O_CREAT | libc::O_WRONLY | libc::O_TRUNC,
        )
        .unwrap()
        .write_all(digest.as_bytes())
        .unwrap();
        let artifact = open_at(
            directory,
            &artifact_name(key, &digest),
            libc::O_CREAT | libc::O_WRONLY,
        )
        .unwrap();
        artifact.set_len(bytes).unwrap();
        artifact
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
        let keys = keys(&directory);
        assert_eq!(keys.len(), 1);
        for key in keys {
            assert!(load(&engine, &private, &key).is_some());

            // Republishing keeps the artifact other launchers may have mapped.
            let name = artifact_name(&key, &pointer(&private, &key).unwrap());
            let inode = entry_inode(&directory, &name);
            let code = fs::read(directory.join(&name)).unwrap();
            save(&private, &key, &code).unwrap();
            assert_eq!(entry_inode(&directory, &name), inode);
        }
        let names: Vec<_> = fs::read_dir(&directory)
            .unwrap()
            .map(|entry| entry.unwrap().file_name().into_string().unwrap())
            .collect();
        assert_eq!(
            names.iter().filter(|name| name.ends_with(".cwasm")).count(),
            1
        );
        assert!(
            !names.iter().any(|name| name.ends_with(".tmp")),
            "{names:?}"
        );
    }

    fn keys(directory: &Path) -> Vec<String> {
        fs::read_dir(directory)
            .unwrap()
            .filter_map(|entry| {
                let name = entry.unwrap().file_name().into_string().unwrap();
                name.strip_suffix(".entry").map(str::to_owned)
            })
            .collect()
    }

    fn entry_inode(directory: &Path, name: &str) -> u64 {
        fs::metadata(directory.join(name)).unwrap().ino()
    }
}
