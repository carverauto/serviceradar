//! Signature key ring.

use crate::{Algorithm, Error, KeyHandle, Result};

#[cfg(feature = "ecdsa")]
use crate::ecdsa;

#[cfg(feature = "ed25519")]
use crate::ed25519;

/// Signature key ring which can contain signing keys for all supported algorithms.
#[derive(Debug, Default)]
pub struct KeyRing {
    /// ECDSA key ring.
    #[cfg(feature = "ecdsa")]
    pub ecdsa: ecdsa::KeyRing,

    /// Ed25519 key ring.
    #[cfg(feature = "ed25519")]
    pub ed25519: ed25519::KeyRing,
}

impl KeyRing {
    /// Create a new keyring.
    pub fn new() -> Self {
        Self::default()
    }
}

/// Support for loading PKCS#8 private keys.
pub trait LoadPkcs8 {
    /// Load a PKCS#8 key into the key ring.
    fn load_pkcs8(&mut self, private_key: pkcs8::PrivateKeyInfo<'_>) -> Result<KeyHandle>;
}

impl LoadPkcs8 for KeyRing {
    fn load_pkcs8(&mut self, private_key: pkcs8::PrivateKeyInfo<'_>) -> Result<KeyHandle> {
        #[allow(unused_variables)]
        let algorithm = Algorithm::try_from(private_key.algorithm)?;

        #[cfg(feature = "ecdsa")]
        if algorithm.is_ecdsa() {
            return self.ecdsa.load_pkcs8(private_key);
        }

        #[cfg(feature = "ed25519")]
        if algorithm == Algorithm::Ed25519 {
            return self.ed25519.load_pkcs8(private_key);
        }

        Err(Error::AlgorithmInvalid)
    }
}
