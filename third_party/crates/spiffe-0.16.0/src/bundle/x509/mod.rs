//! X.509 bundle types.

use crate::bundle::BundleSource;
use crate::cert::error::CertificateError;
use crate::cert::parsing::to_certificate_vec_unbounded;
use crate::cert::Certificate;
use crate::spiffe_id::TrustDomain;
use std::collections::BTreeMap;
use std::convert::Infallible;
use std::sync::Arc;

/// Contains a collection of trusted X.509 authorities for a [`TrustDomain`].
///
/// X.509 bundles are used to verify the signatures of [`X509Svid`] certificates.
/// Obtain bundles from the [Workload API](crate::WorkloadApiClient) or [`X509Source`].
#[derive(Debug, Clone, Eq, PartialEq)]
pub struct X509Bundle {
    trust_domain: TrustDomain,
    x509_authorities: Vec<Certificate>,
}

/// Contains a set of [`X509Bundle`], keyed by [`TrustDomain`].
#[derive(Debug, Clone, Eq, PartialEq)]
pub struct X509BundleSet {
    bundles: BTreeMap<TrustDomain, Arc<X509Bundle>>,
}

/// An error that can arise trying to parse a [`X509Bundle`] from bytes
/// representing DER-encoded X.509 authorities.
#[derive(Debug, thiserror::Error, PartialEq)]
#[non_exhaustive]
pub enum X509BundleError {
    /// Error processing or validating the X.509 certificates in the bundle.
    #[error(transparent)]
    Certificate(#[from] CertificateError),
}

impl X509Bundle {
    /// Creates an empty `X509Bundle` for the given [`TrustDomain`].
    ///
    /// # Examples
    ///
    /// ```no_run
    /// use spiffe::{TrustDomain, X509Bundle};
    ///
    /// let trust_domain = TrustDomain::new("example.org")?;
    /// let bundle = X509Bundle::new(trust_domain);
    /// assert!(bundle.authorities().is_empty());
    /// # Ok::<(), Box<dyn std::error::Error>>(())
    /// ```
    pub const fn new(trust_domain: TrustDomain) -> Self {
        Self {
            trust_domain,
            x509_authorities: Vec::new(),
        }
    }

    /// Creates a bundle from a list of DER-encoded X.509 authorities.
    ///
    /// # Errors
    ///
    /// If the function cannot parse the inputs, a [`X509BundleError`] variant will be returned.
    pub fn from_x509_authorities(
        trust_domain: TrustDomain,
        authorities: &[&[u8]],
    ) -> Result<Self, X509BundleError> {
        let x509_authorities = authorities
            .iter()
            .map(|b| Certificate::try_from(*b))
            .collect::<Result<Vec<_>, _>>()?;

        Ok(Self {
            trust_domain,
            x509_authorities,
        })
    }

    /// Parses a bundle from ASN.1 DER-encoded data representing a concatenated list of certificates.
    ///
    /// # Errors
    ///
    /// If the function cannot parse the inputs, a [`X509BundleError`] variant will be returned.
    ///
    /// **Note**: Bundles may contain many trust anchors, and no length limit
    /// is enforced. This differs from certificate chains (e.g., X.509-SVID chains), which
    /// are limited to prevent `DoS` attacks.
    pub fn parse_from_der(
        trust_domain: TrustDomain,
        bundle_der: &[u8],
    ) -> Result<Self, X509BundleError> {
        let x509_authorities = to_certificate_vec_unbounded(bundle_der)?;

        Ok(Self {
            trust_domain,
            x509_authorities,
        })
    }

    /// Adds an X.509 authority as ASN.1 DER-encoded data (binary format)to the bundle.
    /// It verifies that the `authorities_bytes` represents a valid DER-encoded X.509 certificate.
    ///
    /// # Arguments
    ///
    /// * `authority_bytes` - ASN.1 DER-encoded data (binary format) representing a X.509 authority.
    ///
    /// # Errors
    ///
    /// If the function cannot parse the inputs, a [`X509BundleError`] variant will be returned.
    ///
    /// # Examples
    ///
    /// ```no_run
    /// use spiffe::{TrustDomain, X509Bundle};
    /// # // In practice, you would have DER-encoded certificate bytes:
    /// # // let cert_der: &[u8] = /* ... */;
    /// let trust_domain = TrustDomain::new("example.org")?;
    /// let mut bundle = X509Bundle::new(trust_domain);
    /// # let cert_der = &[];
    /// bundle.add_authority(cert_der)?;
    /// assert_eq!(bundle.authorities().len(), 1);
    /// # Ok::<(), Box<dyn std::error::Error>>(())
    /// ```
    pub fn add_authority(&mut self, authority_bytes: &[u8]) -> Result<(), X509BundleError> {
        let certificate = Certificate::try_from(authority_bytes)?;
        self.x509_authorities.push(certificate);
        Ok(())
    }

    /// Returns the [`TrustDomain`] associated with the bundle.
    ///
    /// # Examples
    ///
    /// ```no_run
    /// use spiffe::{TrustDomain, X509Bundle};
    ///
    /// let trust_domain = TrustDomain::new("example.org")?;
    /// let bundle = X509Bundle::new(trust_domain.clone());
    /// assert_eq!(bundle.trust_domain(), &trust_domain);
    /// # Ok::<(), Box<dyn std::error::Error>>(())
    /// ```
    pub const fn trust_domain(&self) -> &TrustDomain {
        &self.trust_domain
    }

    /// Returns the X.509 authorities in the bundle.
    ///
    /// # Examples
    ///
    /// ```no_run
    /// use spiffe::{TrustDomain, X509Bundle};
    /// # // In practice, you would parse from DER-encoded certificates:
    /// # // let bundle = X509Bundle::from_x509_authorities(trust_domain, &[cert1_der, cert2_der])?;
    /// let trust_domain = TrustDomain::new("example.org")?;
    /// let bundle = X509Bundle::new(trust_domain);
    /// for authority in bundle.authorities() {
    ///     // Use authority to verify X.509-SVID signatures
    ///     let _cert_bytes = authority.as_bytes();
    /// }
    /// # Ok::<(), Box<dyn std::error::Error>>(())
    /// ```
    pub fn authorities(&self) -> &[Certificate] {
        &self.x509_authorities
    }
}

impl X509BundleSet {
    /// Creates a new empty `X509BundleSet`.
    ///
    /// # Examples
    ///
    /// ```no_run
    /// use spiffe::{TrustDomain, X509Bundle, X509BundleSet};
    ///
    /// let mut set = X509BundleSet::new();
    /// let trust_domain = TrustDomain::new("example.org")?;
    /// let bundle = X509Bundle::new(trust_domain.clone());
    /// set.add_bundle(bundle);
    /// # Ok::<(), Box<dyn std::error::Error>>(())
    /// ```
    pub const fn new() -> Self {
        Self {
            bundles: BTreeMap::new(),
        }
    }

    /// Adds a new [`X509Bundle`] into the set. If a bundle already exists for the
    /// trust domain, the existing bundle is replaced.
    pub fn add_bundle(&mut self, bundle: X509Bundle) {
        let trust_domain = bundle.trust_domain().clone();
        self.bundles.insert(trust_domain, Arc::new(bundle));
    }

    /// Returns the bundle for a trust domain.
    ///
    /// # Examples
    ///
    /// ```no_run
    /// use spiffe::{TrustDomain, X509Bundle, X509BundleSet};
    ///
    /// let mut set = X509BundleSet::new();
    /// let trust_domain = TrustDomain::new("example.org")?;
    /// let bundle = X509Bundle::new(trust_domain.clone());
    /// set.add_bundle(bundle);
    ///
    /// let retrieved = set.get(&trust_domain);
    /// assert!(retrieved.is_some());
    /// # Ok::<(), Box<dyn std::error::Error>>(())
    /// ```
    pub fn get(&self, trust_domain: &TrustDomain) -> Option<Arc<X509Bundle>> {
        self.bundles.get(trust_domain).cloned()
    }

    /// Returns a reference to the bundle for a trust domain.
    pub fn get_ref(&self, trust_domain: &TrustDomain) -> Option<&Arc<X509Bundle>> {
        self.bundles.get(trust_domain)
    }

    /// Returns an iterator over `(TrustDomain, X509Bundle)` entries.
    ///
    /// # Examples
    ///
    /// ```no_run
    /// use spiffe::{TrustDomain, X509Bundle, X509BundleSet};
    ///
    /// let mut set = X509BundleSet::new();
    /// let td1 = TrustDomain::new("example.org")?;
    /// let td2 = TrustDomain::new("other.org")?;
    /// set.add_bundle(X509Bundle::new(td1.clone()));
    /// set.add_bundle(X509Bundle::new(td2.clone()));
    ///
    /// for (trust_domain, bundle) in set.iter() {
    ///     println!("Bundle for {}: {} authorities", trust_domain, bundle.authorities().len());
    /// }
    /// # Ok::<(), Box<dyn std::error::Error>>(())
    /// ```
    pub fn iter(&self) -> impl Iterator<Item = (&TrustDomain, &Arc<X509Bundle>)> {
        self.bundles.iter()
    }

    /// Returns the number of bundles in the set.
    pub fn len(&self) -> usize {
        self.bundles.len()
    }

    /// Returns `true` if the set contains no bundles.
    pub fn is_empty(&self) -> bool {
        self.bundles.is_empty()
    }

    /// Returns the [`X509Bundle`] associated with the given [`TrustDomain`].
    #[deprecated(since = "0.9.0", note = "Use `X509BundleSet::get` instead.")]
    pub fn bundle_for(&self, trust_domain: &TrustDomain) -> Option<&Arc<X509Bundle>> {
        self.bundles.get(trust_domain)
    }
}

impl Default for X509BundleSet {
    fn default() -> Self {
        Self::new()
    }
}

impl BundleSource for X509BundleSet {
    type Item = X509Bundle;
    type Error = Infallible;

    fn bundle_for_trust_domain(
        &self,
        trust_domain: &TrustDomain,
    ) -> Result<Option<Arc<Self::Item>>, Self::Error> {
        Ok(self.get(trust_domain))
    }
}

impl Extend<X509Bundle> for X509BundleSet {
    fn extend<T: IntoIterator<Item = X509Bundle>>(&mut self, iter: T) {
        for b in iter {
            self.add_bundle(b);
        }
    }
}

impl FromIterator<X509Bundle> for X509BundleSet {
    fn from_iter<T: IntoIterator<Item = X509Bundle>>(iter: T) -> Self {
        let mut set = Self::new();
        set.extend(iter);
        set
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn bundle_set_add_bundle_replaces_existing_for_same_trust_domain() {
        let td = TrustDomain::new("example.org").unwrap();

        let b1 = X509Bundle::new(td.clone());
        let b2 = X509Bundle::new(td.clone());

        let mut set = X509BundleSet::new();
        set.add_bundle(b1);
        assert_eq!(set.len(), 1);

        set.add_bundle(b2);
        assert_eq!(set.len(), 1, "should replace bundle for same trust domain");
        assert!(set.get(&td).is_some());
    }

    #[test]
    fn bundle_set_extend_and_from_iter_work() {
        let td1 = TrustDomain::new("example.org").unwrap();
        let td2 = TrustDomain::new("example2.org").unwrap();

        let b1 = X509Bundle::new(td1);
        let b2 = X509Bundle::new(td2);

        let mut set = X509BundleSet::new();
        set.extend([b1.clone(), b2.clone()]);
        assert_eq!(set.len(), 2);

        let set2: X509BundleSet = [b1, b2].into_iter().collect();
        assert_eq!(set2.len(), 2);
    }

    #[test]
    fn bundle_set_bundle_source_impl_matches_get() {
        let td = TrustDomain::new("example.org").unwrap();
        let b = X509Bundle::new(td.clone());

        let mut set = X509BundleSet::new();
        set.add_bundle(b);

        let via_get = set.get(&td).unwrap();
        let via_trait = set.bundle_for_trust_domain(&td).unwrap().unwrap();

        assert_eq!(via_get, via_trait);
    }
}
