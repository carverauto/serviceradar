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

mod ca_bundle;
pub mod errors;
pub mod rules;
pub mod secrets;
pub mod traits;
pub mod types;
pub mod utils_tests;

pub use ca_bundle::fetch_ca_bundle;
pub use errors::{CaBundleError, LoadError, SelectorError};
pub use rules::built_ins;
pub use secrets::{
    DATABASE_ADMIN_PASSWORD, DATABASE_CA_CERT, DATABASE_CLIENT_CERT, DATABASE_CLIENT_KEY,
    DATABASE_PASSWORD, DGRAPH_ADMIN_PASSWORD, DGRAPH_CA_CERT,
};
pub use traits::{Filesystem, ReadSource};
pub use types::config_manager::BuiltIns;
pub use types::{ConfigManager, Dsn, Entry, Explanation, Identity, Source, ENV_VAR, MOUNTED_INSTANCE_PATH};
