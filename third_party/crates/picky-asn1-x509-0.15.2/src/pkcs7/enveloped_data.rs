use core::fmt;

use picky_asn1::tag::{TagClass, TagPeeker};
use picky_asn1::wrapper::{
    Asn1SequenceOf, Asn1SetOf, ExplicitContextTag0, ExplicitContextTag2, GeneralizedTimeAsn1, ImplicitContextTag0,
    ImplicitContextTag1, ObjectIdentifierAsn1, OctetStringAsn1, Optional, Utf8StringAsn1,
};
use picky_asn1_der::Asn1RawDer;
use serde::{Deserialize, Serialize, de, ser};

use crate::cmsversion::CmsVersion;
use crate::crls::RevocationInfoChoices;
use crate::signed_data::CertificateSet;
use crate::{AlgorithmIdentifier, Attribute};

/// [ContentInfo](https://www.rfc-editor.org/rfc/rfc5652#section-3)
///
/// ```not_rust
///  ContentInfo ::= SEQUENCE {
///    contentType ContentType,
///    content [0] EXPLICIT ANY DEFINED BY contentType }
///
///  ContentType ::= OBJECT IDENTIFIER
/// ```
#[derive(Serialize, Deserialize, Debug, PartialEq)]
pub struct ContentInfo {
    pub content_type: ObjectIdentifierAsn1,
    pub content: ExplicitContextTag0<Asn1RawDer>,
}

impl ContentInfo {
    /// Returns raw content bytes.
    pub fn content(&self) -> &[u8] {
        &self.content.0.0
    }

    /// Tries to parse the content value and returns parsed object.
    pub fn content_typed<'a, T: Deserialize<'a>>(&'a self) -> picky_asn1_der::Result<T> {
        picky_asn1_der::from_bytes(&self.content.0.0)
    }
}

/// [EnvelopedData Type](https://www.rfc-editor.org/rfc/rfc5652#section-6.1)
///
/// ```not_rust
/// EnvelopedData ::= SEQUENCE {
///   version CMSVersion,
///   originatorInfo [0] IMPLICIT OriginatorInfo OPTIONAL,
///   recipientInfos RecipientInfos,
///   encryptedContentInfo EncryptedContentInfo,
///   unprotectedAttrs [1] IMPLICIT UnprotectedAttributes OPTIONAL }
/// ```
#[derive(Serialize, Deserialize, Debug, PartialEq)]
pub struct EnvelopedData {
    pub version: CmsVersion,
    #[serde(default)]
    pub originator_info: Optional<Option<ImplicitContextTag0<OriginatorInfo>>>,
    pub recipient_infos: RecipientInfos,
    pub encrypted_content_info: EncryptedContentInfo,
    #[serde(default)]
    pub unprotected_attrs: Optional<Option<ImplicitContextTag1<UnprotectedAttributes>>>,
}

/// [OriginatorInfo](https://www.rfc-editor.org/rfc/rfc5652#section-6.1)
///
/// ```not_rust
/// OriginatorInfo ::= SEQUENCE {
///   certs [0] IMPLICIT CertificateSet OPTIONAL,
///   crls [1] IMPLICIT RevocationInfoChoices OPTIONAL }
/// ```
#[derive(Serialize, Deserialize, Debug, PartialEq)]
pub struct OriginatorInfo {
    #[serde(default)]
    pub certs: Optional<Option<ImplicitContextTag0<CertificateSet>>>,
    #[serde(default)]
    pub crls: Optional<Option<ImplicitContextTag1<RevocationInfoChoices>>>,
}

/// [Content Type](https://www.rfc-editor.org/rfc/rfc5652#section-11.1)
///
/// ```not_rust
/// ContentType ::= OBJECT IDENTIFIER
/// ```
pub type ContentType = ObjectIdentifierAsn1;

/// [ContentEncryptionAlgorithmIdentifier](https://www.rfc-editor.org/rfc/rfc5652#section-10.1.4)
///
/// ```not_rust
/// ContentEncryptionAlgorithmIdentifier ::= AlgorithmIdentifier
/// ```
pub type ContentEncryptionAlgorithmIdentifier = AlgorithmIdentifier;

/// [EncryptedContent](https://www.rfc-editor.org/rfc/rfc5652#section-6.1)
///
/// ```not_rust
/// EncryptedContent ::= OCTET STRING
/// ```
pub type EncryptedContent = OctetStringAsn1;

/// [EncryptedContentInfo](https://www.rfc-editor.org/rfc/rfc5652#section-6.1)
///
/// ```not_rust
/// EncryptedContentInfo ::= SEQUENCE {
///   contentType ContentType,
///   contentEncryptionAlgorithm ContentEncryptionAlgorithmIdentifier,
///   encryptedContent [0] IMPLICIT EncryptedContent OPTIONAL }
/// ```
#[derive(Serialize, Deserialize, Debug, PartialEq)]
pub struct EncryptedContentInfo {
    pub content_type: ContentType,
    pub content_encryption_algorithm: ContentEncryptionAlgorithmIdentifier,
    #[serde(default)]
    pub encrypted_content: Optional<Option<ImplicitContextTag0<EncryptedContent>>>,
}

/// [UnprotectedAttributes](https://www.rfc-editor.org/rfc/rfc5652#section-6.1)
///
/// ```not_rust
/// UnprotectedAttributes ::= SET SIZE (1..MAX) OF Attribute
/// ```
pub type UnprotectedAttributes = Asn1SetOf<Attribute>;

/// [RecipientInfos](https://www.rfc-editor.org/rfc/rfc5652#section-6.1)
///
/// ```not_rust
/// RecipientInfos ::= SET SIZE (1..MAX) OF RecipientInfo
/// ```
pub type RecipientInfos = Asn1SetOf<RecipientInfo>;

/// [EncryptedKey](https://www.rfc-editor.org/rfc/rfc5652#section-6.2)
///
/// ```not_rust
/// EncryptedKey ::= OCTET STRING
/// ```
pub type EncryptedKey = OctetStringAsn1;

/// [EncryptedKey](https://www.rfc-editor.org/rfc/rfc5652#section-6.2)
///
/// ```not_rust
/// KeyEncryptionAlgorithmIdentifier ::= AlgorithmIdentifier
/// ```
pub type KeyEncryptionAlgorithmIdentifier = AlgorithmIdentifier;

/// [RecipientInfo Type](https://www.rfc-editor.org/rfc/rfc5652#section-6.2)
///
/// ```not_rust
/// RecipientInfo ::= CHOICE {
///   ktri KeyTransRecipientInfo,
///   kari [1] KeyAgreeRecipientInfo,
///   kekri [2] KEKRecipientInfo,
///   pwri [3] PasswordRecipientinfo,
///   ori [4] OtherRecipientInfo }
/// ```
#[derive(Debug, PartialEq)]
pub enum RecipientInfo {
    // Currently we support only KEK recipient info because we don't need other recipient info types.
    Kek(KekRecipientInfo),
}

/// [KEKRecipientInfo Type](https://www.rfc-editor.org/rfc/rfc5652#section-6.2.3)
///
/// ```not_rust
/// KEKRecipientInfo ::= SEQUENCE {
///   version CMSVersion,  -- always set to 4
///   kekid KEKIdentifier,
///   keyEncryptionAlgorithm KeyEncryptionAlgorithmIdentifier,
///   encryptedKey EncryptedKey }
/// ```
#[derive(Serialize, Deserialize, Debug, PartialEq)]
pub struct KekRecipientInfo {
    pub version: CmsVersion,
    pub kek_id: KekIdentifier,
    pub key_encryption_algorithm: KeyEncryptionAlgorithmIdentifier,
    pub encrypted_key: EncryptedKey,
}

impl<'de> Deserialize<'de> for RecipientInfo {
    fn deserialize<D>(deserializer: D) -> Result<Self, <D as de::Deserializer<'de>>::Error>
    where
        D: de::Deserializer<'de>,
    {
        struct Visitor;

        impl<'de> de::Visitor<'de> for Visitor {
            type Value = RecipientInfo;

            fn expecting(&self, formatter: &mut fmt::Formatter) -> fmt::Result {
                formatter.write_str("a valid DER-encoded RecipientInfo")
            }

            fn visit_seq<A>(self, mut seq: A) -> Result<Self::Value, A::Error>
            where
                A: de::SeqAccess<'de>,
            {
                let tag_peeker: TagPeeker = seq.next_element()?.ok_or_else(|| {
                    de::Error::invalid_value(
                        de::Unexpected::Other("[RecipientInfo] choice tag is missing"),
                        &"valid choice tag",
                    )
                })?;

                match tag_peeker.next_tag.class_and_number() {
                    (TagClass::ContextSpecific, 2) => {
                        let a: ExplicitContextTag2<CmsVersion> = seq.next_element()?.ok_or_else(|| {
                            de::Error::invalid_value(
                                de::Unexpected::Other("KEKRecipientInfo::version is missing"),
                                &"valid KEKRecipientInfo",
                            )
                        })?;

                        Ok(RecipientInfo::Kek(KekRecipientInfo {
                            version: a.0,
                            kek_id: seq.next_element()?.ok_or_else(|| {
                                de::Error::invalid_value(
                                    de::Unexpected::Other("KEKRecipientInfo::kek_id is missing"),
                                    &"valid KEKRecipientInfo",
                                )
                            })?,
                            key_encryption_algorithm: seq.next_element()?.ok_or_else(|| {
                                de::Error::invalid_value(
                                    de::Unexpected::Other("KEKRecipientInfo::key_encryption_algorithm is missing"),
                                    &"valid KEKRecipientInfo",
                                )
                            })?,
                            encrypted_key: seq.next_element()?.ok_or_else(|| {
                                de::Error::invalid_value(
                                    de::Unexpected::Other("KEKRecipientInfo::encrypted_key is missing"),
                                    &"valid KEKRecipientInfo",
                                )
                            })?,
                        }))
                    }
                    _ => Err(de::Error::invalid_value(
                        de::Unexpected::Other("[RecipientInfo] unknown choice value"),
                        &"a supported RecipientInfo choice",
                    )),
                }
            }
        }

        deserializer.deserialize_enum("RecipientInfo", &["KekRecipientInfo"], Visitor)
    }
}

impl Serialize for RecipientInfo {
    fn serialize<S>(&self, serializer: S) -> Result<<S as ser::Serializer>::Ok, <S as ser::Serializer>::Error>
    where
        S: ser::Serializer,
    {
        use serde::ser::Error;

        let buf = match self {
            RecipientInfo::Kek(kek_recipient_info) => {
                let mut buf = picky_asn1_der::to_vec(&kek_recipient_info.version)
                    .map_err(|err| S::Error::custom(format!("Cannot serialize version: {:?}", err)))?;
                buf.extend_from_slice(
                    &picky_asn1_der::to_vec(&kek_recipient_info.kek_id)
                        .map_err(|err| S::Error::custom(format!("Cannot serialize kek_id: {:?}", err)))?,
                );
                buf.extend_from_slice(
                    &picky_asn1_der::to_vec(&kek_recipient_info.key_encryption_algorithm).map_err(|err| {
                        S::Error::custom(format!("Cannot serialize key_encryption_algorithm: {:?}", err))
                    })?,
                );
                buf.extend_from_slice(
                    &picky_asn1_der::to_vec(&kek_recipient_info.encrypted_key)
                        .map_err(|err| S::Error::custom(format!("Cannot serialize encrypted_key: {:?}", err)))?,
                );
                buf
            }
        };

        ExplicitContextTag2::from(Asn1RawDer(buf)).serialize(serializer)
    }
}

/// [KEKIdentifier](https://www.rfc-editor.org/rfc/rfc5652#section-6.2.3)
///
/// ```not_rust
/// KEKIdentifier ::= SEQUENCE {
///   keyIdentifier OCTET STRING,
///   date GeneralizedTime OPTIONAL,
///   other OtherKeyAttribute OPTIONAL }
/// ```
#[derive(Serialize, Deserialize, Debug, Clone, PartialEq)]
pub struct KekIdentifier {
    pub key_identifier: OctetStringAsn1,
    #[serde(default)]
    pub date: Optional<Option<GeneralizedTimeAsn1>>,
    #[serde(default)]
    pub other: Optional<Option<OtherKeyAttribute>>,
}

/// [OtherKeyAttribute](https://www.rfc-editor.org/rfc/rfc5652#section-10.2.7)
///
/// ```not_rust
/// OtherKeyAttribute ::= SEQUENCE {
///   keyAttrId OBJECT IDENTIFIER,
///   keyAttr ANY DEFINED BY keyAttrId OPTIONAL }
/// ```
#[derive(Serialize, Deserialize, Debug, Clone, PartialEq)]
pub struct OtherKeyAttribute {
    pub key_attr_id: ObjectIdentifierAsn1,
    pub key_attr: Option<Asn1RawDer>,
}

#[derive(Serialize, Deserialize, Debug, Clone, PartialEq)]
pub struct GeneralProtectionDescriptor {
    pub descriptor_type: ObjectIdentifierAsn1,
    pub descriptors: Asn1SequenceOf<Asn1SequenceOf<ProtectionDescriptor>>,
}

#[derive(Serialize, Deserialize, Debug, Clone, PartialEq)]
pub struct ProtectionDescriptor {
    pub descriptor_type: Utf8StringAsn1,
    pub descriptor_value: Utf8StringAsn1,
}

#[cfg(test)]
mod tests {
    use picky_asn1::restricted_string::Utf8String;
    use picky_asn1::wrapper::IntegerAsn1;

    use super::*;
    use crate::{AesAuthEncParams, AesMode, AesParameters, oids};

    #[test]
    fn general_protection_descriptor_encoding_decoding() {
        let data = [
            48, 69, 6, 10, 43, 6, 1, 4, 1, 130, 55, 74, 1, 1, 48, 55, 48, 53, 48, 51, 12, 3, 83, 73, 68, 12, 44, 83,
            45, 49, 45, 53, 45, 50, 49, 45, 51, 51, 51, 55, 51, 51, 55, 57, 55, 51, 45, 51, 50, 57, 55, 48, 55, 56, 48,
            50, 56, 45, 52, 51, 55, 51, 56, 54, 48, 54, 54, 45, 53, 49, 50,
        ];
        let expected = GeneralProtectionDescriptor {
            descriptor_type: ObjectIdentifierAsn1::from(oids::sid_protection_descriptor()),
            descriptors: Asn1SequenceOf::from(vec![Asn1SequenceOf::from(vec![ProtectionDescriptor {
                descriptor_type: Utf8StringAsn1::from(Utf8String::from_string("SID".to_owned()).unwrap()),
                descriptor_value: Utf8StringAsn1::from(
                    Utf8String::from_string("S-1-5-21-3337337973-3297078028-437386066-512".to_owned()).unwrap(),
                ),
            }])]),
        };

        let parsed = picky_asn1_der::from_bytes(&data).unwrap();
        let encoded = picky_asn1_der::to_vec(&parsed).unwrap();

        assert_eq!(expected, parsed);
        assert_eq!(data.as_ref(), &encoded);
    }

    #[test]
    fn enveloped_data_encoding_decoding() {
        let data = [
            48, 130, 4, 58, 2, 1, 2, 49, 130, 4, 6, 162, 130, 4, 2, 2, 1, 4, 48, 130, 3, 196, 4, 130, 3, 108, 1, 0, 0,
            0, 75, 68, 83, 75, 3, 0, 0, 0, 105, 1, 0, 0, 16, 0, 0, 0, 3, 0, 0, 0, 113, 194, 120, 215, 37, 144, 130,
            154, 246, 220, 184, 150, 11, 138, 216, 197, 8, 3, 0, 0, 24, 0, 0, 0, 24, 0, 0, 0, 68, 72, 80, 66, 0, 1, 0,
            0, 135, 168, 230, 29, 180, 182, 102, 60, 255, 187, 209, 156, 101, 25, 89, 153, 140, 238, 246, 8, 102, 13,
            208, 242, 93, 44, 238, 212, 67, 94, 59, 0, 224, 13, 248, 241, 214, 25, 87, 212, 250, 247, 223, 69, 97, 178,
            170, 48, 22, 195, 217, 17, 52, 9, 111, 170, 59, 244, 41, 109, 131, 14, 154, 124, 32, 158, 12, 100, 151, 81,
            122, 189, 90, 138, 157, 48, 107, 207, 103, 237, 145, 249, 230, 114, 91, 71, 88, 192, 34, 224, 177, 239, 66,
            117, 191, 123, 108, 91, 252, 17, 212, 95, 144, 136, 185, 65, 245, 78, 177, 229, 155, 184, 188, 57, 160,
            191, 18, 48, 127, 92, 79, 219, 112, 197, 129, 178, 63, 118, 182, 58, 202, 225, 202, 166, 183, 144, 45, 82,
            82, 103, 53, 72, 138, 14, 241, 60, 109, 154, 81, 191, 164, 171, 58, 216, 52, 119, 150, 82, 77, 142, 246,
            161, 103, 181, 164, 24, 37, 217, 103, 225, 68, 229, 20, 5, 100, 37, 28, 202, 203, 131, 230, 180, 134, 246,
            179, 202, 63, 121, 113, 80, 96, 38, 192, 184, 87, 246, 137, 150, 40, 86, 222, 212, 1, 10, 189, 11, 230, 33,
            195, 163, 150, 10, 84, 231, 16, 195, 117, 242, 99, 117, 215, 1, 65, 3, 164, 181, 67, 48, 193, 152, 175, 18,
            97, 22, 210, 39, 110, 17, 113, 95, 105, 56, 119, 250, 215, 239, 9, 202, 219, 9, 74, 233, 30, 26, 21, 151,
            63, 179, 44, 155, 115, 19, 77, 11, 46, 119, 80, 102, 96, 237, 189, 72, 76, 167, 177, 143, 33, 239, 32, 84,
            7, 244, 121, 58, 26, 11, 161, 37, 16, 219, 193, 80, 119, 190, 70, 63, 255, 79, 237, 74, 172, 11, 181, 85,
            190, 58, 108, 27, 12, 107, 71, 177, 188, 55, 115, 191, 126, 140, 111, 98, 144, 18, 40, 248, 194, 140, 187,
            24, 165, 90, 227, 19, 65, 0, 10, 101, 1, 150, 249, 49, 199, 122, 87, 242, 221, 244, 99, 229, 233, 236, 20,
            75, 119, 125, 230, 42, 170, 184, 168, 98, 138, 195, 118, 210, 130, 214, 237, 56, 100, 230, 121, 130, 66,
            142, 188, 131, 29, 20, 52, 143, 111, 47, 145, 147, 181, 4, 90, 242, 118, 113, 100, 225, 223, 201, 103, 193,
            251, 63, 46, 85, 164, 189, 27, 255, 232, 59, 156, 128, 208, 82, 185, 133, 209, 130, 234, 10, 219, 42, 59,
            115, 19, 211, 254, 20, 200, 72, 75, 30, 5, 37, 136, 185, 183, 210, 187, 210, 223, 1, 97, 153, 236, 208,
            110, 21, 87, 205, 9, 21, 179, 53, 59, 187, 100, 224, 236, 55, 127, 208, 40, 55, 13, 249, 43, 82, 199, 137,
            20, 40, 205, 198, 126, 182, 24, 75, 82, 61, 29, 178, 70, 195, 47, 99, 7, 132, 144, 240, 14, 248, 214, 71,
            209, 72, 212, 121, 84, 81, 94, 35, 39, 207, 239, 152, 197, 130, 102, 75, 76, 15, 108, 196, 22, 89, 45, 48,
            255, 175, 224, 178, 34, 113, 55, 121, 103, 94, 57, 230, 149, 227, 2, 8, 211, 56, 135, 63, 75, 228, 67, 79,
            182, 168, 130, 79, 28, 56, 65, 78, 255, 48, 67, 5, 243, 1, 170, 131, 242, 24, 216, 174, 93, 89, 249, 12,
            215, 25, 248, 12, 146, 191, 38, 9, 239, 136, 197, 113, 125, 222, 79, 184, 149, 180, 198, 185, 10, 161, 28,
            53, 69, 19, 173, 197, 112, 73, 23, 172, 239, 88, 66, 170, 206, 185, 238, 228, 152, 153, 163, 198, 94, 147,
            212, 117, 120, 83, 30, 158, 8, 70, 1, 73, 134, 237, 77, 162, 147, 56, 224, 231, 179, 30, 110, 19, 55, 253,
            176, 115, 101, 171, 146, 59, 227, 37, 145, 200, 156, 20, 33, 186, 8, 34, 118, 162, 125, 114, 229, 11, 202,
            36, 115, 124, 83, 60, 251, 141, 83, 244, 164, 213, 197, 199, 2, 130, 173, 22, 120, 61, 63, 196, 111, 60,
            184, 58, 17, 34, 166, 237, 250, 238, 19, 150, 192, 123, 172, 162, 70, 227, 90, 165, 58, 139, 124, 87, 199,
            135, 30, 146, 142, 203, 133, 133, 54, 26, 54, 229, 134, 122, 117, 207, 31, 184, 148, 68, 232, 89, 132, 91,
            246, 40, 87, 225, 14, 74, 23, 81, 228, 241, 146, 171, 106, 211, 196, 222, 192, 142, 81, 207, 169, 185, 24,
            161, 88, 75, 138, 97, 111, 92, 43, 214, 190, 140, 12, 124, 177, 67, 125, 237, 147, 195, 41, 40, 100, 0,
            111, 0, 109, 0, 97, 0, 105, 0, 110, 0, 46, 0, 116, 0, 101, 0, 115, 0, 116, 0, 0, 0, 100, 0, 111, 0, 109, 0,
            97, 0, 105, 0, 110, 0, 46, 0, 116, 0, 101, 0, 115, 0, 116, 0, 0, 0, 48, 82, 6, 9, 43, 6, 1, 4, 1, 130, 55,
            74, 1, 48, 69, 6, 10, 43, 6, 1, 4, 1, 130, 55, 74, 1, 1, 48, 55, 48, 53, 48, 51, 12, 3, 83, 73, 68, 12, 44,
            83, 45, 49, 45, 53, 45, 50, 49, 45, 51, 51, 51, 55, 51, 51, 55, 57, 55, 51, 45, 51, 50, 57, 55, 48, 55, 56,
            48, 50, 56, 45, 52, 51, 55, 51, 56, 54, 48, 54, 54, 45, 53, 49, 50, 48, 11, 6, 9, 96, 134, 72, 1, 101, 3,
            4, 1, 45, 4, 40, 137, 127, 196, 63, 116, 142, 253, 9, 87, 39, 221, 233, 143, 78, 26, 111, 251, 157, 65, 99,
            211, 159, 179, 116, 208, 73, 199, 61, 137, 105, 12, 126, 250, 69, 230, 190, 17, 158, 13, 107, 48, 43, 6, 9,
            42, 134, 72, 134, 247, 13, 1, 7, 1, 48, 30, 6, 9, 96, 134, 72, 1, 101, 3, 4, 1, 46, 48, 17, 4, 12, 158, 91,
            46, 23, 194, 63, 4, 252, 53, 37, 225, 24, 2, 1, 16,
        ];
        let expected = EnvelopedData {
            version: CmsVersion::V2,
            originator_info: Optional::from(None),
            recipient_infos: RecipientInfos::from(vec![RecipientInfo::Kek(KekRecipientInfo {
                version: CmsVersion::V4,
                kek_id: KekIdentifier {
                    key_identifier: OctetStringAsn1::from(vec![
                        1, 0, 0, 0, 75, 68, 83, 75, 3, 0, 0, 0, 105, 1, 0, 0, 16, 0, 0, 0, 3, 0, 0, 0, 113, 194, 120,
                        215, 37, 144, 130, 154, 246, 220, 184, 150, 11, 138, 216, 197, 8, 3, 0, 0, 24, 0, 0, 0, 24, 0,
                        0, 0, 68, 72, 80, 66, 0, 1, 0, 0, 135, 168, 230, 29, 180, 182, 102, 60, 255, 187, 209, 156,
                        101, 25, 89, 153, 140, 238, 246, 8, 102, 13, 208, 242, 93, 44, 238, 212, 67, 94, 59, 0, 224,
                        13, 248, 241, 214, 25, 87, 212, 250, 247, 223, 69, 97, 178, 170, 48, 22, 195, 217, 17, 52, 9,
                        111, 170, 59, 244, 41, 109, 131, 14, 154, 124, 32, 158, 12, 100, 151, 81, 122, 189, 90, 138,
                        157, 48, 107, 207, 103, 237, 145, 249, 230, 114, 91, 71, 88, 192, 34, 224, 177, 239, 66, 117,
                        191, 123, 108, 91, 252, 17, 212, 95, 144, 136, 185, 65, 245, 78, 177, 229, 155, 184, 188, 57,
                        160, 191, 18, 48, 127, 92, 79, 219, 112, 197, 129, 178, 63, 118, 182, 58, 202, 225, 202, 166,
                        183, 144, 45, 82, 82, 103, 53, 72, 138, 14, 241, 60, 109, 154, 81, 191, 164, 171, 58, 216, 52,
                        119, 150, 82, 77, 142, 246, 161, 103, 181, 164, 24, 37, 217, 103, 225, 68, 229, 20, 5, 100, 37,
                        28, 202, 203, 131, 230, 180, 134, 246, 179, 202, 63, 121, 113, 80, 96, 38, 192, 184, 87, 246,
                        137, 150, 40, 86, 222, 212, 1, 10, 189, 11, 230, 33, 195, 163, 150, 10, 84, 231, 16, 195, 117,
                        242, 99, 117, 215, 1, 65, 3, 164, 181, 67, 48, 193, 152, 175, 18, 97, 22, 210, 39, 110, 17,
                        113, 95, 105, 56, 119, 250, 215, 239, 9, 202, 219, 9, 74, 233, 30, 26, 21, 151, 63, 179, 44,
                        155, 115, 19, 77, 11, 46, 119, 80, 102, 96, 237, 189, 72, 76, 167, 177, 143, 33, 239, 32, 84,
                        7, 244, 121, 58, 26, 11, 161, 37, 16, 219, 193, 80, 119, 190, 70, 63, 255, 79, 237, 74, 172,
                        11, 181, 85, 190, 58, 108, 27, 12, 107, 71, 177, 188, 55, 115, 191, 126, 140, 111, 98, 144, 18,
                        40, 248, 194, 140, 187, 24, 165, 90, 227, 19, 65, 0, 10, 101, 1, 150, 249, 49, 199, 122, 87,
                        242, 221, 244, 99, 229, 233, 236, 20, 75, 119, 125, 230, 42, 170, 184, 168, 98, 138, 195, 118,
                        210, 130, 214, 237, 56, 100, 230, 121, 130, 66, 142, 188, 131, 29, 20, 52, 143, 111, 47, 145,
                        147, 181, 4, 90, 242, 118, 113, 100, 225, 223, 201, 103, 193, 251, 63, 46, 85, 164, 189, 27,
                        255, 232, 59, 156, 128, 208, 82, 185, 133, 209, 130, 234, 10, 219, 42, 59, 115, 19, 211, 254,
                        20, 200, 72, 75, 30, 5, 37, 136, 185, 183, 210, 187, 210, 223, 1, 97, 153, 236, 208, 110, 21,
                        87, 205, 9, 21, 179, 53, 59, 187, 100, 224, 236, 55, 127, 208, 40, 55, 13, 249, 43, 82, 199,
                        137, 20, 40, 205, 198, 126, 182, 24, 75, 82, 61, 29, 178, 70, 195, 47, 99, 7, 132, 144, 240,
                        14, 248, 214, 71, 209, 72, 212, 121, 84, 81, 94, 35, 39, 207, 239, 152, 197, 130, 102, 75, 76,
                        15, 108, 196, 22, 89, 45, 48, 255, 175, 224, 178, 34, 113, 55, 121, 103, 94, 57, 230, 149, 227,
                        2, 8, 211, 56, 135, 63, 75, 228, 67, 79, 182, 168, 130, 79, 28, 56, 65, 78, 255, 48, 67, 5,
                        243, 1, 170, 131, 242, 24, 216, 174, 93, 89, 249, 12, 215, 25, 248, 12, 146, 191, 38, 9, 239,
                        136, 197, 113, 125, 222, 79, 184, 149, 180, 198, 185, 10, 161, 28, 53, 69, 19, 173, 197, 112,
                        73, 23, 172, 239, 88, 66, 170, 206, 185, 238, 228, 152, 153, 163, 198, 94, 147, 212, 117, 120,
                        83, 30, 158, 8, 70, 1, 73, 134, 237, 77, 162, 147, 56, 224, 231, 179, 30, 110, 19, 55, 253,
                        176, 115, 101, 171, 146, 59, 227, 37, 145, 200, 156, 20, 33, 186, 8, 34, 118, 162, 125, 114,
                        229, 11, 202, 36, 115, 124, 83, 60, 251, 141, 83, 244, 164, 213, 197, 199, 2, 130, 173, 22,
                        120, 61, 63, 196, 111, 60, 184, 58, 17, 34, 166, 237, 250, 238, 19, 150, 192, 123, 172, 162,
                        70, 227, 90, 165, 58, 139, 124, 87, 199, 135, 30, 146, 142, 203, 133, 133, 54, 26, 54, 229,
                        134, 122, 117, 207, 31, 184, 148, 68, 232, 89, 132, 91, 246, 40, 87, 225, 14, 74, 23, 81, 228,
                        241, 146, 171, 106, 211, 196, 222, 192, 142, 81, 207, 169, 185, 24, 161, 88, 75, 138, 97, 111,
                        92, 43, 214, 190, 140, 12, 124, 177, 67, 125, 237, 147, 195, 41, 40, 100, 0, 111, 0, 109, 0,
                        97, 0, 105, 0, 110, 0, 46, 0, 116, 0, 101, 0, 115, 0, 116, 0, 0, 0, 100, 0, 111, 0, 109, 0, 97,
                        0, 105, 0, 110, 0, 46, 0, 116, 0, 101, 0, 115, 0, 116, 0, 0, 0,
                    ]),
                    date: Optional::from(None),
                    other: Optional::from(Some(OtherKeyAttribute {
                        key_attr_id: ObjectIdentifierAsn1::from(oids::protection_descriptor_type()),
                        key_attr: Some(Asn1RawDer(
                            picky_asn1_der::to_vec(&GeneralProtectionDescriptor {
                                descriptor_type: ObjectIdentifierAsn1::from(oids::sid_protection_descriptor()),
                                descriptors: Asn1SequenceOf::from(vec![Asn1SequenceOf::from(vec![
                                    ProtectionDescriptor {
                                        descriptor_type: Utf8StringAsn1::from(
                                            Utf8String::from_string("SID".to_owned()).unwrap(),
                                        ),
                                        descriptor_value: Utf8StringAsn1::from(
                                            Utf8String::from_string(
                                                "S-1-5-21-3337337973-3297078028-437386066-512".to_owned(),
                                            )
                                            .unwrap(),
                                        ),
                                    },
                                ])]),
                            })
                            .unwrap(),
                        )),
                    })),
                },
                key_encryption_algorithm: KeyEncryptionAlgorithmIdentifier::new_aes256_empty(AesMode::Wrap),
                encrypted_key: EncryptedKey::from(vec![
                    137, 127, 196, 63, 116, 142, 253, 9, 87, 39, 221, 233, 143, 78, 26, 111, 251, 157, 65, 99, 211,
                    159, 179, 116, 208, 73, 199, 61, 137, 105, 12, 126, 250, 69, 230, 190, 17, 158, 13, 107,
                ]),
            })]),
            encrypted_content_info: EncryptedContentInfo {
                content_type: ContentType::from(oids::content_info_type_data()),
                content_encryption_algorithm: ContentEncryptionAlgorithmIdentifier::new_aes256(
                    AesMode::Gcm,
                    AesParameters::AuthenticatedEncryptionParameters(AesAuthEncParams {
                        nonce: OctetStringAsn1::from(vec![158, 91, 46, 23, 194, 63, 4, 252, 53, 37, 225, 24]),
                        icv_len: IntegerAsn1::from(vec![16]),
                    }),
                ),
                encrypted_content: Optional::from(None),
            },
            unprotected_attrs: Optional::from(None),
        };

        let parsed: EnvelopedData = picky_asn1_der::from_bytes(&data).unwrap();
        let encoded = picky_asn1_der::to_vec(&parsed).unwrap();

        assert_eq!(expected, parsed);
        assert_eq!(data.as_ref(), &encoded);
    }

    #[test]
    fn encrypted_content_info() {
        let data = [
            48, 43, 6, 9, 42, 134, 72, 134, 247, 13, 1, 7, 1, 48, 30, 6, 9, 96, 134, 72, 1, 101, 3, 4, 1, 46, 48, 17,
            4, 12, 158, 91, 46, 23, 194, 63, 4, 252, 53, 37, 225, 24, 2, 1, 16,
        ];
        let expected = EncryptedContentInfo {
            content_type: ContentType::from(oids::content_info_type_data()),
            content_encryption_algorithm: ContentEncryptionAlgorithmIdentifier::new_aes256(
                AesMode::Gcm,
                AesParameters::AuthenticatedEncryptionParameters(AesAuthEncParams {
                    nonce: OctetStringAsn1::from(vec![158, 91, 46, 23, 194, 63, 4, 252, 53, 37, 225, 24]),
                    icv_len: IntegerAsn1::from(vec![16]),
                }),
            ),
            encrypted_content: Optional::from(None),
        };

        let parsed: EncryptedContentInfo = picky_asn1_der::from_bytes(&data).unwrap();
        let encoded = picky_asn1_der::to_vec(&parsed).unwrap();

        assert_eq!(expected, parsed);
        assert_eq!(data.as_ref(), &encoded);
    }

    #[test]
    fn recipient_infos() {
        let data = [
            49, 130, 4, 6, 162, 130, 4, 2, 2, 1, 4, 48, 130, 3, 196, 4, 130, 3, 108, 1, 0, 0, 0, 75, 68, 83, 75, 3, 0,
            0, 0, 105, 1, 0, 0, 16, 0, 0, 0, 3, 0, 0, 0, 113, 194, 120, 215, 37, 144, 130, 154, 246, 220, 184, 150, 11,
            138, 216, 197, 8, 3, 0, 0, 24, 0, 0, 0, 24, 0, 0, 0, 68, 72, 80, 66, 0, 1, 0, 0, 135, 168, 230, 29, 180,
            182, 102, 60, 255, 187, 209, 156, 101, 25, 89, 153, 140, 238, 246, 8, 102, 13, 208, 242, 93, 44, 238, 212,
            67, 94, 59, 0, 224, 13, 248, 241, 214, 25, 87, 212, 250, 247, 223, 69, 97, 178, 170, 48, 22, 195, 217, 17,
            52, 9, 111, 170, 59, 244, 41, 109, 131, 14, 154, 124, 32, 158, 12, 100, 151, 81, 122, 189, 90, 138, 157,
            48, 107, 207, 103, 237, 145, 249, 230, 114, 91, 71, 88, 192, 34, 224, 177, 239, 66, 117, 191, 123, 108, 91,
            252, 17, 212, 95, 144, 136, 185, 65, 245, 78, 177, 229, 155, 184, 188, 57, 160, 191, 18, 48, 127, 92, 79,
            219, 112, 197, 129, 178, 63, 118, 182, 58, 202, 225, 202, 166, 183, 144, 45, 82, 82, 103, 53, 72, 138, 14,
            241, 60, 109, 154, 81, 191, 164, 171, 58, 216, 52, 119, 150, 82, 77, 142, 246, 161, 103, 181, 164, 24, 37,
            217, 103, 225, 68, 229, 20, 5, 100, 37, 28, 202, 203, 131, 230, 180, 134, 246, 179, 202, 63, 121, 113, 80,
            96, 38, 192, 184, 87, 246, 137, 150, 40, 86, 222, 212, 1, 10, 189, 11, 230, 33, 195, 163, 150, 10, 84, 231,
            16, 195, 117, 242, 99, 117, 215, 1, 65, 3, 164, 181, 67, 48, 193, 152, 175, 18, 97, 22, 210, 39, 110, 17,
            113, 95, 105, 56, 119, 250, 215, 239, 9, 202, 219, 9, 74, 233, 30, 26, 21, 151, 63, 179, 44, 155, 115, 19,
            77, 11, 46, 119, 80, 102, 96, 237, 189, 72, 76, 167, 177, 143, 33, 239, 32, 84, 7, 244, 121, 58, 26, 11,
            161, 37, 16, 219, 193, 80, 119, 190, 70, 63, 255, 79, 237, 74, 172, 11, 181, 85, 190, 58, 108, 27, 12, 107,
            71, 177, 188, 55, 115, 191, 126, 140, 111, 98, 144, 18, 40, 248, 194, 140, 187, 24, 165, 90, 227, 19, 65,
            0, 10, 101, 1, 150, 249, 49, 199, 122, 87, 242, 221, 244, 99, 229, 233, 236, 20, 75, 119, 125, 230, 42,
            170, 184, 168, 98, 138, 195, 118, 210, 130, 214, 237, 56, 100, 230, 121, 130, 66, 142, 188, 131, 29, 20,
            52, 143, 111, 47, 145, 147, 181, 4, 90, 242, 118, 113, 100, 225, 223, 201, 103, 193, 251, 63, 46, 85, 164,
            189, 27, 255, 232, 59, 156, 128, 208, 82, 185, 133, 209, 130, 234, 10, 219, 42, 59, 115, 19, 211, 254, 20,
            200, 72, 75, 30, 5, 37, 136, 185, 183, 210, 187, 210, 223, 1, 97, 153, 236, 208, 110, 21, 87, 205, 9, 21,
            179, 53, 59, 187, 100, 224, 236, 55, 127, 208, 40, 55, 13, 249, 43, 82, 199, 137, 20, 40, 205, 198, 126,
            182, 24, 75, 82, 61, 29, 178, 70, 195, 47, 99, 7, 132, 144, 240, 14, 248, 214, 71, 209, 72, 212, 121, 84,
            81, 94, 35, 39, 207, 239, 152, 197, 130, 102, 75, 76, 15, 108, 196, 22, 89, 45, 48, 255, 175, 224, 178, 34,
            113, 55, 121, 103, 94, 57, 230, 149, 227, 2, 8, 211, 56, 135, 63, 75, 228, 67, 79, 182, 168, 130, 79, 28,
            56, 65, 78, 255, 48, 67, 5, 243, 1, 170, 131, 242, 24, 216, 174, 93, 89, 249, 12, 215, 25, 248, 12, 146,
            191, 38, 9, 239, 136, 197, 113, 125, 222, 79, 184, 149, 180, 198, 185, 10, 161, 28, 53, 69, 19, 173, 197,
            112, 73, 23, 172, 239, 88, 66, 170, 206, 185, 238, 228, 152, 153, 163, 198, 94, 147, 212, 117, 120, 83, 30,
            158, 8, 70, 1, 73, 134, 237, 77, 162, 147, 56, 224, 231, 179, 30, 110, 19, 55, 253, 176, 115, 101, 171,
            146, 59, 227, 37, 145, 200, 156, 20, 33, 186, 8, 34, 118, 162, 125, 114, 229, 11, 202, 36, 115, 124, 83,
            60, 251, 141, 83, 244, 164, 213, 197, 199, 2, 130, 173, 22, 120, 61, 63, 196, 111, 60, 184, 58, 17, 34,
            166, 237, 250, 238, 19, 150, 192, 123, 172, 162, 70, 227, 90, 165, 58, 139, 124, 87, 199, 135, 30, 146,
            142, 203, 133, 133, 54, 26, 54, 229, 134, 122, 117, 207, 31, 184, 148, 68, 232, 89, 132, 91, 246, 40, 87,
            225, 14, 74, 23, 81, 228, 241, 146, 171, 106, 211, 196, 222, 192, 142, 81, 207, 169, 185, 24, 161, 88, 75,
            138, 97, 111, 92, 43, 214, 190, 140, 12, 124, 177, 67, 125, 237, 147, 195, 41, 40, 100, 0, 111, 0, 109, 0,
            97, 0, 105, 0, 110, 0, 46, 0, 116, 0, 101, 0, 115, 0, 116, 0, 0, 0, 100, 0, 111, 0, 109, 0, 97, 0, 105, 0,
            110, 0, 46, 0, 116, 0, 101, 0, 115, 0, 116, 0, 0, 0, 48, 82, 6, 9, 43, 6, 1, 4, 1, 130, 55, 74, 1, 48, 69,
            6, 10, 43, 6, 1, 4, 1, 130, 55, 74, 1, 1, 48, 55, 48, 53, 48, 51, 12, 3, 83, 73, 68, 12, 44, 83, 45, 49,
            45, 53, 45, 50, 49, 45, 51, 51, 51, 55, 51, 51, 55, 57, 55, 51, 45, 51, 50, 57, 55, 48, 55, 56, 48, 50, 56,
            45, 52, 51, 55, 51, 56, 54, 48, 54, 54, 45, 53, 49, 50, 48, 11, 6, 9, 96, 134, 72, 1, 101, 3, 4, 1, 45, 4,
            40, 137, 127, 196, 63, 116, 142, 253, 9, 87, 39, 221, 233, 143, 78, 26, 111, 251, 157, 65, 99, 211, 159,
            179, 116, 208, 73, 199, 61, 137, 105, 12, 126, 250, 69, 230, 190, 17, 158, 13, 107,
        ];
        let expected = RecipientInfos::from(vec![RecipientInfo::Kek(KekRecipientInfo {
            version: CmsVersion::V4,
            kek_id: KekIdentifier {
                key_identifier: OctetStringAsn1::from(vec![
                    1, 0, 0, 0, 75, 68, 83, 75, 3, 0, 0, 0, 105, 1, 0, 0, 16, 0, 0, 0, 3, 0, 0, 0, 113, 194, 120, 215,
                    37, 144, 130, 154, 246, 220, 184, 150, 11, 138, 216, 197, 8, 3, 0, 0, 24, 0, 0, 0, 24, 0, 0, 0, 68,
                    72, 80, 66, 0, 1, 0, 0, 135, 168, 230, 29, 180, 182, 102, 60, 255, 187, 209, 156, 101, 25, 89, 153,
                    140, 238, 246, 8, 102, 13, 208, 242, 93, 44, 238, 212, 67, 94, 59, 0, 224, 13, 248, 241, 214, 25,
                    87, 212, 250, 247, 223, 69, 97, 178, 170, 48, 22, 195, 217, 17, 52, 9, 111, 170, 59, 244, 41, 109,
                    131, 14, 154, 124, 32, 158, 12, 100, 151, 81, 122, 189, 90, 138, 157, 48, 107, 207, 103, 237, 145,
                    249, 230, 114, 91, 71, 88, 192, 34, 224, 177, 239, 66, 117, 191, 123, 108, 91, 252, 17, 212, 95,
                    144, 136, 185, 65, 245, 78, 177, 229, 155, 184, 188, 57, 160, 191, 18, 48, 127, 92, 79, 219, 112,
                    197, 129, 178, 63, 118, 182, 58, 202, 225, 202, 166, 183, 144, 45, 82, 82, 103, 53, 72, 138, 14,
                    241, 60, 109, 154, 81, 191, 164, 171, 58, 216, 52, 119, 150, 82, 77, 142, 246, 161, 103, 181, 164,
                    24, 37, 217, 103, 225, 68, 229, 20, 5, 100, 37, 28, 202, 203, 131, 230, 180, 134, 246, 179, 202,
                    63, 121, 113, 80, 96, 38, 192, 184, 87, 246, 137, 150, 40, 86, 222, 212, 1, 10, 189, 11, 230, 33,
                    195, 163, 150, 10, 84, 231, 16, 195, 117, 242, 99, 117, 215, 1, 65, 3, 164, 181, 67, 48, 193, 152,
                    175, 18, 97, 22, 210, 39, 110, 17, 113, 95, 105, 56, 119, 250, 215, 239, 9, 202, 219, 9, 74, 233,
                    30, 26, 21, 151, 63, 179, 44, 155, 115, 19, 77, 11, 46, 119, 80, 102, 96, 237, 189, 72, 76, 167,
                    177, 143, 33, 239, 32, 84, 7, 244, 121, 58, 26, 11, 161, 37, 16, 219, 193, 80, 119, 190, 70, 63,
                    255, 79, 237, 74, 172, 11, 181, 85, 190, 58, 108, 27, 12, 107, 71, 177, 188, 55, 115, 191, 126,
                    140, 111, 98, 144, 18, 40, 248, 194, 140, 187, 24, 165, 90, 227, 19, 65, 0, 10, 101, 1, 150, 249,
                    49, 199, 122, 87, 242, 221, 244, 99, 229, 233, 236, 20, 75, 119, 125, 230, 42, 170, 184, 168, 98,
                    138, 195, 118, 210, 130, 214, 237, 56, 100, 230, 121, 130, 66, 142, 188, 131, 29, 20, 52, 143, 111,
                    47, 145, 147, 181, 4, 90, 242, 118, 113, 100, 225, 223, 201, 103, 193, 251, 63, 46, 85, 164, 189,
                    27, 255, 232, 59, 156, 128, 208, 82, 185, 133, 209, 130, 234, 10, 219, 42, 59, 115, 19, 211, 254,
                    20, 200, 72, 75, 30, 5, 37, 136, 185, 183, 210, 187, 210, 223, 1, 97, 153, 236, 208, 110, 21, 87,
                    205, 9, 21, 179, 53, 59, 187, 100, 224, 236, 55, 127, 208, 40, 55, 13, 249, 43, 82, 199, 137, 20,
                    40, 205, 198, 126, 182, 24, 75, 82, 61, 29, 178, 70, 195, 47, 99, 7, 132, 144, 240, 14, 248, 214,
                    71, 209, 72, 212, 121, 84, 81, 94, 35, 39, 207, 239, 152, 197, 130, 102, 75, 76, 15, 108, 196, 22,
                    89, 45, 48, 255, 175, 224, 178, 34, 113, 55, 121, 103, 94, 57, 230, 149, 227, 2, 8, 211, 56, 135,
                    63, 75, 228, 67, 79, 182, 168, 130, 79, 28, 56, 65, 78, 255, 48, 67, 5, 243, 1, 170, 131, 242, 24,
                    216, 174, 93, 89, 249, 12, 215, 25, 248, 12, 146, 191, 38, 9, 239, 136, 197, 113, 125, 222, 79,
                    184, 149, 180, 198, 185, 10, 161, 28, 53, 69, 19, 173, 197, 112, 73, 23, 172, 239, 88, 66, 170,
                    206, 185, 238, 228, 152, 153, 163, 198, 94, 147, 212, 117, 120, 83, 30, 158, 8, 70, 1, 73, 134,
                    237, 77, 162, 147, 56, 224, 231, 179, 30, 110, 19, 55, 253, 176, 115, 101, 171, 146, 59, 227, 37,
                    145, 200, 156, 20, 33, 186, 8, 34, 118, 162, 125, 114, 229, 11, 202, 36, 115, 124, 83, 60, 251,
                    141, 83, 244, 164, 213, 197, 199, 2, 130, 173, 22, 120, 61, 63, 196, 111, 60, 184, 58, 17, 34, 166,
                    237, 250, 238, 19, 150, 192, 123, 172, 162, 70, 227, 90, 165, 58, 139, 124, 87, 199, 135, 30, 146,
                    142, 203, 133, 133, 54, 26, 54, 229, 134, 122, 117, 207, 31, 184, 148, 68, 232, 89, 132, 91, 246,
                    40, 87, 225, 14, 74, 23, 81, 228, 241, 146, 171, 106, 211, 196, 222, 192, 142, 81, 207, 169, 185,
                    24, 161, 88, 75, 138, 97, 111, 92, 43, 214, 190, 140, 12, 124, 177, 67, 125, 237, 147, 195, 41, 40,
                    100, 0, 111, 0, 109, 0, 97, 0, 105, 0, 110, 0, 46, 0, 116, 0, 101, 0, 115, 0, 116, 0, 0, 0, 100, 0,
                    111, 0, 109, 0, 97, 0, 105, 0, 110, 0, 46, 0, 116, 0, 101, 0, 115, 0, 116, 0, 0, 0,
                ]),
                date: Optional::from(None),
                other: Optional::from(Some(OtherKeyAttribute {
                    key_attr_id: ObjectIdentifierAsn1::from(oids::protection_descriptor_type()),
                    key_attr: Some(Asn1RawDer(
                        picky_asn1_der::to_vec(&GeneralProtectionDescriptor {
                            descriptor_type: ObjectIdentifierAsn1::from(oids::sid_protection_descriptor()),
                            descriptors: Asn1SequenceOf::from(vec![Asn1SequenceOf::from(vec![ProtectionDescriptor {
                                descriptor_type: Utf8StringAsn1::from(
                                    Utf8String::from_string("SID".to_owned()).unwrap(),
                                ),
                                descriptor_value: Utf8StringAsn1::from(
                                    Utf8String::from_string("S-1-5-21-3337337973-3297078028-437386066-512".to_owned())
                                        .unwrap(),
                                ),
                            }])]),
                        })
                        .unwrap(),
                    )),
                })),
            },
            key_encryption_algorithm: KeyEncryptionAlgorithmIdentifier::new_aes256_empty(AesMode::Wrap),
            encrypted_key: EncryptedKey::from(vec![
                137, 127, 196, 63, 116, 142, 253, 9, 87, 39, 221, 233, 143, 78, 26, 111, 251, 157, 65, 99, 211, 159,
                179, 116, 208, 73, 199, 61, 137, 105, 12, 126, 250, 69, 230, 190, 17, 158, 13, 107,
            ]),
        })]);

        let parsed: RecipientInfos = picky_asn1_der::from_bytes(&data).unwrap();
        let encoded = picky_asn1_der::to_vec(&parsed).unwrap();

        assert_eq!(expected, parsed);
        assert_eq!(data.as_ref(), &encoded);
    }

    #[test]
    fn kek_identifier() {
        let data = [
            48, 130, 3, 196, 4, 130, 3, 108, 1, 0, 0, 0, 75, 68, 83, 75, 3, 0, 0, 0, 105, 1, 0, 0, 16, 0, 0, 0, 3, 0,
            0, 0, 113, 194, 120, 215, 37, 144, 130, 154, 246, 220, 184, 150, 11, 138, 216, 197, 8, 3, 0, 0, 24, 0, 0,
            0, 24, 0, 0, 0, 68, 72, 80, 66, 0, 1, 0, 0, 135, 168, 230, 29, 180, 182, 102, 60, 255, 187, 209, 156, 101,
            25, 89, 153, 140, 238, 246, 8, 102, 13, 208, 242, 93, 44, 238, 212, 67, 94, 59, 0, 224, 13, 248, 241, 214,
            25, 87, 212, 250, 247, 223, 69, 97, 178, 170, 48, 22, 195, 217, 17, 52, 9, 111, 170, 59, 244, 41, 109, 131,
            14, 154, 124, 32, 158, 12, 100, 151, 81, 122, 189, 90, 138, 157, 48, 107, 207, 103, 237, 145, 249, 230,
            114, 91, 71, 88, 192, 34, 224, 177, 239, 66, 117, 191, 123, 108, 91, 252, 17, 212, 95, 144, 136, 185, 65,
            245, 78, 177, 229, 155, 184, 188, 57, 160, 191, 18, 48, 127, 92, 79, 219, 112, 197, 129, 178, 63, 118, 182,
            58, 202, 225, 202, 166, 183, 144, 45, 82, 82, 103, 53, 72, 138, 14, 241, 60, 109, 154, 81, 191, 164, 171,
            58, 216, 52, 119, 150, 82, 77, 142, 246, 161, 103, 181, 164, 24, 37, 217, 103, 225, 68, 229, 20, 5, 100,
            37, 28, 202, 203, 131, 230, 180, 134, 246, 179, 202, 63, 121, 113, 80, 96, 38, 192, 184, 87, 246, 137, 150,
            40, 86, 222, 212, 1, 10, 189, 11, 230, 33, 195, 163, 150, 10, 84, 231, 16, 195, 117, 242, 99, 117, 215, 1,
            65, 3, 164, 181, 67, 48, 193, 152, 175, 18, 97, 22, 210, 39, 110, 17, 113, 95, 105, 56, 119, 250, 215, 239,
            9, 202, 219, 9, 74, 233, 30, 26, 21, 151, 63, 179, 44, 155, 115, 19, 77, 11, 46, 119, 80, 102, 96, 237,
            189, 72, 76, 167, 177, 143, 33, 239, 32, 84, 7, 244, 121, 58, 26, 11, 161, 37, 16, 219, 193, 80, 119, 190,
            70, 63, 255, 79, 237, 74, 172, 11, 181, 85, 190, 58, 108, 27, 12, 107, 71, 177, 188, 55, 115, 191, 126,
            140, 111, 98, 144, 18, 40, 248, 194, 140, 187, 24, 165, 90, 227, 19, 65, 0, 10, 101, 1, 150, 249, 49, 199,
            122, 87, 242, 221, 244, 99, 229, 233, 236, 20, 75, 119, 125, 230, 42, 170, 184, 168, 98, 138, 195, 118,
            210, 130, 214, 237, 56, 100, 230, 121, 130, 66, 142, 188, 131, 29, 20, 52, 143, 111, 47, 145, 147, 181, 4,
            90, 242, 118, 113, 100, 225, 223, 201, 103, 193, 251, 63, 46, 85, 164, 189, 27, 255, 232, 59, 156, 128,
            208, 82, 185, 133, 209, 130, 234, 10, 219, 42, 59, 115, 19, 211, 254, 20, 200, 72, 75, 30, 5, 37, 136, 185,
            183, 210, 187, 210, 223, 1, 97, 153, 236, 208, 110, 21, 87, 205, 9, 21, 179, 53, 59, 187, 100, 224, 236,
            55, 127, 208, 40, 55, 13, 249, 43, 82, 199, 137, 20, 40, 205, 198, 126, 182, 24, 75, 82, 61, 29, 178, 70,
            195, 47, 99, 7, 132, 144, 240, 14, 248, 214, 71, 209, 72, 212, 121, 84, 81, 94, 35, 39, 207, 239, 152, 197,
            130, 102, 75, 76, 15, 108, 196, 22, 89, 45, 48, 255, 175, 224, 178, 34, 113, 55, 121, 103, 94, 57, 230,
            149, 227, 2, 8, 211, 56, 135, 63, 75, 228, 67, 79, 182, 168, 130, 79, 28, 56, 65, 78, 255, 48, 67, 5, 243,
            1, 170, 131, 242, 24, 216, 174, 93, 89, 249, 12, 215, 25, 248, 12, 146, 191, 38, 9, 239, 136, 197, 113,
            125, 222, 79, 184, 149, 180, 198, 185, 10, 161, 28, 53, 69, 19, 173, 197, 112, 73, 23, 172, 239, 88, 66,
            170, 206, 185, 238, 228, 152, 153, 163, 198, 94, 147, 212, 117, 120, 83, 30, 158, 8, 70, 1, 73, 134, 237,
            77, 162, 147, 56, 224, 231, 179, 30, 110, 19, 55, 253, 176, 115, 101, 171, 146, 59, 227, 37, 145, 200, 156,
            20, 33, 186, 8, 34, 118, 162, 125, 114, 229, 11, 202, 36, 115, 124, 83, 60, 251, 141, 83, 244, 164, 213,
            197, 199, 2, 130, 173, 22, 120, 61, 63, 196, 111, 60, 184, 58, 17, 34, 166, 237, 250, 238, 19, 150, 192,
            123, 172, 162, 70, 227, 90, 165, 58, 139, 124, 87, 199, 135, 30, 146, 142, 203, 133, 133, 54, 26, 54, 229,
            134, 122, 117, 207, 31, 184, 148, 68, 232, 89, 132, 91, 246, 40, 87, 225, 14, 74, 23, 81, 228, 241, 146,
            171, 106, 211, 196, 222, 192, 142, 81, 207, 169, 185, 24, 161, 88, 75, 138, 97, 111, 92, 43, 214, 190, 140,
            12, 124, 177, 67, 125, 237, 147, 195, 41, 40, 100, 0, 111, 0, 109, 0, 97, 0, 105, 0, 110, 0, 46, 0, 116, 0,
            101, 0, 115, 0, 116, 0, 0, 0, 100, 0, 111, 0, 109, 0, 97, 0, 105, 0, 110, 0, 46, 0, 116, 0, 101, 0, 115, 0,
            116, 0, 0, 0, 48, 82, 6, 9, 43, 6, 1, 4, 1, 130, 55, 74, 1, 48, 69, 6, 10, 43, 6, 1, 4, 1, 130, 55, 74, 1,
            1, 48, 55, 48, 53, 48, 51, 12, 3, 83, 73, 68, 12, 44, 83, 45, 49, 45, 53, 45, 50, 49, 45, 51, 51, 51, 55,
            51, 51, 55, 57, 55, 51, 45, 51, 50, 57, 55, 48, 55, 56, 48, 50, 56, 45, 52, 51, 55, 51, 56, 54, 48, 54, 54,
            45, 53, 49, 50,
        ];
        let expected = KekIdentifier {
            key_identifier: OctetStringAsn1::from(vec![
                1, 0, 0, 0, 75, 68, 83, 75, 3, 0, 0, 0, 105, 1, 0, 0, 16, 0, 0, 0, 3, 0, 0, 0, 113, 194, 120, 215, 37,
                144, 130, 154, 246, 220, 184, 150, 11, 138, 216, 197, 8, 3, 0, 0, 24, 0, 0, 0, 24, 0, 0, 0, 68, 72, 80,
                66, 0, 1, 0, 0, 135, 168, 230, 29, 180, 182, 102, 60, 255, 187, 209, 156, 101, 25, 89, 153, 140, 238,
                246, 8, 102, 13, 208, 242, 93, 44, 238, 212, 67, 94, 59, 0, 224, 13, 248, 241, 214, 25, 87, 212, 250,
                247, 223, 69, 97, 178, 170, 48, 22, 195, 217, 17, 52, 9, 111, 170, 59, 244, 41, 109, 131, 14, 154, 124,
                32, 158, 12, 100, 151, 81, 122, 189, 90, 138, 157, 48, 107, 207, 103, 237, 145, 249, 230, 114, 91, 71,
                88, 192, 34, 224, 177, 239, 66, 117, 191, 123, 108, 91, 252, 17, 212, 95, 144, 136, 185, 65, 245, 78,
                177, 229, 155, 184, 188, 57, 160, 191, 18, 48, 127, 92, 79, 219, 112, 197, 129, 178, 63, 118, 182, 58,
                202, 225, 202, 166, 183, 144, 45, 82, 82, 103, 53, 72, 138, 14, 241, 60, 109, 154, 81, 191, 164, 171,
                58, 216, 52, 119, 150, 82, 77, 142, 246, 161, 103, 181, 164, 24, 37, 217, 103, 225, 68, 229, 20, 5,
                100, 37, 28, 202, 203, 131, 230, 180, 134, 246, 179, 202, 63, 121, 113, 80, 96, 38, 192, 184, 87, 246,
                137, 150, 40, 86, 222, 212, 1, 10, 189, 11, 230, 33, 195, 163, 150, 10, 84, 231, 16, 195, 117, 242, 99,
                117, 215, 1, 65, 3, 164, 181, 67, 48, 193, 152, 175, 18, 97, 22, 210, 39, 110, 17, 113, 95, 105, 56,
                119, 250, 215, 239, 9, 202, 219, 9, 74, 233, 30, 26, 21, 151, 63, 179, 44, 155, 115, 19, 77, 11, 46,
                119, 80, 102, 96, 237, 189, 72, 76, 167, 177, 143, 33, 239, 32, 84, 7, 244, 121, 58, 26, 11, 161, 37,
                16, 219, 193, 80, 119, 190, 70, 63, 255, 79, 237, 74, 172, 11, 181, 85, 190, 58, 108, 27, 12, 107, 71,
                177, 188, 55, 115, 191, 126, 140, 111, 98, 144, 18, 40, 248, 194, 140, 187, 24, 165, 90, 227, 19, 65,
                0, 10, 101, 1, 150, 249, 49, 199, 122, 87, 242, 221, 244, 99, 229, 233, 236, 20, 75, 119, 125, 230, 42,
                170, 184, 168, 98, 138, 195, 118, 210, 130, 214, 237, 56, 100, 230, 121, 130, 66, 142, 188, 131, 29,
                20, 52, 143, 111, 47, 145, 147, 181, 4, 90, 242, 118, 113, 100, 225, 223, 201, 103, 193, 251, 63, 46,
                85, 164, 189, 27, 255, 232, 59, 156, 128, 208, 82, 185, 133, 209, 130, 234, 10, 219, 42, 59, 115, 19,
                211, 254, 20, 200, 72, 75, 30, 5, 37, 136, 185, 183, 210, 187, 210, 223, 1, 97, 153, 236, 208, 110, 21,
                87, 205, 9, 21, 179, 53, 59, 187, 100, 224, 236, 55, 127, 208, 40, 55, 13, 249, 43, 82, 199, 137, 20,
                40, 205, 198, 126, 182, 24, 75, 82, 61, 29, 178, 70, 195, 47, 99, 7, 132, 144, 240, 14, 248, 214, 71,
                209, 72, 212, 121, 84, 81, 94, 35, 39, 207, 239, 152, 197, 130, 102, 75, 76, 15, 108, 196, 22, 89, 45,
                48, 255, 175, 224, 178, 34, 113, 55, 121, 103, 94, 57, 230, 149, 227, 2, 8, 211, 56, 135, 63, 75, 228,
                67, 79, 182, 168, 130, 79, 28, 56, 65, 78, 255, 48, 67, 5, 243, 1, 170, 131, 242, 24, 216, 174, 93, 89,
                249, 12, 215, 25, 248, 12, 146, 191, 38, 9, 239, 136, 197, 113, 125, 222, 79, 184, 149, 180, 198, 185,
                10, 161, 28, 53, 69, 19, 173, 197, 112, 73, 23, 172, 239, 88, 66, 170, 206, 185, 238, 228, 152, 153,
                163, 198, 94, 147, 212, 117, 120, 83, 30, 158, 8, 70, 1, 73, 134, 237, 77, 162, 147, 56, 224, 231, 179,
                30, 110, 19, 55, 253, 176, 115, 101, 171, 146, 59, 227, 37, 145, 200, 156, 20, 33, 186, 8, 34, 118,
                162, 125, 114, 229, 11, 202, 36, 115, 124, 83, 60, 251, 141, 83, 244, 164, 213, 197, 199, 2, 130, 173,
                22, 120, 61, 63, 196, 111, 60, 184, 58, 17, 34, 166, 237, 250, 238, 19, 150, 192, 123, 172, 162, 70,
                227, 90, 165, 58, 139, 124, 87, 199, 135, 30, 146, 142, 203, 133, 133, 54, 26, 54, 229, 134, 122, 117,
                207, 31, 184, 148, 68, 232, 89, 132, 91, 246, 40, 87, 225, 14, 74, 23, 81, 228, 241, 146, 171, 106,
                211, 196, 222, 192, 142, 81, 207, 169, 185, 24, 161, 88, 75, 138, 97, 111, 92, 43, 214, 190, 140, 12,
                124, 177, 67, 125, 237, 147, 195, 41, 40, 100, 0, 111, 0, 109, 0, 97, 0, 105, 0, 110, 0, 46, 0, 116, 0,
                101, 0, 115, 0, 116, 0, 0, 0, 100, 0, 111, 0, 109, 0, 97, 0, 105, 0, 110, 0, 46, 0, 116, 0, 101, 0,
                115, 0, 116, 0, 0, 0,
            ]),
            date: Optional::from(None),
            other: Optional::from(Some(OtherKeyAttribute {
                key_attr_id: ObjectIdentifierAsn1::from(oids::protection_descriptor_type()),
                key_attr: Some(Asn1RawDer(
                    picky_asn1_der::to_vec(&GeneralProtectionDescriptor {
                        descriptor_type: ObjectIdentifierAsn1::from(oids::sid_protection_descriptor()),
                        descriptors: Asn1SequenceOf::from(vec![Asn1SequenceOf::from(vec![ProtectionDescriptor {
                            descriptor_type: Utf8StringAsn1::from(Utf8String::from_string("SID".to_owned()).unwrap()),
                            descriptor_value: Utf8StringAsn1::from(
                                Utf8String::from_string("S-1-5-21-3337337973-3297078028-437386066-512".to_owned())
                                    .unwrap(),
                            ),
                        }])]),
                    })
                    .unwrap(),
                )),
            })),
        };

        let parsed: KekIdentifier = picky_asn1_der::from_bytes(&data).unwrap();
        let encoded = picky_asn1_der::to_vec(&parsed).unwrap();

        assert_eq!(expected, parsed);
        assert_eq!(data.as_ref(), &encoded);
    }
}
