//! The provider an environment selects.

use crate::errors::SecretError;
use crate::traits::{EnvProvider, FileProvider, SecretProvider};
use crate::types::Secret;

/// The provider `SERVICERADAR_ENV` chooses.
///
/// An enum rather than `Box<dyn SecretProvider>` because this codebase dispatches statically;
/// the set of providers is closed and known at compile time, so a trait object would buy
/// nothing and cost an allocation and a vtable on a path that runs before anything is up.
///
/// It exists so a component never names a provider. Three call sites used to write
/// `FileProvider::for_kind(...)` themselves, which meant adding a second provider was an edit
/// in three places and the docstring claiming "a component never names a provider" was false.
#[derive(Debug, Clone)]
pub enum EnvironmentProvider {
    Env(EnvProvider),
    File(FileProvider),
}

impl EnvironmentProvider {
    /// Selects by environment kind.
    ///
    /// Everything except `localhost` reads the environment, because that is what the platform
    /// does: `//helm/serviceradar` supplies every credential through `valueFrom.secretKeyRef`,
    /// and a BuildBuddy workflow secret has no other form. `localhost` keeps the file store --
    /// a developer machine has nothing injecting variables into a test action, and asking one
    /// to export a password per shell is how a password ends up in a shell history file.
    pub fn for_kind(kind: &str) -> Self {
        match kind {
            "localhost" => Self::File(FileProvider::for_kind(kind)),
            _ => Self::Env(EnvProvider::new()),
        }
    }
}

impl SecretProvider for EnvironmentProvider {
    fn describe(&self) -> &str {
        match self {
            Self::Env(p) => p.describe(),
            Self::File(p) => p.describe(),
        }
    }

    fn resolve(&self, name: &str) -> Result<Secret, SecretError> {
        match self {
            Self::Env(p) => p.resolve(name),
            Self::File(p) => p.resolve(name),
        }
    }
}
