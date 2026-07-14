//! Filesystem-backed keystore

use crate::{Error, KeyHandle, KeyInfo, KeyName, KeyRing, LoadPkcs8, Result};
use pkcs8::der::pem::PemLabel;
use std::{
    fs,
    path::{Path, PathBuf},
};
use zeroize::Zeroizing;

#[cfg(unix)]
use std::{fs::Permissions, os::unix::fs::PermissionsExt};

/// Required filesystem mode for keystore directories (Unix-only)
#[cfg(unix)]
const REQUIRED_DIR_MODE: u32 = 0o700;

/// PEM encapsulation boundary for private keys.
const PRIVATE_KEY_BOUNDARY: &str = "-----BEGIN PRIVATE KEY-----";

/// PEM encapsulation boundary for encrypted private keys.
const ENCRYPTED_PRIVATE_KEY_BOUNDARY: &str = "-----BEGIN ENCRYPTED PRIVATE KEY-----";

/// Filesystem-backed keystore.
pub struct FsKeyStore {
    path: PathBuf,
}

impl FsKeyStore {
    /// Attempt to open a filesystem-backed keystore at the given path,
    /// creating it if it doesn't already exist.
    pub fn create_or_open(dir_path: &Path) -> Result<Self> {
        Self::open(dir_path).or_else(|_| Self::create(dir_path))
    }

    /// Create a filesystem-backed keystore at the given path, making a new
    /// directory and setting its file permissions.
    pub fn create(dir_path: &Path) -> Result<Self> {
        fs::create_dir_all(dir_path)?;

        #[cfg(unix)]
        fs::set_permissions(dir_path, Permissions::from_mode(REQUIRED_DIR_MODE))?;

        Self::open(dir_path)
    }

    /// Initialize filesystem-backed keystore, opening the directory at the
    /// provided path and checking that it has the correct filesystem
    /// permissions.
    pub fn open(dir_path: &Path) -> Result<Self> {
        let path = dir_path.canonicalize()?;
        let st = path.metadata()?;

        if !st.is_dir() {
            return Err(Error::NotADirectory);
        }

        #[cfg(unix)]
        if st.permissions().mode() & 0o777 != REQUIRED_DIR_MODE {
            return Err(Error::Permissions);
        }

        Ok(Self { path })
    }

    /// Get information about a key with the given name.
    pub fn info(&self, name: &KeyName) -> Result<KeyInfo> {
        let pem_data = Zeroizing::new(fs::read_to_string(self.key_path(name))?);

        let encrypted = if pem_data.starts_with(ENCRYPTED_PRIVATE_KEY_BOUNDARY) {
            true
        } else if pem_data.starts_with(PRIVATE_KEY_BOUNDARY) {
            false
        } else {
            return Err(pkcs8::Error::KeyMalformed.into());
        };

        let algorithm = if encrypted {
            None
        } else {
            let (label, der) = pkcs8::SecretDocument::from_pem(&pem_data)?;
            pkcs8::PrivateKeyInfo::validate_pem_label(label)?;
            der.decode_msg::<pkcs8::PrivateKeyInfo<'_>>()?
                .algorithm
                .try_into()
                .ok()
        };

        Ok(KeyInfo {
            name: name.clone(),
            algorithm,
            encrypted,
        })
    }

    /// Import a key with a given name into the provided keyring.
    pub fn import(&self, name: &KeyName, key_ring: &mut KeyRing) -> Result<KeyHandle> {
        key_ring.load_pkcs8(self.load(name)?.decode_msg()?)
    }

    /// Load a PKCS#8 key from the keystore.
    pub fn load(&self, name: &KeyName) -> Result<pkcs8::SecretDocument> {
        let (label, doc) = pkcs8::SecretDocument::read_pem_file(self.key_path(name))?;
        pkcs8::PrivateKeyInfo::validate_pem_label(&label)?;
        Ok(doc)
    }

    /// Import a PKCS#8 key into the keystore.
    pub fn store(&self, name: &KeyName, der: &pkcs8::SecretDocument) -> Result<()> {
        der.write_pem_file(
            self.key_path(name),
            pkcs8::PrivateKeyInfo::PEM_LABEL,
            Default::default(),
        )?;
        Ok(())
    }

    /// Delete a PKCS#8 key from the keystore.
    pub fn delete(&self, name: &KeyName) -> Result<()> {
        fs::remove_file(self.key_path(name))?;

        Ok(())
    }

    /// Compute the path for a key with a given name.
    fn key_path(&self, name: &KeyName) -> PathBuf {
        let mut path = self.path.join(name);
        path.set_extension("pem");
        path
    }
}

#[cfg(test)]
#[allow(unused_imports)] // TODO(tarcieri): always use imports
mod tests {
    use super::FsKeyStore;
    use crate::{Algorithm, GeneratePkcs8};

    #[cfg(feature = "secp256k1")]
    use crate::ecdsa::secp256k1;

    pub const EXAMPLE_KEY: &str = "example-key";

    pub struct FsStoreHandle {
        pub keystore: FsKeyStore,
        pub dir: tempfile::TempDir,
    }

    /// Create a keystore containing one key named `example_key` with the given content
    #[allow(dead_code)]
    fn create_example_keystore(example_key: &pkcs8::SecretDocument) -> FsStoreHandle {
        let dir = tempfile::tempdir().unwrap();
        let keystore = FsKeyStore::create_or_open(&dir.path().join("keys")).unwrap();

        keystore
            .store(&EXAMPLE_KEY.parse().unwrap(), example_key)
            .unwrap();

        FsStoreHandle { keystore, dir }
    }

    #[cfg(feature = "secp256k1")]
    #[test]
    fn import_and_delete_key() {
        let key_name = EXAMPLE_KEY.parse().unwrap();
        let example_key = secp256k1::SigningKey::generate_pkcs8();
        let ks = create_example_keystore(&example_key);

        let example_key2 = ks.keystore.load(&key_name).unwrap();
        assert_eq!(example_key.as_bytes(), example_key2.as_bytes());

        ks.keystore.delete(&key_name).unwrap();
    }

    #[cfg(feature = "secp256k1")]
    #[test]
    fn get_key_info() {
        let key_name = EXAMPLE_KEY.parse().unwrap();
        let example_key = secp256k1::SigningKey::generate_pkcs8();
        let ks = create_example_keystore(&example_key);

        let key_info = ks.keystore.info(&key_name).unwrap();
        assert_eq!(key_info.name, key_name);
        assert_eq!(key_info.algorithm, Some(Algorithm::EcdsaSecp256k1));
        assert!(!key_info.encrypted);
    }
}
