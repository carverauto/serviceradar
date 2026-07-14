//! PKIX Name Constraint extension

use alloc::vec::Vec;

use const_oid::{db::rfc5280::ID_CE_NAME_CONSTRAINTS, AssociatedOid, ObjectIdentifier};
use der::Sequence;

use super::super::name::GeneralName;

/// NameConstraints extension as defined in [RFC 5280 Section 4.2.1.10].
///
/// ```text
/// NameConstraints ::= SEQUENCE {
///      permittedSubtrees       [0]     GeneralSubtrees OPTIONAL,
///      excludedSubtrees        [1]     GeneralSubtrees OPTIONAL
/// }
/// ```
///
/// [RFC 5280 Section 4.2.1.10]: https://datatracker.ietf.org/doc/html/rfc5280#section-4.2.1.10
#[derive(Clone, Debug, Eq, PartialEq, Sequence)]
#[allow(missing_docs)]
pub struct NameConstraints {
    #[asn1(context_specific = "0", optional = "true", tag_mode = "IMPLICIT")]
    pub permitted_subtrees: Option<GeneralSubtrees>,

    #[asn1(context_specific = "1", optional = "true", tag_mode = "IMPLICIT")]
    pub excluded_subtrees: Option<GeneralSubtrees>,
}

impl AssociatedOid for NameConstraints {
    const OID: ObjectIdentifier = ID_CE_NAME_CONSTRAINTS;
}

impl_extension!(NameConstraints, critical = true);

/// GeneralSubtrees as defined in [RFC 5280 Section 4.2.1.10].
///
/// ```text
/// GeneralSubtrees ::= SEQUENCE SIZE (1..MAX) OF GeneralSubtree
/// ```
///
/// [RFC 5280 Section 4.2.1.10]: https://datatracker.ietf.org/doc/html/rfc5280#section-4.2.1.10
pub type GeneralSubtrees = Vec<GeneralSubtree>;

/// GeneralSubtree as defined in [RFC 5280 Section 4.2.1.10].
///
/// ```text
/// GeneralSubtree ::= SEQUENCE {
///     base                    GeneralName,
///     minimum         [0]     BaseDistance DEFAULT 0,
///     maximum         [1]     BaseDistance OPTIONAL
/// }
/// ```
///
/// [RFC 5280 Section 4.2.1.10]: https://datatracker.ietf.org/doc/html/rfc5280#section-4.2.1.10
#[derive(Clone, Debug, Eq, PartialEq, Sequence)]
#[allow(missing_docs)]
pub struct GeneralSubtree {
    pub base: GeneralName,

    #[asn1(
        context_specific = "0",
        tag_mode = "IMPLICIT",
        default = "Default::default"
    )]
    pub minimum: u32,

    #[asn1(context_specific = "1", tag_mode = "IMPLICIT", optional = "true")]
    pub maximum: Option<u32>,
}
