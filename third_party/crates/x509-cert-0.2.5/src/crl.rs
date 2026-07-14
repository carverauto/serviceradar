//! Certificate Revocation List types

use crate::ext::Extensions;
use crate::name::Name;
use crate::serial_number::SerialNumber;
use crate::time::Time;
use crate::Version;

use alloc::vec::Vec;

use der::asn1::BitString;
use der::{Sequence, ValueOrd};
use spki::AlgorithmIdentifierOwned;

/// `CertificateList` as defined in [RFC 5280 Section 5.1].
///
/// ```text
/// CertificateList  ::=  SEQUENCE  {
///     tbsCertList          TBSCertList,
///     signatureAlgorithm   AlgorithmIdentifier,
///     signatureValue       BIT STRING
/// }
/// ```
///
/// [RFC 5280 Section 5.1]: https://datatracker.ietf.org/doc/html/rfc5280#section-5.1
#[derive(Clone, Debug, Eq, PartialEq, Sequence, ValueOrd)]
#[allow(missing_docs)]
pub struct CertificateList {
    pub tbs_cert_list: TbsCertList,
    pub signature_algorithm: AlgorithmIdentifierOwned,
    pub signature: BitString,
}

/// Implicit intermediate structure from the ASN.1 definition of `TBSCertList`.
///
/// This type is used for the `revoked_certificates` field of `TbsCertList`.
/// See [RFC 5280 Section 5.1].
///
/// ```text
/// RevokedCert ::= SEQUENCE {
///     userCertificate         CertificateSerialNumber,
///     revocationDate          Time,
///     crlEntryExtensions      Extensions OPTIONAL
/// }
/// ```
///
/// [RFC 5280 Section 5.1]: https://datatracker.ietf.org/doc/html/rfc5280#section-5.1
#[derive(Clone, Debug, Eq, PartialEq, Sequence, ValueOrd)]
#[allow(missing_docs)]
pub struct RevokedCert {
    pub serial_number: SerialNumber,
    pub revocation_date: Time,
    pub crl_entry_extensions: Option<Extensions>,
}

/// `TbsCertList` as defined in [RFC 5280 Section 5.1].
///
/// ```text
/// TBSCertList  ::=  SEQUENCE  {
///      version                 Version OPTIONAL, -- if present, MUST be v2
///      signature               AlgorithmIdentifier,
///      issuer                  Name,
///      thisUpdate              Time,
///      nextUpdate              Time OPTIONAL,
///      revokedCertificates     SEQUENCE OF SEQUENCE  {
///           userCertificate         CertificateSerialNumber,
///           revocationDate          Time,
///           crlEntryExtensions      Extensions OPTIONAL -- if present, version MUST be v2
///      }  OPTIONAL,
///      crlExtensions           [0]  EXPLICIT Extensions OPTIONAL -- if present, version MUST be v2
/// }
/// ```
///
/// [RFC 5280 Section 5.1]: https://datatracker.ietf.org/doc/html/rfc5280#section-5.1
#[derive(Clone, Debug, Eq, PartialEq, Sequence, ValueOrd)]
#[allow(missing_docs)]
pub struct TbsCertList {
    pub version: Version,
    pub signature: AlgorithmIdentifierOwned,
    pub issuer: Name,
    pub this_update: Time,
    pub next_update: Option<Time>,
    pub revoked_certificates: Option<Vec<RevokedCert>>,

    #[asn1(context_specific = "0", tag_mode = "EXPLICIT", optional = "true")]
    pub crl_extensions: Option<Extensions>,
}
