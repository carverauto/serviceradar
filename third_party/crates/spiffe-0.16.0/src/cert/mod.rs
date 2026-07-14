//! `Certificate` and `PrivateKey` types and helpers.
//!
//! These types wrap DER-encoded bytes and validate them at construction time.

use crate::cert::error::{CertificateError, PrivateKeyError};
use crate::cert::parsing::{
    extract_spiffe_ids_from_uri_san, parse_der_encoded_bytes_as_x509_certificate,
};
use crate::SpiffeId;
use pkcs8::PrivateKeyInfo;
use x509_parser::certificate::X509Certificate;
use zeroize::Zeroize;

pub mod error;
pub(crate) mod parsing;

/// A single DER-encoded X.509 certificate.
///
/// Invariant: instances are always validated as parseable DER-encoded X.509.
#[derive(Debug, Clone, Eq, PartialEq)]
pub struct Certificate(Vec<u8>);

impl Certificate {
    /// Returns the certificate bytes.
    pub fn as_bytes(&self) -> &[u8] {
        &self.0
    }

    /// Extracts the SPIFFE ID from the certificate's URI SAN.
    ///
    /// This requires the certificate to contain **exactly one** URI SAN that parses
    /// as a SPIFFE ID.
    ///
    /// # Errors
    /// - [`CertificateError::MissingSpiffeId`] if no SPIFFE ID is present in the URI SAN.
    /// - [`CertificateError::MultipleUriSanEntries`] if the certificate contains multiple URI SAN entries.
    /// - [`CertificateError::OversizedUriSan`] if a URI SAN exceeds the maximum allowed length.
    /// - [`CertificateError::ParseX509Certificate`] for parsing errors.
    pub fn spiffe_id(&self) -> Result<SpiffeId, CertificateError> {
        let x509 = parse_der_encoded_bytes_as_x509_certificate(self.as_bytes())?;
        extract_single_spiffe_id_from_uri_san(&x509)
    }
}

impl AsRef<[u8]> for Certificate {
    fn as_ref(&self) -> &[u8] {
        &self.0
    }
}

impl From<X509Certificate<'_>> for Certificate {
    fn from(cert: X509Certificate<'_>) -> Self {
        Self(cert.as_raw().to_vec())
    }
}

impl TryFrom<&[u8]> for Certificate {
    type Error = CertificateError;

    fn try_from(der_bytes: &[u8]) -> Result<Self, Self::Error> {
        parse_der_encoded_bytes_as_x509_certificate(der_bytes)?;
        Ok(Self(Vec::from(der_bytes)))
    }
}

impl TryFrom<Vec<u8>> for Certificate {
    type Error = CertificateError;

    fn try_from(der_bytes: Vec<u8>) -> Result<Self, Self::Error> {
        parse_der_encoded_bytes_as_x509_certificate(&der_bytes)?;
        Ok(Self(der_bytes))
    }
}

/// A DER-encoded private key in PKCS#8 format.
///
/// Invariant: instances are always validated as parseable PKCS#8.
///
/// This type is zeroized on drop.
#[derive(Clone, Eq, PartialEq, Zeroize)]
#[zeroize(drop)]
pub struct PrivateKey(Vec<u8>);

impl PrivateKey {
    /// Returns the private key bytes.
    pub fn as_bytes(&self) -> &[u8] {
        &self.0
    }
}

impl AsRef<[u8]> for PrivateKey {
    fn as_ref(&self) -> &[u8] {
        &self.0
    }
}

impl TryFrom<&[u8]> for PrivateKey {
    type Error = PrivateKeyError;

    fn try_from(bytes: &[u8]) -> Result<Self, Self::Error> {
        // Validate that the bytes are a valid PKCS#8 private key.
        PrivateKeyInfo::try_from(bytes).map_err(PrivateKeyError::DecodePkcs8)?;
        Ok(Self(Vec::from(bytes)))
    }
}

impl TryFrom<Vec<u8>> for PrivateKey {
    type Error = PrivateKeyError;

    fn try_from(bytes: Vec<u8>) -> Result<Self, Self::Error> {
        // Validate that the bytes are a valid PKCS#8 private key.
        PrivateKeyInfo::try_from(bytes.as_slice()).map_err(PrivateKeyError::DecodePkcs8)?;
        Ok(Self(bytes))
    }
}

impl std::fmt::Debug for PrivateKey {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("PrivateKey")
            .field("len", &self.0.len())
            .finish()
    }
}

/// Extracts a SPIFFE ID from a DER-encoded X.509 certificate.
///
/// This requires the certificate to contain **exactly one** URI SAN that parses
/// as a SPIFFE ID.
///
/// # Errors
/// - [`CertificateError::MissingSpiffeId`] if no SPIFFE ID is present in the URI SAN.
/// - [`CertificateError::MultipleUriSanEntries`] if the certificate contains multiple URI SAN entries.
/// - [`CertificateError::OversizedUriSan`] if a URI SAN exceeds the maximum allowed length.
/// - [`CertificateError::ParseX509Certificate`] for parsing errors.
pub fn spiffe_id_from_der(der: &[u8]) -> Result<SpiffeId, CertificateError> {
    let x509 = parse_der_encoded_bytes_as_x509_certificate(der)?;
    extract_single_spiffe_id_from_uri_san(&x509)
}

pub(crate) fn extract_single_spiffe_id_from_uri_san(
    cert: &X509Certificate<'_>,
) -> Result<SpiffeId, CertificateError> {
    let mut ids = extract_spiffe_ids_from_uri_san(cert)?.into_iter();

    let Some(first) = ids.next() else {
        return Err(CertificateError::MissingSpiffeId);
    };
    if ids.next().is_some() {
        return Err(CertificateError::MultipleSpiffeIds);
    }

    Ok(first)
}
