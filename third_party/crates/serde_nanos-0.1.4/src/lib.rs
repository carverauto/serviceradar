//! # Serde Nanos
//!
//! [Documentation](https://docs.rs/serde_nanos) |
//! [Github](https://github.com/caspervonb/serde_nanos) |
//! [Crate](https://crates.io/crates/serde_nanos)
//!
//! A serde wrapper that can be used to serialize timestamps and durations as
//! nanoseconds.
//!
//! It's often useful together with `serde_json` to communicate with JSON
//! protocols.
#![warn(missing_docs)]
#![warn(missing_debug_implementations)]

mod de;
mod ser;

pub use crate::de::Deserialize;
pub use crate::ser::Serialize;

use serde::Deserializer;
use serde::Serializer;

/// Serde `serialize_with` function to serialize time values as nanoseconds.
///
/// This function can be used with either of the following Serde attributes:
///
/// - `#[serde(with = "serde_nanos")]`
/// - `#[serde(serialize_with = "serde_nanos::serialize")]`
///
/// ```
/// # use serde_derive::Serialize;
/// use std::time::Duration;
/// use serde::Serialize;
///
/// #[derive(Serialize)]
/// struct Message {
///     #[serde(with = "serde_nanos")]
///     expires_in: Duration,
/// }
/// ```
pub fn serialize<T, S>(nanos: &T, serializer: S) -> Result<S::Ok, S::Error>
where
    T: ?Sized + Serialize,
    S: Serializer,
{
    Serialize::serialize(nanos, serializer)
}

/// Serde `deserialize_with` function to deserialize time values as nanoseconds.
///
/// This function can be used with either of the following Serde attributes:
///
/// - `#[serde(with = "serde_nanos")]`
/// - `#[serde(deserialize_with = "serde_nanos::deserialize")]`
///
/// ```
/// # use serde_derive::Deserialize;
/// use std::time::Duration;
/// use serde::Deserialize;
///
/// #[derive(Deserialize)]
/// struct Message {
///     #[serde(with = "serde_nanos")]
///     expires_in: Duration,
/// }
/// ```
pub fn deserialize<'de, T, D>(deserializer: D) -> Result<T, D::Error>
where
    T: Deserialize<'de>,
    D: Deserializer<'de>,
{
    Deserialize::deserialize(deserializer)
}
