//! Defines a type that holds all the X.509 materials for a workload (i.e. X.509 SVIDs and bundles)

use crate::constants::DEFAULT_SVID;
use crate::{X509BundleSet, X509Svid};
use std::sync::Arc;

/// Represents all X.509 materials fetched from the Workload API.
///
/// An `X509Context` contains the set of X.509 SVIDs issued to the workload
/// along with the corresponding trust bundles.
#[derive(Debug, Clone, Eq, PartialEq)]
pub struct X509Context {
    svids: Vec<Arc<X509Svid>>,
    bundle_set: Arc<X509BundleSet>,
}

impl X509Context {
    /// Creates a new [`X509Context`].
    ///
    /// The provided SVIDs are collected and stored internally.
    /// The bundle set is shared internally via `Arc`.
    ///
    /// # Examples
    ///
    /// ```no_run
    /// # #[cfg(feature = "x509")]
    /// # fn example() -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    /// use spiffe::{TrustDomain, X509Bundle, X509BundleSet, X509Context, X509Svid};
    /// use std::sync::Arc;
    /// // In practice, you would parse SVIDs from DER:
    /// // let svid = X509Svid::parse_from_der(cert_chain_der, private_key_der)?;
    /// let trust_domain = TrustDomain::new("example.org")?;
    /// let bundle = X509Bundle::new(trust_domain.clone());
    /// let bundle_set = X509BundleSet::new();
    /// let svid = Arc::new(X509Svid::parse_from_der(&[], &[])?);
    /// let context = X509Context::new([svid], bundle_set);
    /// # Ok(())
    /// # }
    /// ```
    #[must_use]
    pub fn new(
        svids: impl IntoIterator<Item = Arc<X509Svid>>,
        bundle_set: impl Into<Arc<X509BundleSet>>,
    ) -> Self {
        Self {
            svids: svids.into_iter().collect(),
            bundle_set: bundle_set.into(),
        }
    }

    /// Returns the default [`X509Svid`], if present.
    ///
    /// The default SVID is the first SVID returned by the Workload API.
    ///
    /// # Examples
    ///
    /// ```no_run
    /// # #[cfg(feature = "x509")]
    /// # fn example() -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    /// use spiffe::{X509Context, X509BundleSet, X509Svid};
    /// use std::sync::Arc;
    /// // In practice, you would get context from WorkloadApiClient:
    /// // let context = client.fetch_x509_context().await?;
    /// let svid = Arc::new(X509Svid::parse_from_der(&[], &[])?);
    /// let context = X509Context::new([svid.clone()], X509BundleSet::new());
    /// if let Some(default_svid) = context.default_svid() {
    ///     println!("Default SVID: {}", default_svid.spiffe_id());
    /// }
    /// # Ok(())
    /// # }
    /// ```
    pub fn default_svid(&self) -> Option<&Arc<X509Svid>> {
        self.svids.get(DEFAULT_SVID)
    }

    /// Returns all X.509 SVIDs in this context.
    ///
    /// # Examples
    ///
    /// ```no_run
    /// # #[cfg(feature = "x509")]
    /// # fn example() -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    /// use spiffe::{X509Context, X509BundleSet, X509Svid};
    /// use std::sync::Arc;
    /// // In practice, you would get context from WorkloadApiClient:
    /// // let context = client.fetch_x509_context().await?;
    /// let svid = Arc::new(X509Svid::parse_from_der(&[], &[])?);
    /// let context = X509Context::new([svid.clone()], X509BundleSet::new());
    /// for svid in context.svids() {
    ///     println!("SVID: {}", svid.spiffe_id());
    ///     if let Some(hint) = svid.hint() {
    ///         println!("  Hint: {}", hint);
    ///     }
    /// }
    /// # Ok(())
    /// # }
    /// ```
    pub const fn svids(&self) -> &[Arc<X509Svid>] {
        self.svids.as_slice()
    }

    /// Returns the set of X.509 bundles associated with this context.
    ///
    /// # Examples
    ///
    /// ```no_run
    /// # #[cfg(feature = "x509")]
    /// # fn example() -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    /// use spiffe::{TrustDomain, X509Context, X509BundleSet, X509Svid};
    /// use std::sync::Arc;
    /// // In practice, you would get context from WorkloadApiClient:
    /// // let context = client.fetch_x509_context().await?;
    /// let svid = Arc::new(X509Svid::parse_from_der(&[], &[])?);
    /// let context = X509Context::new([svid], X509BundleSet::new());
    /// let bundle_set = context.bundle_set();
    /// let trust_domain = TrustDomain::new("example.org")?;
    /// if let Some(bundle) = bundle_set.get(&trust_domain) {
    ///     println!("Bundle has {} authorities", bundle.authorities().len());
    /// }
    /// # Ok(())
    /// # }
    /// ```
    pub const fn bundle_set(&self) -> &Arc<X509BundleSet> {
        &self.bundle_set
    }
}
