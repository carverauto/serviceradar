use crate::oids;
use crate::pkcs12::SafeContentsContentInfo;
use core::fmt;
use oid::ObjectIdentifier;
use picky_asn1::wrapper::{ExplicitContextTag0, ObjectIdentifierAsn1, OctetStringAsn1, OctetStringAsn1Container};
use picky_asn1_der::Asn1RawDer;
use serde::{Deserialize, Serialize, de, ser};

/// Top-level `ContentInfo` type used in context of `AuthenticatedSafe` for PKCS#12 `PFX` structure.
/// Defined in [PKCS #12](https://datatracker.ietf.org/doc/html/rfc7292#section-3.4)
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum AuthenticatedSafeContentInfo<R: AuthenticatedSafeDataRepr = ParsedAuthenticatedSafeDataRepr> {
    Data(R::Repr),
    /// Unknown `ContentInfo` type used in context of `AuthenticatedSafe`.
    /// Most likely `SignedData` is used, which is not currently supported by picky.
    Unknown {
        content_type: ObjectIdentifier,
        content: Option<Asn1RawDer>,
    },
}

/// Raw representation of `AuthenticatedSafe` data
pub type RawAuthenticatedSafeContentInfo = AuthenticatedSafeContentInfo<RawAuthenticatedSafeDataRepr>;

impl<R: AuthenticatedSafeDataRepr> ser::Serialize for AuthenticatedSafeContentInfo<R> {
    fn serialize<S>(&self, serializer: S) -> Result<S::Ok, S::Error>
    where
        S: ser::Serializer,
    {
        use ser::SerializeSeq;

        match self {
            AuthenticatedSafeContentInfo::Data(safe_contents) => {
                let mut seq = serializer.serialize_seq(Some(2))?;
                let oid: ObjectIdentifierAsn1 = oids::content_info_type_data().into();
                seq.serialize_element(&oid)?;
                let content: ExplicitContextTag0<OctetStringAsn1Container<R>> =
                    OctetStringAsn1Container(R::from_repr(safe_contents.clone())).into();
                seq.serialize_element(&content)?;
                seq.end()
            }
            AuthenticatedSafeContentInfo::Unknown { content_type, content } => {
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

impl<'de, R: AuthenticatedSafeDataRepr> de::Deserialize<'de> for AuthenticatedSafeContentInfo<R> {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: de::Deserializer<'de>,
    {
        struct AuthenticatedSafeContentInfoVisitor<R>(core::marker::PhantomData<R>);

        impl<'de, R: AuthenticatedSafeDataRepr> de::Visitor<'de> for AuthenticatedSafeContentInfoVisitor<R> {
            type Value = AuthenticatedSafeContentInfo<R>;

            fn expecting(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
                formatter.write_str("a valid DER-encoded AuthenticatedSafeContentInfo")
            }

            fn visit_seq<A>(self, mut seq: A) -> Result<Self::Value, A::Error>
            where
                A: de::SeqAccess<'de>,
            {
                let content_type: ObjectIdentifierAsn1 = seq_next_element!(
                    seq,
                    AuthenticatedSafeContentInfo,
                    "ContentInfo<AuthenticatedSafe> content type"
                );
                let oid_str: String = content_type.0.clone().into();

                match oid_str.as_str() {
                    oids::CONTENT_INFO_TYPE_DATA => {
                        let content: ExplicitContextTag0<OctetStringAsn1Container<R>> =
                            seq_next_element!(seq, OctetStringAsn1, "ContentInfo<AuthenticatedSafe> content");
                        Ok(AuthenticatedSafeContentInfo::Data(content.0.0.into_repr()))
                    }
                    _ => {
                        let content: Option<ExplicitContextTag0<Asn1RawDer>> = seq.next_element()?;
                        Ok(AuthenticatedSafeContentInfo::Unknown {
                            content_type: content_type.0,
                            content: content.map(|c| c.0),
                        })
                    }
                }
            }
        }

        deserializer.deserialize_seq(AuthenticatedSafeContentInfoVisitor::<R>(core::marker::PhantomData))
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ParsedAuthenticatedSafeDataRepr(Vec<SafeContentsContentInfo>);

impl ser::Serialize for ParsedAuthenticatedSafeDataRepr {
    fn serialize<S>(&self, serializer: S) -> Result<S::Ok, S::Error>
    where
        S: ser::Serializer,
    {
        use ser::SerializeSeq;

        let mut seq = serializer.serialize_seq(Some(self.0.len()))?;
        for safe_content in &self.0 {
            seq.serialize_element(safe_content)?;
        }
        seq.end()
    }
}

impl<'de> de::Deserialize<'de> for ParsedAuthenticatedSafeDataRepr {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: de::Deserializer<'de>,
    {
        struct AuthSafeDataVisitor;

        impl<'de> de::Visitor<'de> for AuthSafeDataVisitor {
            type Value = ParsedAuthenticatedSafeDataRepr;

            fn expecting(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
                formatter.write_str("a valid DER-encoded AuthSafeData")
            }

            fn visit_seq<A>(self, mut seq: A) -> Result<Self::Value, A::Error>
            where
                A: de::SeqAccess<'de>,
            {
                let mut elements = vec![];
                while let Some(element) = seq.next_element()? {
                    elements.push(element);
                }
                Ok(ParsedAuthenticatedSafeDataRepr(elements))
            }
        }

        deserializer.deserialize_seq(AuthSafeDataVisitor)
    }
}

pub trait AuthenticatedSafeDataRepr: Serialize + for<'de> Deserialize<'de> {
    type Repr: core::fmt::Debug + Clone + Eq + PartialEq;

    fn into_repr(self) -> Self::Repr;
    fn from_repr(repr: Self::Repr) -> Self;
}

impl AuthenticatedSafeDataRepr for ParsedAuthenticatedSafeDataRepr {
    type Repr = Vec<SafeContentsContentInfo>;

    fn into_repr(self) -> Self::Repr {
        self.0
    }

    fn from_repr(repr: Self::Repr) -> Self {
        Self(repr)
    }
}

/// A raw representation of the `AuthenticatedSafe` ASN.1 structure. Invernal `Asn1RawDer` data
/// could be serialized and deserialized from/into [`ParsedAuthenticatedSafeDataRepr`]
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(transparent)]
pub struct RawAuthenticatedSafeDataRepr(Asn1RawDer);

impl AuthenticatedSafeDataRepr for RawAuthenticatedSafeDataRepr {
    type Repr = Asn1RawDer;

    fn into_repr(self) -> Self::Repr {
        self.0
    }

    fn from_repr(repr: Self::Repr) -> Self {
        Self(repr)
    }
}
