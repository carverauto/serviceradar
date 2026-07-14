//! Certificate types

use crate::{name::Name, serial_number::SerialNumber, time::Validity};
use alloc::vec::Vec;
use const_oid::AssociatedOid;
use core::{cmp::Ordering, fmt::Debug};
use der::asn1::BitString;
use der::{Decode, Enumerated, Error, ErrorKind, Sequence, Tag, ValueOrd};
use spki::{AlgorithmIdentifierOwned, SubjectPublicKeyInfoOwned};

#[cfg(feature = "pem")]
use der::{
    pem::{self, PemLabel},
    DecodePem,
};

/// [`Profile`] allows the consumer of this crate to customize the behavior when parsing
/// certificates.
/// By default, parsing will be made in a rfc5280-compliant manner.
pub trait Profile: PartialEq + Debug + Eq + Clone {
    /// Checks to run when parsing serial numbers
    fn check_serial_number(serial: &SerialNumber<Self>) -> der::Result<()> {
        // See the note in `SerialNumber::new`: we permit lengths of 21 bytes here,
        // since some X.509 implementations interpret the limit of 20 bytes to refer
        // to the pre-encoded value.
        if serial.inner.len() > SerialNumber::<Self>::MAX_DECODE_LEN {
            Err(Tag::Integer.value_error())
        } else {
            Ok(())
        }
    }
}

#[cfg_attr(feature = "arbitrary", derive(arbitrary::Arbitrary))]
#[derive(Debug, PartialEq, Eq, Clone)]
/// Parse certificates with rfc5280-compliant checks
pub struct Rfc5280;

impl Profile for Rfc5280 {}

#[cfg(feature = "hazmat")]
#[cfg_attr(feature = "arbitrary", derive(arbitrary::Arbitrary))]
#[derive(Debug, PartialEq, Eq, Clone)]
/// Parse raw x509 certificate and disable all the checks
pub struct Raw;

#[cfg(feature = "hazmat")]
impl Profile for Raw {
    fn check_serial_number(_serial: &SerialNumber<Self>) -> der::Result<()> {
        Ok(())
    }
}

/// Certificate `Version` as defined in [RFC 5280 Section 4.1].
///
/// ```text
/// Version  ::=  INTEGER  {  v1(0), v2(1), v3(2)  }
/// ```
///
/// [RFC 5280 Section 4.1]: https://datatracker.ietf.org/doc/html/rfc5280#section-4.1
#[cfg_attr(feature = "arbitrary", derive(arbitrary::Arbitrary))]
#[derive(Clone, Debug, Copy, PartialEq, Eq, Enumerated)]
#[asn1(type = "INTEGER")]
#[repr(u8)]
pub enum Version {
    /// Version 1 (default)
    V1 = 0,

    /// Version 2
    V2 = 1,

    /// Version 3
    V3 = 2,
}

impl ValueOrd for Version {
    fn value_cmp(&self, other: &Self) -> der::Result<Ordering> {
        (*self as u8).value_cmp(&(*other as u8))
    }
}

impl Default for Version {
    fn default() -> Self {
        Self::V1
    }
}

/// X.509 `TbsCertificate` as defined in [RFC 5280 Section 4.1]
pub type TbsCertificate = TbsCertificateInner<Rfc5280>;

/// X.509 `TbsCertificate` as defined in [RFC 5280 Section 4.1]
///
/// ASN.1 structure containing the names of the subject and issuer, a public
/// key associated with the subject, a validity period, and other associated
/// information.
///
/// ```text
/// TBSCertificate  ::=  SEQUENCE  {
///     version         [0]  EXPLICIT Version DEFAULT v1,
///     serialNumber         CertificateSerialNumber,
///     signature            AlgorithmIdentifier,
///     issuer               Name,
///     validity             Validity,
///     subject              Name,
///     subjectPublicKeyInfo SubjectPublicKeyInfo,
///     issuerUniqueID  [1]  IMPLICIT UniqueIdentifier OPTIONAL,
///                          -- If present, version MUST be v2 or v3
///     subjectUniqueID [2]  IMPLICIT UniqueIdentifier OPTIONAL,
///                          -- If present, version MUST be v2 or v3
///     extensions      [3]  Extensions OPTIONAL
///                          -- If present, version MUST be v3 --
/// }
/// ```
///
/// [RFC 5280 Section 4.1]: https://datatracker.ietf.org/doc/html/rfc5280#section-4.1
#[cfg_attr(feature = "arbitrary", derive(arbitrary::Arbitrary))]
#[derive(Clone, Debug, Eq, PartialEq, Sequence, ValueOrd)]
#[allow(missing_docs)]
pub struct TbsCertificateInner<P: Profile = Rfc5280> {
    /// The certificate version
    ///
    /// Note that this value defaults to Version 1 per the RFC. However,
    /// fields such as `issuer_unique_id`, `subject_unique_id` and `extensions`
    /// require later versions. Care should be taken in order to ensure
    /// standards compliance.
    #[asn1(context_specific = "0", default = "Default::default")]
    pub version: Version,

    pub serial_number: SerialNumber<P>,
    pub signature: AlgorithmIdentifierOwned,
    pub issuer: Name,
    pub validity: Validity,
    pub subject: Name,
    pub subject_public_key_info: SubjectPublicKeyInfoOwned,

    #[asn1(context_specific = "1", tag_mode = "IMPLICIT", optional = "true")]
    pub issuer_unique_id: Option<BitString>,

    #[asn1(context_specific = "2", tag_mode = "IMPLICIT", optional = "true")]
    pub subject_unique_id: Option<BitString>,

    #[asn1(context_specific = "3", tag_mode = "EXPLICIT", optional = "true")]
    pub extensions: Option<crate::ext::Extensions>,
}

impl<P: Profile> TbsCertificateInner<P> {
    /// Decodes a single extension
    ///
    /// Returns an error if multiple of these extensions is present. Returns
    /// `Ok(None)` if the extension is not present. Returns a decoding error
    /// if decoding failed. Otherwise returns the extension.
    pub fn get<'a, T: Decode<'a> + AssociatedOid>(&'a self) -> Result<Option<(bool, T)>, Error> {
        let mut iter = self.filter::<T>().peekable();
        match iter.next() {
            None => Ok(None),
            Some(item) => match iter.peek() {
                Some(..) => Err(ErrorKind::Failed.into()),
                None => Ok(Some(item?)),
            },
        }
    }

    /// Filters extensions by an associated OID
    ///
    /// Returns a filtered iterator over all the extensions with the OID.
    pub fn filter<'a, T: Decode<'a> + AssociatedOid>(
        &'a self,
    ) -> impl 'a + Iterator<Item = Result<(bool, T), Error>> {
        self.extensions
            .as_deref()
            .unwrap_or(&[])
            .iter()
            .filter(|e| e.extn_id == T::OID)
            .map(|e| Ok((e.critical, T::from_der(e.extn_value.as_bytes())?)))
    }
}

/// X.509 certificates are defined in [RFC 5280 Section 4.1].
///
/// [RFC 5280 Section 4.1]: https://datatracker.ietf.org/doc/html/rfc5280#section-4.1
pub type Certificate = CertificateInner<Rfc5280>;

/// X.509 certificates are defined in [RFC 5280 Section 4.1].
///
/// ```text
/// Certificate  ::=  SEQUENCE  {
///     tbsCertificate       TBSCertificate,
///     signatureAlgorithm   AlgorithmIdentifier,
///     signature            BIT STRING
/// }
/// ```
///
/// [RFC 5280 Section 4.1]: https://datatracker.ietf.org/doc/html/rfc5280#section-4.1
#[cfg_attr(feature = "arbitrary", derive(arbitrary::Arbitrary))]
#[derive(Clone, Debug, Eq, PartialEq, Sequence, ValueOrd)]
#[allow(missing_docs)]
pub struct CertificateInner<P: Profile = Rfc5280> {
    pub tbs_certificate: TbsCertificateInner<P>,
    pub signature_algorithm: AlgorithmIdentifierOwned,
    pub signature: BitString,
}

#[cfg(feature = "pem")]
impl<P: Profile> PemLabel for CertificateInner<P> {
    const PEM_LABEL: &'static str = "CERTIFICATE";
}

/// `PkiPath` as defined by X.509 and referenced by [RFC 6066].
///
/// This contains a series of certificates in validation order from the
/// top-most certificate to the bottom-most certificate. This means that
/// the first certificate signs the second certificate and so on.
///
/// ```text
/// PkiPath ::= SEQUENCE OF Certificate
/// ```
///
/// [RFC 6066]: https://datatracker.ietf.org/doc/html/rfc6066#section-10.1
pub type PkiPath = Vec<Certificate>;

#[cfg(feature = "pem")]
impl<P: Profile> CertificateInner<P> {
    /// Parse a chain of pem-encoded certificates from a slice.
    ///
    /// Returns the list of certificates.
    pub fn load_pem_chain(mut input: &[u8]) -> Result<Vec<Self>, Error> {
        fn find_boundary<T>(haystack: &[T], needle: &[T]) -> Option<usize>
        where
            for<'a> &'a [T]: PartialEq,
        {
            haystack
                .windows(needle.len())
                .position(|window| window == needle)
        }

        let mut certs = Vec::new();
        let mut position: usize = 0;

        let end_boundary = &b"-----END CERTIFICATE-----"[..];

        // Strip the trailing whitespaces
        loop {
            if input.is_empty() {
                break;
            }
            let last_pos = input.len() - 1;

            match input.get(last_pos) {
                Some(b'\r') | Some(b'\n') => {
                    input = &input[..last_pos];
                }
                _ => break,
            }
        }

        while position < input.len() - 1 {
            let rest = &input[position..];
            let end_pos = find_boundary(rest, end_boundary)
                .ok_or(pem::Error::PostEncapsulationBoundary)?
                + end_boundary.len();

            let cert_buf = &rest[..end_pos];
            let cert = Self::from_pem(cert_buf)?;
            certs.push(cert);

            position += end_pos;
        }

        Ok(certs)
    }
}
