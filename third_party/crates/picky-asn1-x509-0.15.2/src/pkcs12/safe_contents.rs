use crate::oids;
use crate::pkcs12::{Pkcs12EncryptionAlgorithm, SafeBag};
use core::fmt;
use oid::ObjectIdentifier;
use picky_asn1::wrapper::{
    Asn1SequenceOf, ExplicitContextTag0, ImplicitContextTag0, ObjectIdentifierAsn1, OctetStringAsn1,
    OctetStringAsn1Container,
};
use picky_asn1_der::Asn1RawDer;
use serde::{Deserialize, Serialize, de, ser};

/// `ContentInfo`(PKCS#7) wrapper which provides only kinds relevant to PKCS#12 `SafeContents`
/// representation in raw and encrypted form.
/// See [RFC 7292](https://datatracker.ietf.org/doc/html/rfc7292#section-5.1)
///
/// ```not_rust
// ContentInfo ::= SEQUENCE {
//     contentType ContentType,
//     content
//       [0] EXPLICIT ANY DEFINED BY contentType OPTIONAL }
/// ```
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SafeContentsContentInfo {
    /// Raw unencrypted `SafeBag` seqecuence in encapsulated in `OctetString` container
    Data(SafeContents),
    /// Encrypted `SafeBag` encapsulated in `OctetString`
    EncryptedData(EncryptedSafeContents),
    /// Unknown `ContentInfo` type used in context of `SafeContentsContentInfo` container
    Unknown {
        content_type: ObjectIdentifier,
        content: Option<Asn1RawDer>,
    },
}

impl ser::Serialize for SafeContentsContentInfo {
    fn serialize<S>(&self, serializer: S) -> Result<S::Ok, S::Error>
    where
        S: ser::Serializer,
    {
        use ser::SerializeSeq;

        match self {
            SafeContentsContentInfo::Data(safe_contents) => {
                let mut seq = serializer.serialize_seq(Some(2))?;
                let oid: ObjectIdentifierAsn1 = oids::content_info_type_data().into();
                seq.serialize_element(&oid)?;
                let content: ExplicitContextTag0<OctetStringAsn1Container<SafeContents>> =
                    OctetStringAsn1Container(safe_contents.clone()).into();
                seq.serialize_element(&content)?;
                seq.end()
            }
            SafeContentsContentInfo::EncryptedData(encrypted_safe_contents) => {
                let mut seq = serializer.serialize_seq(Some(2))?;
                let oid: ObjectIdentifierAsn1 = oids::content_info_type_encrypted_data().into();
                seq.serialize_element(&oid)?;

                let content: ExplicitContextTag0<EncrytedDataWrapper> = EncrytedDataWrapper {
                    version: 0,
                    inner: encrypted_safe_contents.clone(),
                }
                .into();

                seq.serialize_element(&content)?;
                seq.end()
            }
            SafeContentsContentInfo::Unknown { content_type, content } => {
                let sequence_length = 1 + usize::from(content.is_some());
                let mut seq = serializer.serialize_seq(Some(sequence_length))?;
                let oid: ObjectIdentifierAsn1 = content_type.clone().into();
                seq.serialize_element(&oid)?;
                if let Some(content) = content {
                    let content: ExplicitContextTag0<Asn1RawDer> = content.clone().into();
                    seq.serialize_element(&content)?;
                }
                seq.end()
            }
        }
    }
}

impl<'de> de::Deserialize<'de> for SafeContentsContentInfo {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: de::Deserializer<'de>,
    {
        struct SafeContentsContentInfoVisitor;

        impl<'de> de::Visitor<'de> for SafeContentsContentInfoVisitor {
            type Value = SafeContentsContentInfo;

            fn expecting(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
                formatter.write_str("a valid DER-encoded SafeContentsContentInfo")
            }

            fn visit_seq<A>(self, mut seq: A) -> Result<Self::Value, A::Error>
            where
                A: de::SeqAccess<'de>,
            {
                let content_type: ObjectIdentifierAsn1 =
                    seq_next_element!(seq, SafeContentsContentInfo, "ContentInfo<SafeContents> content type");
                let oid_str: String = content_type.0.clone().into();

                match oid_str.as_str() {
                    oids::CONTENT_INFO_TYPE_DATA => {
                        let content: ExplicitContextTag0<OctetStringAsn1Container<SafeContents>> =
                            seq_next_element!(seq, SafeContentsContentInfo, "ContentInfo<SafeContents> content");
                        Ok(SafeContentsContentInfo::Data(content.0.0))
                    }
                    oids::CONTENT_INFO_TYPE_ENCRYPTED_DATA => {
                        let content: ExplicitContextTag0<EncrytedDataWrapper> = seq_next_element!(
                            seq,
                            SafeContentsContentInfo,
                            "ContentInfo<SafeContents> encrypted content"
                        );

                        if content.0.version != 0 {
                            return Err(serde_invalid_value!(
                                SafeContentsContentInfo,
                                "EncryptedData(SafeContents) version should be 0",
                                "version 0"
                            ));
                        }

                        Ok(SafeContentsContentInfo::EncryptedData(content.0.inner))
                    }
                    _ => {
                        let content: Option<ExplicitContextTag0<Asn1RawDer>> = seq.next_element()?;
                        Ok(SafeContentsContentInfo::Unknown {
                            content_type: content_type.0,
                            content: content.map(|c| c.0),
                        })
                    }
                }
            }
        }

        deserializer.deserialize_seq(SafeContentsContentInfoVisitor)
    }
}

/// Intermediate structure used to serialize/deserialize `SafeContentsContentInfo` as `ContentInfo`
///
/// As defined in [PKCS #7](https://datatracker.ietf.org/doc/html/rfc2315#section-13):
/// ```not_rust
/// EncryptedData ::= SEQUENCE {
///     version Version,
///     encryptedContentInfo EncryptedContentInfo }
/// ```
#[derive(Serialize, Deserialize, Debug, Clone, PartialEq, Eq)]
struct EncrytedDataWrapper {
    /// Should be always equal to 0
    version: u8,
    inner: EncryptedSafeContents,
}

/// [PKCS #7](https://datatracker.ietf.org/doc/html/rfc2315#section-10.1)
///
/// ```not_rust
/// EncryptedContentInfo ::= SEQUENCE {
///     contentType ContentType,
///     contentEncryptionAlgorithm
///       ContentEncryptionAlgorithmIdentifier,
///     encryptedContent
///       [0] IMPLICIT EncryptedContent OPTIONAL }
/// ```
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct EncryptedSafeContents {
    // NOTE: ContentType is always set to `data`
    pub algorithm: Pkcs12EncryptionAlgorithm,
    pub encrypted_content: Option<OctetStringAsn1>,
}

impl ser::Serialize for EncryptedSafeContents {
    fn serialize<S>(&self, serializer: S) -> Result<S::Ok, S::Error>
    where
        S: ser::Serializer,
    {
        use ser::SerializeSeq;

        let sequence_len = 2 + usize::from(self.encrypted_content.is_some());

        let mut seq = serializer.serialize_seq(Some(sequence_len))?;

        let content_type: ObjectIdentifierAsn1 = oids::content_info_type_data().into();
        seq.serialize_element(&content_type)?;
        seq.serialize_element(&self.algorithm)?;

        if let Some(content) = self.encrypted_content.as_ref() {
            let tagged_value = ImplicitContextTag0(content);
            seq.serialize_element(&tagged_value)?;
        }

        seq.end()
    }
}

impl<'de> de::Deserialize<'de> for EncryptedSafeContents {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: de::Deserializer<'de>,
    {
        struct EncryptedSafeContentsVisitor;

        impl<'de> de::Visitor<'de> for EncryptedSafeContentsVisitor {
            type Value = EncryptedSafeContents;

            fn expecting(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
                formatter.write_str("a valid DER-encoded SafeContents")
            }

            fn visit_seq<A>(self, mut seq: A) -> Result<Self::Value, A::Error>
            where
                A: de::SeqAccess<'de>,
            {
                let content_type: ObjectIdentifierAsn1 =
                    seq_next_element!(seq, EncryptedSafeContents, "encrypted safe contents version");

                if content_type.0 != oids::content_info_type_data() {
                    return Err(serde_invalid_value!(
                        EncryptedSafeContents,
                        "invalid encrypted content type",
                        "PKCS#7 data content type"
                    ));
                };

                let algorithm: Pkcs12EncryptionAlgorithm =
                    seq_next_element!(seq, EncryptedSafeContents, "encrypted safe contents algorithm");

                let encrypted_content: Option<ImplicitContextTag0<OctetStringAsn1>> = seq.next_element()?;

                Ok(EncryptedSafeContents {
                    algorithm,
                    encrypted_content: encrypted_content.map(|tagged| tagged.0),
                })
            }
        }

        deserializer.deserialize_seq(EncryptedSafeContentsVisitor)
    }
}

/// [PKCS #12: Personal Information Exchange Syntax Standard Version](https://tools.ietf.org/html/rfc7292#section-4.2)
///
/// ```not_rust
/// SafeContents ::= SEQUENCE OF SafeBag
/// ```
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SafeContents(pub Vec<SafeBag>);

impl ser::Serialize for SafeContents {
    fn serialize<S>(&self, serializer: S) -> Result<S::Ok, S::Error>
    where
        S: ser::Serializer,
    {
        Asn1SequenceOf(self.0.clone()).serialize(serializer)
    }
}

impl<'de> de::Deserialize<'de> for SafeContents {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: de::Deserializer<'de>,
    {
        let asn1_sequence = Asn1SequenceOf::<SafeBag>::deserialize(deserializer)?;
        Ok(Self(asn1_sequence.0))
    }
}
