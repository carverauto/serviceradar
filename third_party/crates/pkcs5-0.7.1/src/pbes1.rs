//! Password-Based Encryption Scheme 1 as defined in [RFC 8018 Section 6.1].
//!
//! [RFC 8018 Section 6.1]: https://tools.ietf.org/html/rfc8018#section-6.1

use crate::AlgorithmIdentifierRef;
use der::{
    asn1::{AnyRef, ObjectIdentifier, OctetStringRef},
    Decode, DecodeValue, Encode, EncodeValue, ErrorKind, Length, Reader, Sequence, Tag, Writer,
};

/// `pbeWithMD2AndDES-CBC` Object Identifier (OID).
pub const PBE_WITH_MD2_AND_DES_CBC_OID: ObjectIdentifier =
    ObjectIdentifier::new_unwrap("1.2.840.113549.1.5.1");

/// `pbeWithMD2AndRC2-CBC` Object Identifier (OID).
pub const PBE_WITH_MD2_AND_RC2_CBC_OID: ObjectIdentifier =
    ObjectIdentifier::new_unwrap("1.2.840.113549.1.5.4");

/// `pbeWithMD5AndDES-CBC` Object Identifier (OID).
pub const PBE_WITH_MD5_AND_DES_CBC_OID: ObjectIdentifier =
    ObjectIdentifier::new_unwrap("1.2.840.113549.1.5.3");

/// `pbeWithMD5AndRC2-CBC` Object Identifier (OID).
pub const PBE_WITH_MD5_AND_RC2_CBC_OID: ObjectIdentifier =
    ObjectIdentifier::new_unwrap("1.2.840.113549.1.5.6");

/// `pbeWithSHA1AndDES-CBC` Object Identifier (OID).
pub const PBE_WITH_SHA1_AND_DES_CBC_OID: ObjectIdentifier =
    ObjectIdentifier::new_unwrap("1.2.840.113549.1.5.10");

/// `pbeWithSHA1AndRC2-CBC` Object Identifier (OID).
pub const PBE_WITH_SHA1_AND_RC2_CBC_OID: ObjectIdentifier =
    ObjectIdentifier::new_unwrap("1.2.840.113549.1.5.11");

/// Length of a PBES1 salt (as defined in the `PBEParameter` ASN.1 message).
pub const SALT_LENGTH: usize = 8;

/// Password-Based Encryption Scheme 1 algorithms as defined in [RFC 8018 Appendix A.C].
///
/// ```text
/// PBES1Algorithms ALGORITHM-IDENTIFIER ::= {
///    {PBEParameter IDENTIFIED BY pbeWithMD2AndDES-CBC}  |
///    {PBEParameter IDENTIFIED BY pbeWithMD2AndRC2-CBC}  |
///    {PBEParameter IDENTIFIED BY pbeWithMD5AndDES-CBC}  |
///    {PBEParameter IDENTIFIED BY pbeWithMD5AndRC2-CBC}  |
///    {PBEParameter IDENTIFIED BY pbeWithSHA1AndDES-CBC} |
///    {PBEParameter IDENTIFIED BY pbeWithSHA1AndRC2-CBC},
///    ...
/// }
/// ```
///
/// [RFC 8018 Appendix A.C]: https://datatracker.ietf.org/doc/html/rfc8018#appendix-C
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Algorithm {
    /// Encryption scheme.
    pub encryption: EncryptionScheme,

    /// Scheme parameters.
    pub parameters: Parameters,
}

impl Algorithm {
    /// Get the [`ObjectIdentifier`] (a.k.a OID) for this algorithm.
    pub fn oid(&self) -> ObjectIdentifier {
        self.encryption.oid()
    }
}

impl<'a> DecodeValue<'a> for Algorithm {
    fn decode_value<R: Reader<'a>>(reader: &mut R, header: der::Header) -> der::Result<Self> {
        AlgorithmIdentifierRef::decode_value(reader, header)?.try_into()
    }
}

impl EncodeValue for Algorithm {
    fn value_len(&self) -> der::Result<Length> {
        self.encryption.encoded_len()? + self.parameters.encoded_len()?
    }

    fn encode_value(&self, writer: &mut impl Writer) -> der::Result<()> {
        self.encryption.encode(writer)?;
        self.parameters.encode(writer)?;
        Ok(())
    }
}

impl Sequence<'_> for Algorithm {}

impl<'a> TryFrom<AlgorithmIdentifierRef<'a>> for Algorithm {
    type Error = der::Error;

    fn try_from(alg: AlgorithmIdentifierRef<'a>) -> der::Result<Self> {
        // Ensure that we have a supported PBES1 algorithm identifier
        let encryption = EncryptionScheme::try_from(alg.oid)
            .map_err(|_| der::Tag::ObjectIdentifier.value_error())?;

        let parameters = alg
            .parameters
            .ok_or_else(|| Tag::OctetString.value_error())?
            .try_into()?;

        Ok(Self {
            encryption,
            parameters,
        })
    }
}

/// Password-Based Encryption Scheme 1 parameters as defined in [RFC 8018 Appendix A.3].
///
/// ```text
/// PBEParameter ::= SEQUENCE {
///    salt OCTET STRING (SIZE(8)),
///    iterationCount INTEGER }
/// ```
///
/// [RFC 8018 Appendix A.3]: https://tools.ietf.org/html/rfc8018#appendix-A.3
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Parameters {
    /// Salt value
    pub salt: [u8; SALT_LENGTH],

    /// Iteration count
    pub iteration_count: u16,
}

impl<'a> DecodeValue<'a> for Parameters {
    fn decode_value<R: Reader<'a>>(reader: &mut R, header: der::Header) -> der::Result<Self> {
        AnyRef::decode_value(reader, header)?.try_into()
    }
}

impl EncodeValue for Parameters {
    fn value_len(&self) -> der::Result<Length> {
        OctetStringRef::new(&self.salt)?.encoded_len()? + self.iteration_count.encoded_len()?
    }

    fn encode_value(&self, writer: &mut impl Writer) -> der::Result<()> {
        OctetStringRef::new(&self.salt)?.encode(writer)?;
        self.iteration_count.encode(writer)?;
        Ok(())
    }
}

impl Sequence<'_> for Parameters {}

impl TryFrom<AnyRef<'_>> for Parameters {
    type Error = der::Error;

    fn try_from(any: AnyRef<'_>) -> der::Result<Parameters> {
        any.sequence(|reader| {
            Ok(Parameters {
                salt: OctetStringRef::decode(reader)?
                    .as_bytes()
                    .try_into()
                    .map_err(|_| der::Tag::OctetString.value_error())?,
                iteration_count: reader.decode()?,
            })
        })
    }
}

/// Password-Based Encryption Scheme 1 ciphersuites as defined in [RFC 8018 Appendix A.3].
///
/// [RFC 8018 Appendix A.3]: https://tools.ietf.org/html/rfc8018#appendix-A.3
#[derive(Copy, Clone, Debug, Eq, PartialEq)]
pub enum EncryptionScheme {
    /// `pbeWithMD2AndDES-CBC`
    PbeWithMd2AndDesCbc,

    /// `pbeWithMD2AndRC2-CBC`
    PbeWithMd2AndRc2Cbc,

    /// `pbeWithMD5AndDES-CBC`
    PbeWithMd5AndDesCbc,

    /// `pbeWithMD5AndRC2-CBC`
    PbeWithMd5AndRc2Cbc,

    /// `pbeWithSHA1AndDES-CBC`
    PbeWithSha1AndDesCbc,

    /// `pbeWithSHA1AndRC2-CBC`
    PbeWithSha1AndRc2Cbc,
}

impl TryFrom<ObjectIdentifier> for EncryptionScheme {
    type Error = der::Error;

    fn try_from(oid: ObjectIdentifier) -> der::Result<Self> {
        match oid {
            PBE_WITH_MD2_AND_DES_CBC_OID => Ok(Self::PbeWithMd2AndDesCbc),
            PBE_WITH_MD2_AND_RC2_CBC_OID => Ok(Self::PbeWithMd2AndRc2Cbc),
            PBE_WITH_MD5_AND_DES_CBC_OID => Ok(Self::PbeWithMd5AndDesCbc),
            PBE_WITH_MD5_AND_RC2_CBC_OID => Ok(Self::PbeWithMd5AndRc2Cbc),
            PBE_WITH_SHA1_AND_DES_CBC_OID => Ok(Self::PbeWithSha1AndDesCbc),
            PBE_WITH_SHA1_AND_RC2_CBC_OID => Ok(Self::PbeWithSha1AndRc2Cbc),
            _ => Err(ErrorKind::OidUnknown { oid }.into()),
        }
    }
}

impl EncryptionScheme {
    /// Get the [`SymmetricCipher`] to be used.
    pub fn cipher(self) -> SymmetricCipher {
        match self {
            Self::PbeWithMd2AndDesCbc => SymmetricCipher::DesCbc,
            Self::PbeWithMd2AndRc2Cbc => SymmetricCipher::Rc2Cbc,
            Self::PbeWithMd5AndDesCbc => SymmetricCipher::DesCbc,
            Self::PbeWithMd5AndRc2Cbc => SymmetricCipher::Rc2Cbc,
            Self::PbeWithSha1AndDesCbc => SymmetricCipher::DesCbc,
            Self::PbeWithSha1AndRc2Cbc => SymmetricCipher::Rc2Cbc,
        }
    }

    /// Get the [`DigestAlgorithm`] to be used.
    pub fn digest(self) -> DigestAlgorithm {
        match self {
            Self::PbeWithMd2AndDesCbc => DigestAlgorithm::Md2,
            Self::PbeWithMd2AndRc2Cbc => DigestAlgorithm::Md2,
            Self::PbeWithMd5AndDesCbc => DigestAlgorithm::Md5,
            Self::PbeWithMd5AndRc2Cbc => DigestAlgorithm::Md5,
            Self::PbeWithSha1AndDesCbc => DigestAlgorithm::Sha1,
            Self::PbeWithSha1AndRc2Cbc => DigestAlgorithm::Sha1,
        }
    }

    /// Get the [`ObjectIdentifier`] (a.k.a OID) for this algorithm.
    pub fn oid(self) -> ObjectIdentifier {
        match self {
            Self::PbeWithMd2AndDesCbc => PBE_WITH_MD2_AND_DES_CBC_OID,
            Self::PbeWithMd2AndRc2Cbc => PBE_WITH_MD2_AND_RC2_CBC_OID,
            Self::PbeWithMd5AndDesCbc => PBE_WITH_MD5_AND_DES_CBC_OID,
            Self::PbeWithMd5AndRc2Cbc => PBE_WITH_MD5_AND_RC2_CBC_OID,
            Self::PbeWithSha1AndDesCbc => PBE_WITH_SHA1_AND_DES_CBC_OID,
            Self::PbeWithSha1AndRc2Cbc => PBE_WITH_SHA1_AND_RC2_CBC_OID,
        }
    }
}

impl Encode for EncryptionScheme {
    fn encoded_len(&self) -> der::Result<Length> {
        self.oid().encoded_len()
    }

    fn encode(&self, writer: &mut impl Writer) -> der::Result<()> {
        self.oid().encode(writer)
    }
}

/// Digest algorithms supported by PBES1.
#[derive(Copy, Clone, Debug, Eq, PartialEq)]
pub enum DigestAlgorithm {
    /// MD2
    Md2,

    /// MD5
    Md5,

    /// SHA-1
    Sha1,
}

/// Symmetric encryption ciphers supported by PBES1.
#[derive(Copy, Clone, Debug, Eq, PartialEq)]
pub enum SymmetricCipher {
    /// DES in CBC mode
    DesCbc,

    /// RC2 in CBC mode
    Rc2Cbc,
}
