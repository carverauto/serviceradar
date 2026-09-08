//! Shared test fixtures.
//!
//! In `src/`, not `tests/`: Bazel cannot reach helper files inside `tests/` but can reach all of
//! `src/` during testing.

use crate::errors::SecretError;
use crate::traits::SecretProvider;
use crate::types::Secret;
use std::collections::BTreeMap;

/// An in-memory provider, so the resolution paths are testable without a mount.
#[derive(Debug, Clone)]
pub struct MapProvider {
    entries: BTreeMap<String, String>,
    label: String,
}

impl MapProvider {
    pub fn new<I, K, V>(entries: I) -> Self
    where
        I: IntoIterator<Item = (K, V)>,
        K: Into<String>,
        V: Into<String>,
    {
        Self {
            entries: entries.into_iter().map(|(k, v)| (k.into(), v.into())).collect(),
            label: "test-map".to_string(),
        }
    }
}

impl SecretProvider for MapProvider {
    fn describe(&self) -> &str {
        &self.label
    }

    fn resolve(&self, name: &str) -> Result<Secret, SecretError> {
        self.entries
            .get(name)
            .and_then(|v| Secret::new(v.clone()))
            .ok_or_else(|| SecretError::Unresolvable {
                name: name.to_string(),
                provider: self.label.clone(),
            })
    }
}
