use crate::oids;
use core::fmt;
use oid::ObjectIdentifier;
use picky_asn1::restricted_string::BmpString;
use picky_asn1::wrapper::{Asn1SetOf, BmpStringAsn1, ObjectIdentifierAsn1, OctetStringAsn1};
use picky_asn1_der::Asn1RawDer;
use serde::{de, ser};

/// [PKCS #12: Personal Information Exchange Syntax Standard Version](https://tools.ietf.org/html/rfc7292#section-4.2)
///
/// ```not_rust
///  PKCS12Attribute ::= SEQUENCE {
///      attrId      ATTRIBUTE.&id ({PKCS12AttrSet}),
///      attrValues  SET OF ATTRIBUTE.&Type ({PKCS12AttrSet}{@attrId})
///  } -- This type is compatible with the X.500 type 'Attribute'
///
///  PKCS12AttrSet ATTRIBUTE ::= {
///      friendlyName | -- from PKCS #9 [23]
///      localKeyId,    -- from PKCS #9
///      ... -- Other attributes are allowed
///  }
/// ```
///
/// [PKCS #9: Selected Object Classes and Attribute Types Version 2.0](https://tools.ietf.org/html/rfc2985#section-5)
///
/// ```not_rust
///
/// friendlyName ATTRIBUTE ::= {
///     WITH SYNTAX BMPString (SIZE(1..pkcs-9-ub-friendlyName))
///     EQUALITY MATCHING RULE caseIgnoreMatch
///     SINGLE VALUE TRUE
///     ID pkcs-9-at-friendlyName
/// }
///
/// localKeyId ATTRIBUTE ::= {
///     WITH SYNTAX OCTET STRING
///     EQUALITY MATCHING RULE octetStringMatch
///     SINGLE VALUE TRUE
///     ID pkcs-9-at-localKeyId
/// }
/// ```
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Pkcs12Attribute {
    /// Note that [`BMPString`] contains UCS-2 encoded string, internal bytes should be manually
    /// converted to/from UTF-8 if needed.
    FriendlyName(BmpString),
    LocalKeyId(OctetStringAsn1),
    Unknown {
        oid: ObjectIdentifier,
        value: Vec<Asn1RawDer>,
    },
}

impl ser::Serialize for Pkcs12Attribute {
    fn serialize<S>(&self, serializer: S) -> Result<S::Ok, S::Error>
    where
        S: ser::Serializer,
    {
        use ser::SerializeSeq;

        let mut seq = serializer.serialize_seq(Some(2))?;

        match self {
            Pkcs12Attribute::FriendlyName(name) => {
                let oid: ObjectIdentifierAsn1 = oids::attribute_pkcs12_friendly_name().into();
                seq.serialize_element(&oid)?;
                let asn1_set = Asn1SetOf(vec![BmpStringAsn1(name.clone())]);
                seq.serialize_element(&asn1_set)?;
            }
            Pkcs12Attribute::LocalKeyId(id) => {
                let oid: ObjectIdentifierAsn1 = oids::attribute_pkcs12_local_key_id().into();
                seq.serialize_element(&oid)?;
                let asn1_set = Asn1SetOf(vec![id.clone()]);
                seq.serialize_element(&asn1_set)?;
            }
            Pkcs12Attribute::Unknown { oid, value } => {
                let oid: ObjectIdentifierAsn1 = oid.clone().into();
                seq.serialize_element(&oid)?;
                let asn1_set = Asn1SetOf(value.clone());
                seq.serialize_element(&asn1_set)?;
            }
        };

        seq.end()
    }
}

impl<'de> de::Deserialize<'de> for Pkcs12Attribute {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: de::Deserializer<'de>,
    {
        struct Pkcs12AttributeVisitor;

        impl<'de> de::Visitor<'de> for Pkcs12AttributeVisitor {
            type Value = Pkcs12Attribute;

            fn expecting(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
                formatter.write_str("a valid DER-encoded Pkcs12Attribute")
            }

            fn visit_seq<A>(self, mut seq: A) -> Result<Self::Value, A::Error>
            where
                A: de::SeqAccess<'de>,
            {
                let oid: ObjectIdentifierAsn1 = seq_next_element!(seq, Pkcs12Attribute, "attribute oid");

                let oid_str: String = oid.0.clone().into();

                let attribute = match oid_str.as_str() {
                    oids::ATTRIBUTE_PKCS12_FRIENDLY_NAME => {
                        let name: Asn1SetOf<BmpStringAsn1> =
                            seq_next_element!(seq, Pkcs12Attribute, "friendly name attribute value");
                        if name.0.len() != 1 {
                            return Err(serde_invalid_value!(
                                Pkcs12Attribute,
                                "Invalid friendly elevent attribute values count",
                                "single friendly name attribute value"
                            ));
                        }

                        let name = name
                            .0
                            .into_iter()
                            .next()
                            .expect("BUG: Should be validated in code block above");

                        Pkcs12Attribute::FriendlyName(name.0)
                    }
                    oids::ATTRIBUTE_PKCS12_LOCAL_KEY_ID => {
                        let id: Asn1SetOf<OctetStringAsn1> =
                            seq_next_element!(seq, Pkcs12Attribute, "local key id attribute value");
                        if id.0.len() != 1 {
                            return Err(serde_invalid_value!(
                                Pkcs12Attribute,
                                "Invalid local key id attribute values count",
                                "single local key id attribute value"
                            ));
                        }

                        let id =
                            id.0.into_iter()
                                .next()
                                .expect("BUG: Should be validated in code block above");

                        Pkcs12Attribute::LocalKeyId(id)
                    }
                    _ => {
                        let value: Asn1SetOf<Asn1RawDer> =
                            seq_next_element!(seq, Pkcs12Attribute, "unknown attribute value");

                        Pkcs12Attribute::Unknown {
                            oid: oid.0,
                            value: value.0,
                        }
                    }
                };

                Ok(attribute)
            }
        }

        deserializer.deserialize_seq(Pkcs12AttributeVisitor)
    }
}

#[cfg(test)]
pub(crate) mod test_data {
    pub const ATTRIBUTE_LOCAL_KEY_ID: &[u8] = &[
        0x30, 0x13, 0x06, 0x09, 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x09, 0x15, 0x31, 0x06, 0x04, 0x04, 0x01,
        0x00, 0x00, 0x00,
    ];

    pub const ATTRIBUTE_FRIENDLY_NAME: &[u8] = &[
        0x30, 0x5B, 0x06, 0x09, 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x09, 0x14, 0x31, 0x4E, 0x1E, 0x4C, 0x00,
        0x7B, 0x00, 0x31, 0x00, 0x43, 0x00, 0x41, 0x00, 0x32, 0x00, 0x41, 0x00, 0x46, 0x00, 0x36, 0x00, 0x36, 0x00,
        0x2D, 0x00, 0x34, 0x00, 0x43, 0x00, 0x42, 0x00, 0x35, 0x00, 0x2D, 0x00, 0x34, 0x00, 0x34, 0x00, 0x33, 0x00,
        0x45, 0x00, 0x2D, 0x00, 0x42, 0x00, 0x39, 0x00, 0x31, 0x00, 0x45, 0x00, 0x2D, 0x00, 0x41, 0x00, 0x37, 0x00,
        0x34, 0x00, 0x30, 0x00, 0x32, 0x00, 0x37, 0x00, 0x44, 0x00, 0x35, 0x00, 0x43, 0x00, 0x45, 0x00, 0x43, 0x00,
        0x37, 0x00, 0x7D,
    ];

    pub const ATTRIBUTE_MS_KEY_PROVIDER_NAME: &[u8] = &[
        0x30, 0x5D, 0x06, 0x09, 0x2B, 0x06, 0x01, 0x04, 0x01, 0x82, 0x37, 0x11, 0x01, 0x31, 0x50, 0x1E, 0x4E, 0x00,
        0x4D, 0x00, 0x69, 0x00, 0x63, 0x00, 0x72, 0x00, 0x6F, 0x00, 0x73, 0x00, 0x6F, 0x00, 0x66, 0x00, 0x74, 0x00,
        0x20, 0x00, 0x53, 0x00, 0x6F, 0x00, 0x66, 0x00, 0x74, 0x00, 0x77, 0x00, 0x61, 0x00, 0x72, 0x00, 0x65, 0x00,
        0x20, 0x00, 0x4B, 0x00, 0x65, 0x00, 0x79, 0x00, 0x20, 0x00, 0x53, 0x00, 0x74, 0x00, 0x6F, 0x00, 0x72, 0x00,
        0x61, 0x00, 0x67, 0x00, 0x65, 0x00, 0x20, 0x00, 0x50, 0x00, 0x72, 0x00, 0x6F, 0x00, 0x76, 0x00, 0x69, 0x00,
        0x64, 0x00, 0x65, 0x00, 0x72,
    ];
}

#[cfg(test)]
mod tests {
    use super::test_data::*;
    use super::*;

    use base64::Engine as _;
    use base64::engine::general_purpose;

    // "Close enough" UTF8 -> UCS2 conversion for testing purposes (works only with ASCII)
    fn utf8_to_ucs2(s: &str) -> Vec<u8> {
        let acc = Vec::with_capacity(s.len() * 2);
        s.as_bytes().iter().copied().fold(acc, |mut acc, c| {
            acc.extend_from_slice(&[0, c]);
            acc
        })
    }

    #[test]
    fn attribute_local_key_id_roundtrip() {
        let decoded: Pkcs12Attribute = picky_asn1_der::from_bytes(ATTRIBUTE_LOCAL_KEY_ID).unwrap();
        let expected = Pkcs12Attribute::LocalKeyId(vec![0x01, 0x00, 0x00, 0x00].into());
        pretty_assertions::assert_eq!(decoded, expected);
        check_serde!(decoded: Pkcs12Attribute in ATTRIBUTE_LOCAL_KEY_ID);
    }

    #[test]
    fn attribute_local_friendly_name_roundtrip() {
        let decoded: Pkcs12Attribute = picky_asn1_der::from_bytes(ATTRIBUTE_FRIENDLY_NAME).unwrap();
        let bmp_string_data = utf8_to_ucs2("{1CA2AF66-4CB5-443E-B91E-A74027D5CEC7}");
        let expected = Pkcs12Attribute::FriendlyName(BmpString::new(bmp_string_data).unwrap());
        pretty_assertions::assert_eq!(decoded, expected);
        check_serde!(decoded: Pkcs12Attribute in ATTRIBUTE_FRIENDLY_NAME);
    }

    #[test]
    fn attribute_ms_key_provider_name_roundtrip() {
        // Test that any unknown or custom attributes could be parsed and serialized back in exactly
        // the same way as they were received.
        let decoded: Pkcs12Attribute = picky_asn1_der::from_bytes(ATTRIBUTE_MS_KEY_PROVIDER_NAME).unwrap();
        // Manual comparison with `pretty_assertions` give less ugly results here than `expect_test`
        let bmp_string_data = utf8_to_ucs2("Microsoft Software Key Storage Provider");
        let bmp_string: BmpStringAsn1 = BmpString::new(bmp_string_data).unwrap().into();
        let expected = Pkcs12Attribute::Unknown {
            oid: ObjectIdentifier::try_from("1.3.6.1.4.1.311.17.1").unwrap(),
            value: vec![Asn1RawDer(picky_asn1_der::to_vec(&bmp_string).unwrap())],
        };
        pretty_assertions::assert_eq!(decoded, expected);
        check_serde!(decoded: Pkcs12Attribute in ATTRIBUTE_MS_KEY_PROVIDER_NAME);
    }
}
