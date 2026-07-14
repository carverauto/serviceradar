//! Password-Based Encryption Scheme 2 as defined in [RFC 8018 Section 6.2].
//!
//! [RFC 8018 Section 6.2]: https://tools.ietf.org/html/rfc8018#section-6.2

mod kdf;

#[cfg(feature = "pbes2")]
mod encryption;

pub use self::kdf::{
    Kdf, Pbkdf2Params, Pbkdf2Prf, ScryptParams, HMAC_WITH_SHA1_OID, HMAC_WITH_SHA256_OID,
    PBKDF2_OID, SCRYPT_OID,
};

use crate::{AlgorithmIdentifierRef, Error, Result};
use der::{
    asn1::{AnyRef, ObjectIdentifier, OctetStringRef},
    Decode, DecodeValue, Encode, EncodeValue, ErrorKind, Length, Reader, Sequence, Tag, Writer,
};

#[cfg(all(feature = "alloc", feature = "pbes2"))]
use alloc::vec::Vec;

/// 128-bit Advanced Encryption Standard (AES) algorithm with Cipher-Block
/// Chaining (CBC) mode of operation.
pub const AES_128_CBC_OID: ObjectIdentifier =
    ObjectIdentifier::new_unwrap("2.16.840.1.101.3.4.1.2");

/// 192-bit Advanced Encryption Standard (AES) algorithm with Cipher-Block
/// Chaining (CBC) mode of operation.
pub const AES_192_CBC_OID: ObjectIdentifier =
    ObjectIdentifier::new_unwrap("2.16.840.1.101.3.4.1.22");

/// 256-bit Advanced Encryption Standard (AES) algorithm with Cipher-Block
/// Chaining (CBC) mode of operation.
pub const AES_256_CBC_OID: ObjectIdentifier =
    ObjectIdentifier::new_unwrap("2.16.840.1.101.3.4.1.42");

/// DES operating in CBC mode
#[cfg(feature = "des-insecure")]
pub const DES_CBC_OID: ObjectIdentifier = ObjectIdentifier::new_unwrap("1.3.14.3.2.7");

/// Triple DES operating in CBC mode
#[cfg(feature = "3des")]
pub const DES_EDE3_CBC_OID: ObjectIdentifier = ObjectIdentifier::new_unwrap("1.2.840.113549.3.7");

/// Password-Based Encryption Scheme 2 (PBES2) OID.
///
/// <https://tools.ietf.org/html/rfc8018#section-6.2>
pub const PBES2_OID: ObjectIdentifier = ObjectIdentifier::new_unwrap("1.2.840.113549.1.5.13");

/// AES cipher block size
const AES_BLOCK_SIZE: usize = 16;

/// DES / Triple DES block size
#[cfg(any(feature = "3des", feature = "des-insecure"))]
const DES_BLOCK_SIZE: usize = 8;

/// Password-Based Encryption Scheme 2 parameters as defined in [RFC 8018 Appendix A.4].
///
/// ```text
///  PBES2-params ::= SEQUENCE {
///       keyDerivationFunc AlgorithmIdentifier {{PBES2-KDFs}},
///       encryptionScheme AlgorithmIdentifier {{PBES2-Encs}} }
/// ```
///
/// [RFC 8018 Appendix A.4]: https://tools.ietf.org/html/rfc8018#appendix-A.4
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Parameters<'a> {
    /// Key derivation function
    pub kdf: Kdf<'a>,

    /// Encryption scheme
    pub encryption: EncryptionScheme<'a>,
}

impl<'a> Parameters<'a> {
    /// Initialize PBES2 parameters using PBKDF2-SHA256 as the password-based
    /// key derivation function and AES-128-CBC as the symmetric cipher.
    pub fn pbkdf2_sha256_aes128cbc(
        pbkdf2_iterations: u32,
        pbkdf2_salt: &'a [u8],
        aes_iv: &'a [u8; AES_BLOCK_SIZE],
    ) -> Result<Self> {
        let kdf = Pbkdf2Params::hmac_with_sha256(pbkdf2_iterations, pbkdf2_salt)?.into();
        let encryption = EncryptionScheme::Aes128Cbc { iv: aes_iv };
        Ok(Self { kdf, encryption })
    }

    /// Initialize PBES2 parameters using PBKDF2-SHA256 as the password-based
    /// key derivation function and AES-256-CBC as the symmetric cipher.
    pub fn pbkdf2_sha256_aes256cbc(
        pbkdf2_iterations: u32,
        pbkdf2_salt: &'a [u8],
        aes_iv: &'a [u8; AES_BLOCK_SIZE],
    ) -> Result<Self> {
        let kdf = Pbkdf2Params::hmac_with_sha256(pbkdf2_iterations, pbkdf2_salt)?.into();
        let encryption = EncryptionScheme::Aes256Cbc { iv: aes_iv };
        Ok(Self { kdf, encryption })
    }

    /// Initialize PBES2 parameters using scrypt as the password-based
    /// key derivation function and AES-128-CBC as the symmetric cipher.
    ///
    /// For more information on scrypt parameters, see documentation for the
    /// [`scrypt::Params`] struct.
    // TODO(tarcieri): encapsulate `scrypt::Params`?
    #[cfg(feature = "pbes2")]
    pub fn scrypt_aes128cbc(
        params: scrypt::Params,
        salt: &'a [u8],
        aes_iv: &'a [u8; AES_BLOCK_SIZE],
    ) -> Result<Self> {
        let kdf = ScryptParams::from_params_and_salt(params, salt)?.into();
        let encryption = EncryptionScheme::Aes128Cbc { iv: aes_iv };
        Ok(Self { kdf, encryption })
    }

    /// Initialize PBES2 parameters using scrypt as the password-based
    /// key derivation function and AES-256-CBC as the symmetric cipher.
    ///
    /// For more information on scrypt parameters, see documentation for the
    /// [`scrypt::Params`] struct.
    ///
    /// When in doubt, use `Default::default()` as the [`scrypt::Params`].
    /// This also avoids the need to import the type from the `scrypt` crate.
    // TODO(tarcieri): encapsulate `scrypt::Params`?
    #[cfg(feature = "pbes2")]
    pub fn scrypt_aes256cbc(
        params: scrypt::Params,
        salt: &'a [u8],
        aes_iv: &'a [u8; AES_BLOCK_SIZE],
    ) -> Result<Self> {
        let kdf = ScryptParams::from_params_and_salt(params, salt)?.into();
        let encryption = EncryptionScheme::Aes256Cbc { iv: aes_iv };
        Ok(Self { kdf, encryption })
    }

    /// Attempt to decrypt the given ciphertext, allocating and returning a
    /// byte vector containing the plaintext.
    #[cfg(all(feature = "alloc", feature = "pbes2"))]
    pub fn decrypt(&self, password: impl AsRef<[u8]>, ciphertext: &[u8]) -> Result<Vec<u8>> {
        let mut buffer = ciphertext.to_vec();
        let pt_len = self.decrypt_in_place(password, &mut buffer)?.len();
        buffer.truncate(pt_len);
        Ok(buffer)
    }

    /// Attempt to decrypt the given ciphertext in-place using a key derived
    /// from the provided password and this scheme's parameters.
    ///
    /// Returns an error if the algorithm specified in this scheme's parameters
    /// is unsupported, or if the ciphertext is malformed (e.g. not a multiple
    /// of a block mode's padding)
    #[cfg(feature = "pbes2")]
    pub fn decrypt_in_place<'b>(
        &self,
        password: impl AsRef<[u8]>,
        buffer: &'b mut [u8],
    ) -> Result<&'b [u8]> {
        encryption::decrypt_in_place(self, password, buffer)
    }

    /// Encrypt the given plaintext, allocating and returning a vector
    /// containing the ciphertext.
    #[cfg(all(feature = "alloc", feature = "pbes2"))]
    pub fn encrypt(&self, password: impl AsRef<[u8]>, plaintext: &[u8]) -> Result<Vec<u8>> {
        // TODO(tarcieri): support non-AES ciphers?
        let mut buffer = Vec::with_capacity(plaintext.len() + AES_BLOCK_SIZE);
        buffer.extend_from_slice(plaintext);
        buffer.extend_from_slice(&[0u8; AES_BLOCK_SIZE]);

        let ct_len = self
            .encrypt_in_place(password, &mut buffer, plaintext.len())?
            .len();

        buffer.truncate(ct_len);
        Ok(buffer)
    }

    /// Encrypt the given plaintext in-place using a key derived from the
    /// provided password and this scheme's parameters, writing the ciphertext
    /// into the same buffer.
    #[cfg(feature = "pbes2")]
    pub fn encrypt_in_place<'b>(
        &self,
        password: impl AsRef<[u8]>,
        buffer: &'b mut [u8],
        pos: usize,
    ) -> Result<&'b [u8]> {
        encryption::encrypt_in_place(self, password, buffer, pos)
    }
}

impl<'a> DecodeValue<'a> for Parameters<'a> {
    fn decode_value<R: Reader<'a>>(reader: &mut R, header: der::Header) -> der::Result<Self> {
        AnyRef::decode_value(reader, header)?.try_into()
    }
}

impl EncodeValue for Parameters<'_> {
    fn value_len(&self) -> der::Result<Length> {
        self.kdf.encoded_len()? + self.encryption.encoded_len()?
    }

    fn encode_value(&self, writer: &mut impl Writer) -> der::Result<()> {
        self.kdf.encode(writer)?;
        self.encryption.encode(writer)?;
        Ok(())
    }
}

impl<'a> Sequence<'a> for Parameters<'a> {}

impl<'a> TryFrom<AnyRef<'a>> for Parameters<'a> {
    type Error = der::Error;

    fn try_from(any: AnyRef<'a>) -> der::Result<Self> {
        any.sequence(|params| {
            let kdf = AlgorithmIdentifierRef::decode(params)?;
            let encryption = AlgorithmIdentifierRef::decode(params)?;

            Ok(Self {
                kdf: kdf.try_into()?,
                encryption: encryption.try_into()?,
            })
        })
    }
}

/// Symmetric encryption scheme used by PBES2.
#[derive(Copy, Clone, Debug, Eq, PartialEq)]
#[non_exhaustive]
pub enum EncryptionScheme<'a> {
    /// AES-128 in CBC mode
    Aes128Cbc {
        /// Initialization vector
        iv: &'a [u8; AES_BLOCK_SIZE],
    },

    /// AES-192 in CBC mode
    Aes192Cbc {
        /// Initialization vector
        iv: &'a [u8; AES_BLOCK_SIZE],
    },

    /// AES-256 in CBC mode
    Aes256Cbc {
        /// Initialization vector
        iv: &'a [u8; AES_BLOCK_SIZE],
    },

    /// 3-Key Triple DES in CBC mode
    #[cfg(feature = "3des")]
    DesEde3Cbc {
        /// Initialisation vector
        iv: &'a [u8; DES_BLOCK_SIZE],
    },

    /// DES in CBC mode
    #[cfg(feature = "des-insecure")]
    DesCbc {
        /// Initialisation vector
        iv: &'a [u8; DES_BLOCK_SIZE],
    },
}

impl<'a> EncryptionScheme<'a> {
    /// Get the size of a key used by this algorithm in bytes.
    pub fn key_size(&self) -> usize {
        match self {
            Self::Aes128Cbc { .. } => 16,
            Self::Aes192Cbc { .. } => 24,
            Self::Aes256Cbc { .. } => 32,
            #[cfg(feature = "des-insecure")]
            Self::DesCbc { .. } => 8,
            #[cfg(feature = "3des")]
            Self::DesEde3Cbc { .. } => 24,
        }
    }

    /// Get the [`ObjectIdentifier`] (a.k.a OID) for this algorithm.
    pub fn oid(&self) -> ObjectIdentifier {
        match self {
            Self::Aes128Cbc { .. } => AES_128_CBC_OID,
            Self::Aes192Cbc { .. } => AES_192_CBC_OID,
            Self::Aes256Cbc { .. } => AES_256_CBC_OID,
            #[cfg(feature = "des-insecure")]
            Self::DesCbc { .. } => DES_CBC_OID,
            #[cfg(feature = "3des")]
            Self::DesEde3Cbc { .. } => DES_EDE3_CBC_OID,
        }
    }

    /// Convenience function to turn the OID (see [`oid`](Self::oid))
    /// of this [`EncryptionScheme`] into error case
    /// [`Error::AlgorithmParametersInvalid`]
    pub fn to_alg_params_invalid(&self) -> Error {
        Error::AlgorithmParametersInvalid { oid: self.oid() }
    }
}

impl<'a> Decode<'a> for EncryptionScheme<'a> {
    fn decode<R: Reader<'a>>(reader: &mut R) -> der::Result<Self> {
        AlgorithmIdentifierRef::decode(reader).and_then(TryInto::try_into)
    }
}

impl<'a> TryFrom<AlgorithmIdentifierRef<'a>> for EncryptionScheme<'a> {
    type Error = der::Error;

    fn try_from(alg: AlgorithmIdentifierRef<'a>) -> der::Result<Self> {
        // TODO(tarcieri): support for non-AES algorithms?
        let iv = match alg.parameters {
            Some(params) => params.decode_as::<OctetStringRef<'a>>()?.as_bytes(),
            None => return Err(Tag::OctetString.value_error()),
        };

        match alg.oid {
            AES_128_CBC_OID => Ok(Self::Aes128Cbc {
                iv: iv
                    .try_into()
                    .map_err(|_| der::Tag::OctetString.value_error())?,
            }),
            AES_192_CBC_OID => Ok(Self::Aes192Cbc {
                iv: iv
                    .try_into()
                    .map_err(|_| der::Tag::OctetString.value_error())?,
            }),
            AES_256_CBC_OID => Ok(Self::Aes256Cbc {
                iv: iv
                    .try_into()
                    .map_err(|_| der::Tag::OctetString.value_error())?,
            }),
            #[cfg(feature = "des-insecure")]
            DES_CBC_OID => Ok(Self::DesCbc {
                iv: iv[0..DES_BLOCK_SIZE]
                    .try_into()
                    .map_err(|_| der::Tag::OctetString.value_error())?,
            }),
            #[cfg(feature = "3des")]
            DES_EDE3_CBC_OID => Ok(Self::DesEde3Cbc {
                iv: iv[0..DES_BLOCK_SIZE]
                    .try_into()
                    .map_err(|_| der::Tag::OctetString.value_error())?,
            }),
            oid => Err(ErrorKind::OidUnknown { oid }.into()),
        }
    }
}

impl<'a> TryFrom<EncryptionScheme<'a>> for AlgorithmIdentifierRef<'a> {
    type Error = der::Error;

    fn try_from(scheme: EncryptionScheme<'a>) -> der::Result<Self> {
        let parameters = OctetStringRef::new(match scheme {
            EncryptionScheme::Aes128Cbc { iv } => iv,
            EncryptionScheme::Aes192Cbc { iv } => iv,
            EncryptionScheme::Aes256Cbc { iv } => iv,
            #[cfg(feature = "des-insecure")]
            EncryptionScheme::DesCbc { iv } => iv,
            #[cfg(feature = "3des")]
            EncryptionScheme::DesEde3Cbc { iv } => iv,
        })?;

        Ok(AlgorithmIdentifierRef {
            oid: scheme.oid(),
            parameters: Some(parameters.into()),
        })
    }
}

impl<'a> Encode for EncryptionScheme<'a> {
    fn encoded_len(&self) -> der::Result<Length> {
        AlgorithmIdentifierRef::try_from(*self)?.encoded_len()
    }

    fn encode(&self, writer: &mut impl Writer) -> der::Result<()> {
        AlgorithmIdentifierRef::try_from(*self)?.encode(writer)
    }
}
