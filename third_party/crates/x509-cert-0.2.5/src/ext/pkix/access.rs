use super::name::GeneralName;

use alloc::vec::Vec;

use const_oid::{
    db::rfc5280::{ID_PE_AUTHORITY_INFO_ACCESS, ID_PE_SUBJECT_INFO_ACCESS},
    AssociatedOid,
};
use der::{asn1::ObjectIdentifier, Sequence, ValueOrd};

/// AuthorityInfoAccessSyntax as defined in [RFC 5280 Section 4.2.2.1].
///
/// ```text
/// AuthorityInfoAccessSyntax ::= SEQUENCE SIZE (1..MAX) OF AccessDescription
/// ```
///
/// [RFC 5280 Section 4.2.2.1]: https://datatracker.ietf.org/doc/html/rfc5280#section-4.2.2.1
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct AuthorityInfoAccessSyntax(pub Vec<AccessDescription>);

impl AssociatedOid for AuthorityInfoAccessSyntax {
    const OID: ObjectIdentifier = ID_PE_AUTHORITY_INFO_ACCESS;
}

impl_newtype!(AuthorityInfoAccessSyntax, Vec<AccessDescription>);
impl_extension!(AuthorityInfoAccessSyntax, critical = false);

/// SubjectInfoAccessSyntax as defined in [RFC 5280 Section 4.2.2.2].
///
/// ```text
/// SubjectInfoAccessSyntax ::= SEQUENCE SIZE (1..MAX) OF AccessDescription
/// ```
///
/// [RFC 5280 Section 4.2.2.2]: https://datatracker.ietf.org/doc/html/rfc5280#section-4.2.2.2
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct SubjectInfoAccessSyntax(pub Vec<AccessDescription>);

impl AssociatedOid for SubjectInfoAccessSyntax {
    const OID: ObjectIdentifier = ID_PE_SUBJECT_INFO_ACCESS;
}

impl_newtype!(SubjectInfoAccessSyntax, Vec<AccessDescription>);
impl_extension!(SubjectInfoAccessSyntax, critical = false);

/// AccessDescription as defined in [RFC 5280 Section 4.2.2.1].
///
/// ```text
/// AccessDescription  ::=  SEQUENCE {
///     accessMethod          OBJECT IDENTIFIER,
///     accessLocation        GeneralName
/// }
/// ```
///
/// [RFC 5280 Section 4.2.2.1]: https://datatracker.ietf.org/doc/html/rfc5280#section-4.2.2.1
#[derive(Clone, Debug, Eq, PartialEq, Sequence, ValueOrd)]
#[allow(missing_docs)]
pub struct AccessDescription {
    pub access_method: ObjectIdentifier,
    pub access_location: GeneralName,
}
