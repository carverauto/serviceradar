use const_oid::{db::rfc5280::ID_CE_BASIC_CONSTRAINTS, AssociatedOid, ObjectIdentifier};
use der::Sequence;

/// BasicConstraints as defined in [RFC 5280 Section 4.2.1.9].
///
/// ```text
/// BasicConstraints ::= SEQUENCE {
///     cA                      BOOLEAN DEFAULT FALSE,
///     pathLenConstraint       INTEGER (0..MAX) OPTIONAL
/// }
/// ```
///
/// [RFC 5280 Section 4.2.1.9]: https://datatracker.ietf.org/doc/html/rfc5280#section-4.2.1.9
#[derive(Clone, Debug, Eq, PartialEq, Sequence)]
#[allow(missing_docs)]
pub struct BasicConstraints {
    #[asn1(default = "Default::default")]
    pub ca: bool,
    pub path_len_constraint: Option<u8>,
}

impl AssociatedOid for BasicConstraints {
    const OID: ObjectIdentifier = ID_CE_BASIC_CONSTRAINTS;
}

impl crate::ext::AsExtension for BasicConstraints {
    fn critical(
        &self,
        _subject: &crate::name::Name,
        _extensions: &[crate::ext::Extension],
    ) -> bool {
        // https://datatracker.ietf.org/doc/html/rfc5280#section-4.2.1.9
        //   Conforming CAs MUST include this extension in all CA certificates
        //   that contain public keys used to validate digital signatures on
        //   certificates and MUST mark the extension as critical in such
        //   certificates.  This extension MAY appear as a critical or non-
        //   critical extension in CA certificates that contain public keys used
        //   exclusively for purposes other than validating digital signatures on
        //   certificates.  Such CA certificates include ones that contain public
        //   keys used exclusively for validating digital signatures on CRLs and
        //   ones that contain key management public keys used with certificate
        //   enrollment protocols.  This extension MAY appear as a critical or
        //   non-critical extension in end entity certificates.

        // NOTE(baloo): from the spec, it doesn't appear to hurt if we force the extension
        // to be critical.
        true
    }
}
