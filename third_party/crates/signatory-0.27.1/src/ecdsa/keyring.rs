//! ECDSA keyring.

use crate::{Algorithm, Error, KeyHandle, LoadPkcs8, Result};

#[cfg(feature = "nistp256")]
use super::nistp256;

#[cfg(feature = "secp256k1")]
use super::secp256k1;

/// ECDSA keyring.
#[derive(Debug, Default)]
pub struct KeyRing {
    /// ECDSA/P-256 keys.
    #[cfg(feature = "nistp256")]
    pub nistp256: nistp256::KeyRing,

    /// ECDSA/secp256k1 keys.
    #[cfg(feature = "secp256k1")]
    pub secp256k1: secp256k1::KeyRing,
}

impl LoadPkcs8 for KeyRing {
    fn load_pkcs8(&mut self, private_key: pkcs8::PrivateKeyInfo<'_>) -> Result<KeyHandle> {
        match Algorithm::try_from(private_key.algorithm)? {
            #[cfg(feature = "nistp256")]
            Algorithm::EcdsaNistP256 => self.nistp256.load_pkcs8(private_key),
            #[cfg(feature = "secp256k1")]
            Algorithm::EcdsaSecp256k1 => self.secp256k1.load_pkcs8(private_key),
            #[allow(unreachable_patterns)]
            _ => Err(Error::AlgorithmInvalid),
        }
    }
}
