use crate::cert::parsing::{get_x509_extension, parse_der_encoded_bytes_as_x509_certificate};
use crate::cert::{extract_single_spiffe_id_from_uri_san, Certificate};
use crate::spiffe_id::SpiffeId;
use crate::svid::x509::X509SvidError;
use x509_parser::certificate::X509Certificate;
use x509_parser::extensions::ParsedExtension;
use x509_parser::oid_registry;

/// Parses `cert` as X.509, validates it as an X.509-SVID leaf,
/// and returns the [`SpiffeId`] from the URI SAN and leaf expiry.
pub(crate) fn validate_leaf_certificate(
    cert: &Certificate,
) -> Result<(SpiffeId, i64), X509SvidError> {
    let x509 = parse_der_encoded_bytes_as_x509_certificate(cert.as_bytes())?;
    validate_x509_leaf_certificate(&x509)?;
    let spiffe_id = extract_single_spiffe_id_from_uri_san(&x509)?;

    if spiffe_id.path().is_empty() {
        return Err(X509SvidError::LeafSpiffeIdMissingPath);
    }

    Ok((spiffe_id, x509.validity().not_after.timestamp()))
}

/// Parses and validates `certs` as signing certificates.
pub(crate) fn validate_signing_certificates(certs: &[Certificate]) -> Result<(), X509SvidError> {
    for cert in certs {
        let x509 = parse_der_encoded_bytes_as_x509_certificate(cert.as_bytes())?;
        validate_signing_certificate(&x509)?;
    }
    Ok(())
}

fn validate_x509_leaf_certificate(cert: &X509Certificate<'_>) -> Result<(), X509SvidError> {
    validate_leaf_certificate_key_usage(cert)?;

    let basic_constraints =
        get_x509_extension(cert, &oid_registry::OID_X509_EXT_BASIC_CONSTRAINTS)?;
    match basic_constraints {
        ParsedExtension::BasicConstraints(b) if b.ca => {
            Err(X509SvidError::LeafCertificateHasCaFlag)
        }
        ParsedExtension::BasicConstraints(_) => Ok(()),
        // Extension OID is present but content could not be parsed.
        // Reject to prevent bypassing validation via malformed extensions.
        _ => Err(X509SvidError::UnparseableExtension {
            extension: "BasicConstraints",
        }),
    }
}

fn validate_signing_certificate(cert: &X509Certificate<'_>) -> Result<(), X509SvidError> {
    let basic_constraints =
        get_x509_extension(cert, &oid_registry::OID_X509_EXT_BASIC_CONSTRAINTS)?;
    match basic_constraints {
        ParsedExtension::BasicConstraints(b) if b.ca => {}
        ParsedExtension::BasicConstraints(_) => {
            return Err(X509SvidError::SigningCertificateMissingCaFlag);
        }
        // Extension OID is present but content could not be parsed.
        // Reject to prevent bypassing validation via malformed extensions.
        _ => {
            return Err(X509SvidError::UnparseableExtension {
                extension: "BasicConstraints",
            });
        }
    }

    let key_usage = get_x509_extension(cert, &oid_registry::OID_X509_EXT_KEY_USAGE)?;
    match key_usage {
        ParsedExtension::KeyUsage(k) if k.key_cert_sign() => {}
        ParsedExtension::KeyUsage(_) => {
            return Err(X509SvidError::SigningCertificateMissingKeyCertSign);
        }
        // Extension OID is present but content could not be parsed.
        // Reject to prevent bypassing validation via malformed extensions.
        _ => {
            return Err(X509SvidError::UnparseableExtension {
                extension: "KeyUsage",
            });
        }
    }

    Ok(())
}

fn validate_leaf_certificate_key_usage(cert: &X509Certificate<'_>) -> Result<(), X509SvidError> {
    let key_usage = get_x509_extension(cert, &oid_registry::OID_X509_EXT_KEY_USAGE)?;
    match key_usage {
        ParsedExtension::KeyUsage(k) if !k.digital_signature() => {
            Err(X509SvidError::LeafCertificateMissingDigitalSignature)
        }
        ParsedExtension::KeyUsage(k) if k.crl_sign() => {
            Err(X509SvidError::LeafCertificateHasCrlSign)
        }
        ParsedExtension::KeyUsage(k) if k.key_cert_sign() => {
            Err(X509SvidError::LeafCertificateHasKeyCertSign)
        }
        ParsedExtension::KeyUsage(_) => Ok(()),
        // Extension OID is present but content could not be parsed.
        // Reject to prevent bypassing validation via malformed extensions.
        _ => Err(X509SvidError::UnparseableExtension {
            extension: "KeyUsage",
        }),
    }
}
