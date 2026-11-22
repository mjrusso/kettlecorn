use std::sync::{
    Arc,
    atomic::{AtomicBool, AtomicU64, AtomicUsize, Ordering},
};
use wasmtime::{AsContext, ResourceLimiter, StoreLimits};

/// Fuel and memory an execution has used, updated while it runs. Both are
/// sampled when the guest calls the host and when it exits. Memory growth
/// counts from the first sample after Wasmtime has allocated it, so readers
/// never see a growth that fails. Memory allocated while instantiating counts
/// once instantiation succeeds: Wasmtime can fail an initial allocation
/// without reporting the failure to the limiter.
#[derive(Debug, Default)]
pub(crate) struct Usage {
    fuel: AtomicU64,
    memory: AtomicUsize,
    /// Growth Wasmtime has allowed but may still fail to allocate.
    growing: AtomicUsize,
    /// Allocated before instantiation finished.
    initial: AtomicUsize,
    instantiated: AtomicBool,
}

impl Usage {
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
        } else {
            self.initial.fetch_add(allocated, Ordering::Relaxed);
        }
    }

    fn grow_failed(&self) {
        self.growing.store(0, Ordering::Relaxed);
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

#[cfg(test)]
mod tests {
    use super::*;

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
