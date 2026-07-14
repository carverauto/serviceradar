//! Key storage providers.

#[cfg(feature = "std")]
pub(crate) mod fs;

#[cfg(feature = "std")]
pub use fs::FsKeyStore;

/// Trait for generating PKCS#8-encoded private keys.
pub trait GeneratePkcs8 {
    /// Randomly generate a new PKCS#8 private key.
    fn generate_pkcs8() -> pkcs8::SecretDocument;
}
