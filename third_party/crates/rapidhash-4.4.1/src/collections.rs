use crate::fast::RandomState;

/// A [`std::collections::HashMap`] that uses the [`crate::fast::RandomState`] hasher.
///
/// # Example
/// ```
/// use rapidhash::{HashMapExt, RapidHashMap};
///
/// let mut map = RapidHashMap::default();
/// map.insert(42, "the answer");
///
/// // with capacity
/// let mut map = RapidHashMap::with_capacity(10);
/// map.insert(42, "the answer");
/// ```
pub type RapidHashMap<K, V> = std::collections::HashMap<K, V, RandomState>;

/// A [`std::collections::HashSet`] that uses the [`crate::fast::RandomState`] hasher.
///
/// # Example
/// ```
/// use rapidhash::{HashSetExt, RapidHashSet};
///
/// let mut set = RapidHashSet::default();
/// set.insert("the answer");
///
/// // with capacity
/// let mut set = RapidHashSet::with_capacity(10);
/// set.insert("the answer");
/// ```
pub type RapidHashSet<K> = std::collections::HashSet<K, RandomState>;

/// A trait for creating a [`RapidHashMap`] with a specified capacity and hasher.
pub trait HashMapExt {
    /// Create a new [`RapidHashMap`] with the default capacity and hasher.
    fn new() -> Self;

    /// Create a new [`RapidHashMap`] with the given capacity and hasher.
    fn with_capacity(capacity: usize) -> Self;
}

impl<K, V> HashMapExt for RapidHashMap<K, V> {
    #[inline]
    fn new() -> Self {
        RapidHashMap::default()
    }

    #[inline]
    fn with_capacity(capacity: usize) -> Self {
        RapidHashMap::with_capacity_and_hasher(capacity, RandomState::default())
    }
}

/// A trait for creating a [`RapidHashSet`] with a specified capacity and hasher.
pub trait HashSetExt {
    /// Create a new [`RapidHashSet`] with the default capacity and hasher.
    fn new() -> Self;

    /// Create a new [`RapidHashSet`] with the given capacity and hasher.
    fn with_capacity(capacity: usize) -> Self;
}

impl<K> HashSetExt for RapidHashSet<K> {
    #[inline]
    fn new() -> Self {
        RapidHashSet::default()
    }

    #[inline]
    fn with_capacity(capacity: usize) -> Self {
        RapidHashSet::with_capacity_and_hasher(capacity, RandomState::default())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_hashmap_new() {
        let mut map = RapidHashMap::new();
        map.insert("key", "value");
        assert_eq!(map.get("key"), Some(&"value"));
        assert_eq!(map.get("na"), None);
    }

    #[test]
    fn test_hashset_new() {
        let mut set = RapidHashSet::new();
        set.insert("value");
        assert!(set.contains("value"));
        assert!(!set.contains("na"));
    }

    #[test]
    fn test_hashmap_size() {
        assert_eq!(core::mem::size_of::<RapidHashMap<u64, u64>>(), 40);
    }
}
