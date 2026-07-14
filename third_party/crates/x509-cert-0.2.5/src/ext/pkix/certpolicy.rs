//! PKIX Certificate Policies extension

use alloc::{string::String, vec::Vec};

use const_oid::db::rfc5912::ID_CE_CERTIFICATE_POLICIES;
use const_oid::AssociatedOid;
use der::asn1::{GeneralizedTime, Ia5String, ObjectIdentifier, Uint};
use der::{Any, Choice, Sequence, ValueOrd};

/// CertificatePolicies as defined in [RFC 5280 Section 4.2.1.4].
///
/// ```text
/// CertificatePolicies ::= SEQUENCE SIZE (1..MAX) OF PolicyInformation
/// ```
///
/// [RFC 5280 Section 4.2.1.4]: https://datatracker.ietf.org/doc/html/rfc5280#section-4.2.1.4
//  If this extension is
//  critical, the path validation software MUST be able to interpret this
//  extension (including the optional qualifier), or MUST reject the
//  certificate.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct CertificatePolicies(pub Vec<PolicyInformation>);

impl AssociatedOid for CertificatePolicies {
    const OID: ObjectIdentifier = ID_CE_CERTIFICATE_POLICIES;
}

impl_newtype!(CertificatePolicies, Vec<PolicyInformation>);
impl_extension!(CertificatePolicies);

/// PolicyInformation as defined in [RFC 5280 Section 4.2.1.4].
///
/// ```text
/// PolicyInformation ::= SEQUENCE {
///     policyIdentifier   CertPolicyId,
///     policyQualifiers   SEQUENCE SIZE (1..MAX) OF PolicyQualifierInfo OPTIONAL
/// }
///
/// CertPolicyId ::= OBJECT IDENTIFIER
/// ```
///
/// [RFC 5280 Section 4.2.1.4]: https://datatracker.ietf.org/doc/html/rfc5280#section-4.2.1.4
#[derive(Clone, Debug, Eq, PartialEq, Sequence, ValueOrd)]
#[allow(missing_docs)]
pub struct PolicyInformation {
    pub policy_identifier: ObjectIdentifier,
    pub policy_qualifiers: Option<Vec<PolicyQualifierInfo>>,
}

/// PolicyQualifierInfo as defined in [RFC 5280 Section 4.2.1.4].
///
/// ```text
/// PolicyQualifierInfo ::= SEQUENCE {
///     policyQualifierId  PolicyQualifierId,
///     qualifier          ANY DEFINED BY policyQualifierId
/// }
/// ```
///
/// [RFC 5280 Section 4.2.1.4]: https://datatracker.ietf.org/doc/html/rfc5280#section-4.2.1.4
#[derive(Clone, Debug, Eq, PartialEq, Sequence, ValueOrd)]
#[allow(missing_docs)]
pub struct PolicyQualifierInfo {
    pub policy_qualifier_id: ObjectIdentifier,
    pub qualifier: Option<Any>,
}

/// CpsUri as defined in [RFC 5280 Section 4.2.1.4].
///
/// ```text
/// CPSuri ::= IA5String
/// ```
///
/// [RFC 5280 Section 4.2.1.4]: https://datatracker.ietf.org/doc/html/rfc5280#section-4.2.1.4
pub type CpsUri = Ia5String;

/// UserNotice as defined in [RFC 5280 Section 4.2.1.4].
///
/// ```text
/// UserNotice ::= SEQUENCE {
///     noticeRef        NoticeReference OPTIONAL,
///     explicitText     DisplayText OPTIONAL
/// }
/// ```
///
/// [RFC 5280 Section 4.2.1.4]: https://datatracker.ietf.org/doc/html/rfc5280#section-4.2.1.4
#[derive(Clone, Debug, Eq, PartialEq, Sequence)]
#[allow(missing_docs)]
pub struct UserNotice {
    pub notice_ref: Option<GeneralizedTime>,
    pub explicit_text: Option<DisplayText>,
}

/// NoticeReference as defined in [RFC 5280 Section 4.2.1.4].
///
/// ```text
/// NoticeReference ::= SEQUENCE {
///      organization     DisplayText,
///      noticeNumbers    SEQUENCE OF INTEGER }
/// ```
///
/// [RFC 5280 Section 4.2.1.4]: https://datatracker.ietf.org/doc/html/rfc5280#section-4.2.1.4
#[derive(Clone, Debug, Eq, PartialEq, Sequence)]
#[allow(missing_docs)]
pub struct NoticeReference {
    pub organization: DisplayText,
    pub notice_numbers: Option<Vec<Uint>>,
}

/// DisplayText as defined in [RFC 5280 Section 4.2.1.4].
///
/// ```text
/// DisplayText ::= CHOICE {
///     ia5String        IA5String      (SIZE (1..200)),
///     visibleString    VisibleString  (SIZE (1..200)),
///     bmpString        BMPString      (SIZE (1..200)),
///     utf8String       UTF8String     (SIZE (1..200))
/// }
/// ```
///
/// Only the ia5String and utf8String options are currently supported.
///
/// [RFC 5280 Section 4.2.1.4]: https://datatracker.ietf.org/doc/html/rfc5280#section-4.2.1.4
#[derive(Choice, Clone, Debug, Eq, PartialEq)]
#[allow(missing_docs)]
pub enum DisplayText {
    #[asn1(type = "IA5String")]
    Ia5String(Ia5String),

    #[asn1(type = "UTF8String")]
    Utf8String(String),
}
