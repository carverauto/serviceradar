//! Error types for certificate and private key parsing/validation.

use crate::SpiffeIdError;
use x509_parser::asn1_rs::Oid;
use x509_parser::error::X509Error;

/// An error that may arise parsing and validating X.509 certificates.
#[derive(Debug, thiserror::Error, PartialEq)]
#[non_exhaustive]
pub enum CertificateError {
    /// An X.509 extension cannot be found.
    #[error("X.509 extension is missing: {0}")]
    MissingX509Extension(Oid<'static>),

    /// Unexpected X.509 extension encountered.
    #[error("unexpected X.509 extension: {0}")]
    UnexpectedExtension(String),

    /// Error returned by the X.509 parsing library.
    #[error("failed parsing X.509 certificate")]
    ParseX509Certificate(#[from] X509Error),

    /// The certificate does not contain any URI SAN that is a SPIFFE ID.
    #[error("certificate is missing SPIFFE ID in URI SAN")]
    MissingSpiffeId,

    /// The certificate contains more than one URI SAN entry.
    ///
    /// X.509-SVID validation requires exactly one URI SAN entry that carries the
    /// SPIFFE ID.
    #[error("certificate contains multiple URI SAN entries")]
    MultipleUriSanEntries,

    /// A URI SAN exceeds the maximum length processed by this library.
    #[error("URI SAN exceeds maximum length ({max} bytes)")]
    OversizedUriSan {
        /// Maximum URI SAN length in bytes (inclusive).
        max: usize,
    },

    /// The certificate contains more than one URI SAN that parses as a SPIFFE ID.
    ///
    /// Kept for compatibility with callers that match this variant specifically.
    #[error("certificate contains multiple SPIFFE IDs in URI SAN")]
    MultipleSpiffeIds,

    /// The certificate has too many URI SAN entries to process safely.
    #[error("certificate has too many URI SAN entries (max {max})")]
    TooManyUriSanEntries {
        /// Maximum number of URI SAN entries that will be inspected before aborting.
        ///
        /// This bound exists to prevent excessive resource usage when processing
        /// malformed or adversarial certificates.
        max: usize,
    },

    /// The certificate chain has too many certificates to process safely.
    #[error("certificate chain has too many certificates (max {max})")]
    TooManyCertificates {
        /// Maximum number of certificates that will be parsed before aborting.
        ///
        /// This bound exists to prevent excessive memory allocation and processing time
        /// when processing malformed or adversarial certificate chains.
        max: usize,
    },

    /// A URI SAN looked like a candidate but failed SPIFFE ID parsing.
    #[error("failed to parse SPIFFE ID from URI SAN: {0}")]
    InvalidSpiffeId(#[from] SpiffeIdError),
}

/// An error that may arise decoding private keys.
#[derive(Debug, thiserror::Error, PartialEq)]
#[non_exhaustive]
pub enum PrivateKeyError {
    /// Error returned by the pkcs#8 private key decoding library.
    #[error("failed decoding PKCS#8 private key")]
    DecodePkcs8(pkcs8::Error),
}
