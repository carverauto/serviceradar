mod pbes1;
pub(crate) mod pbes2;

use crate::{RawAlgorithmIdentifier, oids};
use core::fmt;
use oid::ObjectIdentifier;
use picky_asn1::wrapper::ObjectIdentifierAsn1;
use serde::{de, ser};

pub use pbes1::*;
pub use pbes2::*;

/// [PKCS #7: Cryptographic Message Syntax](https://datatracker.ietf.org/doc/html/rfc2315#section-6.2)
///
/// ```not_rust
/// ContentEncryptionAlgorithmIdentifier ::= AlgorithmIdentifier
/// ```
///
/// Although in ASN.1 it is represented as `AlgorithmIdentifier` we can assume that it is always
/// contains only algorithm relevant to content encryption. Therefore here we represent it as
/// narrowed down type.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Pkcs12EncryptionAlgorithm {
    Pbes1 {
        kind: Pbes1AlgorithmKind,
        params: Pbes1Params,
    },
    Pbes2(Pbes2Params),
    Unknown(RawAlgorithmIdentifier),
}

impl ser::Serialize for Pkcs12EncryptionAlgorithm {
    fn serialize<S>(&self, serializer: S) -> Result<S::Ok, S::Error>
    where
        S: ser::Serializer,
    {
        use ser::SerializeSeq;

        match self {
            Pkcs12EncryptionAlgorithm::Pbes1 { kind, params } => {
                let mut seq = serializer.serialize_seq(Some(2))?;
                let oid: ObjectIdentifierAsn1 = ObjectIdentifier::from(*kind).into();
                seq.serialize_element(&oid)?;
                seq.serialize_element(params)?;
                seq.end()
            }
            Pkcs12EncryptionAlgorithm::Pbes2(params) => {
                let mut seq = serializer.serialize_seq(Some(2))?;
                let oid: ObjectIdentifierAsn1 = oids::pbes2().into();
                seq.serialize_element(&oid)?;
                seq.serialize_element(params)?;
                seq.end()
            }
            Pkcs12EncryptionAlgorithm::Unknown(raw) => raw.serialize(serializer),
        }
    }
}

impl<'de> de::Deserialize<'de> for Pkcs12EncryptionAlgorithm {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: de::Deserializer<'de>,
    {
        struct Pkcs12EncryptionAlgorithmVisitor;

        impl<'de> de::Visitor<'de> for Pkcs12EncryptionAlgorithmVisitor {
            type Value = Pkcs12EncryptionAlgorithm;

            fn expecting(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
                formatter.write_str("a valid DER-encoded Pkcs12EncryptionAlgorithm")
            }

            fn visit_seq<A>(self, mut seq: A) -> Result<Self::Value, A::Error>
            where
                A: de::SeqAccess<'de>,
            {
                let oid: ObjectIdentifierAsn1 =
                    seq_next_element!(seq, RawAlgorithmIdentifier, "PKCS12 encryption algorithm oid");

                let oid_str: String = (&oid.0).into();

                let value = match oid_str.as_str() {
                    oids::PBES2 => {
                        let params = seq_next_element!(seq, Pbes2Params, "PBES2 params");
                        Pkcs12EncryptionAlgorithm::Pbes2(params)
                    }
                    oids::PKCS12_PBE_WITH_SHA_AND_40_BIT_RC2_CBC
                    | oids::PKCS12_PBE_WITH_SHA_AND_3_KEY_TRIPLE_DES_CBC => {
                        let kind = if oid_str == oids::PKCS12_PBE_WITH_SHA_AND_40_BIT_RC2_CBC {
                            Pbes1AlgorithmKind::ShaAnd40BitRc2Cbc
                        } else {
                            Pbes1AlgorithmKind::ShaAnd3Key3DesCbc
                        };

                        let params = seq_next_element!(seq, Pbes1Params, "PBES1 params");

                        Pkcs12EncryptionAlgorithm::Pbes1 { kind, params }
                    }
                    _ => Pkcs12EncryptionAlgorithm::Unknown(RawAlgorithmIdentifier::from_parts(
                        oid.0,
                        seq.next_element()?,
                    )),
                };

                Ok(value)
            }
        }

        deserializer.deserialize_seq(Pkcs12EncryptionAlgorithmVisitor)
    }
}

#[cfg(test)]
pub(crate) mod test_data {
    use super::pbes2::test_data::build_expected_pbes2_params_data;

    pub const PKCS12_ENCRYPTION_ALGORITHM_PBES1: &[u8] = &[
        0x30, 0x1C, 0x06, 0x0A, 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x0C, 0x01, 0x03, 0x30, 0x0E, 0x04, 0x08,
        0xEC, 0xF2, 0xA6, 0xF8, 0x18, 0x5B, 0x46, 0x5F, 0x02, 0x02, 0x07, 0xD0,
    ];

    pub fn build_expected_pkcs12_encryption_algorithm_pbes2_data() -> Vec<u8> {
        // SEQUENCE header
        let mut data = vec![0x30, 0x57];
        // ObjectIdentifier (PBES2)
        data.extend_from_slice(&[0x06, 0x09, 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x05, 0x0D]);
        // Pbes2Params
        data.extend(build_expected_pbes2_params_data());
        data
    }
}

#[cfg(test)]
mod tests {
    use super::test_data::*;
    use super::*;
    use crate::pkcs12::test_data::build_arbitrary_algorithm_identifier;
    use base64::Engine as _;
    use base64::engine::general_purpose;
    use expect_test::expect;

    #[test]
    fn pkcs12_encryption_algorithm_pbes2_roundtrip() {
        let encoded = build_expected_pkcs12_encryption_algorithm_pbes2_data();
        let decoded: Pkcs12EncryptionAlgorithm = picky_asn1_der::from_bytes(&encoded).unwrap();
        expect![[r#"
            Pbes2(
                Pbes2Params {
                    key_derivation_func: Pbkdf2(
                        Pbkdf2Params {
                            salt: Specified(
                                OctetString(0xB06C19DC3E981B1A),
                            ),
                            iteration_count: 2000,
                            key_length: None,
                            prf: Some(
                                HmacWithSha256,
                            ),
                        },
                    ),
                    encryption_scheme: AesCbc {
                        kind: Aes256,
                        iv: OctetString(0x88B512CDBDA4514893FDE536BD79726B),
                    },
                },
            )
        "#]]
        .assert_debug_eq(&decoded);
        check_serde!(decoded: Pkcs12EncryptionAlgorithm in encoded);
    }

    #[test]
    fn pkcs12_encryption_algorithm_pbes1_roundtrip() {
        let decoded: Pkcs12EncryptionAlgorithm = picky_asn1_der::from_bytes(PKCS12_ENCRYPTION_ALGORITHM_PBES1).unwrap();
        expect![[r#"
            Pbes1 {
                kind: ShaAnd3Key3DesCbc,
                params: Pbes1Params {
                    salt: OctetString(0xECF2A6F8185B465F),
                    iterations: 2000,
                },
            }
        "#]]
        .assert_debug_eq(&decoded);
        check_serde!(decoded: Pkcs12EncryptionAlgorithm in PKCS12_ENCRYPTION_ALGORITHM_PBES1);
    }

    #[test]
    fn pkcs12_encryption_algorithm_arbitrary() {
        let expected = Pkcs12EncryptionAlgorithm::Unknown(build_arbitrary_algorithm_identifier());
        let encoded = picky_asn1_der::to_vec(&expected).unwrap();
        let decoded: Pkcs12EncryptionAlgorithm = picky_asn1_der::from_bytes(&encoded).unwrap();
        pretty_assertions::assert_eq!(decoded, expected);
    }
}
