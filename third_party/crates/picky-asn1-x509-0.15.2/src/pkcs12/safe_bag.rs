mod certificate;
mod crl;
mod key;
mod secret;

use crate::oids;
use crate::pkcs12::{Pkcs12Attribute, SafeContents};
use core::fmt;
use oid::ObjectIdentifier;
use picky_asn1::wrapper::{Asn1SetOf, ExplicitContextTag0, ObjectIdentifierAsn1};
use picky_asn1_der::Asn1RawDer;
use serde::{de, ser};

pub use certificate::*;
pub use crl::*;
pub use key::*;
pub use secret::*;

/// [PKCS #12: Personal Information Exchange Syntax Standard](https://datatracker.ietf.org/doc/html/rfc7292#section-4.2)
///
/// SafeBag is a building block of PKCS#12 structure, it could contain concrete data such as
/// `PrivateKeyInfo` or `Certificate` or it could recursively contain other `SafeBag`s via
/// `SafeContents` structure.
///
/// ```not_rust
/// SafeBag ::= SEQUENCE {
///     bagId          BAG-TYPE.&id ({PKCS12BagSet})
///     bagValue       [0] EXPLICIT BAG-TYPE.&Type({PKCS12BagSet}{@bagId}),
///     bagAttributes  SET OF PKCS12Attribute OPTIONAL
/// }
/// ```
///
/// See [`SafeBagKind`] for concrete SafeBag type definitions.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SafeBag {
    pub kind: SafeBagKind,
    pub attributes: Option<Vec<Pkcs12Attribute>>,
}

/// [PKCS #12: Personal Information Exchange Syntax Standard](https://datatracker.ietf.org/doc/html/rfc7292#section-4.2)
///
/// All known SafeBag types defined in RFC as follows:
///
/// ```not_rust
/// keyBag BAG-TYPE ::=
///     {KeyBag IDENTIFIED BY {bagtypes 1}}
/// pkcs8ShroudedKeyBag BAG-TYPE ::=
///     {PKCS8ShroudedKeyBag IDENTIFIED BY {bagtypes 2}}
/// certBag BAG-TYPE ::=
///     {CertBag IDENTIFIED BY {bagtypes 3}}
/// crlBag BAG-TYPE ::=
///     {CRLBag IDENTIFIED BY {bagtypes 4}}
/// secretBag BAG-TYPE ::=
///     {SecretBag IDENTIFIED BY {bagtypes 5}}
/// safeContentsBag BAG-TYPE ::=
///     {SafeContents IDENTIFIED BY {bagtypes 6}}
///
/// PKCS12BagSet BAG-TYPE ::= {
///     keyBag |
///     pkcs8ShroudedKeyBag |
///     certBag |
///     crlBag |
///     secretBag |
///     safeContentsBag,
///     ... -- For future extensions
/// }
/// ```
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SafeBagKind {
    /// Contains `PrivateKeyInfo` ASN.1 structure. Provided in raw form to allow parsing PFX files
    /// with `PrivateKeyInfo` structures that are not yet supported by `picky` crate.
    Key(KeyBag),
    /// Ecnrypted `PrivateKeyInfo` ASN.1 structure inside `OctetString` container
    EncryptedKey(EncryptedKeyBag),
    /// Encapsulated `Certificate` ASN.1 structure inside `OctetString` container
    Certificate(CertificateBag),
    /// Encapsulated `CRL` ASN.1 structure inside `OctetString` container
    Crl(CrlBag),
    /// User-defined `SafeBag` with arbitrary OID and value
    Secret(SecretBag),
    /// Recursive list of `SafeContents`. This allow to build tree-like SafeBag structures
    SafeContents(SafeContents),
    /// Defined for forward compatibility with new `SafeBag` types. If custom user data should
    /// be stored in `SafeBag` it should be encoded as `SecretBag` instead.
    Unknown {
        /// Custom OID for user-defined `Bag` type
        type_id: ObjectIdentifier,
        /// Encapsulated `SecretBag` value
        value: Asn1RawDer,
    },
}

impl ser::Serialize for SafeBag {
    fn serialize<S>(&self, serializer: S) -> Result<S::Ok, S::Error>
    where
        S: ser::Serializer,
    {
        use ser::SerializeSeq;

        let sequence_size = 2 + usize::from(self.attributes.is_some());
        let mut seq = serializer.serialize_seq(Some(sequence_size))?;

        match &self.kind {
            SafeBagKind::Key(key) => {
                let oid: ObjectIdentifierAsn1 = oids::safe_bag_type_key().into();
                seq.serialize_element(&oid)?;
                let tagged_value = ExplicitContextTag0(key.clone());
                seq.serialize_element(&tagged_value)?;
            }
            SafeBagKind::EncryptedKey(encrypted_key) => {
                let oid: ObjectIdentifierAsn1 = oids::safe_bag_type_shrouded_key().into();
                seq.serialize_element(&oid)?;
                let tagged_value = ExplicitContextTag0(encrypted_key.clone());
                seq.serialize_element(&tagged_value)?;
            }
            SafeBagKind::Certificate(cert) => {
                let oid: ObjectIdentifierAsn1 = oids::safe_bag_type_cert().into();
                seq.serialize_element(&oid)?;
                let tagged_value = ExplicitContextTag0(cert.clone());
                seq.serialize_element(&tagged_value)?;
            }
            SafeBagKind::Crl(crl) => {
                let oid: ObjectIdentifierAsn1 = oids::safe_bag_type_crl().into();
                seq.serialize_element(&oid)?;
                let tagged_value = ExplicitContextTag0(crl.clone());
                seq.serialize_element(&tagged_value)?;
            }
            SafeBagKind::Secret(secret) => {
                let oid: ObjectIdentifierAsn1 = oids::safe_bag_type_secret().into();
                seq.serialize_element(&oid)?;
                let tagged_value = ExplicitContextTag0(secret.clone());
                seq.serialize_element(&tagged_value)?;
            }
            SafeBagKind::SafeContents(safe_contents) => {
                let oid: ObjectIdentifierAsn1 = oids::safe_bag_type_safe_contents().into();
                seq.serialize_element(&oid)?;
                let tagged_value = ExplicitContextTag0(safe_contents.clone());
                seq.serialize_element(&tagged_value)?;
            }
            SafeBagKind::Unknown { type_id, value } => {
                let oid: ObjectIdentifierAsn1 = type_id.clone().into();
                seq.serialize_element(&oid)?;
                let tagged_value = ExplicitContextTag0(value.clone());
                seq.serialize_element(&tagged_value)?;
            }
        };

        if let Some(attributes) = &self.attributes {
            let asn1_set = Asn1SetOf(attributes.clone());
            seq.serialize_element(&asn1_set)?;
        }

        seq.end()
    }
}

impl<'de> de::Deserialize<'de> for SafeBag {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: de::Deserializer<'de>,
    {
        struct SafeBagVisitor;

        impl<'de> de::Visitor<'de> for SafeBagVisitor {
            type Value = SafeBag;

            fn expecting(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
                formatter.write_str("a valid DER-encoded SafeBag")
            }

            fn visit_seq<A>(self, mut seq: A) -> Result<Self::Value, A::Error>
            where
                A: de::SeqAccess<'de>,
            {
                let oid: ObjectIdentifierAsn1 = seq_next_element!(seq, SafeBag, "Safe bag type id");

                let oid_str: String = oid.0.clone().into();

                let kind = match oid_str.as_str() {
                    oids::SAFE_BAG_TYPE_KEY => {
                        let key: ExplicitContextTag0<Asn1RawDer> = seq_next_element!(seq, SafeBag, "key value");
                        SafeBagKind::Key(key.0)
                    }
                    oids::SAFE_BAG_TYPE_SHROUDED_KEY => {
                        let encrypted_key: ExplicitContextTag0<EncryptedKeyBag> =
                            seq_next_element!(seq, SafeBag, "encrypted key value");
                        SafeBagKind::EncryptedKey(encrypted_key.0)
                    }
                    oids::SAFE_BAG_TYPE_CERT => {
                        let cert: ExplicitContextTag0<CertificateBag> =
                            seq_next_element!(seq, SafeBag, "certificate value");
                        SafeBagKind::Certificate(cert.0)
                    }
                    oids::SAFE_BAG_TYPE_CRL => {
                        let crl: ExplicitContextTag0<CrlBag> = seq_next_element!(seq, SafeBag, "CRL value");
                        SafeBagKind::Crl(crl.0)
                    }
                    oids::SAFE_BAG_TYPE_SECRET => {
                        let secret: ExplicitContextTag0<SecretBag> =
                            seq_next_element!(seq, SafeBag, "secret bag value");
                        SafeBagKind::Secret(secret.0)
                    }
                    oids::SAFE_BAG_TYPE_SAFE_CONTENTS => {
                        let safe_contents: ExplicitContextTag0<SafeContents> =
                            seq_next_element!(seq, SafeBag, "safe contents value");
                        SafeBagKind::SafeContents(safe_contents.0)
                    }
                    _ => {
                        let value: ExplicitContextTag0<Asn1RawDer> =
                            seq_next_element!(seq, SafeBag, "raw safe bag value");
                        SafeBagKind::Unknown {
                            type_id: oid.0,
                            value: value.0,
                        }
                    }
                };

                let attributes: Option<Asn1SetOf<Pkcs12Attribute>> = seq.next_element()?;

                Ok(SafeBag {
                    kind,
                    attributes: attributes.map(|set| set.0),
                })
            }
        }

        deserializer.deserialize_seq(SafeBagVisitor)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::pkcs12::Pkcs12EncryptionAlgorithm;
    use crate::pkcs12::pbes2::test_data::build_expected_pbes2_params;
    use expect_test::expect;
    use picky_asn1::wrapper::OctetStringAsn1;

    #[test]
    fn secret_safe_bag_roundtrip() {
        let bag = SafeBag {
            kind: SafeBagKind::Secret(SecretBag {
                type_id: oids::content_info_type_data(),
                value: Asn1RawDer(picky_asn1_der::to_vec(&true).unwrap()),
            }),
            attributes: None,
        };
        let encoded = picky_asn1_der::to_vec(&bag).unwrap();
        let decoded: SafeBag = picky_asn1_der::from_bytes(&encoded).unwrap();
        pretty_assertions::assert_eq!(decoded, bag);
    }

    // Also tests attributes parsing
    #[test]
    fn crl_safe_bag_x509_roundtrip() {
        let bag = SafeBag {
            kind: SafeBagKind::Crl(CrlBag::X509(vec![0x01, 0x02, 0x03, 0x04].into())),
            attributes: Some(vec![Pkcs12Attribute::LocalKeyId(vec![0x42].into())]),
        };
        let encoded = picky_asn1_der::to_vec(&bag).unwrap();
        let decoded: SafeBag = picky_asn1_der::from_bytes(&encoded).unwrap();
        expect![[r#"
            SafeBag {
                kind: Crl(
                    X509(
                        OctetString(0x01020304),
                    ),
                ),
                attributes: Some(
                    [
                        LocalKeyId(
                            OctetString(0x42),
                        ),
                    ],
                ),
            }
        "#]]
        .assert_debug_eq(&decoded);
    }

    #[test]
    fn crl_safe_bag_unknown_roundtrip() {
        let bag = SafeBag {
            kind: SafeBagKind::Crl(CrlBag::Unknown {
                type_id: oids::content_info_type_data(),
                value: Asn1RawDer(picky_asn1_der::to_vec(&true).unwrap()),
            }),
            attributes: None,
        };
        let encoded = picky_asn1_der::to_vec(&bag).unwrap();
        let decoded: SafeBag = picky_asn1_der::from_bytes(&encoded).unwrap();
        pretty_assertions::assert_eq!(decoded, bag);
    }

    #[test]
    fn key_safe_bag_roundtrip() {
        let bag = SafeBag {
            // We use `BOOL` instead of `PrivateKeyInfo` just for sake of test simplicity
            kind: SafeBagKind::Key(Asn1RawDer(picky_asn1_der::to_vec(&true).unwrap())),
            attributes: None,
        };
        let encoded = picky_asn1_der::to_vec(&bag).unwrap();
        let decoded: SafeBag = picky_asn1_der::from_bytes(&encoded).unwrap();
        expect![[r#"
            SafeBag {
                kind: Key(
                    RawDer(0x0101FF),
                ),
                attributes: None,
            }
        "#]]
        .assert_debug_eq(&decoded);
    }

    #[test]
    fn encrypted_key_safe_bag_roundtrip() {
        let bag = SafeBag {
            // We use `BOOL` instead of `PrivateKeyInfo` just for sake of test simplicity
            kind: SafeBagKind::EncryptedKey(EncryptedKeyBag {
                algorithm: Pkcs12EncryptionAlgorithm::Pbes2(build_expected_pbes2_params()),
                // Again, as in `key_safe_bag_roundtrip`, we use `BOOL` instead of `PrivateKeyInfo`
                // for sake of test simplicity
                encrypted_data: OctetStringAsn1(picky_asn1_der::to_vec(&true).unwrap()),
            }),
            attributes: None,
        };
        let encoded = picky_asn1_der::to_vec(&bag).unwrap();
        let decoded: SafeBag = picky_asn1_der::from_bytes(&encoded).unwrap();
        expect![[r#"
            SafeBag {
                kind: EncryptedKey(
                    EncryptedKeyBag {
                        algorithm: Pbes2(
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
                        ),
                        encrypted_data: OctetString(0x0101FF),
                    },
                ),
                attributes: None,
            }
        "#]]
        .assert_debug_eq(&decoded);
    }

    #[test]
    fn cert_safe_bag_x509_roundtrip() {
        let bag = SafeBag {
            kind: SafeBagKind::Certificate(CertificateBag::X509(vec![0x01, 0x02, 0x03].into())),
            attributes: None,
        };
        let encoded = picky_asn1_der::to_vec(&bag).unwrap();
        let decoded: SafeBag = picky_asn1_der::from_bytes(&encoded).unwrap();
        expect![[r#"
            SafeBag {
                kind: Certificate(
                    X509(
                        OctetString(0x010203),
                    ),
                ),
                attributes: None,
            }
        "#]]
        .assert_debug_eq(&decoded);
    }

    #[test]
    fn cert_safe_bag_unknown_roundtrip() {
        let bag = SafeBag {
            kind: SafeBagKind::Certificate(CertificateBag::Unknown {
                type_id: oids::content_info_type_data(),
                value: Asn1RawDer(picky_asn1_der::to_vec(&true).unwrap()),
            }),
            attributes: None,
        };
        let encoded = picky_asn1_der::to_vec(&bag).unwrap();
        let decoded: SafeBag = picky_asn1_der::from_bytes(&encoded).unwrap();
        pretty_assertions::assert_eq!(decoded, bag);
    }

    #[test]
    fn safe_contents_safe_bag() {
        let nested_bag_1 = SafeBag {
            kind: SafeBagKind::Certificate(CertificateBag::X509(vec![0x01].into())),
            attributes: None,
        };
        let nested_bag_2 = SafeBag {
            kind: SafeBagKind::Certificate(CertificateBag::X509(vec![0x02].into())),
            attributes: None,
        };
        let bag = SafeBag {
            kind: SafeBagKind::SafeContents(SafeContents(vec![nested_bag_1, nested_bag_2])),
            attributes: None,
        };
        let encoded = picky_asn1_der::to_vec(&bag).unwrap();
        let decoded: SafeBag = picky_asn1_der::from_bytes(&encoded).unwrap();
        expect![[r#"
            SafeBag {
                kind: SafeContents(
                    SafeContents(
                        [
                            SafeBag {
                                kind: Certificate(
                                    X509(
                                        OctetString(0x01),
                                    ),
                                ),
                                attributes: None,
                            },
                            SafeBag {
                                kind: Certificate(
                                    X509(
                                        OctetString(0x02),
                                    ),
                                ),
                                attributes: None,
                            },
                        ],
                    ),
                ),
                attributes: None,
            }
        "#]]
        .assert_debug_eq(&decoded);
    }

    #[test]
    fn unknown_safe_bag() {
        let bag = SafeBag {
            kind: SafeBagKind::Unknown {
                type_id: oids::content_info_type_data(),
                value: Asn1RawDer(picky_asn1_der::to_vec(&true).unwrap()),
            },
            attributes: None,
        };
        let encoded = picky_asn1_der::to_vec(&bag).unwrap();
        let decoded: SafeBag = picky_asn1_der::from_bytes(&encoded).unwrap();
        pretty_assertions::assert_eq!(decoded, bag);
    }
}
