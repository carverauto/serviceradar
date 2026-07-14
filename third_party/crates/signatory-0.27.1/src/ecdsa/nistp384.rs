//! ECDSA/NIST P-384 support.

pub use p384::ecdsa::{Signature, VerifyingKey};

use crate::{
    key::{ring::LoadPkcs8, store::GeneratePkcs8},
    Error, KeyHandle, Map, Result,
};
use alloc::boxed::Box;
use core::fmt;
use pkcs8::EncodePrivateKey;
use signature::Signer;

/// ECDSA/P-384 key ring.
#[derive(Debug, Default)]
pub struct KeyRing {
    keys: Map<VerifyingKey, SigningKey>,
}

impl KeyRing {
    /// Create new ECDSA/NIST P-384 keyring.
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
        Ok(KeyHandle::EcdsaNistP384(verifying_key))
    }
}

/// ECDSA/NIST P-384 signing key.
pub struct SigningKey {
    inner: Box<dyn NistP384Signer + Send + Sync>,
}

impl SigningKey {
    /// Initialize from a provided signer object.
    ///
    /// Use [`SigningKey::from_bytes`] to initialize from a raw private key.
    pub fn new(signer: Box<dyn NistP384Signer + Send + Sync>) -> Self {
        Self { inner: signer }
    }

    /// Initialize from a raw scalar value (big endian).
    pub fn from_bytes(bytes: &[u8]) -> Result<Self> {
        let signing_key = p384::ecdsa::SigningKey::from_slice(bytes)?;
        Ok(Self::new(Box::new(signing_key)))
    }

    /// Get the verifying key that corresponds to this signing key.
    pub fn verifying_key(&self) -> VerifyingKey {
        self.inner.verifying_key()
    }
}

impl TryFrom<pkcs8::PrivateKeyInfo<'_>> for SigningKey {
    type Error = pkcs8::Error;

    fn try_from(private_key_info: pkcs8::PrivateKeyInfo<'_>) -> pkcs8::Result<Self> {
        p384::ecdsa::SigningKey::try_from(private_key_info).map(|key| Self::new(Box::new(key)))
    }
}

impl TryFrom<&[u8]> for SigningKey {
    type Error = Error;

    fn try_from(bytes: &[u8]) -> Result<Self> {
        Self::from_bytes(bytes)
    }
}

#[cfg(feature = "std")]
impl GeneratePkcs8 for SigningKey {
    /// Randomly generate a new PKCS#8 private key.
    fn generate_pkcs8() -> pkcs8::SecretDocument {
        p384::SecretKey::random(&mut rand_core::OsRng)
            .to_pkcs8_der()
            .expect("DER error")
    }
}

impl Signer<Signature> for SigningKey {
    fn try_sign(&self, msg: &[u8]) -> signature::Result<Signature> {
        self.inner.try_sign(msg)
    }
}

impl fmt::Debug for SigningKey {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("SigningKey")
            .field("verifying_key", &self.verifying_key())
            .finish()
    }
}

/// ECDSA/NIST P-384 signer.
pub trait NistP384Signer: Signer<Signature> {
    /// Get the ECDSA verifying key for this signer
    fn verifying_key(&self) -> VerifyingKey;
}

impl<T> NistP384Signer for T
where
    T: Signer<Signature>,
    VerifyingKey: for<'a> From<&'a T>,
{
    fn verifying_key(&self) -> VerifyingKey {
        self.into()
    }
}
