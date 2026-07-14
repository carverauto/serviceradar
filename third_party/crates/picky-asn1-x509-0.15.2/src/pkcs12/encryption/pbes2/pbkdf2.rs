use crate::{RawAlgorithmIdentifier, oids};
use core::fmt;
use picky_asn1::Asn1Type;
use picky_asn1::tag::TagPeeker;
use picky_asn1::wrapper::{IntegerAsn1, OctetStringAsn1};
use serde::{de, ser};

/// [PKCS #12: Personal Information Exchange Syntax Standard Version](https://tools.ietf.org/html/rfc7292#appendix-C)
/// # Appendix C. Keys and IVs for Password Privacy Mode
/// ```not_rust
/// PBKDF2-params ::= SEQUENCE {
///     salt CHOICE {
///       specified OCTET STRING,
///       otherSource AlgorithmIdentifier {{PBKDF2-SaltSources}}
///     },
///     iterationCount INTEGER (1..MAX),
///     keyLength INTEGER (1..MAX) OPTIONAL,
///     prf AlgorithmIdentifier {{PBKDF2-PRFs}} DEFAULT
///     algid-hmacWithSHA1
/// }
/// ```
///
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Pbkdf2Params {
    pub salt: Pbkdf2SaltSource,
    pub iteration_count: u32,
    pub key_length: Option<u32>,
    /// Defaults to HMAC-SHA1 if absent
    pub prf: Option<Pbkdf2Prf>,
}

impl ser::Serialize for Pbkdf2Params {
    fn serialize<S>(&self, serializer: S) -> Result<S::Ok, S::Error>
    where
        S: ser::Serializer,
    {
        use ser::SerializeSeq;

        let sequence_size = 2 + usize::from(self.key_length.is_some()) + usize::from(self.prf.is_some());

        let mut seq = serializer.serialize_seq(Some(sequence_size))?;

        match &self.salt {
            Pbkdf2SaltSource::Specified(octet_string) => {
                seq.serialize_element(octet_string)?;
            }
            Pbkdf2SaltSource::OtherSource(algorithm_identifier) => {
                seq.serialize_element(algorithm_identifier)?;
            }
        }

        seq.serialize_element(&self.iteration_count)?;

        if let Some(key_length) = &self.key_length {
            seq.serialize_element(key_length)?;
        }

        if let Some(prf) = &self.prf {
            let algorithm_identifier = RawAlgorithmIdentifier::from(prf.clone());
            seq.serialize_element(&algorithm_identifier)?;
        }

        seq.end()
    }
}

impl<'de> de::Deserialize<'de> for Pbkdf2Params {
    fn deserialize<D>(deserializer: D) -> Result<Pbkdf2Params, D::Error>
    where
        D: de::Deserializer<'de>,
    {
        struct Pbkdf2ParamsVisitor;

        impl<'de> de::Visitor<'de> for Pbkdf2ParamsVisitor {
            type Value = Pbkdf2Params;

            fn expecting(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
                formatter.write_str("a valid DER-encoded Pbkdf2Params")
            }

            fn visit_seq<A>(self, mut seq: A) -> Result<Self::Value, A::Error>
            where
                A: de::SeqAccess<'de>,
            {
                let salt = if let Some(salt_tag) = seq.next_element::<TagPeeker>()? {
                    if salt_tag.next_tag == OctetStringAsn1::TAG {
                        Pbkdf2SaltSource::Specified(seq_next_element!(seq, Pbkdf2Params, "specified salt value"))
                    } else {
                        Pbkdf2SaltSource::OtherSource(seq_next_element!(
                            seq,
                            RawAlgorithmIdentifier,
                            "salt (other source)"
                        ))
                    }
                } else {
                    return Err(serde_invalid_value!(
                        Pbkdf2Params,
                        "Invalid sequence elements count, expected at least 2, got 0",
                        "salt source field"
                    ));
                };

                let iteration_count: u32 = seq_next_element!(seq, Pbkdf2Params, "Pbkdf2 iteration count");

                let mut last_tag = seq.next_element::<TagPeeker>()?;

                let key_length_set = last_tag
                    .as_ref()
                    .map(|tag| tag.next_tag == IntegerAsn1::TAG)
                    .unwrap_or(false);

                let key_length = if key_length_set {
                    let key_length: u32 = seq_next_element!(seq, Pbkdf2Params, "Pbkdf2 key length hint");

                    // Try to read tag of `prf` which goes after `key_length`
                    last_tag = seq.next_element::<TagPeeker>()?;

                    Some(key_length)
                } else {
                    None
                };

                let prf = if last_tag.is_some() {
                    let prf: RawAlgorithmIdentifier = seq_next_element!(seq, Pbkdf2Params, "Pbkdf2 PRF");

                    Some(Pbkdf2Prf::from(prf))
                } else {
                    None
                };

                Ok(Pbkdf2Params {
                    salt,
                    iteration_count,
                    key_length,
                    prf,
                })
            }
        }

        deserializer.deserialize_seq(Pbkdf2ParamsVisitor)
    }
}

/// Pseudo-random function used by PBKDF2.
/// As defined in [PKCS#5](https://www.rfc-editor.org/rfc/rfc8018)
///
/// ```not_rust
/// PBKDF2-PRFs ALGORITHM-IDENTIFIER ::= {
///     {NULL IDENTIFIED BY id-hmacWithSHA1},
///     {NULL IDENTIFIED BY id-hmacWithSHA224},
///     {NULL IDENTIFIED BY id-hmacWithSHA256},
///     {NULL IDENTIFIED BY id-hmacWithSHA384},
///     {NULL IDENTIFIED BY id-hmacWithSHA512},
///     {NULL IDENTIFIED BY id-hmacWithSHA512-224},
///     {NULL IDENTIFIED BY id-hmacWithSHA512-256},
///     ...
///   }
/// ```
///
/// `id-hmacWithSHA512-224` and `id-hmacWithSHA512-256` are not supported directly as very not
/// widely used.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub enum Pbkdf2Prf {
    // As defined by PKCS#5 RFC 8018, section A.2.
    #[default]
    HmacWithSha1,
    HmacWithSha224,
    HmacWithSha256,
    HmacWithSha384,
    HmacWithSha512,
    Unknown(RawAlgorithmIdentifier),
}

impl From<Pbkdf2Prf> for RawAlgorithmIdentifier {
    fn from(value: Pbkdf2Prf) -> Self {
        let algorithm = match value {
            Pbkdf2Prf::HmacWithSha1 => oids::hmac_with_sha1(),
            Pbkdf2Prf::HmacWithSha224 => oids::hmac_with_sha224(),
            Pbkdf2Prf::HmacWithSha256 => oids::hmac_with_sha256(),
            Pbkdf2Prf::HmacWithSha384 => oids::hmac_with_sha384(),
            Pbkdf2Prf::HmacWithSha512 => oids::hmac_with_sha512(),
            Pbkdf2Prf::Unknown(value) => {
                return value;
            }
        };

        Self::from_parts(algorithm, None)
    }
}

impl From<RawAlgorithmIdentifier> for Pbkdf2Prf {
    fn from(value: RawAlgorithmIdentifier) -> Self {
        let oid: String = value.algorithm().into();
        match oid.as_str() {
            oids::HMAC_WITH_SHA1 => Pbkdf2Prf::HmacWithSha1,
            oids::HMAC_WITH_SHA224 => Pbkdf2Prf::HmacWithSha224,
            oids::HMAC_WITH_SHA256 => Pbkdf2Prf::HmacWithSha256,
            oids::HMAC_WITH_SHA384 => Pbkdf2Prf::HmacWithSha384,
            oids::HMAC_WITH_SHA512 => Pbkdf2Prf::HmacWithSha512,
            _ => Pbkdf2Prf::Unknown(value),
        }
    }
}

/// See [`Pbkdf2Params`] documentation for more details.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Pbkdf2SaltSource {
    Specified(OctetStringAsn1),
    OtherSource(RawAlgorithmIdentifier),
}
