use crate::oids;
use core::fmt;
use oid::ObjectIdentifier;
use picky_asn1::wrapper::{ExplicitContextTag0, ObjectIdentifierAsn1, OctetStringAsn1};
use picky_asn1_der::Asn1RawDer;
use serde::{de, ser};

/// [PKCS #12: Personal Information Exchange Syntax Standard Version](https://tools.ietf.org/html/rfc7292#section-4.2.3)
///
/// ```not_rust
/// CertBag ::= SEQUENCE {
///     certId      BAG-TYPE.&id   ({CertTypes}),
///     certValue   [0] EXPLICIT BAG-TYPE.&Type ({CertTypes}{@certId})
/// }
/// ...
/// x509Certificate BAG-TYPE ::=
///     {OCTET STRING IDENTIFIED BY {certTypes 1}}
///     -- DER-encoded X.509 certificate stored in OCTET STRING
/// ...
/// CertTypes BAG-TYPE ::= {
///     x509Certificate |
///     sdsiCertificate,
///     ... -- For future extensions
/// }
/// ```
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum CertificateBag {
    /// Encapsulated `Certificate` ASN.1 structure inside `OctetString` container
    X509(OctetStringAsn1),

    // SDSI(IA5String) -- Not supported
    /// Other certificate types are allowed by PKCS #12 standard. For example, PFX also could
    /// contain SDSI certificates.
    Unknown {
        type_id: ObjectIdentifier,
        value: Asn1RawDer,
    },
}

impl ser::Serialize for CertificateBag {
    fn serialize<S>(&self, serializer: S) -> Result<S::Ok, S::Error>
    where
        S: ser::Serializer,
    {
        use ser::SerializeSeq;

        let mut seq = serializer.serialize_seq(Some(2))?;
        match self {
            CertificateBag::X509(data) => {
                let type_id: ObjectIdentifierAsn1 = crate::oids::cert_safe_bag_type_x509().into();
                seq.serialize_element(&type_id)?;
                let tagged_value = ExplicitContextTag0(data.clone());
                seq.serialize_element(&tagged_value)?;
            }
            CertificateBag::Unknown { type_id, value } => {
                let type_id: ObjectIdentifierAsn1 = type_id.clone().into();
                seq.serialize_element(&type_id)?;
                let tagged_value = ExplicitContextTag0(value.clone());
                seq.serialize_element(&tagged_value)?;
            }
        }
        seq.end()
    }
}

impl<'de> de::Deserialize<'de> for CertificateBag {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: de::Deserializer<'de>,
    {
        struct CertificateBagVisitor;

        impl<'de> de::Visitor<'de> for CertificateBagVisitor {
            type Value = CertificateBag;

            fn expecting(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
                formatter.write_str("a valid DER-encoded CertificateBag")
            }

            fn visit_seq<A>(self, mut seq: A) -> Result<Self::Value, A::Error>
            where
                A: de::SeqAccess<'de>,
            {
                let oid: ObjectIdentifierAsn1 = seq_next_element!(seq, CertificateBag, "Cert bag type id");

                if oid.0 == oids::cert_safe_bag_type_x509() {
                    let value: ExplicitContextTag0<OctetStringAsn1> =
                        seq_next_element!(seq, CertificateBag, "X509 Cert bag value");

                    Ok(CertificateBag::X509(value.0))
                } else {
                    let value: ExplicitContextTag0<Asn1RawDer> =
                        seq_next_element!(seq, CertificateBag, "Cert bag value");

                    Ok(CertificateBag::Unknown {
                        type_id: oid.0,
                        value: value.0,
                    })
                }
            }
        }

        deserializer.deserialize_seq(CertificateBagVisitor)
    }
}
