//! Resolves declared secrets through the provider the environment selects.

use crate::errors::SecretError;
use crate::traits::SecretProvider;
use crate::types::{Manifest, Secret};

/// Resolves logical secret names for one component.
///
/// It holds the component's manifest, so a name the component did not declare is refused before
/// the provider is consulted at all -- the provider never learns the component tried.
#[derive(Debug, Clone)]
pub struct SecretManager<P: SecretProvider> {
    provider: P,
    manifest: Manifest,
}

impl<P: SecretProvider> SecretManager<P> {
    pub fn new(provider: P, manifest: Manifest) -> Self {
        Self { provider, manifest }
    }

    /// The provider in use, for `explain`.
    pub fn provider(&self) -> &str {
        self.provider.describe()
    }

    pub fn manifest(&self) -> &Manifest {
        &self.manifest
    }

    /// Resolves one declared secret.
    ///
    /// Refusal precedes resolution: an undeclared name is an error about the MANIFEST, and
    /// answering it -- even to say "not found" -- would tell a component whether a secret it may
    /// not have exists.
    pub fn resolve(&self, name: &str) -> Result<Secret, SecretError> {
        if !self.manifest.declares(name) {
            return Err(SecretError::Undeclared {
                name: name.to_string(),
                declared: self.manifest.declared().into_iter().map(str::to_string).collect(),
            });
        }
        self.provider.resolve(name)
    }

    /// Resolves everything the component declared, failing on the first that cannot be resolved.
    ///
    /// Startup calls this: a component that resolves secrets lazily discovers a missing one when
    /// it first needs it, which is under load and far from the deploy that caused it.
    pub fn resolve_all(&self) -> Result<Vec<(String, Secret)>, SecretError> {
        self.manifest
            .declared()
            .into_iter()
            .map(|name| self.resolve(name).map(|secret| (name.to_string(), secret)))
            .collect()
    }
}
