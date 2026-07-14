#![no_std]
#![cfg_attr(docsrs, feature(doc_auto_cfg))]
#![doc = include_str!("../README.md")]
#![doc(
    html_logo_url = "https://raw.githubusercontent.com/RustCrypto/media/8f1a9894/logo.svg",
    html_favicon_url = "https://raw.githubusercontent.com/RustCrypto/media/8f1a9894/logo.svg"
)]
#![forbid(unsafe_code)]
#![warn(
    clippy::unwrap_used,
    missing_docs,
    rust_2018_idioms,
    missing_debug_implementations
)]

#[cfg(feature = "alloc")]
extern crate alloc;

#[cfg(feature = "dev")]
pub mod dev;

pub use crypto_common::{
    Key, KeyInit, KeySizeUser,
    array::{self, typenum::consts},
};

#[cfg(feature = "arrayvec")]
pub use arrayvec;
#[cfg(feature = "bytes")]
pub use bytes;
#[cfg(feature = "rand_core")]
pub use crypto_common::rand_core;
#[cfg(feature = "heapless")]
pub use heapless;
pub use inout;

use core::fmt;
use crypto_common::array::{Array, ArraySize, typenum::Unsigned};
use inout::InOutBuf;

#[cfg(feature = "alloc")]
use alloc::vec::Vec;
#[cfg(feature = "bytes")]
use bytes::BytesMut;
#[cfg(feature = "os_rng")]
use crypto_common::rand_core::{OsError, OsRng, TryRngCore};
#[cfg(feature = "rand_core")]
use rand_core::{CryptoRng, TryCryptoRng};

/// Error type.
///
/// This type is deliberately opaque as to avoid potential side-channel
/// leakage (e.g. padding oracle).
#[derive(Clone, Copy, Debug, Eq, Hash, Ord, PartialEq, PartialOrd)]
pub struct Error;

/// Result type alias with [`Error`].
pub type Result<T> = core::result::Result<T, Error>;

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("aead::Error")
    }
}

impl core::error::Error for Error {}

/// Nonce: single-use value for ensuring ciphertexts are unique
pub type Nonce<A> = Array<u8, <A as AeadCore>::NonceSize>;

/// Tag: authentication code which ensures ciphertexts are authentic
pub type Tag<A> = Array<u8, <A as AeadCore>::TagSize>;

/// Enum which specifies tag position used by an AEAD algorithm.
#[derive(Debug, Clone, Copy, Eq, PartialEq)]
pub enum TagPosition {
    /// Postfix tag
    Postfix,
    /// Prefix tag
    Prefix,
}

/// Authenticated Encryption with Associated Data (AEAD) algorithm.
pub trait AeadCore {
    /// The length of a nonce.
    type NonceSize: ArraySize;

    /// The maximum length of the tag.
    type TagSize: ArraySize;

    /// The AEAD tag position.
    const TAG_POSITION: TagPosition;

    /// Generate a random nonce for this AEAD algorithm.
    ///
    /// AEAD algorithms accept a parameter to encryption/decryption called
    /// a "nonce" which must be unique every time encryption is performed and
    /// never repeated for the same key. The nonce is often prepended to the
    /// ciphertext. The nonce used to produce a given ciphertext must be passed
    /// to the decryption function in order for it to decrypt correctly.
    ///
    /// Nonces don't necessarily have to be random, but it is one strategy
    /// which is implemented by this function.
    ///
    /// # ⚠️Security Warning
    ///
    /// AEAD algorithms often fail catastrophically if nonces are ever repeated
    /// (with SIV modes being an exception).
    ///
    /// Using random nonces runs the risk of repeating them unless the nonce
    /// size is particularly large (e.g. 192-bit extended nonces used by the
    /// `XChaCha20Poly1305` and `XSalsa20Poly1305` constructions.
    ///
    /// [NIST SP 800-38D] recommends the following:
    ///
    /// > The total number of invocations of the authenticated encryption
    /// > function shall not exceed 2^32, including all IV lengths and all
    /// > instances of the authenticated encryption function with the given key.
    ///
    /// Following this guideline, only 4,294,967,296 messages with random
    /// nonces can be encrypted under a given key. While this bound is high,
    /// it's possible to encounter in practice, and systems which might
    /// reach it should consider alternatives to purely random nonces, like
    /// a counter or a combination of a random nonce + counter.
    ///
    /// See the [`aead-stream`] crate for a ready-made implementation of the latter.
    ///
    /// [NIST SP 800-38D]: https://csrc.nist.gov/publications/detail/sp/800-38d/final
    /// [`aead-stream`]: https://docs.rs/aead-stream
    #[cfg(feature = "os_rng")]
    fn generate_nonce() -> core::result::Result<Nonce<Self>, OsError> {
        let mut nonce = Nonce::<Self>::default();
        OsRng.try_fill_bytes(&mut nonce)?;
        Ok(nonce)
    }

    /// Generate a random nonce for this AEAD algorithm using the specified [`CryptoRng`].
    ///
    /// See [`AeadCore::generate_nonce`] documentation for requirements for
    /// random nonces.
    #[cfg(feature = "rand_core")]
    fn generate_nonce_with_rng<R: CryptoRng + ?Sized>(rng: &mut R) -> Nonce<Self> {
        let mut nonce = Nonce::<Self>::default();
        rng.fill_bytes(&mut nonce);
        nonce
    }

    /// Generate a random nonce for this AEAD algorithm using the specified [`TryCryptoRng`].
    ///
    /// See [`AeadCore::generate_nonce`] documentation for requirements for
    /// random nonces.
    #[cfg(feature = "rand_core")]
    fn try_generate_nonce_with_rng<R: TryCryptoRng + ?Sized>(
        rng: &mut R,
    ) -> core::result::Result<Nonce<Self>, R::Error> {
        let mut nonce = Nonce::<Self>::default();
        rng.try_fill_bytes(&mut nonce)?;
        Ok(nonce)
    }
}

/// Authenticated Encryption with Associated Data (AEAD) algorithm.
#[cfg(feature = "alloc")]
pub trait Aead: AeadCore {
    /// Encrypt the given plaintext payload, and return the resulting
    /// ciphertext as a vector of bytes.
    ///
    /// The [`Payload`] type can be used to provide Additional Associated Data
    /// (AAD) along with the message: this is an optional bytestring which is
    /// not encrypted, but *is* authenticated along with the message. Failure
    /// to pass the same AAD that was used during encryption will cause
    /// decryption to fail, which is useful if you would like to "bind" the
    /// ciphertext to some other identifier, like a digital signature key
    /// or other identifier.
    ///
    /// If you don't care about AAD and just want to encrypt a plaintext
    /// message, `&[u8]` will automatically be coerced into a `Payload`:
    ///
    /// ```nobuild
    /// let plaintext = b"Top secret message, handle with care";
    /// let ciphertext = cipher.encrypt(nonce, plaintext);
    /// ```
    ///
    /// The default implementation assumes a postfix tag (ala AES-GCM,
    /// AES-GCM-SIV, ChaCha20Poly1305). [`Aead`] implementations which do not
    /// use a postfix tag will need to override this to correctly assemble the
    /// ciphertext message.
    fn encrypt<'msg, 'aad>(
        &self,
        nonce: &Nonce<Self>,
        plaintext: impl Into<Payload<'msg, 'aad>>,
    ) -> Result<Vec<u8>>;

    /// Decrypt the given ciphertext slice, and return the resulting plaintext
    /// as a vector of bytes.
    ///
    /// See notes on [`Aead::encrypt()`] about allowable message payloads and
    /// Associated Additional Data (AAD).
    ///
    /// If you have no AAD, you can call this as follows:
    ///
    /// ```nobuild
    /// let ciphertext = b"...";
    /// let plaintext = cipher.decrypt(nonce, ciphertext)?;
    /// ```
    ///
    /// The default implementation assumes a postfix tag (ala AES-GCM,
    /// AES-GCM-SIV, ChaCha20Poly1305). [`Aead`] implementations which do not
    /// use a postfix tag will need to override this to correctly parse the
    /// ciphertext message.
    fn decrypt<'msg, 'aad>(
        &self,
        nonce: &Nonce<Self>,
        ciphertext: impl Into<Payload<'msg, 'aad>>,
    ) -> Result<Vec<u8>>;
}

#[cfg(feature = "alloc")]
impl<T: AeadInOut> Aead for T {
    fn encrypt<'msg, 'aad>(
        &self,
        nonce: &Nonce<Self>,
        plaintext: impl Into<Payload<'msg, 'aad>>,
    ) -> Result<Vec<u8>> {
        let payload = plaintext.into();
        let mut buffer = Vec::with_capacity(payload.msg.len() + Self::TagSize::to_usize());
        buffer.extend_from_slice(payload.msg);
        self.encrypt_in_place(nonce, payload.aad, &mut buffer)?;
        Ok(buffer)
    }

    fn decrypt<'msg, 'aad>(
        &self,
        nonce: &Nonce<Self>,
        ciphertext: impl Into<Payload<'msg, 'aad>>,
    ) -> Result<Vec<u8>> {
        let payload = ciphertext.into();
        let mut buffer = Vec::from(payload.msg);
        self.decrypt_in_place(nonce, payload.aad, &mut buffer)?;
        Ok(buffer)
    }
}

/// In-place and inout AEAD trait which handles the authentication tag as a return value/separate parameter.
pub trait AeadInOut: AeadCore {
    /// Encrypt the data in the provided [`InOutBuf`], returning the authentication tag.
    fn encrypt_inout_detached(
        &self,
        nonce: &Nonce<Self>,
        associated_data: &[u8],
        buffer: InOutBuf<'_, '_, u8>,
    ) -> Result<Tag<Self>>;

    /// Decrypt the data in the provided [`InOutBuf`], returning an error in the event the
    /// provided authentication tag is invalid for the given ciphertext (i.e. ciphertext
    /// is modified/unauthentic)
    fn decrypt_inout_detached(
        &self,
        nonce: &Nonce<Self>,
        associated_data: &[u8],
        buffer: InOutBuf<'_, '_, u8>,
        tag: &Tag<Self>,
    ) -> Result<()>;

    /// Encrypt the given buffer containing a plaintext message in-place.
    ///
    /// The buffer must have sufficient capacity to store the ciphertext
    /// message, which will always be larger than the original plaintext.
    /// The exact size needed is cipher-dependent, but generally includes
    /// the size of an authentication tag.
    ///
    /// Returns an error if the buffer has insufficient capacity to store the
    /// resulting ciphertext message.
    fn encrypt_in_place(
        &self,
        nonce: &Nonce<Self>,
        associated_data: &[u8],
        buffer: &mut dyn Buffer,
    ) -> Result<()> {
        match Self::TAG_POSITION {
            TagPosition::Prefix => {
                let msg_len = buffer.len();
                buffer.extend_from_slice(&Tag::<Self>::default())?;
                let buffer = buffer.as_mut();
                let tag_size = Self::TagSize::USIZE;
                buffer.copy_within(..msg_len, tag_size);
                let (tag_dst, msg) = buffer.split_at_mut(tag_size);
                let tag = self.encrypt_inout_detached(nonce, associated_data, msg.into())?;
                tag_dst.copy_from_slice(&tag);
            }
            TagPosition::Postfix => {
                let tag =
                    self.encrypt_inout_detached(nonce, associated_data, buffer.as_mut().into())?;
                buffer.extend_from_slice(tag.as_slice())?;
            }
        }
        Ok(())
    }

    /// Decrypt the message in-place, returning an error in the event the
    /// provided authentication tag does not match the given ciphertext.
    ///
    /// The buffer will be truncated to the length of the original plaintext
    /// message upon success.
    fn decrypt_in_place(
        &self,
        nonce: &Nonce<Self>,
        associated_data: &[u8],
        buffer: &mut dyn Buffer,
    ) -> Result<()> {
        let tag_size = Self::TagSize::USIZE;
        let tagless_len = buffer.len().checked_sub(tag_size).ok_or(Error)?;

        match Self::TAG_POSITION {
            TagPosition::Prefix => {
                let (tag, msg) = buffer.as_mut().split_at_mut(tag_size);
                let tag = Tag::<Self>::try_from(&*tag).expect("tag length mismatch");
                self.decrypt_inout_detached(nonce, associated_data, msg.into(), &tag)?;
                buffer.as_mut().copy_within(tag_size.., 0);
            }
            TagPosition::Postfix => {
                let (msg, tag) = buffer.as_mut().split_at_mut(tagless_len);
                let tag = Tag::<Self>::try_from(&*tag).expect("tag length mismatch");
                self.decrypt_inout_detached(nonce, associated_data, msg.into(), &tag)?;
            }
        }
        buffer.truncate(tagless_len);
        Ok(())
    }
}

/// Legacy in-place stateless AEAD trait.
///
/// NOTE: deprecated! Please migrate to [`AeadInOut`].
#[deprecated(since = "0.6.0", note = "use `AeadInOut` instead")]
pub trait AeadInPlace: AeadCore {
    /// Encrypt the given buffer containing a plaintext message in-place.
    #[deprecated(since = "0.6.0", note = "use `AeadInOut::encrypt_in_place` instead")]
    fn encrypt_in_place(
        &self,
        nonce: &Nonce<Self>,
        associated_data: &[u8],
        buffer: &mut dyn Buffer,
    ) -> Result<()>;

    /// Encrypt the data in-place, returning the authentication tag
    #[deprecated(
        since = "0.6.0",
        note = "use `AeadInOut::encrypt_inout_detached` instead"
    )]
    fn encrypt_in_place_detached(
        &self,
        nonce: &Nonce<Self>,
        associated_data: &[u8],
        buffer: &mut [u8],
    ) -> Result<Tag<Self>>;

    /// Decrypt the message in-place, returning an error in the event the
    /// provided authentication tag does not match the given ciphertext.
    #[deprecated(since = "0.6.0", note = "use `AeadInOut::decrypt_in_place` instead")]
    fn decrypt_in_place(
        &self,
        nonce: &Nonce<Self>,
        associated_data: &[u8],
        buffer: &mut dyn Buffer,
    ) -> Result<()>;

    /// Decrypt the message in-place, returning an error in the event the provided
    /// authentication tag does not match the given ciphertext (i.e. ciphertext
    /// is modified/unauthentic)
    #[deprecated(
        since = "0.6.0",
        note = "use `AeadInOut::decrypt_inout_detached` instead"
    )]
    fn decrypt_in_place_detached(
        &self,
        nonce: &Nonce<Self>,
        associated_data: &[u8],
        buffer: &mut [u8],
        tag: &Tag<Self>,
    ) -> Result<()>;
}

#[allow(deprecated)]
impl<T: AeadInOut> AeadInPlace for T {
    fn encrypt_in_place(
        &self,
        nonce: &Nonce<Self>,
        associated_data: &[u8],
        buffer: &mut dyn Buffer,
    ) -> Result<()> {
        <Self as AeadInOut>::encrypt_in_place(self, nonce, associated_data, buffer)
    }

    fn encrypt_in_place_detached(
        &self,
        nonce: &Nonce<Self>,
        associated_data: &[u8],
        buffer: &mut [u8],
    ) -> Result<Tag<Self>> {
        self.encrypt_inout_detached(nonce, associated_data, buffer.into())
    }

    fn decrypt_in_place(
        &self,
        nonce: &Nonce<Self>,
        associated_data: &[u8],
        buffer: &mut dyn Buffer,
    ) -> Result<()> {
        <Self as AeadInOut>::decrypt_in_place(self, nonce, associated_data, buffer)
    }

    fn decrypt_in_place_detached(
        &self,
        nonce: &Nonce<Self>,
        associated_data: &[u8],
        buffer: &mut [u8],
        tag: &Tag<Self>,
    ) -> Result<()> {
        self.decrypt_inout_detached(nonce, associated_data, buffer.into(), tag)
    }
}

/// AEAD payloads (message + AAD).
///
/// Combination of a message (plaintext or ciphertext) and
/// "additional associated data" (AAD) to be authenticated (in cleartext)
/// along with the message.
///
/// If you don't care about AAD, you can pass a `&[u8]` as the payload to
/// `encrypt`/`decrypt` and it will automatically be coerced to this type.
#[derive(Debug)]
pub struct Payload<'msg, 'aad> {
    /// Message to be encrypted/decrypted
    pub msg: &'msg [u8],

    /// Optional "additional associated data" to authenticate along with
    /// this message. If AAD is provided at the time the message is encrypted,
    /// the same AAD *MUST* be provided at the time the message is decrypted,
    /// or decryption will fail.
    pub aad: &'aad [u8],
}

impl<'msg> From<&'msg [u8]> for Payload<'msg, '_> {
    fn from(msg: &'msg [u8]) -> Self {
        Self { msg, aad: b"" }
    }
}

/// In-place encryption/decryption byte buffers.
///
/// This trait defines the set of methods needed to support in-place operations
/// on a `Vec`-like data type.
pub trait Buffer: AsRef<[u8]> + AsMut<[u8]> {
    /// Get the length of the buffer
    fn len(&self) -> usize {
        self.as_ref().len()
    }

    /// Is the buffer empty?
    fn is_empty(&self) -> bool {
        self.as_ref().is_empty()
    }

    /// Extend this buffer from the given slice
    fn extend_from_slice(&mut self, other: &[u8]) -> Result<()>;

    /// Truncate this buffer to the given size
    fn truncate(&mut self, len: usize);
}

#[cfg(feature = "alloc")]
impl Buffer for Vec<u8> {
    fn extend_from_slice(&mut self, other: &[u8]) -> Result<()> {
        Vec::extend_from_slice(self, other);
        Ok(())
    }

    fn truncate(&mut self, len: usize) {
        Vec::truncate(self, len);
    }
}

#[cfg(feature = "bytes")]
impl Buffer for BytesMut {
    fn len(&self) -> usize {
        BytesMut::len(self)
    }

    fn is_empty(&self) -> bool {
        BytesMut::is_empty(self)
    }

    fn extend_from_slice(&mut self, other: &[u8]) -> Result<()> {
        BytesMut::extend_from_slice(self, other);
        Ok(())
    }

    fn truncate(&mut self, len: usize) {
        BytesMut::truncate(self, len);
    }
}

#[cfg(feature = "arrayvec")]
impl<const N: usize> Buffer for arrayvec::ArrayVec<u8, N> {
    fn extend_from_slice(&mut self, other: &[u8]) -> Result<()> {
        arrayvec::ArrayVec::try_extend_from_slice(self, other).map_err(|_| Error)
    }

    fn truncate(&mut self, len: usize) {
        arrayvec::ArrayVec::truncate(self, len);
    }
}

#[cfg(feature = "heapless")]
impl<const N: usize> Buffer for heapless::Vec<u8, N> {
    fn extend_from_slice(&mut self, other: &[u8]) -> Result<()> {
        heapless::Vec::extend_from_slice(self, other).map_err(|_| Error)
    }

    fn truncate(&mut self, len: usize) {
        heapless::Vec::truncate(self, len);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Ensure that `Aead` is `dyn`-compatible
    #[cfg(feature = "alloc")]
    #[allow(dead_code)]
    type DynAead<N, T> = dyn Aead<NonceSize = N, TagSize = T>;

    /// Ensure that `AeadInOut` is `dyn`-compatible
    #[allow(dead_code)]
    type DynAeadInOut<N, T> = dyn AeadInOut<NonceSize = N, TagSize = T>;
}
