#![no_std]
#![cfg_attr(docsrs, feature(doc_cfg))]
#![doc = include_str!("../README.md")]
#![doc(
    html_logo_url = "https://raw.githubusercontent.com/RustCrypto/media/6ee8e381/logo.svg",
    html_favicon_url = "https://raw.githubusercontent.com/RustCrypto/media/6ee8e381/logo.svg"
)]
#![forbid(unsafe_code)]
#![warn(
    clippy::mod_module_files,
    clippy::unwrap_used,
    missing_docs,
    rust_2018_idioms,
    unused_lifetimes,
    unused_qualifications
)]

//! ## Usage
//!
//! ### Implementing `Deserialize` and `Serialize` for arrays.
//!
#![cfg_attr(feature = "alloc", doc = " ```")]
#![cfg_attr(not(feature = "alloc"), doc = " ```ignore")]
//! # use serde::{Deserialize, Deserializer, Serialize, Serializer};
//! #
//! # #[derive(Debug, PartialEq)]
//! struct SecretData([u8; 32]);
//!
//! impl<'de> Deserialize<'de> for SecretData {
//!     fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
//!     where
//!         D: Deserializer<'de>,
//!     {
//!         let mut buffer = [0; 32];
//!         serdect::array::deserialize_hex_or_bin(&mut buffer, deserializer)?;
//!         Ok(Self(buffer))
//!     }
//! }
//!
//! impl Serialize for SecretData {
//!     fn serialize<S>(&self, serializer: S) -> Result<S::Ok, S::Error>
//!     where
//!         S: Serializer,
//!     {
//!         serdect::array::serialize_hex_lower_or_bin(&self.0, serializer)
//!     }
//! }
//!
//! let data = SecretData([42; 32]);
//!
//! // postcard: an embedded-friendly binary serialization format
//! let serialized = postcard::to_stdvec(&data).unwrap();
//! let deserialized: SecretData = postcard::from_bytes(&serialized).unwrap();
//! assert_eq!(deserialized, data);
//!
//! let serialized = serde_json::to_string(&data).unwrap();
//! // JSON, a human-readable serialization format, is serialized into lower-case HEX.
//! assert_eq!(
//!     serialized,
//!     "\"2a2a2a2a2a2a2a2a2a2a2a2a2a2a2a2a2a2a2a2a2a2a2a2a2a2a2a2a2a2a2a2a\""
//! );
//! # let deserialized: SecretData = serde_json::from_str(&serialized).unwrap();
//! # assert_eq!(deserialized, data);
//! ```
//!
//! ### Implementing `Deserialize` and `Serialize` for slices.
//!
#![cfg_attr(feature = "alloc", doc = " ```")]
#![cfg_attr(not(feature = "alloc"), doc = " ```ignore")]
//! # use serde::{Deserialize, Deserializer, Serialize, Serializer};
//! #
//! # #[derive(Debug, PartialEq)]
//! struct SecretData(Vec<u8>);
//!
//! impl<'de> Deserialize<'de> for SecretData {
//!     fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
//!     where
//!         D: Deserializer<'de>,
//!     {
//!         serdect::slice::deserialize_hex_or_bin_vec(deserializer).map(Self)
//!     }
//! }
//!
//! impl Serialize for SecretData {
//!     fn serialize<S>(&self, serializer: S) -> Result<S::Ok, S::Error>
//!     where
//!         S: Serializer,
//!     {
//!         serdect::slice::serialize_hex_lower_or_bin(&self.0, serializer)
//!     }
//! }
//!
//! let data = SecretData(vec![42; 32]);
//!
//! // postcard: an embedded-friendly binary serialization format
//! let serialized = postcard::to_stdvec(&data).unwrap();
//! let deserialized: SecretData = postcard::from_bytes(&serialized).unwrap();
//! assert_eq!(deserialized, data);
//!
//! let serialized = serde_json::to_string(&data).unwrap();
//! // JSON, a human-readable serialization format is serialized into lower-case HEX.
//! assert_eq!(
//!     serialized,
//!     "\"2a2a2a2a2a2a2a2a2a2a2a2a2a2a2a2a2a2a2a2a2a2a2a2a2a2a2a2a2a2a2a2a\""
//! );
//! # let deserialized: SecretData = serde_json::from_str(&serialized).unwrap();
//! # assert_eq!(deserialized, data);
//! ```

#[cfg(feature = "alloc")]
extern crate alloc;

pub mod array;
mod common;
pub mod slice;

pub use serde;
