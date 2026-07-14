//! Handle to a particular key.

#[cfg(feature = "ecdsa")]
#[allow(unused_imports)]
use crate::ecdsa;

#[cfg(feature = "ed25519")]
use crate::ed25519;

/// Handle to a particular key.
///
/// Uniquely identifies a particular key in the keyring.
#[derive(Copy, Clone, Debug, Eq, PartialEq, PartialOrd, Ord)]
#[non_exhaustive]
pub enum KeyHandle {
    /// ECDSA/P-256.
    #[cfg(feature = "nistp256")]
    EcdsaNistP256(ecdsa::nistp256::VerifyingKey),

    /// ECDSA/P-384.
    #[cfg(feature = "nistp384")]
    EcdsaNistP384(ecdsa::nistp384::VerifyingKey),

    /// ECDSA/secp256k1.
    #[cfg(feature = "secp256k1")]
    EcdsaSecp256k1(ecdsa::secp256k1::VerifyingKey),

    /// Ed25519.
    #[cfg(feature = "ed25519")]
    Ed25519(ed25519::VerifyingKey),
}

impl KeyHandle {
    /// Get ECDSA/P-256 verifying key, if this is an ECDSA/P-256 key.
    #[cfg(feature = "nistp256")]
    pub fn ecdsa_nistp256(&self) -> Option<ecdsa::nistp256::VerifyingKey> {
        match self {
            KeyHandle::EcdsaNistP256(pk) => Some(*pk),
            #[allow(unreachable_patterns)]
            _ => None,
        }
    }

    /// Get ECDSA/P-384 verifying key, if this is an ECDSA/P-384 key.
    #[cfg(feature = "nistp384")]
    pub fn ecdsa_nistp384(&self) -> Option<ecdsa::nistp384::VerifyingKey> {
        match self {
            KeyHandle::EcdsaNistP384(pk) => Some(*pk),
            #[allow(unreachable_patterns)]
            _ => None,
        }
    }

    /// Get ECDSA/secp256k1 verifying key, if this is an ECDSA/secp256k1 key.
    #[cfg(feature = "secp256k1")]
    pub fn ecdsa_secp256k1(&self) -> Option<ecdsa::secp256k1::VerifyingKey> {
        match self {
            KeyHandle::EcdsaSecp256k1(pk) => Some(*pk),
            #[allow(unreachable_patterns)]
            _ => None,
        }
    }

    /// Get Ed25519 verifying key, if this is an Ed25519 key.
    #[cfg(feature = "ed25519")]
    pub fn ed25519(&self) -> Option<ed25519::VerifyingKey> {
        match self {
            KeyHandle::Ed25519(pk) => Some(*pk),
            #[allow(unreachable_patterns)]
            _ => None,
        }
    }
}
