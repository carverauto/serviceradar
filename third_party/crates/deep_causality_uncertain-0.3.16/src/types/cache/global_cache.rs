/*
 * SPDX-License-Identifier: MIT
 * Copyright (c) 2023 - 2026. The DeepCausality Authors and Contributors. All Rights Reserved.
 */

use crate::SampledValue;
use std::collections::HashMap;
use std::sync::{OnceLock, RwLock};

/// Key for the global sample cache: (Uncertain ID, Sample Index)
pub type SampleCacheKey = (usize, u64);

/// Thread-safe, global cache for sampled values.
#[derive(Debug)]
pub struct GlobalSampleCache {
    data: RwLock<HashMap<SampleCacheKey, SampledValue>>,
}

impl Default for GlobalSampleCache {
    fn default() -> Self {
        Self::new()
    }
}

impl GlobalSampleCache {
    /// Creates a new, empty cache.
    pub fn new() -> Self {
        Self {
            data: RwLock::new(HashMap::new()),
        }
    }

    /// Gets a value from the cache.
    pub fn get(&self, key: &SampleCacheKey) -> Option<SampledValue> {
        let reader = self.data.read().expect("RwLock poisoned (read)");
        reader.get(key).copied()
    }

    /// Inserts a value into the cache.
    pub fn insert(&self, key: SampleCacheKey, value: SampledValue) {
        let mut writer = self.data.write().expect("RwLock poisoned (write)");
        writer.insert(key, value);
    }

    /// Gets a value from the cache, or computes it if not present, then caches and returns it.
    /// This implementation includes a double-check to prevent redundant computation in concurrent scenarios.
    pub fn get_or_compute<F>(
        &self,
        key: SampleCacheKey,
        compute_fn: F,
    ) -> Result<SampledValue, crate::UncertainError>
    where
        F: FnOnce() -> Result<SampledValue, crate::UncertainError>,
    {
        // Try to get from cache first (read lock).
        if let Some(value) = self.get(&key) {
            return Ok(value);
        };

        // If not in the cache, acquire a write lock.
        let mut writer = self.data.write().expect("RwLock poisoned (write)");

        // Double-check if another thread inserted the value while we were waiting for the lock.
        // This avoids redundant computation.
        if let Some(value) = writer.get(&key) {
            return Ok(*value);
        }

        // If the value is still not in the cache, compute it while holding the lock.
        let computed_value = compute_fn()?;
        writer.insert(key, computed_value);
        Ok(computed_value)
    }

    /// Clears all entries from the cache.
    pub fn clear(&self) {
        let mut writer = self.data.write().expect("RwLock poisoned (clear)");
        writer.clear();
    }
}

// Conditional Compilation for Test-Specific Global State
//
// This approach allows you to define the global cache as truly global for production builds,
// but replace it with a thread_local! version  when compiling for tests.
//
// * Truly Global in Production: When you build your release binary (cargo build --release),
//   the #[cfg(not(test))] branches are compiled, giving you a single, shared global cache.
//
// * Isolated in Tests: When you run cargo test, the #[cfg(test)] branches are compiled,
//   providing each test thread with its own independent cache and ID counter.
//
// * Reliable Parallel Tests: This completely resolves the global state contamination issues,
//   allowing all tests to run reliably in parallel.
//
//  * Minimal Impact on Core Logic: The changes are primarily at the definition site of the
//    global statics and their direct access functions, not throughout the entire library's logic.
//
/// Global static instance of the cache, initialized once.
#[cfg(not(test))]
static GLOBAL_SAMPLE_CACHE: OnceLock<GlobalSampleCache> = const { OnceLock::new() };

#[cfg(test)]
thread_local! {
    static GLOBAL_SAMPLE_CACHE: OnceLock<GlobalSampleCache> = const { OnceLock::new() };
}

/// Executes a closure with a reference to the global sample cache.
/// This pattern is used to safely access thread-local storage without returning a reference
/// that could outlive the scope of the thread-local data.
pub fn with_global_cache<F, R>(closure: F) -> R
where
    F: FnOnce(&GlobalSampleCache) -> R,
{
    #[cfg(not(test))]
    {
        let cache = GLOBAL_SAMPLE_CACHE.get_or_init(GlobalSampleCache::new);
        closure(cache)
    }
    #[cfg(test)]
    {
        GLOBAL_SAMPLE_CACHE
            .with(|cache_once_lock| closure(cache_once_lock.get_or_init(GlobalSampleCache::new)))
    }
}
