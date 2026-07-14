mod pbkdf2;

use crate::{RawAlgorithmIdentifier, oids};
use core::fmt;
use oid::ObjectIdentifier;
use picky_asn1::wrapper::{ObjectIdentifierAsn1, OctetStringAsn1};
use serde::{Deserialize, Serialize, de, ser};

pub use pbkdf2::*;

/// [PKCS #12: Personal Information Exchange Syntax Standard Version](https://tools.ietf.org/html/rfc7292#appendix-C)
/// # Appendix C. Keys and IVs for Password Privacy Mode
/// ```not_rust
/// PBES2-params ::= SEQUENCE {
///     keyDerivationFunc {{PBES2-KDFs}},
///     encryptionScheme {{PBES2-Encs}}
/// }
/// ```
#[derive(Serialize, Deserialize, Debug, Clone, PartialEq, Eq)]
pub struct Pbes2Params {
    pub key_derivation_func: Pbes2KeyDerivationFunc,
    pub encryption_scheme: Pbes2EncryptionScheme,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Pbes2KeyDerivationFunc {
    Pbkdf2(Pbkdf2Params),
    Unknown(RawAlgorithmIdentifier),
}

impl ser::Serialize for Pbes2KeyDerivationFunc {
    fn serialize<S>(&self, serializer: S) -> Result<S::Ok, S::Error>
    where
        S: ser::Serializer,
    {
        use ser::SerializeSeq;

        match self {
            Pbes2KeyDerivationFunc::Pbkdf2(params) => {
                let mut seq = serializer.serialize_seq(Some(2))?;
                let oid: ObjectIdentifierAsn1 = oids::pbkdf2().into();
                seq.serialize_element(&oid)?;
                seq.serialize_element(params)?;
                seq.end()
            }
            Pbes2KeyDerivationFunc::Unknown(raw) => raw.serialize(serializer),
        }
    }
}

impl<'de> de::Deserialize<'de> for Pbes2KeyDerivationFunc {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: de::Deserializer<'de>,
    {
        struct Pbes2KeyDerivationFuncVisitor;

        impl<'de> de::Visitor<'de> for Pbes2KeyDerivationFuncVisitor {
            type Value = Pbes2KeyDerivationFunc;

            fn expecting(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
                formatter.write_str("a valid DER-encoded Pbes2KeyDerivationFunc")
            }

            fn visit_seq<A>(self, mut seq: A) -> Result<Self::Value, A::Error>
            where
                A: de::SeqAccess<'de>,
            {
                let oid: ObjectIdentifierAsn1 =
                    seq_next_element!(seq, RawAlgorithmIdentifier, "PBES2 KDF algorithm oid");

                if oid.0 == oids::pbkdf2() {
                    let parameters = seq_next_element!(seq, Pbkdf2Params, "pbkdf2 params");
                    Ok(Pbes2KeyDerivationFunc::Pbkdf2(parameters))
                } else {
                    let parameters = seq.next_element()?;
                    Ok(Pbes2KeyDerivationFunc::Unknown(RawAlgorithmIdentifier::from_parts(
                        oid.0, parameters,
                    )))
                }
            }
        }

        deserializer.deserialize_seq(Pbes2KeyDerivationFuncVisitor)
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Pbes2AesCbcEncryption {
    Aes128,
    Aes192,
    Aes256,
}

impl From<Pbes2AesCbcEncryption> for ObjectIdentifier {
    fn from(value: Pbes2AesCbcEncryption) -> Self {
        match value {
            Pbes2AesCbcEncryption::Aes128 => oids::aes128_cbc(),
            Pbes2AesCbcEncryption::Aes192 => oids::aes192_cbc(),
            Pbes2AesCbcEncryption::Aes256 => oids::aes256_cbc(),
        }
    }
}

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
pub enum Pbes2EncryptionScheme {
    AesCbc {
        kind: Pbes2AesCbcEncryption,
        iv: OctetStringAsn1,
    },
    /// Non-AES-CBC PBES2 encryption for PKCS12 is extremely rare, but we still need to be able to
    /// read/write it as raw algorithm identifier.
    Unknown(RawAlgorithmIdentifier),
}

impl ser::Serialize for Pbes2EncryptionScheme {
    fn serialize<S>(&self, serializer: S) -> Result<S::Ok, S::Error>
    where
        S: ser::Serializer,
    {
        use ser::SerializeSeq;

        match self {
            Pbes2EncryptionScheme::AesCbc { kind, iv } => {
                let mut seq = serializer.serialize_seq(Some(2))?;
                let oid: ObjectIdentifierAsn1 = ObjectIdentifier::from(*kind).into();
                seq.serialize_element(&oid)?;
                seq.serialize_element(iv)?;
                seq.end()
            }
            Pbes2EncryptionScheme::Unknown(raw) => raw.serialize(serializer),
        }
    }
}

impl<'de> de::Deserialize<'de> for Pbes2EncryptionScheme {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: de::Deserializer<'de>,
    {
        struct Pbes2EncryptionSchemeVisitor;

        impl<'de> de::Visitor<'de> for Pbes2EncryptionSchemeVisitor {
            type Value = Pbes2EncryptionScheme;

            fn expecting(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
                formatter.write_str("a valid DER-encoded Pbes2KeyDerivationFunc")
            }

            fn visit_seq<A>(self, mut seq: A) -> Result<Self::Value, A::Error>
            where
                A: de::SeqAccess<'de>,
            {
                let oid: ObjectIdentifierAsn1 =
                    seq_next_element!(seq, RawAlgorithmIdentifier, "PBES2 encryption algorithm oid");

                let oid_str: String = (&oid.0).into();

                let aes_cbc_kind = match oid_str.as_str() {
                    oids::AES128_CBC => Some(Pbes2AesCbcEncryption::Aes128),
                    oids::AES192_CBC => Some(Pbes2AesCbcEncryption::Aes192),
                    oids::AES256_CBC => Some(Pbes2AesCbcEncryption::Aes256),
                    _ => None,
                };

                if let Some(kind) = aes_cbc_kind {
                    // AES CBC params is lonely octet string
                    let iv: OctetStringAsn1 = seq_next_element!(seq, OctetStringAsn1, "PBES2 AES CBC encryption IV");

                    Ok(Pbes2EncryptionScheme::AesCbc { kind, iv })
                } else {
                    let parameters = seq.next_element()?;
                    Ok(Pbes2EncryptionScheme::Unknown(RawAlgorithmIdentifier::from_parts(
                        oid.0, parameters,
                    )))
                }
            }
        }

        deserializer.deserialize_seq(Pbes2EncryptionSchemeVisitor)
    }
}

#[cfg(test)]
pub(crate) mod test_data {
    use super::*;

    pub const PBKDF2_PARAMS: &[u8] = &[
        0x30, 0x1C, 0x04, 0x08, 0xB0, 0x6C, 0x19, 0xDC, 0x3E, 0x98, 0x1B, 0x1A, 0x02, 0x02, 0x07, 0xD0, 0x30, 0x0C,
        0x06, 0x08, 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x02, 0x09, 0x05, 0x00,
    ];

    pub const PBES2_ENCRYPTION_SCHEME: &[u8] = &[
        0x30, 0x1D, 0x06, 0x09, 0x60, 0x86, 0x48, 0x01, 0x65, 0x03, 0x04, 0x01, 0x2A, 0x04, 0x10, 0x88, 0xB5, 0x12,
        0xCD, 0xBD, 0xA4, 0x51, 0x48, 0x93, 0xFD, 0xE5, 0x36, 0xBD, 0x79, 0x72, 0x6B,
    ];

    /// Extracted from `PBKDF2_PARAMS`
    pub fn build_expected_pbkdf2_params() -> Pbkdf2Params {
        Pbkdf2Params {
            salt: Pbkdf2SaltSource::Specified(OctetStringAsn1::from(vec![
                0xB0, 0x6C, 0x19, 0xDC, 0x3E, 0x98, 0x1B, 0x1A,
            ])),
            iteration_count: 2000,
            key_length: None,
            prf: Some(Pbkdf2Prf::HmacWithSha256),
        }
    }

    pub fn build_expected_pbes2_kdf_func_data() -> Vec<u8> {
        // AlgorithmIdentifier header
        let mut data = vec![0x30, 0x29];
        // ObjectIdentifier
        data.extend_from_slice(&[0x06, 0x09, 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x05, 0x0C]);
        // Pbkdf2Params
        data.extend_from_slice(PBKDF2_PARAMS);
        data
    }

    pub fn build_expected_pbes2_kdf_func() -> Pbes2KeyDerivationFunc {
        Pbes2KeyDerivationFunc::Pbkdf2(build_expected_pbkdf2_params())
    }

    /// Extracted from `PBES2_ENCRYPTION_SCHEME`
    pub fn build_expected_pbes2_encryption_scheme() -> Pbes2EncryptionScheme {
        Pbes2EncryptionScheme::AesCbc {
            kind: Pbes2AesCbcEncryption::Aes256,
            iv: OctetStringAsn1::from(vec![
                0x88, 0xB5, 0x12, 0xCD, 0xBD, 0xA4, 0x51, 0x48, 0x93, 0xFD, 0xE5, 0x36, 0xBD, 0x79, 0x72, 0x6B,
            ]),
        }
    }

    pub fn build_expected_pbes2_params() -> Pbes2Params {
        Pbes2Params {
            key_derivation_func: build_expected_pbes2_kdf_func(),
            encryption_scheme: build_expected_pbes2_encryption_scheme(),
        }
    }

    pub fn build_expected_pbes2_params_data() -> Vec<u8> {
        // SEQUENCE header
        let mut data = vec![0x30, 0x4A];
        // Pbes2KeyDerivationFunc
        data.extend(build_expected_pbes2_kdf_func_data());
        data.extend_from_slice(PBES2_ENCRYPTION_SCHEME);
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
    fn pbes2_kdf_func_pbkdf2() {
        let encoded = build_expected_pbes2_kdf_func_data();
        let decoded: Pbes2KeyDerivationFunc = picky_asn1_der::from_bytes(&encoded).unwrap();
        expect![[r#"
            Pbkdf2(
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
            )
        "#]]
        .assert_debug_eq(&decoded);
        check_serde!(decoded: Pbes2KeyDerivationFunc in encoded);
    }

    #[test]
    fn pbes2_kdf_func_arbitrary() {
        let expected = Pbes2KeyDerivationFunc::Unknown(build_arbitrary_algorithm_identifier());
        let encoded = picky_asn1_der::to_vec(&expected).unwrap();
        let decoded: Pbes2KeyDerivationFunc = picky_asn1_der::from_bytes(&encoded).unwrap();
        pretty_assertions::assert_eq!(decoded, expected);
    }

    #[test]
    fn pbes2_encryption_scheme_roundtrip() {
        let decoded: Pbes2EncryptionScheme = picky_asn1_der::from_bytes(PBES2_ENCRYPTION_SCHEME).unwrap();
        expect![[r#"
            AesCbc {
                kind: Aes256,
                iv: OctetString(0x88B512CDBDA4514893FDE536BD79726B),
            }
        "#]]
        .assert_debug_eq(&decoded);
        check_serde!(decoded: Pbes2EncryptionScheme in PBES2_ENCRYPTION_SCHEME);
    }

    #[test]
    fn pbes2_encryption_scheme_arbitrary() {
        let expected = Pbes2EncryptionScheme::Unknown(build_arbitrary_algorithm_identifier());
        let encoded = picky_asn1_der::to_vec(&expected).unwrap();
        let decoded: Pbes2EncryptionScheme = picky_asn1_der::from_bytes(&encoded).unwrap();
        pretty_assertions::assert_eq!(decoded, expected);
    }

    #[test]
    fn pbes2_params_roundtrip() {
        let encoded = build_expected_pbes2_params_data();
        let decoded: Pbes2Params = picky_asn1_der::from_bytes(&encoded).unwrap();
        expect![[r#"
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
            }
        "#]]
        .assert_debug_eq(&decoded);
        check_serde!(decoded: Pbes2Params in encoded);
    }
}
