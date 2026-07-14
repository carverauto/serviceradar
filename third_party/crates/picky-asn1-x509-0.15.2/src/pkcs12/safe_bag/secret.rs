use core::fmt;
use oid::ObjectIdentifier;
use picky_asn1::wrapper::{ExplicitContextTag0, ObjectIdentifierAsn1};
use picky_asn1_der::Asn1RawDer;
use serde::{de, ser};

/// [PKCS #12: Personal Information Exchange Syntax Standard Version](https://tools.ietf.org/html/rfc7292#section-4.2.5)
///
/// ```not_rust
/// SecretBag ::= SEQUENCE {
///     secretTypeId   BAG-TYPE.&id ({SecretTypes}),
///     secretValue    [0] EXPLICIT BAG-TYPE.&Type ({SecretTypes}{@secretTypeId})
/// }
/// ```
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SecretBag {
    /// Custom OID for user-defined `SecretBag` type
    pub type_id: ObjectIdentifier,
    /// Encapsulated `SecretBag` value
    pub value: Asn1RawDer,
}

impl ser::Serialize for SecretBag {
    fn serialize<S>(&self, serializer: S) -> Result<S::Ok, S::Error>
    where
        S: ser::Serializer,
    {
        use ser::SerializeSeq;

        let mut seq = serializer.serialize_seq(Some(2))?;
        let type_id: ObjectIdentifierAsn1 = self.type_id.clone().into();
        seq.serialize_element(&type_id)?;
        let tagged_value = ExplicitContextTag0(self.value.clone());
        seq.serialize_element(&tagged_value)?;
        seq.end()
    }
}

impl<'de> de::Deserialize<'de> for SecretBag {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: de::Deserializer<'de>,
    {
        struct SecretBagVisitor;

        impl<'de> de::Visitor<'de> for SecretBagVisitor {
            type Value = SecretBag;

            fn expecting(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
                formatter.write_str("a valid DER-encoded SecretBag")
            }

            fn visit_seq<A>(self, mut seq: A) -> Result<Self::Value, A::Error>
            where
                A: de::SeqAccess<'de>,
            {
                let oid: ObjectIdentifierAsn1 = seq_next_element!(seq, SecretBag, "secret bag type id");

                let value: ExplicitContextTag0<Asn1RawDer> = seq_next_element!(seq, SecretBag, "secret bag value");

                Ok(SecretBag {
                    type_id: oid.0,
                    value: value.0,
                })
            }
        }

        deserializer.deserialize_seq(SecretBagVisitor)
    }
}
