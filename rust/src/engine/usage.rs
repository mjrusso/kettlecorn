use std::fs::File;
use std::ops::{Deref, DerefMut};
use std::ptr::NonNull;
use std::sync::{
    Arc,
    atomic::{AtomicBool, AtomicU64, AtomicUsize, Ordering},
};
use wasmtime::{AsContext, ResourceLimiter, Store, StoreLimits};

/// Tracks fuel and allocated linear memory during execution.
/// Commit initial memory only after instantiation succeeds. Wasmtime can
/// fail an initial allocation without notifying the resource limiter.
#[derive(Debug, Default)]
pub(crate) struct Usage {
    fuel: AtomicU64,
    memory: AtomicUsize,
    /// Growth Wasmtime has allowed but may still fail to allocate.
    growing: AtomicUsize,
    /// Allocated before instantiation finished.
    initial: AtomicUsize,
    instantiated: AtomicBool,
    published: Option<Published>,
}

impl Usage {
    /// Publishes updates in the stats file format defined in `PROTOCOL.md`.
    #[cfg(any(feature = "cli", test))]
    pub fn published(path: &std::path::Path) -> anyhow::Result<Self> {
        Ok(Self {
            published: Some(Published::create(path)?),
            ..Self::default()
        })
    }

    pub fn fuel(&self) -> u64 {
        self.fuel.load(Ordering::Relaxed)
    }

    pub fn memory(&self) -> usize {
        self.memory.load(Ordering::Relaxed)
    }

    /// Records fuel when the store is metered, and commits allocated growth.
    pub(super) fn sample(&self, budget: Option<u64>, store: impl AsContext) {
        if let Some(budget) = budget
            && let Ok(remaining) = store.as_context().get_fuel()
        {
            self.fuel.store(budget - remaining, Ordering::Relaxed);
        }
        self.commit();
    }

    fn commit(&self) {
        if self.instantiated.load(Ordering::Relaxed) {
            self.memory
                .fetch_add(self.growing.swap(0, Ordering::Relaxed), Ordering::Relaxed);
        }
        self.publish();
    }

    /// Commits the memory allocated while instantiating.
    pub(super) fn instantiated(&self) {
        let initial = self.initial.swap(0, Ordering::Relaxed);
        self.memory.fetch_add(initial, Ordering::Relaxed);
        self.instantiated.store(true, Ordering::Relaxed);
        self.commit();
    }

    // Wasmtime reports a failed growth before requesting another, so any
    // pending bytes here were allocated.
    fn grow(&self, bytes: usize) {
        let allocated = self.growing.swap(bytes, Ordering::Relaxed);
        if self.instantiated.load(Ordering::Relaxed) {
            self.memory.fetch_add(allocated, Ordering::Relaxed);
            self.publish();
        } else {
            self.initial.fetch_add(allocated, Ordering::Relaxed);
        }
    }

    fn grow_failed(&self) {
        self.growing.store(0, Ordering::Relaxed);
    }

    // Only the thread running the store updates usage, so there is one writer.
    fn publish(&self) {
        if let Some(published) = &self.published {
            published.write(self.fuel(), self.memory() as u64);
        }
    }
}

/// Readers can sample during an update, so they accept fuel and memory
/// together only when the checksum matches. See `PROTOCOL.md` for the layout.
#[derive(Debug)]
struct Published {
    words: NonNull<AtomicU64>,
    _file: File,
}

// The mapping is only accessed through atomics.
unsafe impl Send for Published {}
unsafe impl Sync for Published {}

const WORDS: usize = 3;
const BYTES: usize = WORDS * size_of::<u64>();

impl Published {
    #[cfg(any(feature = "cli", test))]
    fn create(path: &std::path::Path) -> anyhow::Result<Self> {
        use anyhow::Context;
        use std::os::fd::AsRawFd;
        use std::os::unix::fs::OpenOptionsExt;

        let file = File::options()
            .read(true)
            .write(true)
            .create_new(true)
            .mode(0o600)
            .open(path)
            .with_context(|| format!("create stats file {}", path.display()))?;
        file.set_len(BYTES as u64)?;
        let address = unsafe {
            libc::mmap(
                std::ptr::null_mut(),
                BYTES,
                libc::PROT_READ | libc::PROT_WRITE,
                libc::MAP_SHARED,
                file.as_raw_fd(),
                0,
            )
        };
        if address == libc::MAP_FAILED {
            return Err(std::io::Error::last_os_error()).context("map stats file");
        }
        Ok(Self {
            words: NonNull::new(address.cast()).context("map stats file")?,
            _file: file,
        })
    }

    fn word(&self, index: usize) -> &AtomicU64 {
        debug_assert!(index < WORDS);
        unsafe { &*self.words.as_ptr().add(index) }
    }

    fn write(&self, fuel: u64, memory: u64) {
        self.word(0).store(fuel.to_le(), Ordering::Relaxed);
        self.word(1).store(memory.to_le(), Ordering::Relaxed);
        self.word(2)
            .store(checksum(fuel, memory).to_le(), Ordering::Relaxed);
    }
}

// Keep this calculation in sync with Kettlecorn.VM.Stats.
fn checksum(fuel: u64, memory: u64) -> u64 {
    fn mix(mut z: u64) -> u64 {
        z = (z ^ (z >> 30)).wrapping_mul(0xbf58_476d_1ce4_e5b9);
        z = (z ^ (z >> 27)).wrapping_mul(0x94d0_49bb_1331_11eb);
        z ^ (z >> 31)
    }
    mix(fuel ^ mix(memory))
}

impl Drop for Published {
    fn drop(&mut self) {
        unsafe { libc::munmap(self.words.as_ptr().cast(), BYTES) };
    }
}

/// `StoreLimits` that also records the memory it allows.
pub(super) struct Limits {
    limits: StoreLimits,
    usage: Arc<Usage>,
}

impl Limits {
    pub fn new(limits: StoreLimits, usage: Arc<Usage>) -> Self {
        Self { limits, usage }
    }
}

impl ResourceLimiter for Limits {
    fn memory_growing(
        &mut self,
        current: usize,
        desired: usize,
        maximum: Option<usize>,
    ) -> wasmtime::Result<bool> {
        let allowed = self.limits.memory_growing(current, desired, maximum)?;
        if allowed {
            self.usage.grow(desired - current);
        }
        Ok(allowed)
    }

    // Wasmtime reports a failure without first calling `memory_growing` only
    // for memories with 1-byte pages, which this engine doesn't enable. Any
    // other failure belongs to the growth `memory_growing` just allowed.
    fn memory_grow_failed(&mut self, error: wasmtime::Error) -> wasmtime::Result<()> {
        self.usage.grow_failed();
        self.limits.memory_grow_failed(error)
    }

    fn table_growing(
        &mut self,
        current: usize,
        desired: usize,
        maximum: Option<usize>,
    ) -> wasmtime::Result<bool> {
        self.limits.table_growing(current, desired, maximum)
    }

    fn table_grow_failed(&mut self, error: wasmtime::Error) -> wasmtime::Result<()> {
        self.limits.table_grow_failed(error)
    }

    fn instances(&self) -> usize {
        self.limits.instances()
    }

    fn tables(&self) -> usize {
        self.limits.tables()
    }

    fn memories(&self) -> usize {
        self.limits.memories()
    }
}

/// A store that samples its final usage when dropped, including when
/// cancellation or a timeout drops the execution while the guest runs.
pub(super) struct Metered<T: 'static> {
    store: Store<T>,
    usage: Arc<Usage>,
    budget: Option<u64>,
}

impl<T> Metered<T> {
    pub fn new(store: Store<T>, usage: Arc<Usage>, budget: Option<u64>) -> Self {
        Self {
            store,
            usage,
            budget,
        }
    }
}

impl<T> Deref for Metered<T> {
    type Target = Store<T>;
    fn deref(&self) -> &Store<T> {
        &self.store
    }
}

impl<T> DerefMut for Metered<T> {
    fn deref_mut(&mut self) -> &mut Store<T> {
        &mut self.store
    }
}

impl<T> Drop for Metered<T> {
    fn drop(&mut self) {
        self.usage.sample(self.budget, &self.store);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn published_file_holds_fuel_memory_and_their_checksum() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("stats");
        let usage = Usage::published(&path).unwrap();
        assert_eq!(std::fs::read(&path).unwrap(), [0; BYTES]);

        usage.instantiated();
        usage.grow(65_536);
        usage.commit();
        let bytes = std::fs::read(&path).unwrap();
        let words: Vec<u64> = bytes
            .as_chunks::<8>()
            .0
            .iter()
            .map(|word| u64::from_le_bytes(*word))
            .collect();
        assert_eq!(words, [0, 65_536, checksum(0, 65_536)]);
        assert!(Usage::published(&path).is_err());
    }

    #[test]
    fn checksum_matches_the_documented_test_vector() {
        // PROTOCOL.md and host/test/stats_test.exs use the same vector.
        assert_eq!(checksum(123, 456), 0x2481_f22f_5c03_602e);
        assert_eq!(checksum(0, 0), 0, "a new, zeroed file is a valid record");
    }

    #[test]
    fn failed_growth_is_not_counted() {
        let usage = Arc::new(Usage::default());
        usage.instantiated();
        let mut limits = Limits::new(wasmtime::StoreLimitsBuilder::new().build(), usage.clone());
        assert!(limits.memory_growing(0, 65_536, None).unwrap());
        assert_eq!(usage.memory(), 0, "an allowed growth waits for allocation");
        assert!(limits.memory_growing(65_536, 131_072, None).unwrap());
        assert_eq!(usage.memory(), 65_536);
        limits
            .memory_grow_failed(wasmtime::format_err!("allocation failed"))
            .unwrap();
        usage.commit();
        assert_eq!(usage.memory(), 65_536);
    }

    #[test]
    fn memory_allocated_while_instantiating_counts_once_instantiation_succeeds() {
        let usage = Arc::new(Usage::default());
        let mut limits = Limits::new(wasmtime::StoreLimitsBuilder::new().build(), usage.clone());
        assert!(limits.memory_growing(0, 65_536, None).unwrap());
        assert!(limits.memory_growing(0, 131_072, None).unwrap());
        usage.commit();
        assert_eq!(usage.memory(), 0, "instantiation can still fail");
        usage.instantiated();
        assert_eq!(usage.memory(), 196_608);
    }
}
