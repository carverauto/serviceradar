//! Template cache metrics and cache information types for monitoring parser performance.

use super::ttl::TtlConfig;

/// Metrics for tracking template cache performance.
///
/// All counters use plain u64 fields. The parser itself is not thread-safe
/// and should not be shared across threads.
#[derive(Debug, Default, Clone, Copy)]
pub(crate) struct CacheMetricsInner {
    /// Number of successful template lookups (cache hits)
    pub hits: u64,
    /// Number of failed template lookups (cache misses)
    pub misses: u64,
    /// Number of templates evicted due to LRU policy
    pub evictions: u64,
    /// Number of templates that expired due to TTL
    pub expired: u64,
    /// Number of template insertions (including replacements)
    pub insertions: u64,
    /// Number of template ID collisions (same ID, different definition)
    pub collisions: u64,
    /// Number of flows cached as pending (awaiting template)
    pub pending_cached: u64,
    /// Number of pending flows successfully replayed after template arrived
    pub pending_replayed: u64,
    /// Number of pending flows dropped (expired or evicted)
    pub pending_dropped: u64,
    /// Number of pending flows that failed to replay (parse error after template arrived)
    pub pending_replay_failed: u64,
    /// Number of templates restored from the secondary `TemplateStore` on a
    /// primary-cache miss (read-through hits).
    pub template_store_restored: u64,
    /// Number of secondary `TemplateStore` payloads that failed to decode.
    /// Non-zero values indicate operational issues — a corrupted entry,
    /// a wire-format version mismatch after upgrade, or a bug in a custom
    /// `TemplateStore` impl. The parser removes the offending key on each
    /// occurrence to allow re-population from a fresh template announce.
    pub template_store_codec_errors: u64,
    /// Number of `TemplateStore::get`, `put`, or `remove` calls that returned
    /// an `Err`. Backend-level failures are best-effort from the parser's
    /// perspective and do not abort packet parsing, but a sustained non-zero
    /// rate indicates the secondary tier is unhealthy.
    pub template_store_backend_errors: u64,
}

impl CacheMetricsInner {
    /// Create a new metrics instance with all counters at zero
    pub fn new() -> Self {
        Self::default()
    }

    /// Record a cache hit
    #[inline]
    pub(crate) fn record_hit(&mut self) {
        self.hits = self.hits.saturating_add(1);
    }

    /// Record a cache miss
    #[inline]
    pub(crate) fn record_miss(&mut self) {
        self.misses = self.misses.saturating_add(1);
    }

    /// Record a template eviction
    #[inline]
    pub(crate) fn record_eviction(&mut self) {
        self.evictions = self.evictions.saturating_add(1);
    }

    /// Record a template expiration
    #[inline]
    pub(crate) fn record_expiration(&mut self) {
        self.expired = self.expired.saturating_add(1);
    }

    /// Record a template insertion
    #[inline]
    pub(crate) fn record_insertion(&mut self) {
        self.insertions = self.insertions.saturating_add(1);
    }

    /// Record a template collision (same ID, different definition)
    #[inline]
    pub(crate) fn record_collision(&mut self) {
        self.collisions = self.collisions.saturating_add(1);
    }

    /// Record a flow cached as pending (awaiting template)
    #[inline]
    pub(crate) fn record_pending_cached(&mut self) {
        self.pending_cached = self.pending_cached.saturating_add(1);
    }

    /// Record a pending flow successfully replayed
    #[inline]
    pub(crate) fn record_pending_replayed(&mut self) {
        self.pending_replayed = self.pending_replayed.saturating_add(1);
    }

    /// Record a pending flow dropped (expired or evicted)
    #[inline]
    pub(crate) fn record_pending_dropped(&mut self) {
        self.pending_dropped = self.pending_dropped.saturating_add(1);
    }

    /// Record multiple pending flows dropped at once
    #[inline]
    pub(crate) fn record_pending_dropped_n(&mut self, n: u64) {
        self.pending_dropped = self.pending_dropped.saturating_add(n);
    }

    /// Record a pending flow that failed to replay (parse error)
    #[inline]
    pub(crate) fn record_pending_replay_failed(&mut self) {
        self.pending_replay_failed = self.pending_replay_failed.saturating_add(1);
    }

    /// Record multiple pending flows that failed to replay at once
    #[inline]
    pub(crate) fn record_pending_replay_failed_n(&mut self, n: u64) {
        self.pending_replay_failed = self.pending_replay_failed.saturating_add(n);
    }

    /// Record a successful read-through against the secondary template store.
    #[inline]
    pub(crate) fn record_template_store_restored(&mut self) {
        self.template_store_restored = self.template_store_restored.saturating_add(1);
    }

    /// Record a codec failure when decoding a secondary-store payload.
    #[inline]
    pub(crate) fn record_template_store_codec_error(&mut self) {
        self.template_store_codec_errors = self.template_store_codec_errors.saturating_add(1);
    }

    /// Record a backend failure from a secondary-store get/put/remove call.
    #[inline]
    pub(crate) fn record_template_store_backend_error(&mut self) {
        self.template_store_backend_errors =
            self.template_store_backend_errors.saturating_add(1);
    }

    /// Get a snapshot of current metrics
    pub fn snapshot(&self) -> CacheMetrics {
        CacheMetrics {
            hits: self.hits,
            misses: self.misses,
            evictions: self.evictions,
            expired: self.expired,
            insertions: self.insertions,
            collisions: self.collisions,
            pending_cached: self.pending_cached,
            pending_replayed: self.pending_replayed,
            pending_dropped: self.pending_dropped,
            pending_replay_failed: self.pending_replay_failed,
            template_store_restored: self.template_store_restored,
            template_store_codec_errors: self.template_store_codec_errors,
            template_store_backend_errors: self.template_store_backend_errors,
        }
    }
}

/// A point-in-time snapshot of cache metrics.
///
/// This provides a consistent view of metrics without requiring atomic operations
/// for each field access.
#[non_exhaustive]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct CacheMetrics {
    /// Number of successful template lookups (cache hits)
    pub hits: u64,
    /// Number of failed template lookups (cache misses)
    pub misses: u64,
    /// Number of templates evicted due to LRU policy
    pub evictions: u64,
    /// Number of templates that expired due to TTL
    pub expired: u64,
    /// Number of template insertions (including replacements)
    pub insertions: u64,
    /// Number of template ID collisions (same ID, different definition)
    pub collisions: u64,
    /// Number of flows cached as pending (awaiting template)
    pub pending_cached: u64,
    /// Number of pending flows successfully replayed after template arrived
    pub pending_replayed: u64,
    /// Number of pending flows dropped (expired or evicted)
    pub pending_dropped: u64,
    /// Number of pending flows that failed to replay (parse error after template arrived)
    pub pending_replay_failed: u64,
    /// Number of templates restored from the secondary `TemplateStore` on a
    /// primary-cache miss.
    pub template_store_restored: u64,
    /// Number of secondary `TemplateStore` payloads that failed to decode
    /// (corrupted entry, wire-format mismatch, or buggy backend).
    pub template_store_codec_errors: u64,
    /// Number of secondary-store get/put/remove calls that returned `Err`.
    pub template_store_backend_errors: u64,
}

impl CacheMetrics {
    /// Calculate the cache hit rate (0.0 to 1.0)
    ///
    /// Returns `None` if there have been no lookups yet.
    pub fn hit_rate(&self) -> Option<f64> {
        let total = self.hits.saturating_add(self.misses);
        if total == 0 {
            None
        } else {
            Some(self.hits as f64 / total as f64)
        }
    }

    /// Calculate the cache miss rate (0.0 to 1.0)
    ///
    /// Returns `None` if there have been no lookups yet.
    pub fn miss_rate(&self) -> Option<f64> {
        self.hit_rate().map(|hr| 1.0 - hr)
    }

    /// Total number of template lookups (hits + misses)
    pub fn total_lookups(&self) -> u64 {
        self.hits.saturating_add(self.misses)
    }
}

/// Statistics about template cache utilization.
#[non_exhaustive]
#[derive(Debug, Clone)]
pub struct CacheInfo {
    /// Current number of cached templates (summed across all internal caches).
    ///
    /// This is the total across `num_caches` independent LRU caches. The theoretical
    /// maximum is `max_size_per_cache * num_caches`, since each cache enforces
    /// `max_size_per_cache` independently.
    pub current_size: usize,
    /// Maximum cache size per internal cache (each template type has its own LRU cache).
    ///
    /// Each of the `num_caches` internal caches can hold up to this many templates
    /// independently.
    pub max_size_per_cache: usize,
    /// Number of internal caches (V9 has 2: templates + options; IPFIX has 4)
    pub num_caches: usize,
    /// TTL configuration (if enabled)
    pub ttl_config: Option<TtlConfig>,
    /// Performance metrics snapshot
    pub metrics: CacheMetrics,
    /// Number of flows currently cached as pending (awaiting template)
    pub pending_flow_count: usize,
}

/// Combined cache information for both V9 and IPFIX template caches.
///
/// This struct provides named fields instead of positional tuples,
/// making it clear which info belongs to V9 vs IPFIX.
#[non_exhaustive]
#[derive(Debug, Clone)]
pub struct ParserCacheInfo {
    /// V9 template cache information
    pub v9: CacheInfo,
    /// IPFIX template cache information
    pub ipfix: CacheInfo,
}

#[cfg(test)]
mod tests {
    use super::*;

    // Verify each record method increments the correct counter in the snapshot
    #[test]
    fn test_metrics_recording() {
        let mut metrics = CacheMetricsInner::new();

        metrics.record_hit();
        metrics.record_hit();
        metrics.record_miss();
        metrics.record_eviction();
        metrics.record_expiration();
        metrics.record_insertion();

        let snapshot = metrics.snapshot();
        assert_eq!(snapshot.hits, 2);
        assert_eq!(snapshot.misses, 1);
        assert_eq!(snapshot.evictions, 1);
        assert_eq!(snapshot.expired, 1);
        assert_eq!(snapshot.insertions, 1);
    }

    // Verify hit_rate and miss_rate calculations, including None when no lookups exist
    #[test]
    fn test_hit_rate() {
        let mut metrics = CacheMetricsInner::new();

        // No lookups yet
        let snapshot = metrics.snapshot();
        assert_eq!(snapshot.hit_rate(), None);

        // Record some hits and misses
        metrics.record_hit();
        metrics.record_hit();
        metrics.record_hit();
        metrics.record_miss();

        let snapshot = metrics.snapshot();
        assert_eq!(snapshot.hit_rate(), Some(0.75));
        assert_eq!(snapshot.miss_rate(), Some(0.25));
        assert_eq!(snapshot.total_lookups(), 4);
    }
}
