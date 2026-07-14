use alloc::vec::Vec;

use const_oid::db::rfc5280::ID_CE_POLICY_MAPPINGS;
use const_oid::AssociatedOid;
use der::asn1::ObjectIdentifier;
use der::{Sequence, ValueOrd};

/// PolicyMappings as defined in [RFC 5280 Section 4.2.1.5].
///
/// ```text
/// PolicyMappings ::= SEQUENCE SIZE (1..MAX) OF SEQUENCE {
/// ```
///
/// [RFC 5280 Section 4.2.1.5]: https://datatracker.ietf.org/doc/html/rfc5280#section-4.2.1.5
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PolicyMappings(pub Vec<PolicyMapping>);

impl AssociatedOid for PolicyMappings {
    const OID: ObjectIdentifier = ID_CE_POLICY_MAPPINGS;
}

impl_newtype!(PolicyMappings, Vec<PolicyMapping>);
impl_extension!(PolicyMappings, critical = true);

/// PolicyMapping as defined in [RFC 5280 Section 4.2.1.5].
///
/// ```text
/// PolicyMapping ::= SEQUENCE {
///     issuerDomainPolicy      CertPolicyId,
///     subjectDomainPolicy     CertPolicyId
/// }
/// ```
///
/// [RFC 5280 Section 4.2.1.5]: https://datatracker.ietf.org/doc/html/rfc5280#section-4.2.1.5
#[derive(Clone, Debug, Eq, PartialEq, Sequence, ValueOrd)]
#[allow(missing_docs)]
pub struct PolicyMapping {
    pub issuer_domain_policy: ObjectIdentifier,
    pub subject_domain_policy: ObjectIdentifier,
}
