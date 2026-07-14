//! X.509-SVID types.

mod validations;

use crate::cert::error::{CertificateError, PrivateKeyError};
use crate::cert::parsing::to_certificate_vec;
use crate::cert::{Certificate, PrivateKey};
use crate::spiffe_id::SpiffeId;
use crate::svid::x509::validations::{validate_leaf_certificate, validate_signing_certificates};
use std::convert::TryFrom as _;
use std::sync::Arc;

use self::chain::CertificateChain;

/// Represents a SPIFFE X.509-SVID.
///
/// Contains a [`SpiffeId`], a certificate chain as DER-encoded X.509 certificates,
/// and a private key as DER-encoded PKCS#8.
///
/// Use [`X509Svid::parse_from_der`] to create an SVID from DER-encoded data, or
/// obtain one from the [Workload API](crate::WorkloadApiClient) or [`X509Source`].
#[derive(Debug, Clone, Eq, PartialEq)]
pub struct X509Svid {
    spiffe_id: SpiffeId,
    cert_chain: CertificateChain,
    private_key: PrivateKey,
    expiry_unix: i64,
    hint: Option<Arc<str>>,
}

/// Errors that may arise parsing a [`X509Svid`] from a DER-encoded
/// chain of certificates and private key.
#[derive(Debug, thiserror::Error, PartialEq)]
#[non_exhaustive]
pub enum X509SvidError {
    /// The chain of certificates is empty.
    #[error("no certificates found in chain")]
    EmptyChain,

    /// 'CA' flag not allowed in leaf certificate.
    #[error("leaf certificate must not have CA flag set to true")]
    LeafCertificateHasCaFlag,

    /// 'cRLSign' not allowed as key usage in leaf certificate.
    #[error("leaf certificate must not have 'cRLSign' set as key usage")]
    LeafCertificateHasCrlSign,

    /// 'keyCertSign' not allowed as key usage in leaf certificate.
    #[error("leaf certificate must not have 'keyCertSign' set as key usage")]
    LeafCertificateHasKeyCertSign,

    /// 'digitalSignature' as key usage must be present in leaf certificate.
    #[error("leaf certificate must have 'digitalSignature' set as key usage")]
    LeafCertificateMissingDigitalSignature,

    /// 'CA' flag must be set in intermediate certificate.
    #[error("signing certificate must have CA flag set to true")]
    SigningCertificateMissingCaFlag,

    /// 'keyCertSign' as key usage must be present in intermediate certificate.
    #[error("signing certificate must have 'keyCertSign' set as key usage")]
    SigningCertificateMissingKeyCertSign,

    /// Extension is present but could not be parsed.
    #[error("{extension} extension is present but could not be parsed")]
    UnparseableExtension {
        /// The name of the extension that failed to parse.
        extension: &'static str,
    },

    /// Error processing or validating the X.509 certificates.
    #[error(transparent)]
    Certificate(#[from] CertificateError),

    /// The leaf certificate's SPIFFE ID must contain a non-root path component.
    ///
    /// Per the X.509-SVID specification, leaf SVIDs MUST NOT use a bare trust
    /// domain SPIFFE ID (e.g. `spiffe://example.org`) and instead MUST include
    /// at least one path segment.
    #[error("leaf certificate SPIFFE ID must have a non-root path component")]
    LeafSpiffeIdMissingPath,

    /// Error processing the private key.
    #[error(transparent)]
    PrivateKey(#[from] PrivateKeyError),
}

impl X509Svid {
    /// Creates a `X509Svid` from certificate chain and private key DER-encoded data.
    ///
    /// # Arguments
    /// * `cert_chain_der` - DER-encoded (concatenated) certificate chain (no padding between certs).
    /// * `private_key_der` - DER-encoded PKCS#8 private key.
    ///
    /// # Errors
    /// Returns [`X509SvidError`] if parsing or validation fails.
    pub fn parse_from_der(
        cert_chain_der: &[u8],
        private_key_der: &[u8],
    ) -> Result<Self, X509SvidError> {
        Self::parse_from_der_with_hint(cert_chain_der, private_key_der, None)
    }

    /// Creates a [`X509Svid`] from a certificate chain and private key, with an optional usage hint.
    ///
    /// The `hint` is an operator-provided string supplied by the SPIFFE Workload API
    /// to convey guidance on how the SVID should be used when multiple SVIDs are
    /// available (e.g. `"internal"`, `"external"`). The hint is optional and may be
    /// absent.
    ///
    /// # Arguments
    ///
    /// * `cert_chain_der` - DER-encoded (concatenated) X.509 certificate chain
    ///   (no padding between certificates).
    /// * `private_key_der` - DER-encoded PKCS#8 private key.
    /// * `hint` - Optional usage hint associated with this SVID.
    ///
    /// # Errors
    ///
    /// Returns [`X509SvidError`] if parsing or validation of the certificate chain
    /// or private key fails.
    pub fn parse_from_der_with_hint(
        cert_chain_der: &[u8],
        private_key_der: &[u8],
        hint: Option<Arc<str>>,
    ) -> Result<Self, X509SvidError> {
        let cert_chain = CertificateChain::try_from_vec(to_certificate_vec(cert_chain_der)?)?;

        let (spiffe_id, expiry_unix) = validate_leaf_certificate(cert_chain.leaf())?;
        validate_signing_certificates(cert_chain.intermediates())?;
        let private_key = PrivateKey::try_from(private_key_der)?;

        Ok(Self {
            spiffe_id,
            cert_chain,
            private_key,
            expiry_unix,
            hint,
        })
    }

    /// Returns the [`SpiffeId`] of the `X509Svid`.
    pub const fn spiffe_id(&self) -> &SpiffeId {
        &self.spiffe_id
    }

    /// Returns the certificate chain. The first certificate is the leaf certificate.
    pub fn cert_chain(&self) -> &[Certificate] {
        self.cert_chain.as_slice()
    }

    /// Returns the leaf certificate.
    pub const fn leaf(&self) -> &Certificate {
        self.cert_chain.leaf()
    }

    /// Returns the private key.
    pub const fn private_key(&self) -> &PrivateKey {
        &self.private_key
    }

    #[cfg(feature = "x509-source")]
    pub(crate) const fn expiry_unix(&self) -> i64 {
        self.expiry_unix
    }

    /// Returns the optional hint provided by the Workload API.
    pub fn hint(&self) -> Option<&str> {
        self.hint.as_deref()
    }
}

mod chain {
    use crate::cert::Certificate;
    use crate::svid::x509::X509SvidError;

    /// An ordered X.509 certificate chain with a guaranteed leaf certificate.
    ///
    /// The first certificate is the leaf and any remaining certificates are
    /// intermediates. Construction rejects empty chains, so callers can access
    /// the leaf without a panic path.
    #[derive(Debug, Clone, Eq, PartialEq)]
    pub(super) struct CertificateChain {
        leaf: Certificate,
        certs: Vec<Certificate>,
    }

    impl CertificateChain {
        pub(super) fn try_from_vec(certs: Vec<Certificate>) -> Result<Self, X509SvidError> {
            let Some(leaf) = certs.first().cloned() else {
                return Err(X509SvidError::EmptyChain);
            };

            Ok(Self { leaf, certs })
        }

        pub(super) const fn leaf(&self) -> &Certificate {
            &self.leaf
        }

        pub(super) fn intermediates(&self) -> &[Certificate] {
            match self.certs.split_first() {
                Some((_, intermediates)) => intermediates,
                None => &[],
            }
        }

        pub(super) fn as_slice(&self) -> &[Certificate] {
            &self.certs
        }
    }
}
