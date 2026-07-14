use asn1_rs::BitString;
use der_parser::num_bigint::BigUint;
use oid_registry::*;

use crate::extensions::*;
use crate::revocation_list::*;
use crate::time::ASN1Time;
use crate::x509::*;

/// Visitor pattern for [`CertificateRevocationList`]
///
/// # Extensions
///
/// Visitor methods are provided for extensions, both in a generic way (receiving a [`X509Extension`]
/// object) and in a specific way for standard extensions (for ex, `visit_extension_aki` receives a
/// [`AuthorityKeyIdentifier`]).
///
/// For a specific method to be called, the extension OID must be correct and the extension must be
/// successfully parsed as the specific type.
///
/// A specific method can be called multiple times, if the extension is present multiple times.
///
/// Extension parsing methods are redundant. This is not a problem because default methods do nothing,
/// but if a trait implementation provides several `visit_extension...` methods it must be aware
/// that it will visit the same extension multiple times.
///
/// # Example
///
/// ```rust
/// use der_parser::num_bigint::BigUint;
/// use x509_parser::prelude::*;
/// use x509_parser::visitor::CertificateRevocationListVisitor;
/// #[derive(Debug, Default)]
/// struct RevokedCertsVisitor {
///     certificates: Vec<BigUint>,
/// }
///
/// impl CertificateRevocationListVisitor for RevokedCertsVisitor {
///     fn visit_revoked_certificate(&mut self, certificate: &RevokedCertificate<'_>) {
///         self.certificates.push(certificate.user_certificate.clone());
///     }
/// }
/// ```
pub trait CertificateRevocationListVisitor {
    /// Run the provided visitor (`self`) over the Certificate Revocation List
    fn walk(&mut self, crl: &CertificateRevocationList)
    where
        Self: Sized,
    {
        crl.walk(self);
    }

    /// Invoked for the "tbsCertList" field of the Certificate Revocation List, before visiting children
    fn visit_tbs_cert_list(&mut self, _tbs: &TbsCertList) {}

    /// Invoked for the "signatureAlgorithm" field of the Certificate Revocation List
    ///
    /// Note: this is the "signatureAlgorithm" in the "CertificateList" sequence. According to the
    /// specifications, it should be equal to "signature" field from the "TBSCertificate" sequence.
    fn visit_signature_algorithm(&mut self, _algorithm: &AlgorithmIdentifier) {}

    /// Invoked for the "signatureValue" field of the TBSCertList
    fn visit_signature_value(&mut self, _signature: &BitString) {}

    /// Invoked for the "version" field of the TBSCertList
    fn visit_version(&mut self, _version: Option<&X509Version>) {}

    /// Invoked for the "signature" field of the TBSCertList
    ///
    /// Note: this is the "signature" field from the "TBSCertList" sequence. According to the
    /// specifications, it should be equal to "signatureAlgorithm" in the "CertificateList" sequence.
    fn visit_tbs_signature_algorithm(&mut self, _algorithm: &AlgorithmIdentifier) {}

    /// Invoked for the "issuer" field of the TBSCertList
    fn visit_issuer(&mut self, _name: &X509Name) {}

    /// Invoked for the "thisUpdate" field of the TBSCertList
    fn visit_this_update(&mut self, _time: &ASN1Time) {}

    /// Invoked for the "nextUpdate" field of the TBSCertList
    fn visit_next_update(&mut self, _time: Option<&ASN1Time>) {}

    /// Invoked for revoked certificate that appear in the TBSCertList
    fn visit_revoked_certificates(&mut self, _certificate: &[RevokedCertificate]) {}

    /// Invoked for any revoked certificates that appear in the TBSCertList
    ///
    /// Note: this function is redundant with `visit_revoked_certificates`
    fn visit_revoked_certificate(&mut self, _certificate: &RevokedCertificate) {}

    /// Invoked for extensions, before visiting children
    fn pre_visit_extensions(&mut self, _extensions: &[X509Extension]) {}

    /// Invoked for any extension that appear in the TBSCertList
    ///
    /// Note: this method may be redundant with any other extension visitor method
    fn visit_extension(&mut self, _extension: &X509Extension) {}

    /// Invoked for extensions, after visiting children
    fn post_visit_extensions(&mut self, _extensions: &[X509Extension]) {}

    /// Invoked for the "Authority Key Identifier" (if present)
    fn visit_extension_aki(&mut self, _aki: &AuthorityKeyIdentifier) {}

    /// Invoked for the "Issuer Alternative Name" (if present)
    fn visit_extension_issuer_alternative_name(&mut self, _ian: &IssuerAlternativeName) {}

    /// Invoked for the "CRL Number" (if present)
    fn visit_extension_crl_number(&mut self, _number: &BigUint) {}

    /// Invoked for the "Issuing Distribution Point" (if present)
    fn visit_extension_issuing_distribution_point(&mut self, _dp: &IssuingDistributionPoint) {}

    /// Invoked for the "Authority Information Access" (if present)
    fn visit_extension_authority_information_access(&mut self, _info: &AuthorityInfoAccess) {}

    /// Invoked for the "Reason Code" (if present)
    fn visit_extension_reason_code(&mut self, _code: &ReasonCode) {}

    /// Invoked for the "Invalidity Date" (if present)
    fn visit_extension_invalidity_date(&mut self, _time: &ASN1Time) {}

    /// Invoked for the "Signed Certificate Timestamp" (SCT) (if present)
    fn visit_extension_sct(&mut self, _sct: &[SignedCertificateTimestamp]) {}

    /// Invoked for any other extension than the specific (recognized) types
    ///
    /// This can happen for several reasons:
    /// - the parser did not recognize the extension content
    /// - the parser was explicitly asked to not parse extension content
    /// - the extension could be correct (for ex in a CRL), but is not supposed to be part of a Certificate
    fn visit_extension_unknown(&mut self, _ext: &X509Extension) {}

    /// Invoked for any extension than caused a parse error
    ///
    /// Normally, this should not match anything except for invalid data.
    /// This could match any known extension malformed or wrongly encoded.
    fn visit_extension_parse_error(
        &mut self,
        _extension: &X509Extension,
        _error: &asn1_rs::Err<asn1_rs::Error>,
    ) {
    }
}

impl CertificateRevocationList<'_> {
    /// Run the provided [`CertificateRevocationListVisitor`] over the Certificate Revocation List (`self`)
    pub fn walk<V: CertificateRevocationListVisitor>(&self, visitor: &mut V) {
        visitor.visit_tbs_cert_list(&self.tbs_cert_list);
        self.tbs_cert_list.walk(visitor);
        visitor.visit_signature_algorithm(&self.signature_algorithm);
        visitor.visit_signature_value(&self.signature_value);
    }
}

impl TbsCertList<'_> {
    /// Run the provided `visitor` over the [`TbsCertList`] object
    pub fn walk<V: CertificateRevocationListVisitor>(&self, visitor: &mut V) {
        // shorten name to reduce line length
        let v = visitor;
        v.visit_version(self.version.as_ref());
        v.visit_tbs_signature_algorithm(&self.signature);
        v.visit_issuer(&self.issuer);
        v.visit_this_update(&self.this_update);
        v.visit_next_update(self.next_update.as_ref());
        v.visit_revoked_certificates(&self.revoked_certificates);
        for certificate in &self.revoked_certificates {
            v.visit_revoked_certificate(certificate);
        }
        v.pre_visit_extensions(self.extensions());
        for extension in self.extensions() {
            v.visit_extension(extension);

            match extension.parsed_extension() {
                ParsedExtension::AuthorityInfoAccess(info) => {
                    v.visit_extension_authority_information_access(info)
                }
                ParsedExtension::AuthorityKeyIdentifier(aki) => v.visit_extension_aki(aki),
                ParsedExtension::CRLNumber(number) => v.visit_extension_crl_number(number),
                ParsedExtension::InvalidityDate(time) => v.visit_extension_invalidity_date(time),
                ParsedExtension::IssuerAlternativeName(ian) => {
                    v.visit_extension_issuer_alternative_name(ian)
                }
                ParsedExtension::IssuingDistributionPoint(dp) => {
                    v.visit_extension_issuing_distribution_point(dp)
                }
                ParsedExtension::ReasonCode(code) => v.visit_extension_reason_code(code),
                ParsedExtension::SCT(sct) => v.visit_extension_sct(sct),
                ParsedExtension::ParseError { error } => {
                    v.visit_extension_parse_error(extension, error)
                }
                _ => v.visit_extension_unknown(extension),
            }
        }
        v.post_visit_extensions(self.extensions());
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::FromDer;

    static CRL: &[u8] = include_bytes!("../../assets/example.crl");

    #[test]
    fn visitor_crl() {
        #[derive(Debug, Default)]
        struct RevokedCertsVisitor {
            certificates: Vec<BigUint>,
        }

        impl CertificateRevocationListVisitor for RevokedCertsVisitor {
            fn visit_revoked_certificate(&mut self, certificate: &RevokedCertificate) {
                self.certificates.push(certificate.user_certificate.clone());
            }
        }

        let mut visitor = RevokedCertsVisitor::default();
        let (_, crl) = CertificateRevocationList::from_der(CRL).unwrap();

        crl.walk(&mut visitor);
        assert_eq!(visitor.certificates.len(), 5);
    }
}
