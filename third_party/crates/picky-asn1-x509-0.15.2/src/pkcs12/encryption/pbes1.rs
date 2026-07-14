use crate::oids;
use oid::ObjectIdentifier;
use picky_asn1::wrapper::OctetStringAsn1;
use serde::{Deserialize, Serialize};

/// Pkcs12Pbe is deprecated and should not be used, but we still need to support at least
/// basic cases (like `pkcs12_pbe_with_sha_and_40_bit_rc4` and
/// `pkcs12_pbe_with_sha_and_3_key_triple_des_cbc`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Pbes1AlgorithmKind {
    ShaAnd40BitRc2Cbc,
    ShaAnd3Key3DesCbc,
}

impl From<Pbes1AlgorithmKind> for ObjectIdentifier {
    fn from(value: Pbes1AlgorithmKind) -> Self {
        match value {
            Pbes1AlgorithmKind::ShaAnd40BitRc2Cbc => oids::pkcs12_pbe_with_sha_and_40_bit_rc2_cbc(),
            Pbes1AlgorithmKind::ShaAnd3Key3DesCbc => oids::pkcs12_pbe_with_sha_and_3_key_triple_des_cbc(),
        }
    }
}

/// [PKCS #12: Personal Information Exchange Syntax Standard Version](https://tools.ietf.org/html/rfc7292#appendix-C)
/// # Appendix C. Keys and IVs for Password Privacy Mode
/// ```not_rust
/// pkcs-12PbeParams ::= SEQUENCE {
///     salt        OCTET STRING,
///     iterations  INTEGER
/// }
/// ```
#[derive(Serialize, Deserialize, Debug, Clone, PartialEq, Eq)]
pub struct Pbes1Params {
    pub salt: OctetStringAsn1,
    pub iterations: u32,
}
