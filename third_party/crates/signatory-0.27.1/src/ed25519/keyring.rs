//! Ed25519 keyring.

use super::{SigningKey, VerifyingKey};
use crate::{Error, KeyHandle, LoadPkcs8, Map, Result};

/// Ed25519 keyring.
#[derive(Debug, Default)]
pub struct KeyRing {
    keys: Map<VerifyingKey, SigningKey>,
}

impl KeyRing {
    /// Create new Ed25519 keyring.
    pub fn new() -> Self {
        Self::default()
    }

    /// Get the [`SigningKey`] that corresponds to the provided [`VerifyingKey`]
    /// (i.e. public key)
    pub fn get(&self, verifying_key: &VerifyingKey) -> Option<&SigningKey> {
        self.keys.get(verifying_key)
    }

    /// Iterate over the keys in the keyring.
    pub fn iter(&self) -> impl Iterator<Item = &SigningKey> {
        self.keys.values()
    }
}

impl LoadPkcs8 for KeyRing {
    fn load_pkcs8(&mut self, private_key: pkcs8::PrivateKeyInfo<'_>) -> Result<KeyHandle> {
        let signing_key = SigningKey::try_from(private_key)?;
        let verifying_key = signing_key.verifying_key();

        if self.keys.contains_key(&verifying_key) {
            return Err(Error::DuplicateKey);
        }

        self.keys.insert(verifying_key, signing_key);
        Ok(KeyHandle::Ed25519(verifying_key))
    }
}
