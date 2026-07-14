//! Internal parsing and validation helpers.

use crate::cert::error::CertificateError;
use crate::cert::Certificate;
use crate::spiffe_id::uri_has_spiffe_scheme;
use crate::SpiffeId;
use x509_parser::certificate::X509Certificate;
use x509_parser::der_parser::oid::Oid;
use x509_parser::error::X509Error;
use x509_parser::extensions::ParsedExtension;
use x509_parser::nom::Err;
use x509_parser::oid_registry;
use x509_parser::prelude::GeneralName;

const MAX_URI_LENGTH: usize = 2048;

/// Maximum number of certificates allowed in a certificate chain.
///
/// This limit prevents `DoS` attacks through excessive memory allocation and processing time.
/// A typical SPIFFE X.509-SVID chain contains 1-3 certificates (leaf + intermediate(s) + optional root).
/// A limit of 16 certificates is conservative and sufficient for legitimate use cases while preventing
/// resource exhaustion attacks from adversarial or malformed inputs.
const MAX_CERT_CHAIN_LENGTH: usize = 16;

/// Takes a concatenated chain of DER-encoded certificates and parses it
/// into a `Vec<Certificate>`.
///
/// # Security
///
/// Enforces a maximum chain length to prevent `DoS` attacks through
/// excessive memory allocation. See [`MAX_CERT_CHAIN_LENGTH`] for details.
///
/// **Note**: Intended for parsing certificate chains (e.g., X.509-SVID chains).
/// For parsing X.509 bundles, use [`to_certificate_vec_unbounded`] instead, as bundles
/// may legitimately contain many certificates.
pub(crate) fn to_certificate_vec(
    cert_chain_der: &[u8],
) -> Result<Vec<Certificate>, CertificateError> {
    let mut rest = cert_chain_der;
    let mut certs = Vec::new();

    while !rest.is_empty() {
        // Enforce maximum chain length before parsing to prevent resource exhaustion.
        if certs.len() >= MAX_CERT_CHAIN_LENGTH {
            return Err(CertificateError::TooManyCertificates {
                max: MAX_CERT_CHAIN_LENGTH,
            });
        }

        let (new_rest, cert) = x509_parser::parse_x509_certificate(rest).map_err(|e| match e {
            Err::Incomplete(_) => {
                CertificateError::ParseX509Certificate(X509Error::InvalidCertificate)
            }
            Err::Error(err) | Err::Failure(err) => CertificateError::ParseX509Certificate(err),
        })?;

        // Validate and store the original DER bytes
        certs.push(cert.into());

        rest = new_rest;
    }

    Ok(certs)
}

/// Takes a concatenated list of DER-encoded certificates and parses it
/// into a `Vec<Certificate>` without enforcing a maximum length limit.
///
/// Intended for parsing X.509 bundles, which may legitimately
/// contain many trust anchors. For certificate chains (e.g., X.509-SVID
/// chains), use [`to_certificate_vec`] instead, which enforces a length limit.
///
/// **Note**: Intentionally unbounded. Callers must enforce
/// input limits (e.g., via resource limits or size checks) if needed to prevent
/// resource exhaustion from adversarial inputs.
pub(crate) fn to_certificate_vec_unbounded(
    cert_list_der: &[u8],
) -> Result<Vec<Certificate>, CertificateError> {
    let mut rest = cert_list_der;
    let mut certs = Vec::new();

    while !rest.is_empty() {
        let (new_rest, cert) = x509_parser::parse_x509_certificate(rest).map_err(|e| match e {
            Err::Incomplete(_) => {
                CertificateError::ParseX509Certificate(X509Error::InvalidCertificate)
            }
            Err::Error(err) | Err::Failure(err) => CertificateError::ParseX509Certificate(err),
        })?;

        // Validate and store the original DER bytes
        certs.push(cert.into());

        rest = new_rest;
    }

    Ok(certs)
}

/// Parses the given DER-encoded bytes as a single X.509 certificate.
///
/// The input must contain exactly one DER-encoded certificate with no trailing
/// bytes. Any data after the parsed certificate is rejected as invalid.
///
/// Returns a [`CertificateError`] if the input is not a parseable DER-encoded
/// X.509 certificate or contains trailing bytes.
pub(crate) fn parse_der_encoded_bytes_as_x509_certificate(
    der_bytes: &[u8],
) -> Result<X509Certificate<'_>, CertificateError> {
    match x509_parser::parse_x509_certificate(der_bytes) {
        Ok((rest, cert)) => {
            if !rest.is_empty() {
                return Err(CertificateError::ParseX509Certificate(
                    X509Error::InvalidCertificate,
                ));
            }
            Ok(cert)
        }
        Err(Err::Incomplete(_)) => Err(CertificateError::ParseX509Certificate(
            X509Error::InvalidCertificate,
        )),
        Err(Err::Error(e) | Err::Failure(e)) => Err(CertificateError::ParseX509Certificate(e)),
    }
}

/// Returns the parsed X.509 extension for the provided OID.
///
/// # Errors
/// - [`CertificateError::MissingX509Extension`] if the extension is not present.
/// - [`CertificateError::ParseX509Certificate`] for underlying parsing issues.
pub(crate) fn get_x509_extension<'a>(
    cert: &'a X509Certificate<'_>,
    oid: &Oid<'static>,
) -> Result<&'a ParsedExtension<'a>, CertificateError> {
    match cert.tbs_certificate.get_extension_unique(oid)? {
        None => Err(CertificateError::MissingX509Extension(oid.clone())),
        Some(ext) => Ok(ext.parsed_extension()),
    }
}

pub(crate) fn extract_spiffe_ids_from_uri_san(
    cert: &X509Certificate<'_>,
) -> Result<Vec<SpiffeId>, CertificateError> {
    let ext = get_x509_extension(cert, &oid_registry::OID_X509_EXT_SUBJECT_ALT_NAME)?;

    let san = match ext {
        ParsedExtension::SubjectAlternativeName(s) => s,
        other => return Err(CertificateError::UnexpectedExtension(format!("{other:?}"))),
    };

    // Conservative preallocation. Usually 0–1 in practice.
    let mut ids = Vec::new();

    let mut uri_count = 0usize;
    for name in &san.general_names {
        let uri = match name {
            GeneralName::URI(u) => *u,
            _ => continue,
        };

        uri_count += 1;
        // X.509-SVID leaf certificates must contain exactly one URI SAN entry.
        // Reject early as soon as a second URI SAN appears, regardless of scheme.
        if uri_count > 1 {
            return Err(CertificateError::MultipleUriSanEntries);
        }

        if uri.len() > MAX_URI_LENGTH {
            return Err(CertificateError::OversizedUriSan {
                max: MAX_URI_LENGTH,
            });
        }

        if !uri_has_spiffe_scheme(uri) {
            continue;
        }

        // Strict: any SPIFFE-scheme URI must parse as a valid SPIFFE ID.
        ids.push(SpiffeId::new(uri)?);
    }

    Ok(ids)
}
