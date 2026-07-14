//! Information about a key in a keystore

use crate::{Algorithm, KeyName};

/// Information/metadata about a particular key.
#[derive(Clone, Debug, Eq, PartialEq, PartialOrd, Ord)]
pub struct KeyInfo {
    /// Name of the key.
    pub name: KeyName,

    /// Algorithm of this key (if recognized).
    pub algorithm: Option<Algorithm>,

    /// Is this key encrypted (i.e. under a password)?
    pub encrypted: bool,
}
