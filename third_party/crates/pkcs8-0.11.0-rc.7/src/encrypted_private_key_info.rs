//! PKCS#8 `EncryptedPrivateKeyInfo`

use crate::{Error, Result};
use core::fmt;
use der::{
    Decode, DecodeValue, Encode, EncodeValue, FixedTag, Header, Length, Reader, Sequence, Writer,
    asn1::OctetStringRef,
};
use pkcs5::EncryptionScheme;

#[cfg(feature = "alloc")]
use der::{SecretDocument, asn1::OctetString};

#[cfg(feature = "encryption")]
use {pkcs5::pbes2, rand_core::CryptoRng};

#[cfg(feature = "pem")]
use der::pem::PemLabel;

/// PKCS#8 `EncryptedPrivateKeyInfo`.
///
/// ASN.1 structure containing a PKCS#5 [`EncryptionScheme`] identifier for a
/// password-based symmetric encryption scheme and encrypted private key data.
///
/// ## Schema
/// Structure described in [RFC 5208 Section 6]:
///
/// ```text
/// EncryptedPrivateKeyInfo ::= SEQUENCE {
///   encryptionAlgorithm  EncryptionAlgorithmIdentifier,
///   encryptedData        EncryptedData }
///
/// EncryptionAlgorithmIdentifier ::= AlgorithmIdentifier
///
/// EncryptedData ::= OCTET STRING
/// ```
///
/// [RFC 5208 Section 6]: https://tools.ietf.org/html/rfc5208#section-6
#[derive(Clone, Eq, PartialEq)]
pub struct EncryptedPrivateKeyInfo<Data> {
    /// Algorithm identifier describing a password-based symmetric encryption
    /// scheme used to encrypt the `encrypted_data` field.
    pub encryption_algorithm: EncryptionScheme,

    /// Private key data
    pub encrypted_data: Data,
}

impl<'a, Data> EncryptedPrivateKeyInfo<Data>
where
    Data: DecodeValue<'a, Error = der::Error> + EncodeValue + FixedTag + 'a,
    Data: AsRef<[u8]>,
{
    /// Attempt to decrypt this encrypted private key using the provided
    /// password to derive an encryption key.
    #[cfg(feature = "encryption")]
    pub fn decrypt(&self, password: impl AsRef<[u8]>) -> Result<SecretDocument> {
        Ok(self
            .encryption_algorithm
            .decrypt(password, self.encrypted_data.as_ref())?
            .try_into()?)
    }

    /// Encrypt the given ASN.1 DER document using a symmetric encryption key
    /// derived from the provided password.
    #[cfg(feature = "encryption")]
    pub(crate) fn encrypt<R: CryptoRng>(
        rng: &mut R,
        password: impl AsRef<[u8]>,
        doc: &[u8],
    ) -> Result<SecretDocument> {
        let pbes2_params = pbes2::Parameters::recommended(rng);
        EncryptedPrivateKeyInfoOwned::encrypt_with(pbes2_params, password, doc)
    }

    /// Encrypt this private key using a symmetric encryption key derived
    /// from the provided password and [`pbes2::Parameters`].
    #[cfg(feature = "encryption")]
    pub(crate) fn encrypt_with(
        pbes2_params: pbes2::Parameters,
        password: impl AsRef<[u8]>,
        doc: &[u8],
    ) -> Result<SecretDocument> {
        let encrypted_data = pbes2_params.encrypt(password, doc)?;
        let encrypted_data = OctetStringRef::new(&encrypted_data)?;

        EncryptedPrivateKeyInfo {
            encryption_algorithm: pbes2_params.into(),
            encrypted_data,
        }
        .try_into()
    }
}

impl<'a, Data> DecodeValue<'a> for EncryptedPrivateKeyInfo<Data>
where
    Data: DecodeValue<'a, Error = der::Error> + FixedTag + 'a,
{
    type Error = der::Error;

    fn decode_value<R: Reader<'a>>(reader: &mut R, _header: Header) -> der::Result<Self> {
        Ok(Self {
            encryption_algorithm: reader.decode()?,
            encrypted_data: reader.decode()?,
        })
    }
}

impl<Data> EncodeValue for EncryptedPrivateKeyInfo<Data>
where
    Data: EncodeValue + FixedTag,
{
    fn value_len(&self) -> der::Result<Length> {
        self.encryption_algorithm.encoded_len()? + self.encrypted_data.encoded_len()?
    }

    fn encode_value(&self, writer: &mut impl Writer) -> der::Result<()> {
        self.encryption_algorithm.encode(writer)?;
        self.encrypted_data.encode(writer)?;
        Ok(())
    }
}

impl<'a, Data> Sequence<'a> for EncryptedPrivateKeyInfo<Data> where
    Data: DecodeValue<'a, Error = der::Error> + EncodeValue + FixedTag + 'a
{
}

impl<'a, Data> TryFrom<&'a [u8]> for EncryptedPrivateKeyInfo<Data>
where
    Data: DecodeValue<'a, Error = der::Error> + EncodeValue + FixedTag + 'a,
{
    type Error = Error;

    fn try_from(bytes: &'a [u8]) -> Result<Self> {
        Ok(Self::from_der(bytes)?)
    }
}

impl<Data> fmt::Debug for EncryptedPrivateKeyInfo<Data> {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("EncryptedPrivateKeyInfo")
            .field("encryption_algorithm", &self.encryption_algorithm)
            .finish_non_exhaustive()
    }
}

#[cfg(feature = "alloc")]
impl<'a, Data> TryFrom<EncryptedPrivateKeyInfo<Data>> for SecretDocument
where
    Data: DecodeValue<'a, Error = der::Error> + EncodeValue + FixedTag + 'a,
{
    type Error = Error;

    fn try_from(encrypted_private_key: EncryptedPrivateKeyInfo<Data>) -> Result<SecretDocument> {
        SecretDocument::try_from(&encrypted_private_key)
    }
}

#[cfg(feature = "alloc")]
impl<'a, Data> TryFrom<&EncryptedPrivateKeyInfo<Data>> for SecretDocument
where
    Data: DecodeValue<'a, Error = der::Error> + EncodeValue + FixedTag + 'a,
{
    type Error = Error;

    fn try_from(encrypted_private_key: &EncryptedPrivateKeyInfo<Data>) -> Result<SecretDocument> {
        Ok(Self::encode_msg(encrypted_private_key)?)
    }
}

#[cfg(feature = "pem")]
impl<Data> PemLabel for EncryptedPrivateKeyInfo<Data> {
    const PEM_LABEL: &'static str = "ENCRYPTED PRIVATE KEY";
}

/// [`EncryptedPrivateKeyInfo`] with [`OctetStringRef`] encrypted data.
pub type EncryptedPrivateKeyInfoRef<'a> = EncryptedPrivateKeyInfo<&'a OctetStringRef>;

#[cfg(feature = "alloc")]
/// [`EncryptedPrivateKeyInfo`] with [`OctetString`] encrypted data.
pub type EncryptedPrivateKeyInfoOwned = EncryptedPrivateKeyInfo<OctetString>;
