use der::{Sequence, ValueOrd};

use super::DirectoryString;

/// EDIPartyName as defined in [RFC 5280 Section 4.2.1.6].
///
/// ```text
/// EDIPartyName ::= SEQUENCE {
///     nameAssigner            [0] DirectoryString OPTIONAL,
///     partyName               [1] DirectoryString
/// }
/// ```
///
/// Note that although the module uses `IMPLICIT` tagging, these tags are
/// `EXPLICIT` because of `X.680-2015 31.2.7 (c)`:
///
/// ```text
/// c) the "Tag Type" alternative is used and the value of "TagDefault" for
/// the module is IMPLICIT TAGS or AUTOMATIC TAGS, but the type defined by
/// "Type" is an untagged choice type, an untagged open type, or an untagged
/// "DummyReference" (see Rec. ITU-T X.683 | ISO/IEC 8824-4, 8.3).
/// ```
///
/// See [this OpenSSL bug] for more details.
///
/// [this OpenSSL bug]: https://github.com/openssl/openssl/issues/6859
/// [RFC 5280 Section 4.2.1.6]: https://datatracker.ietf.org/doc/html/rfc5280#section-4.2.1.6
#[derive(Clone, Debug, Eq, PartialEq, Sequence, ValueOrd)]
#[allow(missing_docs)]
pub struct EdiPartyName {
    #[asn1(context_specific = "0", tag_mode = "EXPLICIT", optional = "true")]
    pub name_assigner: Option<DirectoryString>,

    #[asn1(context_specific = "1", tag_mode = "EXPLICIT")]
    pub party_name: DirectoryString,
}
