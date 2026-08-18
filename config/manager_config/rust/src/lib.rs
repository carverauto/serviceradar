//! Resolves a component's environment configuration from one variable, and validates it before
//! exposing a value.
//!
//! `SERVICERADAR_ENV` is the only input. Everything else follows from the identity it names:
//! which instance to load, where that instance comes from, and -- for SecretManager -- which
//! provider resolves credentials. A component never learns a second variable.
//!
//! Loading validates. Decision 10's guarantee is that no instance is loaded that has not been
//! checked against the committed rule set; a committed instance is checked at BUILD time and then
//! trusted, so checking here is what makes the guarantee hold for an instance the build never saw.

#![forbid(unsafe_code)]

pub mod errors;
pub mod traits;
pub mod types;
pub mod utils_tests;

pub use errors::{LoadError, SelectorError};
pub use traits::{Filesystem, ReadSource};
pub use types::config_manager::BuiltIns;
pub use types::{ConfigManager, Identity, Source, ENV_VAR, MOUNTED_INSTANCE_PATH};
