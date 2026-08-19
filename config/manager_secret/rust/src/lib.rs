//! Resolves a component's secrets through the provider its environment selects.
//!
//! The environment comes from `SERVICERADAR_ENV`, the same single variable ConfigManager reads;
//! a component never names a provider. Logical secret names are identical across environments and
//! languages, so only the provider changes.
//!
//! Two properties are load-bearing and both are enforced by types rather than by discipline:
//! a [`Secret`] cannot be printed, and a name a component did not declare is refused before the
//! provider is consulted.

#![forbid(unsafe_code)]

pub mod errors;
pub mod traits;
pub mod types;
pub mod utils_tests;

pub use errors::SecretError;
pub use traits::{
    EnvProvider, EnvironmentProvider, FileProvider, SecretProvider, LOCAL_SECRETS_SUBDIR,
    MOUNTED_SECRETS_DIR, SECRET_ENV_PREFIX,
};
pub use types::{Manifest, Secret, SecretManager, REDACTED};
