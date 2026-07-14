//! Standardized X.509 Certificate Extensions

use const_oid::AssociatedOid;
use der::{asn1::OctetString, Sequence, ValueOrd};
use spki::ObjectIdentifier;

pub mod pkix;

/// Extension as defined in [RFC 5280 Section 4.1.2.9].
///
/// The ASN.1 definition for Extension objects is below. The extnValue type
/// may be further parsed using a decoder corresponding to the extnID value.
///
/// ```text
/// Extension  ::=  SEQUENCE  {
///     extnID      OBJECT IDENTIFIER,
///     critical    BOOLEAN DEFAULT FALSE,
///     extnValue   OCTET STRING
///                 -- contains the DER encoding of an ASN.1 value
///                 -- corresponding to the extension type identified
///                 -- by extnID
/// }
/// ```
///
/// [RFC 5280 Section 4.1.2.9]: https://datatracker.ietf.org/doc/html/rfc5280#section-4.1.2.9
#[cfg_attr(feature = "arbitrary", derive(arbitrary::Arbitrary))]
#[derive(Clone, Debug, Eq, PartialEq, Sequence, ValueOrd)]
#[allow(missing_docs)]
pub struct Extension {
    pub extn_id: ObjectIdentifier,

    #[asn1(default = "Default::default")]
    pub critical: bool,

    pub extn_value: OctetString,
}

/// Extensions as defined in [RFC 5280 Section 4.1.2.9].
///
/// ```text
/// Extensions  ::=  SEQUENCE SIZE (1..MAX) OF Extension
/// ```
///
/// [RFC 5280 Section 4.1.2.9]: https://datatracker.ietf.org/doc/html/rfc5280#section-4.1.2.9
pub type Extensions = alloc::vec::Vec<Extension>;

/// Trait to be implemented by extensions to allow them to be formated as x509 v3 extensions by
/// builder.
pub trait AsExtension: AssociatedOid + der::Encode {
    /// Should the extension be marked critical
    fn critical(&self, subject: &crate::name::Name, extensions: &[Extension]) -> bool;

    /// Returns the Extension with the content encoded.
    fn to_extension(
        &self,
        subject: &crate::name::Name,
        extensions: &[Extension],
    ) -> Result<Extension, der::Error> {
        let content = OctetString::new(<Self as der::Encode>::to_der(self)?)?;

        Ok(Extension {
            extn_id: <Self as AssociatedOid>::OID,
            critical: self.critical(subject, extensions),
            extn_value: content,
        })
    }
}
