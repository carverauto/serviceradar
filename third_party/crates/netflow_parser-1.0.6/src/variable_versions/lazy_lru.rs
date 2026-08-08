use lru::LruCache;
use std::borrow::Borrow;
use std::fmt;
use std::hash::Hash;
use std::num::NonZeroUsize;

/// An LRU cache that allocates its backing storage on first insertion.
///
/// `lru::LruCache::new(capacity)` reserves the full configured capacity.
/// Template parsers own several independent caches, most of which remain unused
/// for a given exporter. This wrapper retains the same capacity and eviction
/// semantics without reserving memory for empty caches.
pub(crate) struct LazyLruCache<K: Hash + Eq, V> {
    capacity: NonZeroUsize,
    cache: Option<LruCache<K, V>>,
}

impl<K: Hash + Eq, V> fmt::Debug for LazyLruCache<K, V> {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        // Preserve the parser's existing debug representation.
        formatter
            .debug_struct("LruCache")
            .field("len", &self.len())
            .field("cap", &self.capacity)
            .finish()
    }
}

impl<K: Hash + Eq, V> LazyLruCache<K, V> {
    pub(crate) fn new(capacity: NonZeroUsize) -> Self {
        Self {
            capacity,
            cache: None,
        }
    }

    fn cache_mut(&mut self) -> &mut LruCache<K, V> {
        let capacity = self.capacity;
        self.cache.get_or_insert_with(|| {
            // `unbounded()` starts with an empty hash map. Resizing it before
            // the first insertion sets the eviction limit without reserving
            // storage for every possible entry.
            let mut cache = LruCache::unbounded();
            cache.resize(capacity);
            cache
        })
    }

    fn release_if_empty(&mut self) {
        if self.cache.as_ref().is_some_and(LruCache::is_empty) {
            self.cache = None;
        }
    }

    pub(crate) fn push(&mut self, key: K, value: V) -> Option<(K, V)> {
        self.cache_mut().push(key, value)
    }

    #[cfg(test)]
    pub(crate) fn put(&mut self, key: K, value: V) -> Option<V> {
        self.cache_mut().put(key, value)
    }

    pub(crate) fn peek<Q>(&self, key: &Q) -> Option<&V>
    where
        K: Borrow<Q>,
        Q: Hash + Eq + ?Sized,
    {
        self.cache.as_ref()?.peek(key)
    }

    pub(crate) fn pop<Q>(&mut self, key: &Q) -> Option<V>
    where
        K: Borrow<Q>,
        Q: Hash + Eq + ?Sized,
    {
        let value = self.cache.as_mut()?.pop(key);
        self.release_if_empty();
        value
    }

    pub(crate) fn promote<Q>(&mut self, key: &Q) -> bool
    where
        K: Borrow<Q>,
        Q: Hash + Eq + ?Sized,
    {
        self.cache.as_mut().is_some_and(|cache| cache.promote(key))
    }

    pub(crate) fn resize(&mut self, capacity: NonZeroUsize) {
        self.capacity = capacity;
        if let Some(cache) = self.cache.as_mut() {
            cache.resize(capacity);
        }
        self.release_if_empty();
    }

    pub(crate) fn clear(&mut self) {
        self.cache = None;
    }

    pub(crate) fn len(&self) -> usize {
        self.cache.as_ref().map_or(0, LruCache::len)
    }

    #[cfg(test)]
    pub(crate) fn cap(&self) -> NonZeroUsize {
        self.capacity
    }

    pub(crate) fn iter(&self) -> impl Iterator<Item = (&K, &V)> {
        self.cache.iter().flat_map(|cache| cache.iter())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reads_and_resizes_do_not_allocate_an_empty_cache() {
        let mut cache = LazyLruCache::<u16, u16>::new(NonZeroUsize::new(10).unwrap());

        assert!(cache.cache.is_none());
        assert_eq!(cache.cap().get(), 10);
        assert_eq!(cache.len(), 0);
        assert_eq!(cache.peek(&1), None);
        assert!(!cache.promote(&1));
        assert_eq!(cache.pop(&1), None);
        assert_eq!(cache.iter().count(), 0);

        cache.resize(NonZeroUsize::new(20).unwrap());
        assert!(cache.cache.is_none());
        assert_eq!(cache.cap().get(), 20);
    }

    #[test]
    fn first_insert_allocates_and_preserves_lru_eviction() {
        let mut cache = LazyLruCache::new(NonZeroUsize::new(2).unwrap());

        assert_eq!(cache.push(1, "one"), None);
        assert!(cache.cache.is_some());
        assert_eq!(cache.push(2, "two"), None);
        assert!(cache.promote(&1));
        assert_eq!(cache.push(3, "three"), Some((2, "two")));
        assert_eq!(cache.peek(&1), Some(&"one"));
        assert_eq!(cache.peek(&2), None);
        assert_eq!(cache.peek(&3), Some(&"three"));
    }

    #[test]
    fn removing_the_last_entry_releases_storage() {
        let mut cache = LazyLruCache::new(NonZeroUsize::new(2).unwrap());
        cache.put(1, "one");

        assert_eq!(cache.pop(&1), Some("one"));
        assert!(cache.cache.is_none());

        cache.put(2, "two");
        cache.clear();
        assert!(cache.cache.is_none());
        assert_eq!(cache.cap().get(), 2);
    }
}
