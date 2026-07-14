//! Pending flow cache for flows arriving before their template.
//!
//! When enabled, flows that reference an unknown template ID are cached in an LRU
//! structure keyed by template ID. When the template later arrives, cached flows
//! are drained and re-parsed.

use super::config::ConfigError;
use super::metrics::CacheMetricsInner;
use lru::LruCache;
use std::num::NonZeroUsize;
use std::time::{Duration, Instant};

/// Configuration for pending flow caching.
///
/// When enabled, flows that arrive before their template are cached.
/// When the template later arrives, cached flows are automatically
/// re-parsed and included in the output.
///
/// Disabled by default; enable via the builder pattern.
#[non_exhaustive]
#[derive(Debug, Clone)]
pub struct PendingFlowsConfig {
    /// Maximum number of template IDs to track in the LRU pending cache.
    pub max_pending_flows: usize,
    /// Maximum number of pending flow entries per template ID.
    /// Prevents unbounded memory growth from a flood of data for a single unknown template.
    pub max_entries_per_template: usize,
    /// Maximum size in bytes of a single pending flow entry's raw data.
    /// Entries exceeding this limit are dropped to prevent memory exhaustion
    /// from oversized flowset bodies. Default: 65531 (u16::MAX - 4).
    /// Must not exceed 65531 to fit within the 16-bit FlowSet length field.
    pub max_entry_size_bytes: usize,
    /// Maximum total bytes across all pending flow entries.
    /// When exceeded, LRU template entries are evicted until under the limit.
    /// Default: 67,108,864 (64 MB).
    pub max_total_bytes: usize,
    /// TTL for pending flows. `None` means pending flows never expire
    /// (only evicted by LRU or per-template cap).
    pub ttl: Option<Duration>,
}

/// Default total byte limit: 64 MB
const DEFAULT_MAX_TOTAL_BYTES: usize = 64 * 1024 * 1024;

/// Maximum allowed entry size in bytes. The FlowSet header is 4 bytes, so the
/// data portion must fit in `u16::MAX - 4` to avoid overflow in the 16-bit
/// FlowSet length field on replay.
const MAX_ENTRY_SIZE_LIMIT: usize = u16::MAX as usize - 4;

impl Default for PendingFlowsConfig {
    fn default() -> Self {
        Self {
            max_pending_flows: 256,
            max_entries_per_template: 1024,
            max_entry_size_bytes: MAX_ENTRY_SIZE_LIMIT,
            max_total_bytes: DEFAULT_MAX_TOTAL_BYTES,
            ttl: None,
        }
    }
}

impl PendingFlowsConfig {
    /// Create a new PendingFlowsConfig with the given capacity.
    pub fn new(max_pending_flows: usize) -> Self {
        Self {
            max_pending_flows,
            max_entries_per_template: 1024,
            max_entry_size_bytes: MAX_ENTRY_SIZE_LIMIT,
            max_total_bytes: DEFAULT_MAX_TOTAL_BYTES,
            ttl: None,
        }
    }

    /// Create a new PendingFlowsConfig with capacity and TTL.
    pub fn with_ttl(max_pending_flows: usize, ttl: Duration) -> Self {
        Self {
            max_pending_flows,
            max_entries_per_template: 1024,
            max_entry_size_bytes: MAX_ENTRY_SIZE_LIMIT,
            max_total_bytes: DEFAULT_MAX_TOTAL_BYTES,
            ttl: Some(ttl),
        }
    }
}

/// Entry in the pending flows cache, storing raw data with a timestamp.
#[derive(Debug, Clone)]
pub(crate) struct PendingFlowEntry {
    pub(crate) raw_data: Vec<u8>,
    pub(crate) cached_at: Instant,
}

/// LRU cache for pending flows keyed by template ID.
///
/// Provides caching, draining with TTL expiration, and per-template-ID entry limits.
/// Recalculate `total_bytes` every this many cache/drain operations
/// to correct any drift from saturating arithmetic.
const RECALC_INTERVAL: u64 = 1024;

#[derive(Debug)]
pub(crate) struct PendingFlowCache {
    cache: LruCache<u16, Vec<PendingFlowEntry>>,
    config: PendingFlowsConfig,
    total_bytes: usize,
    ops_since_recalc: u64,
}

impl PendingFlowCache {
    /// Best-effort check whether the cache would accept a new entry for
    /// `template_id` with `data_len` bytes.  Returns `false` when the
    /// per-template cap is already reached or the total byte budget would
    /// be exceeded, avoiding a full clone that would be immediately rejected.
    ///
    /// Uses `peek` so the query does not promote the key in the LRU.
    /// When TTL is configured, only non-expired entries count toward the cap
    /// so the decision matches what `cache()` would do after pruning.
    pub(crate) fn would_accept(&self, template_id: u16, data_len: usize) -> bool {
        // Reject if the entry itself exceeds the per-entry size limit
        if data_len > self.config.max_entry_size_bytes {
            return false;
        }
        // Check total byte budget, but allow if eviction could make room.
        // Only reject if the single entry alone exceeds the total budget
        // (cache() evicts LRU templates to free space when over budget).
        if data_len > self.config.max_total_bytes {
            return false;
        }
        match self.cache.peek(&template_id) {
            Some(entries) => {
                let live = match self.config.ttl {
                    Some(ttl) => entries
                        .iter()
                        .filter(|e| e.cached_at.elapsed() < ttl)
                        .count(),
                    None => entries.len(),
                };
                live < self.config.max_entries_per_template
            }
            None => true,
        }
    }

    /// Validates pending flow configuration without allocating.
    pub(crate) fn validate_config(config: &PendingFlowsConfig) -> Result<(), ConfigError> {
        NonZeroUsize::new(config.max_pending_flows).ok_or(
            ConfigError::InvalidPendingCacheSize(config.max_pending_flows),
        )?;
        if config.max_entries_per_template == 0 {
            return Err(ConfigError::InvalidEntriesPerTemplate(
                config.max_entries_per_template,
            ));
        }
        if config.max_entry_size_bytes == 0
            || config.max_entry_size_bytes > MAX_ENTRY_SIZE_LIMIT
        {
            return Err(ConfigError::InvalidEntrySize(config.max_entry_size_bytes));
        }
        if config.max_total_bytes == 0 {
            return Err(ConfigError::InvalidPendingTotalBytes {
                max_total_bytes: 0,
                max_entry_size_bytes: config.max_entry_size_bytes,
            });
        }
        if config.max_total_bytes < config.max_entry_size_bytes {
            return Err(ConfigError::InvalidPendingTotalBytes {
                max_total_bytes: config.max_total_bytes,
                max_entry_size_bytes: config.max_entry_size_bytes,
            });
        }
        Ok(())
    }

    /// Create a new PendingFlowCache from the given configuration.
    ///
    /// # Errors
    /// Returns `ConfigError::InvalidPendingCacheSize` if `max_pending_flows` is 0.
    pub(crate) fn new(config: PendingFlowsConfig) -> Result<Self, ConfigError> {
        let size = NonZeroUsize::new(config.max_pending_flows).ok_or(
            ConfigError::InvalidPendingCacheSize(config.max_pending_flows),
        )?;
        Ok(Self {
            cache: LruCache::new(size),
            config,
            total_bytes: 0,
            ops_since_recalc: 0,
        })
    }

    /// Verify that `total_bytes` matches the actual sum of all entry sizes.
    ///
    /// This is a debug-only check to catch drift during development.
    /// It has no runtime cost in release builds.
    #[cfg(debug_assertions)]
    fn debug_verify_total_bytes(&self) {
        let actual: usize = self
            .cache
            .iter()
            .flat_map(|(_, entries)| entries.iter())
            .map(|e| e.raw_data.len())
            .sum();
        debug_assert_eq!(
            self.total_bytes, actual,
            "PendingFlowCache total_bytes drift: tracked={}, actual={}",
            self.total_bytes, actual
        );
    }

    /// Cache a pending flow for later replay when its template arrives.
    ///
    /// Returns `None` if the entry was successfully cached.
    /// Returns `Some(raw_data)` if the entry was dropped (due to size limits,
    /// per-template cap, or LRU eviction), returning ownership of the data
    /// so the caller can preserve it for diagnostic output.
    ///
    /// When a TTL is configured, expired entries for the touched `template_id`
    /// are pruned before checking capacity. If the cache is at its template-ID
    /// limit, a global expired-entry sweep runs before falling back to LRU
    /// eviction, so stale entries don't displace valid ones.
    pub(crate) fn cache(
        &mut self,
        template_id: u16,
        raw_data: Vec<u8>,
        metrics: &mut CacheMetricsInner,
    ) -> Option<Vec<u8>> {
        if raw_data.len() > self.config.max_entry_size_bytes {
            metrics.record_pending_dropped();
            return Some(raw_data);
        }

        // Enforce total byte limit: evict LRU templates until under budget.
        while self.total_bytes.saturating_add(raw_data.len()) > self.config.max_total_bytes {
            if let Some((_, evicted)) = self.cache.pop_lru() {
                let evicted_bytes: usize = evicted.iter().map(|e| e.raw_data.len()).sum();
                self.total_bytes = self.total_bytes.saturating_sub(evicted_bytes);
                metrics.record_pending_dropped_n(evicted.len() as u64);
            } else {
                // Cache is empty but single entry exceeds total limit
                metrics.record_pending_dropped();
                return Some(raw_data);
            }
        }

        // Prune expired entries for this template before checking capacity.
        self.prune_expired_for_template(template_id, metrics);

        // The peek_mut borrow must be released before we call promote(),
        // so we resolve the entire if/else in one expression and promote
        // afterward based on the returned flag.
        let entry_size = raw_data.len();
        let needs_promote = if let Some(entries) = self.cache.peek_mut(&template_id) {
            if entries.len() >= self.config.max_entries_per_template {
                // Reject without promoting the key in the LRU so a
                // hot-but-full template can still be evicted.
                metrics.record_pending_dropped();
                return Some(raw_data);
            }
            entries.push(PendingFlowEntry {
                raw_data,
                cached_at: Instant::now(),
            });
            true
        } else {
            // Before LRU eviction, sweep all expired entries to free space.
            if self.cache.len() >= self.cache.cap().get() {
                self.purge_expired(metrics);
            }
            // If still at capacity after purging, evict LRU to free a slot.
            // After this pop, push() below should not trigger a second
            // eviction because the slot was just freed. The push() return
            // value is still checked defensively in case of key replacement.
            if self.cache.len() >= self.cache.cap().get()
                && let Some((_, evicted)) = self.cache.pop_lru()
            {
                let evicted_bytes: usize = evicted.iter().map(|e| e.raw_data.len()).sum();
                self.total_bytes = self.total_bytes.saturating_sub(evicted_bytes);
                metrics.record_pending_dropped_n(evicted.len() as u64);
            }
            // Use push() instead of put() so we capture any entry evicted
            // due to LRU capacity overflow and can update total_bytes.
            if let Some((_, evicted)) = self.cache.push(
                template_id,
                vec![PendingFlowEntry {
                    raw_data,
                    cached_at: Instant::now(),
                }],
            ) {
                let evicted_bytes: usize = evicted.iter().map(|e| e.raw_data.len()).sum();
                self.total_bytes = self.total_bytes.saturating_sub(evicted_bytes);
                metrics.record_pending_dropped_n(evicted.len() as u64);
            }
            false
        };
        if needs_promote {
            self.cache.promote(&template_id);
        }
        self.total_bytes = self.total_bytes.saturating_add(entry_size);
        metrics.record_pending_cached();
        self.ops_since_recalc = self.ops_since_recalc.saturating_add(1);
        if self.ops_since_recalc >= RECALC_INTERVAL {
            self.recalculate_total_bytes();
            self.ops_since_recalc = 0;
        }
        #[cfg(debug_assertions)]
        self.debug_verify_total_bytes();
        None
    }

    /// Drain pending flows for a given template ID, filtering expired entries.
    pub(crate) fn drain(
        &mut self,
        template_id: u16,
        metrics: &mut CacheMetricsInner,
    ) -> Vec<PendingFlowEntry> {
        let Some(entries) = self.cache.pop(&template_id) else {
            return Vec::new();
        };

        let popped_bytes: usize = entries.iter().map(|e| e.raw_data.len()).sum();
        self.total_bytes = self.total_bytes.saturating_sub(popped_bytes);

        let result = if let Some(ttl_duration) = self.config.ttl {
            let (valid, expired): (Vec<_>, Vec<_>) = entries
                .into_iter()
                .partition(|e| e.cached_at.elapsed() < ttl_duration);
            metrics.record_pending_dropped_n(expired.len() as u64);
            valid
        } else {
            entries
        };
        self.ops_since_recalc = self.ops_since_recalc.saturating_add(1);
        if self.ops_since_recalc >= RECALC_INTERVAL {
            self.recalculate_total_bytes();
            self.ops_since_recalc = 0;
        }
        #[cfg(debug_assertions)]
        self.debug_verify_total_bytes();
        result
    }

    /// Remove expired entries from a single template's vector.
    /// If all entries expire, the key is removed from the cache.
    fn prune_expired_for_template(
        &mut self,
        template_id: u16,
        metrics: &mut CacheMetricsInner,
    ) {
        let Some(ttl) = self.config.ttl else { return };
        // Use peek_mut so pruning alone doesn't promote the key.
        let result = self
            .cache
            .peek_mut(&template_id)
            .map(|entries| Self::drop_expired_entries(entries, ttl, metrics));
        if let Some((is_empty, freed)) = result {
            self.total_bytes = self.total_bytes.saturating_sub(freed);
            if is_empty {
                self.cache.pop(&template_id);
            }
        }
    }

    /// Remove expired entries from every template in the cache.
    /// Empty keys are removed so their slots can be reused.
    fn purge_expired(&mut self, metrics: &mut CacheMetricsInner) {
        let Some(ttl) = self.config.ttl else { return };
        let keys: Vec<u16> = self.cache.iter().map(|(&k, _)| k).collect();
        for key in keys {
            // Use peek_mut so sweeping doesn't disturb LRU ordering.
            let result = self
                .cache
                .peek_mut(&key)
                .map(|entries| Self::drop_expired_entries(entries, ttl, metrics));
            if let Some((is_empty, freed)) = result {
                self.total_bytes = self.total_bytes.saturating_sub(freed);
                if is_empty {
                    self.cache.pop(&key);
                }
            }
        }
    }

    /// Retain only non-expired entries, recording `pending_dropped` for each
    /// removed entry. Returns `(is_empty, freed_bytes)`.
    fn drop_expired_entries(
        entries: &mut Vec<PendingFlowEntry>,
        ttl: Duration,
        metrics: &mut CacheMetricsInner,
    ) -> (bool, usize) {
        let before_len = entries.len();
        let before_bytes: usize = entries.iter().map(|e| e.raw_data.len()).sum();
        entries.retain(|e| e.cached_at.elapsed() < ttl);
        let after_bytes: usize = entries.iter().map(|e| e.raw_data.len()).sum();
        metrics.record_pending_dropped_n(before_len.saturating_sub(entries.len()) as u64);
        (entries.is_empty(), before_bytes.saturating_sub(after_bytes))
    }

    /// Returns the total number of pending flow entries across all template IDs.
    pub(crate) fn count(&self) -> usize {
        self.cache.iter().map(|(_, entries)| entries.len()).sum()
    }

    /// Recalculate `total_bytes` from scratch by summing all cached entries.
    ///
    /// This corrects any drift that may have accumulated due to saturating
    /// arithmetic in hot paths. Called automatically every [`RECALC_INTERVAL`]
    /// operations, but can also be called manually.
    pub(crate) fn recalculate_total_bytes(&mut self) {
        self.total_bytes = self
            .cache
            .iter()
            .flat_map(|(_, entries)| entries.iter())
            .map(|e| e.raw_data.len())
            .sum();
    }

    /// Clear all pending flows.
    ///
    /// Callers are responsible for recording dropped metrics via
    /// `metrics.record_pending_dropped_n(cache.count())` before calling this.
    pub(crate) fn clear(&mut self) {
        self.cache.clear();
        self.total_bytes = 0;
    }

    /// Resize the LRU cache, recording `pending_dropped` for every entry
    /// evicted when the new capacity is smaller than the current size.
    ///
    /// Also enforces the new `max_entries_per_template` and
    /// `max_entry_size_bytes` limits on already-cached entries, dropping
    /// any that exceed the new bounds.
    ///
    /// Returns the number of individual flow entries that were dropped during
    /// the resize operation (LRU evictions + limit enforcement).
    ///
    /// # Errors
    /// Returns `ConfigError::InvalidPendingCacheSize` if `max_pending_flows` is 0.
    pub(crate) fn resize(
        &mut self,
        config: PendingFlowsConfig,
        metrics: &mut CacheMetricsInner,
    ) -> Result<u64, ConfigError> {
        // Validate the full config, not just max_pending_flows
        Self::validate_config(&config)?;
        let size = NonZeroUsize::new(config.max_pending_flows).ok_or(
            ConfigError::InvalidPendingCacheSize(config.max_pending_flows),
        )?;
        let mut total_dropped: u64 = 0;
        // Manually evict LRU entries that exceed the new capacity so each
        // individual pending flow entry is reflected in pending_dropped.
        while self.cache.len() > size.get() {
            if let Some((_, evicted)) = self.cache.pop_lru() {
                let evicted_bytes: usize = evicted.iter().map(|e| e.raw_data.len()).sum();
                self.total_bytes = self.total_bytes.saturating_sub(evicted_bytes);
                let n = evicted.len() as u64;
                metrics.record_pending_dropped_n(n);
                total_dropped = total_dropped.saturating_add(n);
            }
        }
        self.cache.resize(size);

        // Enforce new per-entry and per-template limits on remaining entries.
        let (freed, trimmed) = Self::trim_existing_entries(&mut self.cache, &config, metrics);
        self.total_bytes = self.total_bytes.saturating_sub(freed);
        total_dropped = total_dropped.saturating_add(trimmed);

        // Enforce new max_total_bytes by evicting LRU templates until within budget.
        while self.total_bytes > config.max_total_bytes {
            if let Some((_, evicted)) = self.cache.pop_lru() {
                let evicted_bytes: usize = evicted.iter().map(|e| e.raw_data.len()).sum();
                self.total_bytes = self.total_bytes.saturating_sub(evicted_bytes);
                let n = evicted.len() as u64;
                metrics.record_pending_dropped_n(n);
                total_dropped = total_dropped.saturating_add(n);
            } else {
                break;
            }
        }

        self.config = config;
        // Recalculate to correct any drift from cascaded saturating_sub operations.
        self.recalculate_total_bytes();
        Ok(total_dropped)
    }

    /// Drop entries that violate `max_entry_size_bytes` and truncate
    /// per-template vectors that exceed `max_entries_per_template`,
    /// recording `pending_dropped` for each removed entry.
    /// Returns `(bytes_freed, entries_dropped)`.
    fn trim_existing_entries(
        cache: &mut LruCache<u16, Vec<PendingFlowEntry>>,
        config: &PendingFlowsConfig,
        metrics: &mut CacheMetricsInner,
    ) -> (usize, u64) {
        let mut freed = 0usize;
        let mut dropped: u64 = 0;
        // Collect keys first to avoid borrowing issues during iteration.
        let keys: Vec<u16> = cache.iter().map(|(&k, _)| k).collect();
        for key in keys {
            // Use peek_mut so trimming doesn't disturb LRU ordering.
            let Some(entries) = cache.peek_mut(&key) else {
                continue;
            };

            // Drop entries whose raw_data exceeds the new size limit.
            let before_len = entries.len();
            let before_bytes: usize = entries.iter().map(|e| e.raw_data.len()).sum();
            entries.retain(|e| e.raw_data.len() <= config.max_entry_size_bytes);
            let size_dropped = before_len.saturating_sub(entries.len()) as u64;
            metrics.record_pending_dropped_n(size_dropped);
            dropped = dropped.saturating_add(size_dropped);

            // Truncate to the new per-template cap (keep newest = back).
            if entries.len() > config.max_entries_per_template {
                let excess = (entries.len() - config.max_entries_per_template) as u64;
                entries.drain(..entries.len() - config.max_entries_per_template);
                metrics.record_pending_dropped_n(excess);
                dropped = dropped.saturating_add(excess);
            }

            let after_bytes: usize = entries.iter().map(|e| e.raw_data.len()).sum();
            freed += before_bytes.saturating_sub(after_bytes);

            // Remove the key entirely if no entries remain.
            if entries.is_empty() {
                cache.pop(&key);
            }
        }
        (freed, dropped)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::variable_versions::metrics::CacheMetricsInner;

    fn default_metrics() -> CacheMetricsInner {
        CacheMetricsInner::default()
    }

    fn small_config(max_flows: usize) -> PendingFlowsConfig {
        PendingFlowsConfig {
            max_pending_flows: max_flows,
            max_entries_per_template: 4,
            max_entry_size_bytes: 128,
            max_total_bytes: 1024,
            ttl: None,
        }
    }

    #[test]
    fn test_cache_and_drain() {
        let config = small_config(8);
        let mut cache = PendingFlowCache::new(config).unwrap();
        let mut metrics = default_metrics();

        let data = vec![1u8, 2, 3, 4];
        let result = cache.cache(100, data.clone(), &mut metrics);
        assert!(result.is_none(), "entry should be accepted");
        assert_eq!(cache.count(), 1);
        assert_eq!(metrics.pending_cached, 1);

        let drained = cache.drain(100, &mut metrics);
        assert_eq!(drained.len(), 1);
        assert_eq!(drained[0].raw_data, data);
        assert_eq!(cache.count(), 0);
    }

    #[test]
    fn test_max_entry_size() {
        let config = PendingFlowsConfig {
            max_pending_flows: 8,
            max_entries_per_template: 4,
            max_entry_size_bytes: 10,
            max_total_bytes: 1024,
            ttl: None,
        };
        let mut cache = PendingFlowCache::new(config).unwrap();
        let mut metrics = default_metrics();

        // Entry exceeding max_entry_size_bytes should be rejected
        let big_data = vec![0u8; 11];
        let result = cache.cache(100, big_data.clone(), &mut metrics);
        assert!(result.is_some(), "oversized entry should be rejected");
        assert_eq!(result.unwrap(), big_data);
        assert_eq!(cache.count(), 0);
        assert_eq!(metrics.pending_dropped, 1);
    }

    #[test]
    fn test_per_template_cap() {
        let config = PendingFlowsConfig {
            max_pending_flows: 8,
            max_entries_per_template: 2,
            max_entry_size_bytes: 128,
            max_total_bytes: 4096,
            ttl: None,
        };
        let mut cache = PendingFlowCache::new(config).unwrap();
        let mut metrics = default_metrics();

        // Cache 2 entries for template 100 (at cap)
        assert!(cache.cache(100, vec![1, 2], &mut metrics).is_none());
        assert!(cache.cache(100, vec![3, 4], &mut metrics).is_none());
        assert_eq!(cache.count(), 2);

        // Third entry should be rejected
        let result = cache.cache(100, vec![5, 6], &mut metrics);
        assert!(
            result.is_some(),
            "should reject when per-template cap reached"
        );
        assert_eq!(cache.count(), 2);
        assert_eq!(metrics.pending_dropped, 1);
    }

    #[test]
    fn test_total_byte_limit() {
        let config = PendingFlowsConfig {
            max_pending_flows: 8,
            max_entries_per_template: 100,
            max_entry_size_bytes: 128,
            max_total_bytes: 20,
            ttl: None,
        };
        let mut cache = PendingFlowCache::new(config).unwrap();
        let mut metrics = default_metrics();

        // Cache entries for different templates to trigger LRU eviction
        assert!(cache.cache(1, vec![0u8; 10], &mut metrics).is_none());
        assert!(cache.cache(2, vec![0u8; 10], &mut metrics).is_none());
        assert_eq!(cache.count(), 2);

        // Adding another 10 bytes should evict the LRU template (template 1)
        assert!(cache.cache(3, vec![0u8; 10], &mut metrics).is_none());

        // Template 1 should have been evicted to make room
        let drained_1 = cache.drain(1, &mut metrics);
        assert!(drained_1.is_empty(), "template 1 should have been evicted");
    }

    #[test]
    fn test_ttl_expiration() {
        let config = PendingFlowsConfig {
            max_pending_flows: 8,
            max_entries_per_template: 100,
            max_entry_size_bytes: 128,
            max_total_bytes: 4096,
            ttl: Some(Duration::from_millis(1)),
        };
        let mut cache = PendingFlowCache::new(config).unwrap();
        let mut metrics = default_metrics();

        assert!(cache.cache(100, vec![1, 2, 3], &mut metrics).is_none());
        assert_eq!(cache.count(), 1);

        // Sleep briefly to let the TTL expire
        std::thread::sleep(Duration::from_millis(10));

        let drained = cache.drain(100, &mut metrics);
        assert!(
            drained.is_empty(),
            "expired entries should be filtered out on drain"
        );
    }

    #[test]
    fn test_resize_shrink() {
        let config = PendingFlowsConfig {
            max_pending_flows: 4,
            max_entries_per_template: 100,
            max_entry_size_bytes: 128,
            max_total_bytes: 4096,
            ttl: None,
        };
        let mut cache = PendingFlowCache::new(config).unwrap();
        let mut metrics = default_metrics();

        // Fill 4 template slots
        for i in 0..4u16 {
            assert!(cache.cache(i, vec![i as u8; 4], &mut metrics).is_none());
        }
        assert_eq!(cache.count(), 4);

        // Resize to 2 slots
        let new_config = PendingFlowsConfig {
            max_pending_flows: 2,
            max_entries_per_template: 100,
            max_entry_size_bytes: 128,
            max_total_bytes: 4096,
            ttl: None,
        };
        let dropped = cache.resize(new_config, &mut metrics).unwrap();
        assert_eq!(
            dropped, 2,
            "should have dropped 2 entries from LRU eviction"
        );
        assert_eq!(cache.count(), 2);
    }

    #[test]
    fn test_would_accept() {
        let config = PendingFlowsConfig {
            max_pending_flows: 8,
            max_entries_per_template: 2,
            max_entry_size_bytes: 128,
            max_total_bytes: 4096,
            ttl: None,
        };
        let mut cache = PendingFlowCache::new(config).unwrap();
        let mut metrics = default_metrics();

        // No entries yet, should accept
        assert!(cache.would_accept(100, 10));

        // Fill to cap
        assert!(cache.cache(100, vec![1], &mut metrics).is_none());
        assert!(cache.cache(100, vec![2], &mut metrics).is_none());

        // At cap, should not accept
        assert!(!cache.would_accept(100, 10));

        // Different template should still accept
        assert!(cache.would_accept(200, 10));

        // Reject entry exceeding per-entry size limit
        assert!(cache.would_accept(200, 128));
        assert!(!cache.would_accept(200, 129));

        // Reject entry that would exceed total byte budget
        let config_small = PendingFlowsConfig {
            max_pending_flows: 8,
            max_entries_per_template: 10,
            max_entry_size_bytes: 128,
            max_total_bytes: 16,
            ttl: None,
        };
        let cache_small = PendingFlowCache::new(config_small).unwrap();
        assert!(cache_small.would_accept(100, 16));
        assert!(!cache_small.would_accept(100, 17));
    }

    #[test]
    fn test_empty_drain() {
        let config = small_config(8);
        let mut cache = PendingFlowCache::new(config).unwrap();
        let mut metrics = default_metrics();

        let drained = cache.drain(999, &mut metrics);
        assert!(
            drained.is_empty(),
            "draining non-existent template should return empty vec"
        );
    }

    #[test]
    fn test_validate_config() {
        // Zero max_pending_flows
        let bad = PendingFlowsConfig {
            max_pending_flows: 0,
            ..PendingFlowsConfig::default()
        };
        assert!(PendingFlowCache::validate_config(&bad).is_err());

        // Zero max_entries_per_template
        let bad = PendingFlowsConfig {
            max_entries_per_template: 0,
            ..PendingFlowsConfig::default()
        };
        assert!(PendingFlowCache::validate_config(&bad).is_err());

        // Zero max_entry_size_bytes
        let bad = PendingFlowsConfig {
            max_entry_size_bytes: 0,
            ..PendingFlowsConfig::default()
        };
        assert!(PendingFlowCache::validate_config(&bad).is_err());

        // max_entry_size_bytes exceeding limit
        let bad = PendingFlowsConfig {
            max_entry_size_bytes: u16::MAX as usize,
            ..PendingFlowsConfig::default()
        };
        assert!(PendingFlowCache::validate_config(&bad).is_err());

        // Zero max_total_bytes
        let bad = PendingFlowsConfig {
            max_total_bytes: 0,
            ..PendingFlowsConfig::default()
        };
        assert!(PendingFlowCache::validate_config(&bad).is_err());

        // max_total_bytes < max_entry_size_bytes
        let bad = PendingFlowsConfig {
            max_total_bytes: 10,
            max_entry_size_bytes: 100,
            ..PendingFlowsConfig::default()
        };
        assert!(PendingFlowCache::validate_config(&bad).is_err());

        // Valid default config should pass
        assert!(PendingFlowCache::validate_config(&PendingFlowsConfig::default()).is_ok());
    }
}
