use core::hash::{BuildHasherDefault, Hash, Hasher};
use std::{
    collections::{hash_map::Entry, HashMap},
    sync::Arc,
};

use ahash::AHasher;
use fluent_uri::Uri;
use parking_lot::RwLock;

use crate::{hasher::BuildNoHashHasher, uri, Error};

#[derive(Debug, Clone)]
pub(crate) struct UriCache {
    cache: HashMap<u64, Arc<Uri<String>>, BuildNoHashHasher>,
}

impl UriCache {
    pub(crate) fn new() -> Self {
        Self {
            cache: HashMap::with_hasher(BuildHasherDefault::default()),
        }
    }

    pub(crate) fn with_capacity(capacity: usize) -> Self {
        Self {
            cache: HashMap::with_capacity_and_hasher(capacity, BuildHasherDefault::default()),
        }
    }

    pub(crate) fn resolve_against(
        &mut self,
        base: &Uri<&str>,
        uri: impl AsRef<str>,
    ) -> Result<Arc<Uri<String>>, Error> {
        let mut hasher = AHasher::default();
        (base.as_str(), uri.as_ref()).hash(&mut hasher);
        let hash = hasher.finish();

        Ok(match self.cache.entry(hash) {
            Entry::Occupied(entry) => Arc::clone(entry.get()),
            Entry::Vacant(entry) => {
                let new = Arc::new(uri::resolve_against(base, uri.as_ref())?);
                Arc::clone(entry.insert(new))
            }
        })
    }

    pub(crate) fn into_shared(self) -> SharedUriCache {
        SharedUriCache {
            cache: RwLock::new(self.cache),
        }
    }
}

/// A dedicated type for URI resolution caching.
#[derive(Debug)]
pub(crate) struct SharedUriCache {
    cache: RwLock<HashMap<u64, Arc<Uri<String>>, BuildNoHashHasher>>,
}

impl Clone for SharedUriCache {
    fn clone(&self) -> Self {
        Self {
            cache: RwLock::new(
                self.cache
                    .read()
                    .iter()
                    .map(|(k, v)| (*k, Arc::clone(v)))
                    .collect(),
            ),
        }
    }
}

impl SharedUriCache {
    pub(crate) fn resolve_against(
        &self,
        base: &Uri<&str>,
        uri: impl AsRef<str>,
    ) -> Result<Arc<Uri<String>>, Error> {
        let mut hasher = AHasher::default();
        (base.as_str(), uri.as_ref()).hash(&mut hasher);
        let hash = hasher.finish();

        if let Some(cached) = self.cache.read().get(&hash).cloned() {
            return Ok(cached);
        }

        let new = Arc::new(uri::resolve_against(base, uri.as_ref())?);
        self.cache.write().insert(hash, Arc::clone(&new));
        Ok(new)
    }

    pub(crate) fn into_local(self) -> UriCache {
        UriCache {
            cache: self.cache.into_inner(),
        }
    }
}
