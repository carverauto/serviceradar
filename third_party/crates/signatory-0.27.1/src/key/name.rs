//! Key names: unambiguous identifier strings.

use crate::{Error, Result};
use alloc::string::String;
use core::{
    fmt::{self, Display},
    ops::Deref,
    str::FromStr,
};

/// Key names.
///
/// These are constrained to the following characters:
/// - Letters: `a-z`, A-Z`
/// - Numbers: `0-9`
/// - Delimiters: `-`, `_`
#[derive(Clone, Debug, Eq, Hash, PartialEq, PartialOrd, Ord)]
pub struct KeyName(String);

impl KeyName {
    /// Create a new key name from the given string.
    pub fn new(name: impl Into<String>) -> Result<Self> {
        let name = name.into();

        if !name
            .as_bytes()
            .iter()
            .all(|&byte| matches!(byte, b'a'..=b'z' | b'A'..=b'Z' | b'0'..=b'9' | b'-' | b'_'))
        {
            return Err(Error::KeyNameInvalid);
        }

        Ok(Self(name))
    }
}

impl AsRef<str> for KeyName {
    fn as_ref(&self) -> &str {
        &self.0
    }
}

#[cfg(feature = "std")]
impl AsRef<std::path::Path> for KeyName {
    fn as_ref(&self) -> &std::path::Path {
        self.0.as_ref()
    }
}

impl Deref for KeyName {
    type Target = str;

    fn deref(&self) -> &str {
        &self.0
    }
}

impl Display for KeyName {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.0)
    }
}

impl FromStr for KeyName {
    type Err = Error;

    fn from_str(name: &str) -> Result<Self> {
        Self::new(name)
    }
}
