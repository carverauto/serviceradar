//! Secret strings

use super::{CloneableSecret, DebugSecret, Secret};
use alloc::str::FromStr;
use alloc::string::{String, ToString};

/// Secret strings
#[cfg_attr(docsrs, doc(cfg(feature = "alloc")))]
pub type SecretString = Secret<String>;

impl DebugSecret for String {}
impl CloneableSecret for String {}

impl FromStr for SecretString {
    type Err = core::convert::Infallible;

    fn from_str(src: &str) -> Result<Self, Self::Err> {
        Ok(SecretString::new(src.to_string()))
    }
}
