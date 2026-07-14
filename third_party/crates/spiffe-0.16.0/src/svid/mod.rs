//! X.509-SVID and JWT-SVID types.

use std::error::Error;
use std::sync::Arc;

#[cfg(feature = "jwt")]
pub mod jwt;
#[cfg(feature = "x509")]
pub mod x509;

/// Represents a source of SVIDs.
///
/// This trait returns an `Arc` to avoid forcing either:
/// - cloning large SVID structs, or
/// - exposing borrowing lifetimes in the public API.
///
/// Implementations are free to internally cache and rotate SVIDs.
pub trait SvidSource {
    /// The type of the SVIDs provided by the source.
    type Item: Send + Sync + 'static;

    /// The error type returned by the source.
    type Error: Error + Send + Sync + 'static;

    /// Returns the current SVID.
    ///
    /// # Errors
    ///
    /// Returns `Self::Error` if the SVID cannot be retrieved.
    fn svid(&self) -> Result<Arc<Self::Item>, Self::Error>;
}
