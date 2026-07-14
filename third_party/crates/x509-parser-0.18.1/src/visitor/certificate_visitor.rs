use asn1_rs::BitString;
use oid_registry::*;

use crate::certificate::*;
use crate::extensions::*;
use crate::x509::*;

/// Visitor pattern for [`X509Certificate`]
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
/// use x509_parser::prelude::*;
/// use x509_parser::visitor::X509CertificateVisitor;
/// #[derive(Debug, Default)]
/// struct SubjectIssuerVisitor {
///     issuer: String,
///     subject: String,
///     is_ca: bool,
/// }
///
/// impl X509CertificateVisitor for SubjectIssuerVisitor {
///     fn visit_issuer(&mut self, name: &X509Name<'_>) {
///         self.issuer = name.to_string();
///     }
///
///     fn visit_subject(&mut self, name: &X509Name<'_>) {
///         self.subject = name.to_string();
///     }
///
///     fn visit_extension_basic_constraints(&mut self, bc: &BasicConstraints) {
///         self.is_ca = bc.ca;
///     }
/// }
/// ```
pub trait X509CertificateVisitor {
    /// Run the provided visitor (`self`) over the [`X509Certificate`] object
    fn walk(&mut self, x509: &X509Certificate)
    where
        Self: Sized,
    {
        x509.walk(self);
    }

    /// Invoked for the "TBSCertificate" field of the X.509 Certificate, before visiting children
    fn visit_tbs_certificate(&mut self, _tbs: &TbsCertificate) {}

    /// Invoked for the "signatureAlgorithm" field of the X.509 Certificate
    ///
    /// Note: this is the "signatureAlgorithm" in the "Certificate" sequence. According to the
    /// specifications, it should be equal to "signature" field from the "TBSCertificate" sequence.
    fn visit_signature_algorithm(&mut self, _algorithm: &AlgorithmIdentifier) {}

    /// Invoked for the "signatureValue" field of the TBSCertificate
    fn visit_signature_value(&mut self, _signature: &BitString) {}

    /// Invoked for the "version" field of the TBSCertificate
    fn visit_version(&mut self, _version: &X509Version) {}

    /// Invoked for the "serialNumber" field of the TBSCertificate
    fn visit_serial_number(&mut self, _serial: &[u8]) {}

    /// Invoked for the "signature" field of the TBSCertificate
    ///
    /// Note: this is the "signature" field from the "TBSCertificate" sequence. According to the
    /// specifications, it should be equal to "signatureAlgorithm" in the "Certificate" sequence.
    fn visit_tbs_signature_algorithm(&mut self, _algorithm: &AlgorithmIdentifier) {}

    /// Invoked for the "issuer" field of the TBSCertificate
    fn visit_issuer(&mut self, _name: &X509Name) {}

    /// Invoked for the "validity" field of the TBSCertificate
    fn visit_validity(&mut self, _validity: &Validity) {}

    /// Invoked for the "subject" field of the TBSCertificate
    fn visit_subject(&mut self, _name: &X509Name) {}

    /// Invoked for the "subjectPublicKeyInfo" field of the TBSCertificate
    fn visit_subject_public_key_info(&mut self, _subject_pki: &SubjectPublicKeyInfo) {}

    /// Invoked for the "issuerUniqueID" field of the TBSCertificate
    fn visit_issuer_unique_id(&mut self, _id: Option<&UniqueIdentifier>) {}

    /// Invoked for the "subjectUniqueID" field of the TBSCertificate
    fn visit_subject_unique_id(&mut self, _id: Option<&UniqueIdentifier>) {}

    /// Invoked for extensions, before visiting children
    fn pre_visit_extensions(&mut self, _extensions: &[X509Extension]) {}

    /// Invoked for any extension that appear in the X.509 Certificate
    ///
    /// Note: this method may be redundant with any other extension visitor method
    fn visit_extension(&mut self, _extension: &X509Extension) {}

    /// Invoked for extensions, after visiting children
    fn post_visit_extensions(&mut self, _extensions: &[X509Extension]) {}

    /// Invoked for the "Authority Key Identifier" extension (if present)
    fn visit_extension_aki(&mut self, _aki: &AuthorityKeyIdentifier) {}

    /// Invoked for the "Subject Key Identifier" extension (if present)
    fn visit_extension_ski(&mut self, _id: &KeyIdentifier) {}

    /// Invoked for the "Key Usage" extension (if present)
    fn visit_extension_key_usage(&mut self, _usage: &KeyUsage) {}

    /// Invoked for the "Certificate Policies" extension (if present)
    fn visit_extension_certificate_policies(&mut self, _policies: &CertificatePolicies) {}

    /// Invoked for the "Subject Alternative Name" extension (if present)
    fn visit_extension_subject_alternative_name(&mut self, _san: &SubjectAlternativeName) {}

    /// Invoked for the "Issuer Alternative Name" extension (if present)
    fn visit_extension_issuer_alternative_name(&mut self, _ian: &IssuerAlternativeName) {}

    /// Invoked for the "Basic Constraints" extension (if present)
    fn visit_extension_basic_constraints(&mut self, _bc: &BasicConstraints) {}

    /// Invoked for the "Name Constraints" extension (if present)
    fn visit_extension_name_constraints(&mut self, _constraints: &NameConstraints) {}

    /// Invoked for the "Name Constraints" extension (if present)
    fn visit_extension_nscert_comment(&mut self, _nscert_comment: &str) {}

    /// Invoked for the "Name Constraints" extension (if present)
    fn visit_extension_nscert_type(&mut self, _nscert_type: &NSCertType) {}

    /// Invoked for the "Policy Constraints" extension (if present)
    fn visit_extension_policy_constraints(&mut self, _constraints: &PolicyConstraints) {}

    /// Invoked for the "Policy Mappings" extension (if present)
    fn visit_extension_policy_mappings(&mut self, _mappings: &PolicyMappings) {}

    /// Invoked for the "Extended Key Usage" extension (if present)
    fn visit_extension_extended_key_usage(&mut self, _usage: &ExtendedKeyUsage) {}

    /// Invoked for the "CRL Distribution Points" extension (if present)
    fn visit_extension_crl_distribution_points(&mut self, _crl: &CRLDistributionPoints) {}

    /// Invoked for the "Inhibit anyPolicy" extension (if present)
    fn visit_extension_inhibit_anypolicy(&mut self, _policy: &InhibitAnyPolicy) {}

    /// Invoked for the "Authority Information Access" extension (if present)
    fn visit_extension_authority_information_access(&mut self, _info: &AuthorityInfoAccess) {}

    /// Invoked for the "Signed Certificate Timestamp" (SCT) extension (if present)
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

impl X509Certificate<'_> {
    /// Run the provided [`X509CertificateVisitor`] over the X.509 Certificate (`self`)
    pub fn walk<V: X509CertificateVisitor>(&self, visitor: &mut V) {
        visitor.visit_tbs_certificate(&self.tbs_certificate);
        self.tbs_certificate.walk(visitor);
        visitor.visit_signature_algorithm(&self.signature_algorithm);
        visitor.visit_signature_value(&self.signature_value);
    }
}

impl TbsCertificate<'_> {
    /// Run the provided `visitor` over the [`TbsCertificate`] object
    pub fn walk<V: X509CertificateVisitor>(&self, visitor: &mut V) {
        // shorten name to reduce line length
        let v = visitor;
        v.visit_version(&self.version);
        v.visit_serial_number(self.raw_serial());
        v.visit_tbs_signature_algorithm(&self.signature);
        v.visit_issuer(&self.issuer);
        v.visit_validity(&self.validity);
        v.visit_subject(&self.subject);
        v.visit_subject_public_key_info(&self.subject_pki);
        v.visit_issuer_unique_id(self.issuer_uid.as_ref());
        v.visit_subject_unique_id(self.subject_uid.as_ref());
        v.pre_visit_extensions(self.extensions());
        for extension in self.extensions() {
            v.visit_extension(extension);

            match extension.parsed_extension() {
                ParsedExtension::AuthorityInfoAccess(info) => {
                    v.visit_extension_authority_information_access(info)
                }
                ParsedExtension::AuthorityKeyIdentifier(aki) => v.visit_extension_aki(aki),
                ParsedExtension::BasicConstraints(bc) => v.visit_extension_basic_constraints(bc),
                ParsedExtension::CertificatePolicies(policies) => {
                    v.visit_extension_certificate_policies(policies)
                }
                ParsedExtension::CRLDistributionPoints(crl) => {
                    v.visit_extension_crl_distribution_points(crl)
                }
                ParsedExtension::ExtendedKeyUsage(usage) => {
                    v.visit_extension_extended_key_usage(usage)
                }
                ParsedExtension::InhibitAnyPolicy(policy) => {
                    v.visit_extension_inhibit_anypolicy(policy)
                }
                ParsedExtension::IssuerAlternativeName(ian) => {
                    v.visit_extension_issuer_alternative_name(ian)
                }
                ParsedExtension::KeyUsage(usage) => v.visit_extension_key_usage(usage),
                ParsedExtension::NSCertType(nscert_type) => {
                    v.visit_extension_nscert_type(nscert_type)
                }
                ParsedExtension::NameConstraints(constraints) => {
                    v.visit_extension_name_constraints(constraints)
                }
                ParsedExtension::NsCertComment(comment) => {
                    v.visit_extension_nscert_comment(comment)
                }
                ParsedExtension::PolicyConstraints(constraints) => {
                    v.visit_extension_policy_constraints(constraints)
                }
                ParsedExtension::PolicyMappings(mappings) => {
                    v.visit_extension_policy_mappings(mappings)
                }
                ParsedExtension::SCT(sct) => v.visit_extension_sct(sct),
                ParsedExtension::SubjectAlternativeName(san) => {
                    v.visit_extension_subject_alternative_name(san)
                }
                ParsedExtension::SubjectKeyIdentifier(id) => v.visit_extension_ski(id),
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

    static IGCA_DER: &[u8] = include_bytes!("../../assets/IGC_A.der");

    #[test]
    fn visitor_certificate() {
        #[derive(Debug, Default)]
        struct SubjectIssuerVisitor {
            issuer: String,
            subject: String,
            is_ca: bool,
        }

        impl X509CertificateVisitor for SubjectIssuerVisitor {
            fn visit_issuer(&mut self, name: &X509Name) {
                self.issuer = name.to_string();
            }

            fn visit_subject(&mut self, name: &X509Name) {
                self.subject = name.to_string();
            }

            fn visit_extension_basic_constraints(&mut self, bc: &BasicConstraints) {
                self.is_ca = bc.ca;
            }
        }

        let mut visitor = SubjectIssuerVisitor::default();
        let (_, x509) = X509Certificate::from_der(IGCA_DER).unwrap();

        x509.walk(&mut visitor);
        assert!(!visitor.issuer.is_empty());
        assert!(visitor.is_ca);
        assert_eq!(&visitor.issuer, &visitor.subject);
    }
}
