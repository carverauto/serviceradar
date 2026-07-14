//! PKIX distribution point types

use const_oid::{db::rfc5280::ID_PE_SUBJECT_INFO_ACCESS, AssociatedOid, ObjectIdentifier};
use der::flagset::{flags, FlagSet};
use der::{Sequence, ValueOrd};

use crate::ext::pkix::name::{DistributionPointName, GeneralNames};

/// IssuingDistributionPoint as defined in [RFC 5280 Section 5.2.5].
///
/// ```text
/// IssuingDistributionPoint ::= SEQUENCE {
///     distributionPoint          [0] DistributionPointName OPTIONAL,
///     onlyContainsUserCerts      [1] BOOLEAN DEFAULT FALSE,
///     onlyContainsCACerts        [2] BOOLEAN DEFAULT FALSE,
///     onlySomeReasons            [3] ReasonFlags OPTIONAL,
///     indirectCRL                [4] BOOLEAN DEFAULT FALSE,
///     onlyContainsAttributeCerts [5] BOOLEAN DEFAULT FALSE
///     -- at most one of onlyContainsUserCerts, onlyContainsCACerts,
///     -- and onlyContainsAttributeCerts may be set to TRUE.
/// }
/// ```
///
/// [RFC 5280 Section 5.2.5]: https://datatracker.ietf.org/doc/html/rfc5280#section-5.2.5
#[derive(Clone, Debug, Eq, PartialEq, Sequence)]
#[allow(missing_docs)]
pub struct IssuingDistributionPoint {
    #[asn1(context_specific = "0", tag_mode = "EXPLICIT", optional = "true")]
    pub distribution_point: Option<DistributionPointName>,

    #[asn1(
        context_specific = "1",
        tag_mode = "IMPLICIT",
        default = "Default::default"
    )]
    pub only_contains_user_certs: bool,

    #[asn1(
        context_specific = "2",
        tag_mode = "IMPLICIT",
        default = "Default::default"
    )]
    pub only_contains_ca_certs: bool,

    #[asn1(context_specific = "3", tag_mode = "IMPLICIT", optional = "true")]
    pub only_some_reasons: Option<ReasonFlags>,

    #[asn1(
        context_specific = "4",
        tag_mode = "IMPLICIT",
        default = "Default::default"
    )]
    pub indirect_crl: bool,

    #[asn1(
        context_specific = "5",
        tag_mode = "IMPLICIT",
        default = "Default::default"
    )]
    pub only_contains_attribute_certs: bool,
}

impl AssociatedOid for IssuingDistributionPoint {
    const OID: ObjectIdentifier = ID_PE_SUBJECT_INFO_ACCESS;
}

impl_extension!(IssuingDistributionPoint, critical = true);

/// DistributionPoint as defined in [RFC 5280 Section 4.2.1.13].
///
/// ```text
/// DistributionPoint ::= SEQUENCE {
///      distributionPoint       [0]     DistributionPointName OPTIONAL,
///      reasons                 [1]     ReasonFlags OPTIONAL,
///      cRLIssuer               [2]     GeneralNames OPTIONAL }
/// ```
///
/// [RFC 5280 Section 4.2.1.13]: https://datatracker.ietf.org/doc/html/rfc5280#section-4.2.1.13
#[derive(Clone, Debug, PartialEq, Eq, Sequence, ValueOrd)]
#[allow(missing_docs)]
pub struct DistributionPoint {
    #[asn1(context_specific = "0", tag_mode = "EXPLICIT", optional = "true")]
    pub distribution_point: Option<DistributionPointName>,

    #[asn1(context_specific = "1", tag_mode = "IMPLICIT", optional = "true")]
    pub reasons: Option<ReasonFlags>,

    #[asn1(context_specific = "2", tag_mode = "IMPLICIT", optional = "true")]
    pub crl_issuer: Option<GeneralNames>,
}

/// ReasonFlags as defined in [RFC 5280 Section 4.2.1.13].
///
/// [RFC 5280 Section 4.2.1.13]: https://datatracker.ietf.org/doc/html/rfc5280#section-4.2.1.13
pub type ReasonFlags = FlagSet<Reasons>;

flags! {
    /// ReasonFlags values as defined in [RFC 5280 Section 4.2.1.13].
    ///
    /// ```text
    /// ReasonFlags ::= BIT STRING {
    ///      unused                  (0),
    ///      keyCompromise           (1),
    ///      cACompromise            (2),
    ///      affiliationChanged      (3),
    ///      superseded              (4),
    ///      cessationOfOperation    (5),
    ///      certificateHold         (6),
    ///      privilegeWithdrawn      (7),
    ///      aACompromise            (8)
    /// }
    /// ```
    ///
    /// [RFC 5280 Section 4.2.1.13]: https://datatracker.ietf.org/doc/html/rfc5280#section-4.2.1.13
    #[allow(missing_docs)]
    pub enum Reasons: u16 {
        Unused = 1 << 0,
        KeyCompromise = 1 << 1,
        CaCompromise = 1 << 2,
        AffiliationChanged = 1 << 3,
        Superseded = 1 << 4,
        CessationOfOperation = 1 << 5,
        CertificateHold = 1 << 6,
        PrivilegeWithdrawn = 1 << 7,
        AaCompromise = 1 << 8,
    }
}
