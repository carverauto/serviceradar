//! Traits for parsing objects from PKCS#1 encoded documents

use crate::Result;

#[cfg(feature = "alloc")]
use der::{Document, SecretDocument};

#[cfg(feature = "pem")]
use {
    crate::LineEnding,
    alloc::string::String,
    der::{pem::PemLabel, zeroize::Zeroizing},
};

#[cfg(feature = "std")]
use std::path::Path;

#[cfg(all(feature = "alloc", feature = "pem"))]
use crate::{RsaPrivateKey, RsaPublicKey};

/// Parse an [`RsaPrivateKey`] from a PKCS#1-encoded document.
pub trait DecodeRsaPrivateKey: Sized {
    /// Deserialize PKCS#1 private key from ASN.1 DER-encoded data
    /// (binary format).
    fn from_pkcs1_der(bytes: &[u8]) -> Result<Self>;

    /// Deserialize PKCS#1-encoded private key from PEM.
    ///
    /// Keys in this format begin with the following:
    ///
    /// ```text
    /// -----BEGIN RSA PRIVATE KEY-----
    /// ```
    #[cfg(feature = "pem")]
    fn from_pkcs1_pem(s: &str) -> Result<Self> {
        let (label, doc) = SecretDocument::from_pem(s)?;
        RsaPrivateKey::validate_pem_label(label)?;
        Self::from_pkcs1_der(doc.as_bytes())
    }

    /// Load PKCS#1 private key from an ASN.1 DER-encoded file on the local
    /// filesystem (binary format).
    #[cfg(feature = "std")]
    fn read_pkcs1_der_file(path: impl AsRef<Path>) -> Result<Self> {
        Self::from_pkcs1_der(SecretDocument::read_der_file(path)?.as_bytes())
    }

    /// Load PKCS#1 private key from a PEM-encoded file on the local filesystem.
    #[cfg(all(feature = "pem", feature = "std"))]
    fn read_pkcs1_pem_file(path: impl AsRef<Path>) -> Result<Self> {
        let (label, doc) = SecretDocument::read_pem_file(path)?;
        RsaPrivateKey::validate_pem_label(&label)?;
        Self::from_pkcs1_der(doc.as_bytes())
    }
}

/// Parse a [`RsaPublicKey`] from a PKCS#1-encoded document.
pub trait DecodeRsaPublicKey: Sized {
    /// Deserialize object from ASN.1 DER-encoded [`RsaPublicKey`]
    /// (binary format).
    fn from_pkcs1_der(bytes: &[u8]) -> Result<Self>;

    /// Deserialize PEM-encoded [`RsaPublicKey`].
    ///
    /// Keys in this format begin with the following:
    ///
    /// ```text
    /// -----BEGIN RSA PUBLIC KEY-----
    /// ```
    #[cfg(feature = "pem")]
    fn from_pkcs1_pem(s: &str) -> Result<Self> {
        let (label, doc) = Document::from_pem(s)?;
        RsaPublicKey::validate_pem_label(label)?;
        Self::from_pkcs1_der(doc.as_bytes())
    }

    /// Load [`RsaPublicKey`] from an ASN.1 DER-encoded file on the local
    /// filesystem (binary format).
    #[cfg(feature = "std")]
    fn read_pkcs1_der_file(path: impl AsRef<Path>) -> Result<Self> {
        let doc = Document::read_der_file(path)?;
        Self::from_pkcs1_der(doc.as_bytes())
    }

    /// Load [`RsaPublicKey`] from a PEM-encoded file on the local filesystem.
    #[cfg(all(feature = "pem", feature = "std"))]
    fn read_pkcs1_pem_file(path: impl AsRef<Path>) -> Result<Self> {
        let (label, doc) = Document::read_pem_file(path)?;
        RsaPublicKey::validate_pem_label(&label)?;
        Self::from_pkcs1_der(doc.as_bytes())
    }
}

/// Serialize a [`RsaPrivateKey`] to a PKCS#1 encoded document.
#[cfg(feature = "alloc")]
pub trait EncodeRsaPrivateKey {
    /// Serialize a [`SecretDocument`] containing a PKCS#1-encoded private key.
    fn to_pkcs1_der(&self) -> Result<SecretDocument>;

    /// Serialize this private key as PEM-encoded PKCS#1 with the given [`LineEnding`].
    #[cfg(feature = "pem")]
    fn to_pkcs1_pem(&self, line_ending: LineEnding) -> Result<Zeroizing<String>> {
        let doc = self.to_pkcs1_der()?;
        Ok(doc.to_pem(RsaPrivateKey::PEM_LABEL, line_ending)?)
    }

    /// Write ASN.1 DER-encoded PKCS#1 private key to the given path.
    #[cfg(feature = "std")]
    fn write_pkcs1_der_file(&self, path: impl AsRef<Path>) -> Result<()> {
        Ok(self.to_pkcs1_der()?.write_der_file(path)?)
    }

    /// Write ASN.1 PEM-encoded PKCS#1 private key to the given path.
    #[cfg(all(feature = "pem", feature = "std"))]
    fn write_pkcs1_pem_file(&self, path: impl AsRef<Path>, line_ending: LineEnding) -> Result<()> {
        let doc = self.to_pkcs1_der()?;
        Ok(doc.write_pem_file(path, RsaPrivateKey::PEM_LABEL, line_ending)?)
    }
}

/// Serialize a [`RsaPublicKey`] to a PKCS#1-encoded document.
#[cfg(feature = "alloc")]
pub trait EncodeRsaPublicKey {
    /// Serialize a [`Document`] containing a PKCS#1-encoded public key.
    fn to_pkcs1_der(&self) -> Result<Document>;

    /// Serialize this public key as PEM-encoded PKCS#1 with the given line ending.
    #[cfg(feature = "pem")]
    fn to_pkcs1_pem(&self, line_ending: LineEnding) -> Result<String> {
        let doc = self.to_pkcs1_der()?;
        Ok(doc.to_pem(RsaPublicKey::PEM_LABEL, line_ending)?)
    }

    /// Write ASN.1 DER-encoded public key to the given path.
    #[cfg(feature = "std")]
    fn write_pkcs1_der_file(&self, path: impl AsRef<Path>) -> Result<()> {
        Ok(self.to_pkcs1_der()?.write_der_file(path)?)
    }

    /// Write ASN.1 PEM-encoded public key to the given path.
    #[cfg(all(feature = "pem", feature = "std"))]
    fn write_pkcs1_pem_file(&self, path: impl AsRef<Path>, line_ending: LineEnding) -> Result<()> {
        let doc = self.to_pkcs1_der()?;
        Ok(doc.write_pem_file(path, RsaPublicKey::PEM_LABEL, line_ending)?)
    }
}
