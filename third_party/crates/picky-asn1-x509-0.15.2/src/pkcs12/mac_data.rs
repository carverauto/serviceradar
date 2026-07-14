use crate::pkcs12::Pkcs12DigestInfo;
use core::fmt;
use picky_asn1::wrapper::OctetStringAsn1;
use serde::{de, ser};

/// [PKCS #12: Personal Information Exchange Syntax Standard Version](https://tools.ietf.org/html/rfc7292#appendix-C)
/// ```not_rust
/// MacData ::= SEQUENCE {
///     mac         DigestInfo,
///     macSalt     OCTET STRING,
///     iterations  INTEGER DEFAULT 1
///     -- Note: The default is for historical reasons and its
///     --       use is deprecated.
/// }
/// ```
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MacData {
    pub mac: Pkcs12DigestInfo,
    pub salt: OctetStringAsn1,
    pub iterations: Option<u32>,
}

impl ser::Serialize for MacData {
    fn serialize<S>(&self, serializer: S) -> Result<S::Ok, S::Error>
    where
        S: ser::Serializer,
    {
        use ser::SerializeSeq;

        let sequence_len = 2 + usize::from(self.iterations.is_some());
        let mut seq = serializer.serialize_seq(Some(sequence_len))?;
        seq.serialize_element(&self.mac)?;
        seq.serialize_element(&self.salt)?;
        if let Some(iterations) = self.iterations {
            seq.serialize_element(&iterations)?;
        }
        seq.end()
    }
}

impl<'de> de::Deserialize<'de> for MacData {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: de::Deserializer<'de>,
    {
        struct MacDataVisitor;

        impl<'de> de::Visitor<'de> for MacDataVisitor {
            type Value = MacData;

            fn expecting(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
                formatter.write_str("a valid DER-encoded Pkcs12DigestInfo")
            }

            fn visit_seq<A>(self, mut seq: A) -> Result<Self::Value, A::Error>
            where
                A: de::SeqAccess<'de>,
            {
                let mac: Pkcs12DigestInfo = seq_next_element!(seq, MacData, "MacData digest info");

                let salt: OctetStringAsn1 = seq_next_element!(seq, MacData, "MacData salt");

                let iterations: Option<u32> = seq.next_element()?;

                Ok(MacData { mac, salt, iterations })
            }
        }

        deserializer.deserialize_seq(MacDataVisitor)
    }
}

#[cfg(test)]
pub(crate) mod test_data {
    use crate::pkcs12::digest::test_data::*;

    pub fn build_expected_mac_data_data() -> Vec<u8> {
        // SEQUENCE header
        let mut value = vec![0x30, 0x41];
        value.extend_from_slice(PKCS12_DIGEST_INFO);
        // OCTET STRING (8 bytes)
        value.extend_from_slice(&[0x04, 0x08, 0x36, 0xE7, 0x17, 0x5C, 0x70, 0x59, 0x08, 0x42]);
        // INTEGER (2048)
        value.extend_from_slice(&[0x02, 0x02, 0x08, 0x00]);
        value
    }
}

#[cfg(test)]
mod tests {
    use super::test_data::*;
    use super::*;

    use base64::Engine as _;
    use base64::engine::general_purpose;
    use expect_test::expect;

    #[test]
    fn mac_data_roundtrip() {
        let encoded = build_expected_mac_data_data();
        let decoded: MacData = picky_asn1_der::from_bytes(&encoded).unwrap();
        expect![[r#"
            MacData {
                mac: Pkcs12DigestInfo {
                    digest_algorithm: Sha256,
                    digest: OctetString(0x82CAC9D63BA44781EBAB3BBF7272347B1B0C10803895B2430772D572EB016364),
                },
                salt: OctetString(0x36E7175C70590842),
                iterations: Some(
                    2048,
                ),
            }
        "#]]
        .assert_debug_eq(&decoded);
        check_serde!(decoded: MacData in encoded);
    }
}
