use super::GeneralNames;
use crate::name::RelativeDistinguishedName;

use der::{Choice, ValueOrd};

/// DistributionPointName as defined in [RFC 5280 Section 4.2.1.13].
///
/// ```text
/// DistributionPointName ::= CHOICE {
///     fullName                [0]     GeneralNames,
///     nameRelativeToCRLIssuer [1]     RelativeDistinguishedName
/// }
/// ```
///
/// [RFC 5280 Section 4.2.1.13]: https://datatracker.ietf.org/doc/html/rfc5280#section-4.2.1.13
#[derive(Clone, Debug, Eq, PartialEq, Choice, ValueOrd)]
#[allow(missing_docs)]
pub enum DistributionPointName {
    #[asn1(context_specific = "0", tag_mode = "IMPLICIT", constructed = "true")]
    FullName(GeneralNames),

    #[asn1(context_specific = "1", tag_mode = "IMPLICIT", constructed = "true")]
    NameRelativeToCRLIssuer(RelativeDistinguishedName),
}
