//! PKIX X.509 Certificate Extensions (RFC 5280)

pub mod certpolicy;
pub mod constraints;
pub mod crl;
pub mod name;

mod access;
mod authkeyid;
mod keyusage;
mod policymap;
#[cfg(feature = "sct")]
pub mod sct;

use crate::attr::AttributeTypeAndValue;

pub use access::{AccessDescription, AuthorityInfoAccessSyntax, SubjectInfoAccessSyntax};
pub use authkeyid::AuthorityKeyIdentifier;
pub use certpolicy::CertificatePolicies;
use const_oid::{AssociatedOid, ObjectIdentifier};
pub use constraints::{BasicConstraints, NameConstraints, PolicyConstraints};
pub use crl::{
    BaseCrlNumber, CrlDistributionPoints, CrlNumber, CrlReason, FreshestCrl,
    IssuingDistributionPoint,
};
pub use keyusage::{ExtendedKeyUsage, KeyUsage, KeyUsages, PrivateKeyUsagePeriod};
pub use policymap::{PolicyMapping, PolicyMappings};

#[cfg(feature = "sct")]
pub use sct::{
    Error, HashAlgorithm, SerializedSct, SignatureAlgorithm, SignatureAndHashAlgorithm,
    SignedCertificateTimestamp, SignedCertificateTimestampList, Version,
};

pub use const_oid::db::rfc5280::{
    ID_CE_INHIBIT_ANY_POLICY, ID_CE_ISSUER_ALT_NAME, ID_CE_SUBJECT_ALT_NAME,
    ID_CE_SUBJECT_DIRECTORY_ATTRIBUTES, ID_CE_SUBJECT_KEY_IDENTIFIER,
};

use alloc::vec::Vec;

use der::asn1::OctetString;

/// SubjectKeyIdentifier as defined in [RFC 5280 Section 4.2.1.2].
///
/// ```text
/// SubjectKeyIdentifier ::= KeyIdentifier
/// ```
///
/// [RFC 5280 Section 4.2.1.2]: https://datatracker.ietf.org/doc/html/rfc5280#section-4.2.1.2
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SubjectKeyIdentifier(pub OctetString);

impl AssociatedOid for SubjectKeyIdentifier {
    const OID: ObjectIdentifier = ID_CE_SUBJECT_KEY_IDENTIFIER;
}

impl_newtype!(SubjectKeyIdentifier, OctetString);
impl_extension!(SubjectKeyIdentifier, critical = false);
impl_key_identifier!(
    SubjectKeyIdentifier,
    (|result: &[u8]| Ok(Self(OctetString::new(result)?)))
);

/// SubjectAltName as defined in [RFC 5280 Section 4.2.1.6].
///
/// ```text
/// SubjectAltName ::= GeneralNames
/// ```
///
/// [RFC 5280 Section 4.2.1.6]: https://datatracker.ietf.org/doc/html/rfc5280#section-4.2.1.6
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct SubjectAltName(pub name::GeneralNames);

impl AssociatedOid for SubjectAltName {
    const OID: ObjectIdentifier = ID_CE_SUBJECT_ALT_NAME;
}

impl_newtype!(SubjectAltName, name::GeneralNames);

impl crate::ext::AsExtension for SubjectAltName {
    fn critical(&self, subject: &crate::name::Name, _extensions: &[super::Extension]) -> bool {
        // https://datatracker.ietf.org/doc/html/rfc5280#section-4.2.1.6
        //   Further, if the only subject identity included in the certificate is
        //   an alternative name form (e.g., an electronic mail address), then the
        //   subject distinguished name MUST be empty (an empty sequence), and the
        //   subjectAltName extension MUST be present.  If the subject field
        //   contains an empty sequence, then the issuing CA MUST include a
        //   subjectAltName extension that is marked as critical.  When including
        //   the subjectAltName extension in a certificate that has a non-empty
        //   subject distinguished name, conforming CAs SHOULD mark the
        //   subjectAltName extension as non-critical.

        subject.is_empty()
    }
}

/// IssuerAltName as defined in [RFC 5280 Section 4.2.1.7].
///
/// ```text
/// IssuerAltName ::= GeneralNames
/// ```
///
/// [RFC 5280 Section 4.2.1.7]: https://datatracker.ietf.org/doc/html/rfc5280#section-4.2.1.7
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct IssuerAltName(pub name::GeneralNames);

impl AssociatedOid for IssuerAltName {
    const OID: ObjectIdentifier = ID_CE_ISSUER_ALT_NAME;
}

impl_newtype!(IssuerAltName, name::GeneralNames);
impl_extension!(IssuerAltName, critical = false);

/// SubjectDirectoryAttributes as defined in [RFC 5280 Section 4.2.1.8].
///
/// ```text
/// SubjectDirectoryAttributes ::= SEQUENCE SIZE (1..MAX) OF AttributeSet
/// ```
///
/// [RFC 5280 Section 4.2.1.8]: https://datatracker.ietf.org/doc/html/rfc5280#section-4.2.1.8
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct SubjectDirectoryAttributes(pub Vec<AttributeTypeAndValue>);

impl AssociatedOid for SubjectDirectoryAttributes {
    const OID: ObjectIdentifier = ID_CE_SUBJECT_DIRECTORY_ATTRIBUTES;
}

impl_newtype!(SubjectDirectoryAttributes, Vec<AttributeTypeAndValue>);
impl_extension!(SubjectDirectoryAttributes, critical = false);

/// InhibitAnyPolicy as defined in [RFC 5280 Section 4.2.1.14].
///
/// ```text
/// InhibitAnyPolicy ::= SkipCerts
/// ```
///
/// [RFC 5280 Section 4.2.1.14]: https://datatracker.ietf.org/doc/html/rfc5280#section-4.2.1.14
#[derive(Copy, Clone, Debug, Default, PartialEq, Eq)]
pub struct InhibitAnyPolicy(pub u32);

impl AssociatedOid for InhibitAnyPolicy {
    const OID: ObjectIdentifier = ID_CE_INHIBIT_ANY_POLICY;
}

impl_newtype!(InhibitAnyPolicy, u32);
impl_extension!(InhibitAnyPolicy, critical = true);
