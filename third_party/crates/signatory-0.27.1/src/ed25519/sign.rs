//! Ed25519 keys.

use super::{Signature, VerifyingKey, ALGORITHM_ID, ALGORITHM_OID};
use crate::{key::store::GeneratePkcs8, Error, Result};
use alloc::boxed::Box;
use core::fmt;
use ed25519_dalek::SECRET_KEY_LENGTH;
use rand_core::{OsRng, RngCore};
use signature::Signer;
use zeroize::Zeroizing;

/// Ed25519 signing key.
pub struct SigningKey {
    inner: Box<dyn Ed25519Signer + Send + Sync>,
}

impl SigningKey {
    /// Initialize from a provided signer object.
    ///
    /// Use [`SigningKey::from_bytes`] to initialize from a raw private key.
    pub fn new(signer: Box<dyn Ed25519Signer + Send + Sync>) -> Self {
        Self { inner: signer }
    }

    /// Initialize from a raw scalar value (big endian).
    pub fn from_bytes(bytes: &[u8]) -> Result<Self> {
        let signing_key = ed25519_dalek::SigningKey::try_from(bytes).map_err(|_| Error::Parse)?;
        Ok(Self::new(Box::new(signing_key)))
    }

    /// Get the verifying key that corresponds to this signing key.
    pub fn verifying_key(&self) -> VerifyingKey {
        self.inner.verifying_key()
    }
}

// TODO(tarcieri): use upstream decoder from `ed25519` crate.
// See: https://docs.rs/ed25519/latest/ed25519/pkcs8/struct.KeypairBytes.html
impl TryFrom<pkcs8::PrivateKeyInfo<'_>> for SigningKey {
    type Error = pkcs8::Error;

    fn try_from(private_key: pkcs8::PrivateKeyInfo<'_>) -> pkcs8::Result<Self> {
        private_key.algorithm.assert_algorithm_oid(ALGORITHM_OID)?;

        if private_key.algorithm.parameters.is_some() {
            return Err(pkcs8::Error::ParametersMalformed);
        }

        Self::from_bytes(private_key.private_key).map_err(|_| pkcs8::Error::KeyMalformed)
    }
}

#[cfg(feature = "std")]
impl GeneratePkcs8 for SigningKey {
    /// Randomly generate a new PKCS#8 private key.
    fn generate_pkcs8() -> pkcs8::SecretDocument {
        let mut private_key = Zeroizing::new([0u8; SECRET_KEY_LENGTH]);
        OsRng.fill_bytes(&mut *private_key);
        pkcs8::SecretDocument::encode_msg(&pkcs8::PrivateKeyInfo::new(ALGORITHM_ID, &*private_key))
            .expect("DER encoding error")
    }
}

impl Signer<Signature> for SigningKey {
    fn try_sign(&self, msg: &[u8]) -> signature::Result<Signature> {
        self.inner.try_sign(msg)
    }
}

impl TryFrom<&[u8]> for SigningKey {
    type Error = Error;

    fn try_from(bytes: &[u8]) -> Result<Self> {
        Self::from_bytes(bytes)
    }
}

impl fmt::Debug for SigningKey {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("SigningKey")
            .field("verifying_key", &self.verifying_key())
            .finish()
    }
}

/// Ed25519 signer
pub trait Ed25519Signer: Signer<Signature> {
    /// Get the ECDSA verifying key for this signer
    fn verifying_key(&self) -> VerifyingKey;
}

impl<T> Ed25519Signer for T
where
    T: Signer<Signature>,
    VerifyingKey: for<'a> From<&'a T>,
{
    fn verifying_key(&self) -> VerifyingKey {
        self.into()
    }
}
