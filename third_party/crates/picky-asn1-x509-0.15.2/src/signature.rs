use picky_asn1::wrapper::IntegerAsn1;
use serde::{Deserialize, Serialize};

/// Defined in [RFC 3279](https://tools.ietf.org/html/rfc3279#section-2.2.3)
///
/// ```not_rust
/// Ecdsa-Sig-Value ::= SEQUENCE {
///     r INTEGER,
///     s INTEGER
/// }
/// ```
#[derive(Serialize, Deserialize, Debug, PartialEq, Eq, Clone)]
pub struct EcdsaSignatureValue {
    pub r: IntegerAsn1,
    pub s: IntegerAsn1,
}
