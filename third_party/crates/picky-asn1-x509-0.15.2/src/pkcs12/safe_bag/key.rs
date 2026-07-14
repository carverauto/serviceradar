use crate::pkcs12::Pkcs12EncryptionAlgorithm;
use picky_asn1::wrapper::OctetStringAsn1;
use picky_asn1_der::Asn1RawDer;
use serde::{Deserialize, Serialize};

/// PKCS12 SafeBag with `PrivateKeyInfo` ASN.1 structure encapsualted inside
pub type KeyBag = Asn1RawDer;

/// [PKCS #12: Personal Information Exchange Syntax Standard Version](https://tools.ietf.org/html/rfc7292#section-4.2.2)
///
/// PKCS8ShroudedKeyBag ::= EncryptedPrivateKeyInfo
///
/// [PKCS #8: Private-Key Information Syntax Standard](https://tools.ietf.org/html/rfc5208#section-6)
/// ```not_rust
/// EncryptedPrivateKeyInfo ::= SEQUENCE {
///     encryptionAlgorithm  EncryptionAlgorithmIdentifier,
///     encryptedData        EncryptedData }
///
///   EncryptionAlgorithmIdentifier ::= AlgorithmIdentifier
///
///   EncryptedData ::= OCTET STRING
/// ```
#[derive(Serialize, Deserialize, Debug, Clone, PartialEq, Eq)]
pub struct EncryptedKeyBag {
    pub algorithm: Pkcs12EncryptionAlgorithm,
    /// After decryption this will contain `PrivateKeyInfo` ASN.1 structure
    pub encrypted_data: OctetStringAsn1,
}
