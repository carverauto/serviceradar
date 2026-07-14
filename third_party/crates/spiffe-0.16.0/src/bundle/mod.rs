//! X.509 bundle and JWT bundle types.

use crate::spiffe_id::TrustDomain;
use std::error::Error;
use std::sync::Arc;

#[cfg(feature = "jwt")]
pub mod jwt;
#[cfg(feature = "x509")]
pub mod x509;

/// Represents a source of bundles queryable by [`TrustDomain`].
pub trait BundleSource {
    /// The bundle type provided by the source.
    type Item: Send + Sync + 'static;

    /// The error type returned by the source.
    type Error: Error + Send + Sync + 'static;

    /// Returns the bundle associated with the given [`TrustDomain`].
    ///
    /// If no bundle is associated with the trust domain, returns `Ok(None)`.
    ///
    /// # Errors
    ///
    /// Returns `Err(Self::Error)` if the bundle cannot be retrieved from the underlying source.
    fn bundle_for_trust_domain(
        &self,
        trust_domain: &TrustDomain,
    ) -> Result<Option<Arc<Self::Item>>, Self::Error>;
}
