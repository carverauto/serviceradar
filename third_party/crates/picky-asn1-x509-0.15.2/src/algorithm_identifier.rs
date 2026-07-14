use crate::oids;
use oid::ObjectIdentifier;
use picky_asn1::tag::{Tag, TagPeeker};
use picky_asn1::wrapper::{
    ExplicitContextTag0, ExplicitContextTag1, ExplicitContextTag2, IntegerAsn1, ObjectIdentifierAsn1, OctetStringAsn1,
};
use picky_asn1_der::Asn1RawDer;
use serde::{Deserialize, Serialize, de, ser};
use std::cmp::Ordering;
use std::error::Error;
use std::fmt;

/// unsupported algorithm
#[derive(Debug)]
pub struct UnsupportedAlgorithmError {
    pub algorithm: String,
}

impl fmt::Display for UnsupportedAlgorithmError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "unsupported algorithm:  {}", self.algorithm)
    }
}

impl Error for UnsupportedAlgorithmError {}

#[derive(Debug, PartialEq, Eq, Clone)]
pub struct AlgorithmIdentifier {
    algorithm: ObjectIdentifierAsn1,
    parameters: AlgorithmIdentifierParameters,
}

impl AlgorithmIdentifier {
    pub fn oid(&self) -> &ObjectIdentifier {
        &self.algorithm.0
    }

    pub fn oid_asn1(&self) -> &ObjectIdentifierAsn1 {
        &self.algorithm
    }

    pub fn parameters(&self) -> &AlgorithmIdentifierParameters {
        &self.parameters
    }

    pub fn is_a(&self, algorithm: ObjectIdentifier) -> bool {
        algorithm.eq(&self.algorithm.0)
    }

    pub fn is_one_of(&self, algorithms: impl IntoIterator<Item = ObjectIdentifier>) -> bool {
        algorithms.into_iter().any(|oid| self.is_a(oid))
    }

    pub fn new_md5_with_rsa_encryption() -> Self {
        Self {
            algorithm: oids::md5_with_rsa_encryption().into(),
            parameters: AlgorithmIdentifierParameters::Null,
        }
    }

    pub fn new_sha1_with_rsa_encryption() -> Self {
        Self {
            algorithm: oids::sha1_with_rsa_encryption().into(),
            parameters: AlgorithmIdentifierParameters::Null,
        }
    }

    pub fn new_sha1() -> Self {
        Self {
            algorithm: oids::sha1().into(),
            parameters: AlgorithmIdentifierParameters::Null,
        }
    }

    pub fn new_sha224_with_rsa_encryption() -> Self {
        Self {
            algorithm: oids::sha224_with_rsa_encryption().into(),
            parameters: AlgorithmIdentifierParameters::Null,
        }
    }

    pub fn new_sha256_with_rsa_encryption() -> Self {
        Self {
            algorithm: oids::sha256_with_rsa_encryption().into(),
            parameters: AlgorithmIdentifierParameters::Null,
        }
    }

    pub fn new_sha384_with_rsa_encryption() -> Self {
        Self {
            algorithm: oids::sha384_with_rsa_encryption().into(),
            parameters: AlgorithmIdentifierParameters::Null,
        }
    }

    pub fn new_sha512_with_rsa_encryption() -> Self {
        Self {
            algorithm: oids::sha512_with_rsa_encryption().into(),
            parameters: AlgorithmIdentifierParameters::Null,
        }
    }

    pub fn new_sha3_224_with_rsa_encryption() -> Self {
        Self {
            algorithm: oids::id_rsassa_pkcs1_v1_5_with_sha3_224().into(),
            parameters: AlgorithmIdentifierParameters::Null,
        }
    }

    pub fn new_sha3_256_with_rsa_encryption() -> Self {
        Self {
            algorithm: oids::id_rsassa_pkcs1_v1_5_with_sha3_256().into(),
            parameters: AlgorithmIdentifierParameters::Null,
        }
    }

    pub fn new_sha3_384_with_rsa_encryption() -> Self {
        Self {
            algorithm: oids::id_rsassa_pkcs1_v1_5_with_sha3_384().into(),
            parameters: AlgorithmIdentifierParameters::Null,
        }
    }

    pub fn new_sha3_512_with_rsa_encryption() -> Self {
        Self {
            algorithm: oids::id_rsassa_pkcs1_v1_5_with_sha3_512().into(),
            parameters: AlgorithmIdentifierParameters::Null,
        }
    }

    pub fn new_rsassa_pss(parameters: RsassaPssParams) -> Self {
        Self {
            algorithm: oids::rsassa_pss().into(),
            parameters: AlgorithmIdentifierParameters::RsassaPss(parameters),
        }
    }

    pub fn new_rsa_encryption() -> Self {
        Self {
            algorithm: oids::rsa_encryption().into(),
            parameters: AlgorithmIdentifierParameters::Null,
        }
    }

    pub fn new_rsa_encryption_with_sha(variant: ShaVariant) -> Result<Self, UnsupportedAlgorithmError> {
        let algorithm = match variant {
            ShaVariant::SHA2_224 => oids::sha224_with_rsa_encryption(),
            ShaVariant::SHA2_256 => oids::sha256_with_rsa_encryption(),
            ShaVariant::SHA2_384 => oids::sha384_with_rsa_encryption(),
            ShaVariant::SHA2_512 => oids::sha512_with_rsa_encryption(),
            ShaVariant::SHA3_384 => oids::id_rsassa_pkcs1_v1_5_with_sha3_384(),
            ShaVariant::SHA3_512 => oids::id_rsassa_pkcs1_v1_5_with_sha3_512(),
            _ => {
                return Err(UnsupportedAlgorithmError {
                    algorithm: format!("{:?}", variant),
                });
            }
        };

        Ok(Self {
            algorithm: algorithm.into(),
            parameters: AlgorithmIdentifierParameters::Null,
        })
    }

    pub fn new_dsa_with_sha1() -> Self {
        Self {
            algorithm: oids::dsa_with_sha1().into(),
            parameters: AlgorithmIdentifierParameters::Null,
        }
    }

    pub fn new_ecdsa_with_sha512() -> Self {
        Self {
            algorithm: oids::ecdsa_with_sha512().into(),
            parameters: AlgorithmIdentifierParameters::None,
        }
    }

    pub fn new_ecdsa_with_sha384() -> Self {
        Self {
            algorithm: oids::ecdsa_with_sha384().into(),
            parameters: AlgorithmIdentifierParameters::None,
        }
    }

    pub fn new_ecdsa_with_sha256() -> Self {
        Self {
            algorithm: oids::ecdsa_with_sha256().into(),
            parameters: AlgorithmIdentifierParameters::None,
        }
    }

    pub fn new_elliptic_curve(ec_params: EcParameters) -> Self {
        Self {
            algorithm: oids::ec_public_key().into(),
            parameters: AlgorithmIdentifierParameters::Ec(ec_params),
        }
    }

    /// Create new algorithm identifier without checking if the algorithm parameters are valid for
    /// the given algorithm.
    pub(crate) fn new_unchecked(algorithm: ObjectIdentifier, parameters: AlgorithmIdentifierParameters) -> Self {
        Self {
            algorithm: algorithm.into(),
            parameters,
        }
    }

    pub fn new_ed25519() -> Self {
        Self {
            algorithm: oids::ed25519().into(),
            parameters: AlgorithmIdentifierParameters::None,
        }
    }

    pub fn new_x25519() -> Self {
        Self {
            algorithm: oids::x25519().into(),
            parameters: AlgorithmIdentifierParameters::None,
        }
    }

    pub fn new_ed448() -> Self {
        Self {
            algorithm: oids::ed448().into(),
            parameters: AlgorithmIdentifierParameters::None,
        }
    }

    pub fn new_x448() -> Self {
        Self {
            algorithm: oids::x448().into(),
            parameters: AlgorithmIdentifierParameters::None,
        }
    }

    pub fn new_aes128(mode: AesMode, params: AesParameters) -> Self {
        Self {
            algorithm: mode.to_128bit_oid(),
            parameters: AlgorithmIdentifierParameters::Aes(params),
        }
    }

    pub fn new_aes192(mode: AesMode, params: AesParameters) -> Self {
        Self {
            algorithm: mode.to_192bit_oid(),
            parameters: AlgorithmIdentifierParameters::Aes(params),
        }
    }

    pub fn new_aes256(mode: AesMode, params: AesParameters) -> Self {
        Self {
            algorithm: mode.to_256bit_oid(),
            parameters: AlgorithmIdentifierParameters::Aes(params),
        }
    }

    pub fn new_aes256_empty(mode: AesMode) -> Self {
        Self {
            algorithm: mode.to_256bit_oid(),
            parameters: AlgorithmIdentifierParameters::None,
        }
    }

    pub fn new_sha(variant: ShaVariant) -> Self {
        Self {
            algorithm: variant.into(),
            parameters: AlgorithmIdentifierParameters::Null,
        }
    }

    pub fn new_ecdsa_with_sha3_224() -> Self {
        Self {
            algorithm: oids::id_ecdsa_with_sha3_224().into(),
            parameters: AlgorithmIdentifierParameters::None,
        }
    }

    pub fn new_ecdsa_with_sha3_256() -> Self {
        Self {
            algorithm: oids::id_ecdsa_with_sha3_256().into(),
            parameters: AlgorithmIdentifierParameters::None,
        }
    }

    pub fn new_ecdsa_with_sha3_384() -> Self {
        Self {
            algorithm: oids::id_ecdsa_with_sha3_384().into(),
            parameters: AlgorithmIdentifierParameters::None,
        }
    }

    pub fn new_ecdsa_with_sha3_512() -> Self {
        Self {
            algorithm: oids::id_ecdsa_with_sha3_512().into(),
            parameters: AlgorithmIdentifierParameters::None,
        }
    }

    pub fn new_mldsa_44() -> Self {
        Self {
            algorithm: oids::id_mldsa_44().into(),
            parameters: AlgorithmIdentifierParameters::None,
        }
    }

    pub fn new_mldsa_65() -> Self {
        Self {
            algorithm: oids::id_mldsa_65().into(),
            parameters: AlgorithmIdentifierParameters::None,
        }
    }

    pub fn new_mldsa_87() -> Self {
        Self {
            algorithm: oids::id_mldsa_87().into(),
            parameters: AlgorithmIdentifierParameters::None,
        }
    }
}

impl ser::Serialize for AlgorithmIdentifier {
    fn serialize<S>(&self, serializer: S) -> Result<<S as ser::Serializer>::Ok, <S as ser::Serializer>::Error>
    where
        S: ser::Serializer,
    {
        use ser::SerializeSeq;
        let mut seq = serializer.serialize_seq(Some(2))?;
        seq.serialize_element(&self.algorithm)?;
        match &self.parameters {
            AlgorithmIdentifierParameters::None => {}
            AlgorithmIdentifierParameters::Null => {
                seq.serialize_element(&())?;
            }
            AlgorithmIdentifierParameters::Ec(ec_params) => {
                seq.serialize_element(ec_params)?;
            }
            AlgorithmIdentifierParameters::Aes(aes_params) => {
                seq.serialize_element(aes_params)?;
            }
            AlgorithmIdentifierParameters::RsassaPss(rsa_params) => {
                seq.serialize_element(rsa_params)?;
            }
        }
        seq.end()
    }
}

impl<'de> de::Deserialize<'de> for AlgorithmIdentifier {
    fn deserialize<D>(deserializer: D) -> Result<Self, <D as de::Deserializer<'de>>::Error>
    where
        D: de::Deserializer<'de>,
    {
        struct Visitor;

        impl<'de> de::Visitor<'de> for Visitor {
            type Value = AlgorithmIdentifier;

            fn expecting(&self, formatter: &mut fmt::Formatter) -> fmt::Result {
                formatter.write_str("a valid DER-encoded algorithm identifier")
            }

            fn visit_seq<A>(self, mut seq: A) -> Result<Self::Value, A::Error>
            where
                A: de::SeqAccess<'de>,
            {
                let oid: ObjectIdentifierAsn1 = seq_next_element!(seq, AlgorithmIdentifier, "algorithm oid");

                let args = match Into::<String>::into(&oid.0).as_str() {
                    oids::RSA_ENCRYPTION
                    | oids::SHA1_WITH_RSA_ENCRYPTION
                    | oids::SHA224_WITH_RSA_ENCRYPTION
                    | oids::SHA256_WITH_RSA_ENCRYPTION
                    | oids::SHA384_WITH_RSA_ENCRYPTION
                    | oids::SHA512_WITH_RSA_ENCRYPTION
                    | oids::ID_RSASSA_PKCS1_V1_5_WITH_SHA3_224
                    | oids::ID_RSASSA_PKCS1_V1_5_WITH_SHA3_256
                    | oids::ID_RSASSA_PKCS1_V1_5_WITH_SHA3_384
                    | oids::ID_RSASSA_PKCS1_V1_5_WITH_SHA3_512 => {
                        // Try to deserialize next element in sequence.
                        // Error is ignored because some implementations just leave no parameter at all for
                        // RSA encryption (ie: rsa-export-0.1.1 crate) but we still want to be able
                        // to parse their output.
                        let _ = seq.next_element::<()>();
                        AlgorithmIdentifierParameters::Null
                    }
                    oids::RSASSA_PSS => AlgorithmIdentifierParameters::RsassaPss(seq_next_element!(
                        seq,
                        RsassaPssParams,
                        "RSASSA-PSS parameters"
                    )),
                    oids::ECDSA_WITH_SHA384
                    | oids::ECDSA_WITH_SHA256
                    | oids::ECDSA_WITH_SHA512
                    | oids::ID_ECDSA_WITH_SHA3_224
                    | oids::ID_ECDSA_WITH_SHA3_256
                    | oids::ID_ECDSA_WITH_SHA3_384
                    | oids::ID_ECDSA_WITH_SHA3_512
                    | oids::ED25519
                    | oids::ED448
                    | oids::X25519
                    | oids::X448
                    | oids::ID_MLDSA_44
                    | oids::ID_MLDSA_65
                    | oids::ID_MLDSA_87 => AlgorithmIdentifierParameters::None,
                    oids::DSA_WITH_SHA1 => {
                        // A note from [RFC 3927](https://www.ietf.org/rfc/rfc3279.txt)
                        // When the id-dsa-with-sha1 algorithm identifier appears as the
                        // algorithm field in an AlgorithmIdentifier, the encoding SHALL omit
                        // the parameters field.  That is, the AlgorithmIdentifier SHALL be a
                        // SEQUENCE of one component: the OBJECT IDENTIFIER id-dsa-with-sha1.
                        AlgorithmIdentifierParameters::None
                    }
                    // A note from [RFC 5480](https://tools.ietf.org/html/rfc5480#section-2.1.1)
                    // The parameter for id-ecPublicKey is as follows and MUST always be present
                    oids::EC_PUBLIC_KEY => AlgorithmIdentifierParameters::Ec(seq_next_element!(
                        seq,
                        EcParameters,
                        AlgorithmIdentifier,
                        "elliptic curves parameters"
                    )),
                    // AES
                    x if x.starts_with("2.16.840.1.101.3.4.1.") => {
                        if let Some(aes_parameters) = seq.next_element()? {
                            AlgorithmIdentifierParameters::Aes(aes_parameters)
                        } else {
                            AlgorithmIdentifierParameters::None
                        }
                    }
                    // SHA
                    x if x.starts_with("2.16.840.1.101.3.4.2.") || x == oids::SHA1 => {
                        type Unit = ();
                        seq_next_element!(seq, Unit, AlgorithmIdentifier, "sha algorithm identifier");
                        AlgorithmIdentifierParameters::Null
                    }
                    _ => {
                        return Err(serde_invalid_value!(
                            AlgorithmIdentifier,
                            "unsupported algorithm (unknown oid)",
                            "a supported algorithm"
                        ));
                    }
                };

                Ok(AlgorithmIdentifier {
                    algorithm: oid,
                    parameters: args,
                })
            }
        }

        deserializer.deserialize_seq(Visitor)
    }
}

#[derive(Debug, PartialEq, Eq, Clone)]
pub enum AlgorithmIdentifierParameters {
    None,
    Null,
    Aes(AesParameters),
    Ec(EcParameters),
    RsassaPss(RsassaPssParams),
}

/// [RFC 4055 #3.1](https://www.rfc-editor.org/rfc/rfc4055#section-3.1)
///
/// ```not_rust
///       RSASSA-PSS-params  ::=  SEQUENCE  {
///           hashAlgorithm      [0] HashAlgorithm DEFAULT
///                                     sha1Identifier,
///           maskGenAlgorithm   [1] MaskGenAlgorithm DEFAULT
///                                     mgf1SHA1Identifier,
///           saltLength         [2] INTEGER DEFAULT 20,
///           trailerField       [3] INTEGER DEFAULT 1  }
/// ```
///
/// Implementations that perform signature generation MUST omit the trailerField
/// field, indicating that the default trailer field value was used... thus the
/// reason no trailer field is specified in this structure.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct RsassaPssParams {
    pub hash_algorithm: HashAlgorithm,
    pub mask_gen_algorithm: MaskGenAlgorithm,
    pub salt_length: usize,
}

impl RsassaPssParams {
    pub fn new(hash_algorithm: HashAlgorithm) -> Self {
        Self {
            hash_algorithm,
            mask_gen_algorithm: MaskGenAlgorithm::new(hash_algorithm),
            salt_length: hash_algorithm.len(),
        }
    }
}

impl ser::Serialize for RsassaPssParams {
    fn serialize<S>(&self, serializer: S) -> Result<<S as ser::Serializer>::Ok, <S as ser::Serializer>::Error>
    where
        S: ser::Serializer,
    {
        use ser::SerializeSeq;
        let mut seq = serializer.serialize_seq(Some(3))?;
        seq.serialize_element(&ExplicitContextTag0(&self.hash_algorithm))?;
        seq.serialize_element(&ExplicitContextTag1(&self.mask_gen_algorithm))?;
        seq.serialize_element(&ExplicitContextTag2(&IntegerAsn1::from_bytes_be_signed(
            self.salt_length.to_be_bytes().to_vec(),
        )))?;
        seq.end()
    }
}

fn usize_from_be_bytes(asn1: &IntegerAsn1) -> usize {
    let bytes = asn1.as_unsigned_bytes_be();
    match bytes.len().cmp(&8) {
        Ordering::Greater => usize::MAX,
        Ordering::Less => {
            const USIZE_SIZE: usize = std::mem::size_of::<usize>();

            let mut tmp = [0; USIZE_SIZE];
            tmp[(USIZE_SIZE - bytes.len())..USIZE_SIZE].clone_from_slice(bytes);
            usize::from_be_bytes(tmp)
        }
        // unwrap is safe since we know this is exactly 8 bytes.
        Ordering::Equal => usize::from_be_bytes(bytes.try_into().unwrap()),
    }
}

impl<'de> de::Deserialize<'de> for RsassaPssParams {
    fn deserialize<D>(deserializer: D) -> Result<Self, <D as de::Deserializer<'de>>::Error>
    where
        D: de::Deserializer<'de>,
    {
        struct Visitor;

        impl<'de> de::Visitor<'de> for Visitor {
            type Value = RsassaPssParams;

            fn expecting(&self, formatter: &mut fmt::Formatter) -> fmt::Result {
                formatter.write_str("a valid DER-encoded RsassaPssParams")
            }

            fn visit_seq<A>(self, mut seq: A) -> Result<Self::Value, A::Error>
            where
                A: de::SeqAccess<'de>,
            {
                let hash = seq_next_element!(seq, ExplicitContextTag0<HashAlgorithm>, HashAlgorithm, "cont [0]");
                let mask_gen = seq_next_element!(
                    seq,
                    ExplicitContextTag1<MaskGenAlgorithm>,
                    MaskGenAlgorithm,
                    "maskGenAlgorithm"
                );
                let salt = seq_next_element!(seq, ExplicitContextTag2<IntegerAsn1>, IntegerAsn1, "saltLength");
                Ok(RsassaPssParams {
                    hash_algorithm: hash.0,
                    mask_gen_algorithm: mask_gen.0,
                    salt_length: usize_from_be_bytes(&salt.0),
                })
            }
        }

        deserializer.deserialize_seq(Visitor)
    }
}

// https://www.rfc-editor.org/rfc/rfc4055#section-2.1
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
#[allow(non_camel_case_types)]
pub enum HashAlgorithm {
    // Nobody should be using SHA1 in 2023, it is completely broken... and the RFC for RsassaPssParams
    // adds needless complexity in regard to requiring the omission of parameters if SHA1 is used.
    //SHA1,
    SHA224,
    SHA256,
    SHA384,
    SHA512,

    SHA3_224,
    SHA3_256,
    SHA3_384,
    SHA3_512,
}

impl HashAlgorithm {
    pub fn len(&self) -> usize {
        use HashAlgorithm::*;
        match self {
            SHA224 => 28,
            SHA256 => 32,
            SHA384 => 48,
            SHA512 => 64,
            SHA3_224 => 28,
            SHA3_256 => 32,
            SHA3_384 => 48,
            SHA3_512 => 64,
        }
    }
    pub fn is_empty(&self) -> bool {
        false
    }
}
impl From<&HashAlgorithm> for ObjectIdentifierAsn1 {
    fn from(variant: &HashAlgorithm) -> Self {
        use HashAlgorithm::*;
        match variant {
            //SHA1 => oids::sha1().into(),
            SHA224 => oids::sha224().into(),
            SHA256 => oids::sha256().into(),
            SHA384 => oids::sha384().into(),
            SHA512 => oids::sha512().into(),
            SHA3_224 => oids::sha3_224().into(),
            SHA3_256 => oids::sha3_256().into(),
            SHA3_384 => oids::sha384().into(),
            SHA3_512 => oids::sha512().into(),
        }
    }
}

impl TryFrom<ObjectIdentifierAsn1> for HashAlgorithm {
    type Error = UnsupportedAlgorithmError;

    fn try_from(oid: ObjectIdentifierAsn1) -> Result<Self, Self::Error> {
        match Into::<String>::into(oid.0).as_str() {
            //oids::SHA1 => Ok(HashAlgorithm::SHA1),
            oids::SHA224 => Ok(HashAlgorithm::SHA224),
            oids::SHA256 => Ok(HashAlgorithm::SHA256),
            oids::SHA384 => Ok(HashAlgorithm::SHA384),
            oids::SHA512 => Ok(HashAlgorithm::SHA512),
            oids::SHA3_224 => Ok(HashAlgorithm::SHA3_224),
            oids::SHA3_256 => Ok(HashAlgorithm::SHA3_256),
            oids::SHA3_384 => Ok(HashAlgorithm::SHA3_384),
            oids::SHA3_512 => Ok(HashAlgorithm::SHA3_512),
            unsupported => Err(UnsupportedAlgorithmError {
                algorithm: unsupported.to_string(),
            }),
        }
    }
}

impl ser::Serialize for HashAlgorithm {
    fn serialize<S>(&self, serializer: S) -> Result<<S as ser::Serializer>::Ok, <S as ser::Serializer>::Error>
    where
        S: ser::Serializer,
    {
        use ser::SerializeSeq;
        let mut seq = serializer.serialize_seq(Some(2))?;
        seq.serialize_element(&ObjectIdentifierAsn1::from(self))?;
        seq.serialize_element(&())?;
        seq.end()
    }
}

impl<'de> de::Deserialize<'de> for HashAlgorithm {
    fn deserialize<D>(deserializer: D) -> Result<Self, <D as de::Deserializer<'de>>::Error>
    where
        D: de::Deserializer<'de>,
    {
        struct Visitor;

        impl<'de> de::Visitor<'de> for Visitor {
            type Value = HashAlgorithm;

            fn expecting(&self, formatter: &mut fmt::Formatter) -> fmt::Result {
                formatter.write_str("a valid DER-encoded HashAlgorithm")
            }

            fn visit_seq<A>(self, mut seq: A) -> Result<Self::Value, A::Error>
            where
                A: de::SeqAccess<'de>,
            {
                let oid: ObjectIdentifierAsn1 = seq_next_element!(seq, ObjectIdentifierAsn1, "oid of hashAlgorithm");
                let _: Option<()> = seq.next_element()?;
                oid.try_into().map_err(|_| {
                    serde_invalid_value!(
                        HashAlgorithm,
                        "unsupported or unknown hash algorithm",
                        "a supported hash algorithm"
                    )
                })
            }
        }

        deserializer.deserialize_seq(Visitor)
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct MaskGenAlgorithm {
    pub mask_gen_algorithm: ObjectIdentifierAsn1,
    pub hash_algorithm: HashAlgorithm,
}

impl MaskGenAlgorithm {
    pub fn new(hash_algorithm: HashAlgorithm) -> Self {
        Self {
            mask_gen_algorithm: ObjectIdentifierAsn1::from(oids::id_mgf1()),
            hash_algorithm,
        }
    }
}

impl ser::Serialize for MaskGenAlgorithm {
    fn serialize<S>(&self, serializer: S) -> Result<<S as ser::Serializer>::Ok, <S as ser::Serializer>::Error>
    where
        S: ser::Serializer,
    {
        use ser::SerializeSeq;
        let mut seq = serializer.serialize_seq(Some(2))?;
        seq.serialize_element(&self.mask_gen_algorithm)?;
        seq.serialize_element(&self.hash_algorithm)?;
        seq.end()
    }
}

impl<'de> de::Deserialize<'de> for MaskGenAlgorithm {
    fn deserialize<D>(deserializer: D) -> Result<Self, <D as de::Deserializer<'de>>::Error>
    where
        D: de::Deserializer<'de>,
    {
        struct Visitor;

        impl<'de> de::Visitor<'de> for Visitor {
            type Value = MaskGenAlgorithm;

            fn expecting(&self, formatter: &mut fmt::Formatter) -> fmt::Result {
                formatter.write_str("a valid DER-encoded MaskGenAlgorithm")
            }

            fn visit_seq<A>(self, mut seq: A) -> Result<Self::Value, A::Error>
            where
                A: de::SeqAccess<'de>,
            {
                let mask_gen_algorithm: ObjectIdentifierAsn1 =
                    seq_next_element!(seq, ObjectIdentifierAsn1, "oid of maskGenAlgorithm");
                let hash_algorithm: HashAlgorithm = seq_next_element!(seq, HashAlgorithm, "hashAlgorithm");
                Ok(MaskGenAlgorithm {
                    mask_gen_algorithm,
                    hash_algorithm,
                })
            }
        }

        deserializer.deserialize_seq(Visitor)
    }
}

#[derive(Debug, PartialEq, Eq, Clone)]
pub enum EcParameters {
    NamedCurve(ObjectIdentifierAsn1),
    // -- implicitCurve and specifiedCurve MUST NOT be used in PKIX.
    // ImplicitCurve,
    // SpecifiedCurve(SpecifiedECDomain)
}

impl EcParameters {
    pub fn curve_oid(&self) -> &ObjectIdentifier {
        match self {
            EcParameters::NamedCurve(oid) => &oid.0,
        }
    }
}

impl From<ObjectIdentifierAsn1> for EcParameters {
    fn from(oid: ObjectIdentifierAsn1) -> Self {
        Self::NamedCurve(oid)
    }
}

impl From<ObjectIdentifier> for EcParameters {
    fn from(oid: ObjectIdentifier) -> Self {
        Self::NamedCurve(oid.into())
    }
}

impl ser::Serialize for EcParameters {
    fn serialize<S>(&self, serializer: S) -> Result<<S as ser::Serializer>::Ok, <S as ser::Serializer>::Error>
    where
        S: ser::Serializer,
    {
        match &self {
            EcParameters::NamedCurve(oid) => oid.serialize(serializer),
        }
    }
}

impl<'de> de::Deserialize<'de> for EcParameters {
    fn deserialize<D>(deserializer: D) -> Result<Self, <D as de::Deserializer<'de>>::Error>
    where
        D: de::Deserializer<'de>,
    {
        struct Visitor;

        impl<'de> de::Visitor<'de> for Visitor {
            type Value = EcParameters;

            fn expecting(&self, formatter: &mut fmt::Formatter) -> fmt::Result {
                formatter.write_str("a valid DER-encoded DirectoryString")
            }

            fn visit_seq<A>(self, mut seq: A) -> Result<Self::Value, A::Error>
            where
                A: de::SeqAccess<'de>,
            {
                let tag_peeker: TagPeeker = seq_next_element!(seq, EcParameters, "choice tag");

                let curve_oid = match tag_peeker.next_tag {
                    Tag::OID => seq_next_element!(seq, ObjectIdentifierAsn1, "NamedCurve object identifier"),
                    _ => {
                        return Err(serde_invalid_value!(
                            EcParameters,
                            "unsupported or unknown elliptic curve parameter",
                            "a supported elliptic curve parameter"
                        ));
                    }
                };

                Ok(EcParameters::NamedCurve(curve_oid))
            }
        }

        deserializer.deserialize_enum("DirectoryString", &["NamedCurve", "ImplicitCurve"], Visitor)
    }
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum AesMode {
    Ecb,
    Cbc,
    Ofb,
    Cfb,
    Wrap,
    Gcm,
    Ccm,
    WrapPad,
}

#[derive(Debug, PartialEq, Eq, Clone)]
pub enum AesParameters {
    Null,
    InitializationVector(OctetStringAsn1),
    AuthenticatedEncryptionParameters(AesAuthEncParams),
}

#[derive(serde::Serialize, serde::Deserialize, Debug, PartialEq, Eq, Clone)]
pub struct AesAuthEncParams {
    pub(crate) nonce: OctetStringAsn1,
    pub(crate) icv_len: IntegerAsn1,
}

impl AesAuthEncParams {
    pub fn new(nonce: Vec<u8>, icv_len: usize) -> Self {
        Self {
            nonce: OctetStringAsn1::from(nonce),
            icv_len: IntegerAsn1::from(
                icv_len
                    .to_be_bytes()
                    // Remove leading zeroes.
                    .into_iter()
                    .skip_while(|n| *n == 0)
                    .collect::<Vec<_>>(),
            ),
        }
    }

    pub fn nonce(&self) -> &[u8] {
        &self.nonce.0
    }

    pub fn icv_len(&self) -> &[u8] {
        &self.icv_len.0
    }
}

impl AesMode {
    fn to_128bit_oid(self) -> ObjectIdentifierAsn1 {
        match self {
            AesMode::Ecb => oids::aes128_ecb().into(),
            AesMode::Cbc => oids::aes128_cbc().into(),
            AesMode::Ofb => oids::aes128_ofb().into(),
            AesMode::Cfb => oids::aes128_cfb().into(),
            AesMode::Wrap => oids::aes128_wrap().into(),
            AesMode::Gcm => oids::aes128_gcm().into(),
            AesMode::Ccm => oids::aes128_ccm().into(),
            AesMode::WrapPad => oids::aes128_wrap_pad().into(),
        }
    }

    fn to_192bit_oid(self) -> ObjectIdentifierAsn1 {
        match self {
            AesMode::Ecb => oids::aes192_ecb().into(),
            AesMode::Cbc => oids::aes192_cbc().into(),
            AesMode::Ofb => oids::aes192_ofb().into(),
            AesMode::Cfb => oids::aes192_cfb().into(),
            AesMode::Wrap => oids::aes192_wrap().into(),
            AesMode::Gcm => oids::aes192_gcm().into(),
            AesMode::Ccm => oids::aes192_ccm().into(),
            AesMode::WrapPad => oids::aes192_wrap_pad().into(),
        }
    }

    fn to_256bit_oid(self) -> ObjectIdentifierAsn1 {
        match self {
            AesMode::Ecb => oids::aes256_ecb().into(),
            AesMode::Cbc => oids::aes256_cbc().into(),
            AesMode::Ofb => oids::aes256_ofb().into(),
            AesMode::Cfb => oids::aes256_cfb().into(),
            AesMode::Wrap => oids::aes256_wrap().into(),
            AesMode::Gcm => oids::aes256_gcm().into(),
            AesMode::Ccm => oids::aes256_ccm().into(),
            AesMode::WrapPad => oids::aes256_wrap_pad().into(),
        }
    }
}

impl ser::Serialize for AesParameters {
    fn serialize<S>(&self, serializer: S) -> Result<<S as ser::Serializer>::Ok, <S as ser::Serializer>::Error>
    where
        S: ser::Serializer,
    {
        match self {
            AesParameters::Null => ().serialize(serializer),
            AesParameters::InitializationVector(iv) => iv.serialize(serializer),
            AesParameters::AuthenticatedEncryptionParameters(params) => params.serialize(serializer),
        }
    }
}

impl<'de> de::Deserialize<'de> for AesParameters {
    fn deserialize<D>(deserializer: D) -> Result<Self, <D as de::Deserializer<'de>>::Error>
    where
        D: de::Deserializer<'de>,
    {
        struct Visitor;

        impl<'de> de::Visitor<'de> for Visitor {
            type Value = AesParameters;

            fn expecting(&self, formatter: &mut fmt::Formatter) -> fmt::Result {
                formatter.write_str("a valid DER-encoded DirectoryString")
            }

            fn visit_seq<A>(self, mut seq: A) -> Result<Self::Value, A::Error>
            where
                A: de::SeqAccess<'de>,
            {
                let tag_peeker: TagPeeker = seq_next_element!(seq, AesParameters, "choice tag");
                match tag_peeker.next_tag {
                    Tag::OCTET_STRING => Ok(AesParameters::InitializationVector(seq_next_element!(
                        seq,
                        AesParameters,
                        "Object Identifier"
                    ))),
                    Tag::NULL => {
                        seq.next_element::<()>()?.expect("should not panic");
                        Ok(AesParameters::Null)
                    }
                    Tag::SEQUENCE => Ok(AesParameters::AuthenticatedEncryptionParameters(seq_next_element!(
                        seq,
                        AesAuthEncParams,
                        "AES Authenticated Encryption parameters"
                    ))),
                    _ => Err(serde_invalid_value!(
                        AesParameters,
                        "unsupported or unknown AES parameter",
                        "a supported AES parameter"
                    )),
                }
            }
        }

        deserializer.deserialize_enum(
            "DirectoryString",
            &["Null", "InitializationVector", "AuthenticatedEncryptionParameters"],
            Visitor,
        )
    }
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
#[allow(non_camel_case_types)] // 'SHA2_512_224' is clearer than 'SHA2512224' or 'Sha2512224' imo
pub enum ShaVariant {
    // TODO: rename enum (breaking)
    MD5,
    SHA1,
    SHA2_224,
    SHA2_256,
    SHA2_384,
    SHA2_512,
    SHA2_512_224,
    SHA2_512_256,
    SHA3_224,
    SHA3_256,
    SHA3_384,
    SHA3_512,
    SHAKE128,
    SHAKE256,
}

impl From<ShaVariant> for ObjectIdentifierAsn1 {
    fn from(variant: ShaVariant) -> Self {
        match variant {
            ShaVariant::MD5 => oids::md5().into(),
            ShaVariant::SHA1 => oids::sha1().into(),
            ShaVariant::SHA2_224 => oids::sha224().into(),
            ShaVariant::SHA2_256 => oids::sha256().into(),
            ShaVariant::SHA2_384 => oids::sha384().into(),
            ShaVariant::SHA2_512 => oids::sha512().into(),
            ShaVariant::SHA2_512_224 => oids::sha512_224().into(),
            ShaVariant::SHA2_512_256 => oids::sha512_256().into(),
            ShaVariant::SHA3_224 => oids::sha3_224().into(),
            ShaVariant::SHA3_256 => oids::sha3_256().into(),
            ShaVariant::SHA3_384 => oids::sha3_384().into(),
            ShaVariant::SHA3_512 => oids::sha3_512().into(),
            ShaVariant::SHAKE128 => oids::shake128().into(),
            ShaVariant::SHAKE256 => oids::shake256().into(),
        }
    }
}

impl TryFrom<ObjectIdentifierAsn1> for ShaVariant {
    type Error = UnsupportedAlgorithmError;

    fn try_from(oid: ObjectIdentifierAsn1) -> Result<Self, Self::Error> {
        match Into::<String>::into(oid.0).as_str() {
            oids::MD5 => Ok(ShaVariant::MD5),
            oids::SHA1 => Ok(ShaVariant::SHA1),
            oids::SHA224 => Ok(ShaVariant::SHA2_224),
            oids::SHA256 => Ok(ShaVariant::SHA2_256),
            oids::SHA384 => Ok(ShaVariant::SHA2_384),
            oids::SHA512 => Ok(ShaVariant::SHA2_512),
            oids::SHA512_224 => Ok(ShaVariant::SHA2_512_224),
            oids::SHA512_256 => Ok(ShaVariant::SHA2_512_256),
            oids::SHA3_224 => Ok(ShaVariant::SHA3_224),
            oids::SHA3_256 => Ok(ShaVariant::SHA3_256),
            oids::SHA3_384 => Ok(ShaVariant::SHA3_384),
            oids::SHA3_512 => Ok(ShaVariant::SHA3_512),
            oids::SHAKE128 => Ok(ShaVariant::SHAKE128),
            oids::SHAKE256 => Ok(ShaVariant::SHAKE256),
            unsupported => Err(UnsupportedAlgorithmError {
                algorithm: unsupported.to_string(),
            }),
        }
    }
}

/// [PKCS #1: RSA Cryptography Specifications Version
/// 2.2](https://tools.ietf.org/html/rfc8017.html#section-9.2)
///
/// # Section 9.2
///
/// The type DigestInfo has the syntax:
///
/// ```not_rust
///    DigestInfo ::= SEQUENCE {
///        digestAlgorithm AlgorithmIdentifier,
///        digest OCTET STRING
///    }
/// ```
#[derive(Serialize, Deserialize, Debug, Clone, PartialEq, Eq)]
pub struct DigestInfo {
    pub oid: AlgorithmIdentifier,
    pub digest: OctetStringAsn1,
}

/// Raw representation of `AlgorithmIdentifier` ASN.1 type to allow parsing unknown algorithms.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RawAlgorithmIdentifier {
    algorithm: ObjectIdentifier,
    /// Parameters here are defined in X509 as follows:
    /// ```not_rust
    /// parameters ANY DEFINED BY algorithm OPTIONAL
    /// ```
    /// therefore we will parse it as raw DER and allow user to parse it later.
    parameters: Option<Asn1RawDer>,
}

impl RawAlgorithmIdentifier {
    /// Create new `RawAlgorithmIdentifier` from algorithm OID and optional parameters.
    pub fn from_parts(algorithm: ObjectIdentifier, parameters: Option<Asn1RawDer>) -> Self {
        let parameters = parameters.and_then(|raw| {
            // `params` field is always present and set to NULL if no parameters are needed.
            // therefore, we need special handling to show absence of parameters in
            // `RawAlgorithmIdentifier` API
            if raw.0 == [0x05, 0x00] { None } else { Some(raw) }
        });

        Self { algorithm, parameters }
    }

    pub fn algorithm(&self) -> &ObjectIdentifier {
        &self.algorithm
    }

    pub fn parameters(&self) -> Option<&Asn1RawDer> {
        self.parameters.as_ref()
    }
}

impl ser::Serialize for RawAlgorithmIdentifier {
    fn serialize<S>(&self, serializer: S) -> Result<S::Ok, S::Error>
    where
        S: ser::Serializer,
    {
        use ser::SerializeSeq;

        let mut seq = serializer.serialize_seq(Some(2))?;
        let oid = ObjectIdentifierAsn1(self.algorithm.clone());
        seq.serialize_element(&oid)?;
        if let Some(parameters) = &self.parameters {
            seq.serialize_element(parameters)?;
        } else {
            // NULL should be still serialized to AlgortihmIdentifier even if params are absent
            seq.serialize_element(&())?;
        }
        seq.end()
    }
}

impl<'de> de::Deserialize<'de> for RawAlgorithmIdentifier {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: de::Deserializer<'de>,
    {
        struct RawAlgorithmIdentifierVisitor;

        impl<'de> de::Visitor<'de> for RawAlgorithmIdentifierVisitor {
            type Value = RawAlgorithmIdentifier;

            fn expecting(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
                formatter.write_str("a valid DER-encoded RawAlgorithmIdentifier")
            }

            fn visit_seq<A>(self, mut seq: A) -> Result<Self::Value, A::Error>
            where
                A: de::SeqAccess<'de>,
            {
                let oid: ObjectIdentifierAsn1 = seq_next_element!(seq, RawAlgorithmIdentifier, "raw algorithm oid");

                let algorithm = oid.0;
                let parameters: Option<Asn1RawDer> = seq.next_element::<Asn1RawDer>()?;
                Ok(RawAlgorithmIdentifier::from_parts(algorithm, parameters))
            }
        }

        deserializer.deserialize_seq(RawAlgorithmIdentifierVisitor)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use base64::Engine as _;
    use base64::engine::general_purpose;

    #[test]
    fn aes_null_params() {
        let expected = [48, 13, 6, 9, 96, 134, 72, 1, 101, 3, 4, 1, 1, 5, 0];
        let aes_id = AlgorithmIdentifier::new_aes128(AesMode::Ecb, AesParameters::Null);
        check_serde!(aes_id: AlgorithmIdentifier in expected);
    }

    #[test]
    fn aes_iv_params() {
        let expected = [
            48, 25, 6, 9, 96, 134, 72, 1, 101, 3, 4, 1, 1, 4, 12, 165, 165, 165, 165, 165, 165, 165, 165, 165, 165,
            165, 165,
        ];
        let aes_id =
            AlgorithmIdentifier::new_aes128(AesMode::Ecb, AesParameters::InitializationVector(vec![0xA5; 12].into()));
        check_serde!(aes_id: AlgorithmIdentifier in expected);
    }

    #[test]
    fn aes_ae_params() {
        let expected = [
            48, 30, 6, 9, 96, 134, 72, 1, 101, 3, 4, 1, 1, 48, 17, 4, 12, 255, 255, 255, 255, 255, 255, 255, 255, 255,
            255, 255, 255, 2, 1, 12,
        ];
        let aes_id = AlgorithmIdentifier::new_aes128(
            AesMode::Ecb,
            AesParameters::AuthenticatedEncryptionParameters(AesAuthEncParams {
                nonce: vec![0xff; 12].into(),
                icv_len: vec![12].into(),
            }),
        );
        check_serde!(aes_id: AlgorithmIdentifier in expected);
    }

    #[test]
    fn sha256() {
        let expected = [48, 13, 6, 9, 96, 134, 72, 1, 101, 3, 4, 2, 1, 5, 0];
        let sha = AlgorithmIdentifier::new_sha(ShaVariant::SHA2_256);
        check_serde!(sha: AlgorithmIdentifier in expected);
    }

    #[test]
    fn sha3_256() {
        let expected = [
            0x30, 0x0d, 0x06, 0x09, 0x60, 0x86, 0x48, 0x01, 0x65, 0x03, 0x04, 0x02, 0x08, 0x05, 0x00,
        ];
        let sha = AlgorithmIdentifier::new_sha(ShaVariant::SHA3_256);
        check_serde!(sha: AlgorithmIdentifier in expected);
    }

    #[test]
    fn rsa_enc_with_sha3_256() {
        let expected = [
            0x30, 0x0d, 0x06, 0x09, 0x60, 0x86, 0x48, 0x01, 0x65, 0x03, 0x04, 0x03, 0x0e, 0x05, 0x00,
        ];
        let sha = AlgorithmIdentifier::new_sha3_256_with_rsa_encryption();
        check_serde!(sha: AlgorithmIdentifier in expected);
    }

    #[test]
    fn ecdsa_with_sha3_512() {
        let expected = [
            0x30, 0x0B, 0x06, 0x09, 0x60, 0x86, 0x48, 0x01, 0x65, 0x03, 0x04, 0x03, 0x0C,
        ];
        let sha = AlgorithmIdentifier::new_ecdsa_with_sha3_512();
        check_serde!(sha: AlgorithmIdentifier in expected);
    }

    #[test]
    fn ec_params() {
        let expected = [
            48, 19, 6, 7, 42, 134, 72, 206, 61, 2, 1, 6, 8, 42, 134, 72, 206, 61, 4, 3, 2,
        ];
        let ec_params =
            AlgorithmIdentifier::new_elliptic_curve(EcParameters::NamedCurve(oids::ecdsa_with_sha256().into()));
        check_serde!(ec_params: AlgorithmIdentifier in expected);
    }

    #[test]
    fn digest_info() {
        let digest = picky_asn1_der::to_vec(&DigestInfo {
            oid: AlgorithmIdentifier::new_sha(ShaVariant::SHA2_256),
            // Random 32 bytes generated for a SHA256 hash
            digest: vec![
                0xf4, 0x12, 0x6b, 0x55, 0xbf, 0xcf, 0x8c, 0xc4, 0xe9, 0xe0, 0xbe, 0x5a, 0x9c, 0x16, 0x88, 0x55, 0x0f,
                0x26, 0x00, 0x8c, 0x2c, 0xa5, 0xf6, 0xaf, 0xbd, 0xe7, 0x9c, 0x42, 0x22, 0xe9, 0x25, 0xed,
            ]
            .into(),
        })
        .unwrap();

        let expected = vec![
            0x30, 0x31, 0x30, 0x0D, 0x06, 0x09, 0x60, 0x86, 0x48, 0x01, 0x65, 0x03, 0x04, 0x02, 0x01, 0x05, 0x00, 0x04,
            0x20, 0xf4, 0x12, 0x6b, 0x55, 0xbf, 0xcf, 0x8c, 0xc4, 0xe9, 0xe0, 0xbe, 0x5a, 0x9c, 0x16, 0x88, 0x55, 0x0f,
            0x26, 0x00, 0x8c, 0x2c, 0xa5, 0xf6, 0xaf, 0xbd, 0xe7, 0x9c, 0x42, 0x22, 0xe9, 0x25, 0xed,
        ];

        assert_eq!(digest, expected);
    }

    #[test]
    fn rsa_pss_params_sha256() {
        let expected = [
            0x30, 0x34, 0xa0, 0x0f, 0x30, 0x0d, 0x06, 0x09, 0x60, 0x86, 0x48, 0x01, 0x65, 0x03, 0x04, 0x02, 0x01, 0x05,
            0x00, 0xa1, 0x1c, 0x30, 0x1a, 0x06, 0x09, 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x08, 0x30, 0x0d,
            0x06, 0x09, 0x60, 0x86, 0x48, 0x01, 0x65, 0x03, 0x04, 0x02, 0x01, 0x05, 0x00, 0xa2, 0x03, 0x02, 0x01, 0x20,
        ];
        let structure = RsassaPssParams::new(HashAlgorithm::SHA256);
        check_serde!(structure: RsassaPssParams in expected);
    }

    #[test]
    fn rsa_pss_params_sha384() {
        let expected = [
            0x30, 0x34, 0xa0, 0x0f, 0x30, 0x0d, 0x06, 0x09, 0x60, 0x86, 0x48, 0x01, 0x65, 0x03, 0x04, 0x02, 0x02, 0x05,
            0x00, 0xa1, 0x1c, 0x30, 0x1a, 0x06, 0x09, 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x08, 0x30, 0x0d,
            0x06, 0x09, 0x60, 0x86, 0x48, 0x01, 0x65, 0x03, 0x04, 0x02, 0x02, 0x05, 0x00, 0xa2, 0x03, 0x02, 0x01, 0x30,
        ];
        let structure = RsassaPssParams::new(HashAlgorithm::SHA384);
        check_serde!(structure: RsassaPssParams in expected);
    }

    #[test]
    fn rsa_pss_params_sha512() {
        let expected = [
            0x30, 0x34, 0xa0, 0x0f, 0x30, 0x0d, 0x06, 0x09, 0x60, 0x86, 0x48, 0x01, 0x65, 0x03, 0x04, 0x02, 0x03, 0x05,
            0x00, 0xa1, 0x1c, 0x30, 0x1a, 0x06, 0x09, 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x08, 0x30, 0x0d,
            0x06, 0x09, 0x60, 0x86, 0x48, 0x01, 0x65, 0x03, 0x04, 0x02, 0x03, 0x05, 0x00, 0xa2, 0x03, 0x02, 0x01, 0x40,
        ];
        let structure = RsassaPssParams::new(HashAlgorithm::SHA512);
        check_serde!(structure: RsassaPssParams in expected);
    }

    #[test]
    fn rsa_pss_encryption() {
        let expected = [
            0x30, 0x41, 0x06, 0x09, 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x0A, 0x30, 0x34, 0xa0, 0x0f, 0x30,
            0x0d, 0x06, 0x09, 0x60, 0x86, 0x48, 0x01, 0x65, 0x03, 0x04, 0x02, 0x01, 0x05, 0x00, 0xa1, 0x1c, 0x30, 0x1a,
            0x06, 0x09, 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x08, 0x30, 0x0d, 0x06, 0x09, 0x60, 0x86, 0x48,
            0x01, 0x65, 0x03, 0x04, 0x02, 0x01, 0x05, 0x00, 0xa2, 0x03, 0x02, 0x01, 0x20,
        ];
        let structure = AlgorithmIdentifier::new_rsassa_pss(RsassaPssParams::new(HashAlgorithm::SHA256));
        check_serde!(structure: AlgorithmIdentifier in expected);
    }

    #[test]
    fn rsa_encryption() {
        let expected = [
            0x30, 0x0D, 0x06, 0x09, 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01, 0x05, 0x00,
        ];
        let rsa_encryption = AlgorithmIdentifier::new_rsa_encryption();
        check_serde!(rsa_encryption: AlgorithmIdentifier in expected);
    }

    #[test]
    fn rsa_encryption_with_missing_params() {
        let encoded = [
            0x30, 0x0B, 0x06, 0x09, 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01,
        ];
        let deserialized: AlgorithmIdentifier =
            picky_asn1_der::from_bytes(&encoded).expect("failed AlgorithmIdentifier deserialization");
        pretty_assertions::assert_eq!(
            deserialized,
            AlgorithmIdentifier::new_rsa_encryption(),
            concat!("deserialized ", stringify!($item), " doesn't match")
        );
    }

    #[test]
    fn raw_algorithm_roundtrip_no_params() {
        let encoded = [
            0x30, 0x0C, 0x06, 0x08, 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x02, 0x09, 0x05, 0x00,
        ];
        let decoded: RawAlgorithmIdentifier = picky_asn1_der::from_bytes(&encoded).unwrap();
        let expected = RawAlgorithmIdentifier::from_parts(oids::hmac_with_sha256(), None);
        pretty_assertions::assert_eq!(decoded, expected);
        check_serde!(decoded: RawAlgorithmIdentifier in encoded);
    }

    #[test]
    fn raw_algorithm_roundtrip() {
        let encoded = [
            0x30, 0x16, 0x06, 0x03, 0x55, 0x04, 0x03, 0x0C, 0x0F, 0x69, 0x6E, 0x74, 0x65, 0x72, 0x6D, 0x65, 0x64, 0x69,
            0x61, 0x74, 0x65, 0x5F, 0x63, 0x61,
        ];
        let decoded: RawAlgorithmIdentifier = picky_asn1_der::from_bytes(&encoded).unwrap();
        let oid: ObjectIdentifier = "2.5.4.3".to_string().try_into().unwrap();
        let params = Asn1RawDer(vec![
            0x0C, 0x0F, 0x69, 0x6E, 0x74, 0x65, 0x72, 0x6D, 0x65, 0x64, 0x69, 0x61, 0x74, 0x65, 0x5F, 0x63, 0x61,
        ]);
        let expected = RawAlgorithmIdentifier::from_parts(oid, Some(params));
        pretty_assertions::assert_eq!(decoded, expected);
        check_serde!(decoded: RawAlgorithmIdentifier in encoded);
    }

    #[test]
    fn mldsa_44() {
        let expected = [
            0x30, 0x0B, 0x06, 0x09, 0x60, 0x86, 0x48, 0x01, 0x65, 0x03, 0x04, 0x03, 0x11,
        ];
        let mldsa = AlgorithmIdentifier::new_mldsa_44();
        check_serde!(mldsa: AlgorithmIdentifier in expected);
    }

    #[test]
    fn mldsa_65() {
        let expected = [
            0x30, 0x0B, 0x06, 0x09, 0x60, 0x86, 0x48, 0x01, 0x65, 0x03, 0x04, 0x03, 0x12,
        ];
        let mldsa = AlgorithmIdentifier::new_mldsa_65();
        check_serde!(mldsa: AlgorithmIdentifier in expected);
    }

    #[test]
    fn mldsa_87() {
        let expected = [
            0x30, 0x0B, 0x06, 0x09, 0x60, 0x86, 0x48, 0x01, 0x65, 0x03, 0x04, 0x03, 0x13,
        ];
        let mldsa = AlgorithmIdentifier::new_mldsa_87();
        check_serde!(mldsa: AlgorithmIdentifier in expected);
    }
}
