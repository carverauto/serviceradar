use crate::cri_attributes::*;
use crate::error::{X509Error, X509Result};
use crate::extensions::*;
use crate::x509::{
    parse_signature_value, AlgorithmIdentifier, SubjectPublicKeyInfo, X509Name, X509Version,
};

#[cfg(any(feature = "verify", feature = "verify-aws"))]
use crate::verify::verify_signature;
use asn1_rs::{BitString, FromDer};
use der_parser::der::*;
use der_parser::*;
use nom::Offset;
use std::collections::HashMap;

/// Certification Signing Request (CSR)
#[derive(Debug, PartialEq)]
pub struct X509CertificationRequest<'a> {
    pub certification_request_info: X509CertificationRequestInfo<'a>,
    pub signature_algorithm: AlgorithmIdentifier<'a>,
    pub signature_value: BitString<'a>,

    /// Complete raw ASN.1 DER content (request info, signature algorithm and signature).
    pub(crate) raw: &'a [u8],
}

impl<'a> X509CertificationRequest<'a> {
    /// Return the raw ASN.1 DER content of the complete signed certification request that was parsed.
    ///
    /// This includes the certification request info, the signature algorithm, and the signature.
    ///
    /// We avoid the `AsRef` trait in this instance to ensure the full lifetime of the `X509CertificationRequest` is used.
    pub fn as_raw(&self) -> &'a [u8] {
        self.raw
    }

    pub fn requested_extensions(&self) -> Option<impl Iterator<Item = &ParsedExtension<'_>>> {
        self.certification_request_info
            .iter_attributes()
            .find_map(|attr| {
                if let ParsedCriAttribute::ExtensionRequest(requested) = &attr.parsed_attribute {
                    Some(requested.extensions.iter().map(|ext| &ext.parsed_extension))
                } else {
                    None
                }
            })
    }

    /// Verify the cryptographic signature of this certification request
    ///
    /// Uses the public key contained in the CSR, which must be the one of the entity
    /// requesting the certification for this verification to succeed.
    #[cfg(any(feature = "verify", feature = "verify-aws"))]
    #[cfg_attr(docsrs, doc(cfg(any(feature = "verify", feature = "verify-aws"))))]
    pub fn verify_signature(&self) -> Result<(), X509Error> {
        let spki = &self.certification_request_info.subject_pki;
        verify_signature(
            spki,
            &self.signature_algorithm,
            &self.signature_value,
            self.certification_request_info.raw,
        )
    }
}

impl<'a> AsRef<[u8]> for X509CertificationRequest<'a> {
    fn as_ref(&self) -> &[u8] {
        self.as_raw()
    }
}

/// <pre>
/// CertificationRequest ::= SEQUENCE {
///     certificationRequestInfo CertificationRequestInfo,
///     signatureAlgorithm AlgorithmIdentifier{{ SignatureAlgorithms }},
///     signature          BIT STRING
/// }
/// </pre>
impl<'a> FromDer<'a, X509Error> for X509CertificationRequest<'a> {
    fn from_der(i: &'a [u8]) -> X509Result<'a, Self> {
        let start_i = i;
        let (rem, mut req) = parse_der_sequence_defined_g(|i, _| {
            let (i, certification_request_info) = X509CertificationRequestInfo::from_der(i)?;
            let (i, signature_algorithm) = AlgorithmIdentifier::from_der(i)?;
            let (i, signature_value) = parse_signature_value(i)?;
            let cert = X509CertificationRequest {
                certification_request_info,
                signature_algorithm,
                signature_value,
                raw: &[],
            };
            Ok((i, cert))
        })(i)?;
        let len = start_i.offset(rem);
        req.raw = &start_i[..len];
        Ok((rem, req))
    }
}

/// Certification Request Info structure
///
/// Certification request information is defined by the following ASN.1 structure:
///
/// <pre>
/// CertificationRequestInfo ::= SEQUENCE {
///      version       INTEGER { v1(0) } (v1,...),
///      subject       Name,
///      subjectPKInfo SubjectPublicKeyInfo{{ PKInfoAlgorithms }},
///      attributes    [0] Attributes{{ CRIAttributes }}
/// }
/// </pre>
///
/// version is the version number; subject is the distinguished name of the certificate
/// subject; subject_pki contains information about the public key being certified, and
/// attributes is a collection of attributes providing additional information about the
/// subject of the certificate.
#[derive(Debug, PartialEq)]
pub struct X509CertificationRequestInfo<'a> {
    pub version: X509Version,
    pub subject: X509Name<'a>,
    pub subject_pki: SubjectPublicKeyInfo<'a>,
    attributes: Vec<X509CriAttribute<'a>>,
    pub raw: &'a [u8],
}

impl X509CertificationRequestInfo<'_> {
    /// Get the CRL entry extensions.
    #[inline]
    pub fn attributes(&self) -> &[X509CriAttribute<'_>] {
        &self.attributes
    }

    /// Returns an iterator over the CRL entry extensions
    #[inline]
    pub fn iter_attributes(&self) -> impl Iterator<Item = &X509CriAttribute<'_>> {
        self.attributes.iter()
    }

    /// Searches for a CRL entry extension with the given `Oid`.
    ///
    /// Note: if there are several extensions with the same `Oid`, the first one is returned.
    pub fn find_attribute(&self, oid: &Oid) -> Option<&X509CriAttribute<'_>> {
        self.attributes.iter().find(|&ext| ext.oid == *oid)
    }

    /// Builds and returns a map of CRL entry extensions.
    ///
    /// If an extension is present twice, this will fail and return `DuplicateExtensions`.
    pub fn attributes_map(&self) -> Result<HashMap<Oid<'_>, &X509CriAttribute<'_>>, X509Error> {
        self.attributes
            .iter()
            .try_fold(HashMap::new(), |mut m, ext| {
                if m.contains_key(&ext.oid) {
                    return Err(X509Error::DuplicateAttributes);
                }
                m.insert(ext.oid.clone(), ext);
                Ok(m)
            })
    }
}

/// <pre>
/// CertificationRequestInfo ::= SEQUENCE {
///      version       INTEGER { v1(0) } (v1,...),
///      subject       Name,
///      subjectPKInfo SubjectPublicKeyInfo{{ PKInfoAlgorithms }},
///      attributes    [0] Attributes{{ CRIAttributes }}
/// }
/// </pre>
impl<'a> FromDer<'a, X509Error> for X509CertificationRequestInfo<'a> {
    fn from_der(i: &'a [u8]) -> X509Result<'a, Self> {
        let start_i = i;
        parse_der_sequence_defined_g(move |i, _| {
            let (i, version) = X509Version::from_der(i)?;
            let (i, subject) = X509Name::from_der(i)?;
            let (i, subject_pki) = SubjectPublicKeyInfo::from_der(i)?;
            let (i, attributes) = parse_cri_attributes(i)?;
            let len = start_i.offset(i);
            let tbs = X509CertificationRequestInfo {
                version,
                subject,
                subject_pki,
                attributes,
                raw: &start_i[..len],
            };
            Ok((i, tbs))
        })(i)
    }
}
