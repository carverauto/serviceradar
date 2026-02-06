use std::collections::HashMap;
use std::sync::Mutex;
use std::time::{Duration, Instant};

/// Key for dedup: (hostname, resolved_addr bytes).
/// PTR records use an empty vec for resolved_addr.
type DedupKey = (String, Vec<u8>);

struct Entry {
    inserted_at: Instant,
}

pub struct DedupCache {
    inner: Mutex<DedupInner>,
    ttl: Duration,
    max_entries: usize,
}

struct DedupInner {
    map: HashMap<DedupKey, Entry>,
}

impl DedupCache {
    pub fn new(ttl_secs: u64, max_entries: usize) -> Self {
        Self {
            inner: Mutex::new(DedupInner {
                map: HashMap::new(),
            }),
            ttl: Duration::from_secs(ttl_secs),
            max_entries,
        }
    }

    /// Returns `true` if the record should be published (not a duplicate).
    /// Returns `false` if the record is a duplicate within the TTL window.
    pub fn check_and_insert(&self, hostname: &str, resolved_addr: &[u8]) -> bool {
        let key = (hostname.to_string(), resolved_addr.to_vec());
        let now = Instant::now();
        let mut inner = self.inner.lock().unwrap();

        if let Some(entry) = inner.map.get(&key) {
            if now.duration_since(entry.inserted_at) < self.ttl {
                return false; // duplicate within TTL
            }
        }

        // Evict oldest entry if at capacity
        if inner.map.len() >= self.max_entries && !inner.map.contains_key(&key) {
            if let Some(oldest_key) = inner
                .map
                .iter()
                .min_by_key(|(_, e)| e.inserted_at)
                .map(|(k, _)| k.clone())
            {
                inner.map.remove(&oldest_key);
            }
        }

        inner.map.insert(key, Entry { inserted_at: now });
        true
    }

    /// Remove entries that have expired past the TTL.
    /// Returns the number of entries removed.
    pub fn cleanup(&self) -> usize {
        let now = Instant::now();
        let mut inner = self.inner.lock().unwrap();
        let before = inner.map.len();
        inner
            .map
            .retain(|_, entry| now.duration_since(entry.inserted_at) < self.ttl);
        before - inner.map.len()
    }

    /// Returns the current number of entries in the cache.
    pub fn len(&self) -> usize {
        self.inner.lock().unwrap().map.len()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::thread::sleep;

    #[test]
    fn test_new_entry_is_not_duplicate() {
        let cache = DedupCache::new(300, 1000);
        assert!(cache.check_and_insert("mydevice.local", &[192, 168, 1, 1]));
    }

    #[test]
    fn test_duplicate_within_ttl() {
        let cache = DedupCache::new(300, 1000);
        assert!(cache.check_and_insert("mydevice.local", &[192, 168, 1, 1]));
        assert!(!cache.check_and_insert("mydevice.local", &[192, 168, 1, 1]));
    }

    #[test]
    fn test_different_hostname_not_duplicate() {
        let cache = DedupCache::new(300, 1000);
        assert!(cache.check_and_insert("device-a.local", &[192, 168, 1, 1]));
        assert!(cache.check_and_insert("device-b.local", &[192, 168, 1, 1]));
    }

    #[test]
    fn test_different_addr_not_duplicate() {
        let cache = DedupCache::new(300, 1000);
        assert!(cache.check_and_insert("mydevice.local", &[192, 168, 1, 1]));
        assert!(cache.check_and_insert("mydevice.local", &[192, 168, 1, 2]));
    }

    #[test]
    fn test_ptr_records_dedup_with_empty_addr() {
        let cache = DedupCache::new(300, 1000);
        assert!(cache.check_and_insert("mydevice.local", &[]));
        assert!(!cache.check_and_insert("mydevice.local", &[]));
    }

    #[test]
    fn test_ttl_expiry() {
        let cache = DedupCache::new(1, 1000); // 1 second TTL
        assert!(cache.check_and_insert("mydevice.local", &[192, 168, 1, 1]));
        assert!(!cache.check_and_insert("mydevice.local", &[192, 168, 1, 1]));

        sleep(Duration::from_millis(1100));

        // After TTL expires, should be treated as new
        assert!(cache.check_and_insert("mydevice.local", &[192, 168, 1, 1]));
    }

    #[test]
    fn test_cleanup_removes_expired() {
        let cache = DedupCache::new(1, 1000); // 1 second TTL
        cache.check_and_insert("device-a.local", &[10, 0, 0, 1]);
        cache.check_and_insert("device-b.local", &[10, 0, 0, 2]);
        assert_eq!(cache.len(), 2);

        sleep(Duration::from_millis(1100));

        let removed = cache.cleanup();
        assert_eq!(removed, 2);
        assert_eq!(cache.len(), 0);
    }

    #[test]
    fn test_capacity_eviction() {
        let cache = DedupCache::new(300, 2); // max 2 entries
        cache.check_and_insert("device-a.local", &[10, 0, 0, 1]);

        sleep(Duration::from_millis(10));

        cache.check_and_insert("device-b.local", &[10, 0, 0, 2]);
        assert_eq!(cache.len(), 2);

        // Adding a third entry should evict the oldest (device-a)
        cache.check_and_insert("device-c.local", &[10, 0, 0, 3]);
        assert_eq!(cache.len(), 2);

        // device-a was evicted, so inserting it again should succeed
        assert!(cache.check_and_insert("device-a.local", &[10, 0, 0, 1]));
    }

    #[test]
    fn test_reinsert_same_key_at_capacity_no_eviction() {
        let cache = DedupCache::new(1, 2);
        cache.check_and_insert("device-a.local", &[10, 0, 0, 1]);
        cache.check_and_insert("device-b.local", &[10, 0, 0, 2]);
        assert_eq!(cache.len(), 2);

        sleep(Duration::from_millis(1100));

        // TTL expired, re-inserting device-a should succeed without evicting device-b
        assert!(cache.check_and_insert("device-a.local", &[10, 0, 0, 1]));
        assert_eq!(cache.len(), 2);
    }
}
