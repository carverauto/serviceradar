//! AES block cipher implementation using the ARMv8 Cryptography Extensions.
//!
//! Based on this C intrinsics implementation:
//! <https://github.com/noloader/AES-Intrinsics/blob/master/aes-arm.c>
//!
//! Original C written and placed in public domain by Jeffrey Walton.
//! Based on code from ARM, and by Johannes Schneiders, Skip Hovsmith and
//! Barry O'Rourke for the mbedTLS project.

#![allow(clippy::needless_range_loop)]

#[cfg(feature = "hazmat")]
pub(crate) mod hazmat;

mod encdec;
mod expand;
#[cfg(test)]
mod test_expand;

use cipher::{
    AlgorithmName, BlockCipherDecClosure, BlockCipherDecrypt, BlockCipherEncClosure,
    BlockCipherEncrypt, BlockSizeUser, Key, KeyInit, KeySizeUser,
    consts::{self, U16, U24, U32},
    crypto_common::WeakKeyError,
};
use core::fmt;

impl_backends!(
    enc_name = Aes128BackEnc,
    dec_name = Aes128BackDec,
    key_size = consts::U16,
    keys_ty = expand::Aes128RoundKeys,
    par_size = consts::U21,
    expand_keys = expand::expand_key,
    inv_keys = expand::inv_expanded_keys,
    encrypt = encdec::encrypt,
    encrypt_par = encdec::encrypt_par,
    decrypt = encdec::decrypt,
    decrypt_par = encdec::decrypt_par,
);

impl_backends!(
    enc_name = Aes192BackEnc,
    dec_name = Aes192BackDec,
    key_size = consts::U24,
    keys_ty = expand::Aes192RoundKeys,
    par_size = consts::U19,
    expand_keys = expand::expand_key,
    inv_keys = expand::inv_expanded_keys,
    encrypt = encdec::encrypt,
    encrypt_par = encdec::encrypt_par,
    decrypt = encdec::decrypt,
    decrypt_par = encdec::decrypt_par,
);

impl_backends!(
    enc_name = Aes256BackEnc,
    dec_name = Aes256BackDec,
    key_size = consts::U32,
    keys_ty = expand::Aes256RoundKeys,
    par_size = consts::U17,
    expand_keys = expand::expand_key,
    inv_keys = expand::inv_expanded_keys,
    encrypt = encdec::encrypt,
    encrypt_par = encdec::encrypt_par,
    decrypt = encdec::decrypt,
    decrypt_par = encdec::decrypt_par,
);

macro_rules! define_aes_impl {
    (
        $name:ident,
        $name_enc:ident,
        $name_dec:ident,
        $name_back_enc:ident,
        $name_back_dec:ident,
        $key_size:ty,
        $rounds:tt,
        $doc:expr $(,)?
    ) => {
        #[doc=$doc]
        #[doc = "block cipher"]
        #[derive(Clone)]
        pub struct $name {
            encrypt: $name_back_enc,
            decrypt: $name_back_dec,
        }

        impl $name {
            #[inline(always)]
            pub(crate) fn get_enc_backend(&self) -> &$name_back_enc {
                &self.encrypt
            }

            #[inline(always)]
            pub(crate) fn get_dec_backend(&self) -> &$name_back_dec {
                &self.decrypt
            }
        }

        impl KeySizeUser for $name {
            type KeySize = $key_size;
        }

        impl KeyInit for $name {
            #[inline]
            fn new(key: &Key<Self>) -> Self {
                let encrypt = $name_back_enc::new(key);
                let decrypt = $name_back_dec::from(encrypt.clone());
                Self { encrypt, decrypt }
            }

            #[inline]
            fn weak_key_test(key: &Key<Self>) -> Result<(), WeakKeyError> {
                crate::weak_key_test(&key.0)
            }
        }

        impl From<$name_enc> for $name {
            #[inline]
            fn from(encrypt: $name_enc) -> $name {
                let encrypt = encrypt.backend.clone();
                let decrypt = encrypt.clone().into();
                Self { encrypt, decrypt }
            }
        }

        impl From<&$name_enc> for $name {
            #[inline]
            fn from(encrypt: &$name_enc) -> $name {
                let encrypt = encrypt.backend.clone();
                let decrypt = encrypt.clone().into();
                Self { encrypt, decrypt }
            }
        }

        impl BlockSizeUser for $name {
            type BlockSize = U16;
        }

        impl BlockCipherEncrypt for $name {
            fn encrypt_with_backend(&self, f: impl BlockCipherEncClosure<BlockSize = U16>) {
                f.call(&self.encrypt)
            }
        }

        impl BlockCipherDecrypt for $name {
            fn decrypt_with_backend(&self, f: impl BlockCipherDecClosure<BlockSize = U16>) {
                f.call(&self.decrypt)
            }
        }

        impl fmt::Debug for $name {
            fn fmt(&self, f: &mut fmt::Formatter<'_>) -> Result<(), fmt::Error> {
                f.write_str(concat!(stringify!($name), " { .. }"))
            }
        }

        impl AlgorithmName for $name {
            fn write_alg_name(f: &mut fmt::Formatter<'_>) -> fmt::Result {
                f.write_str(stringify!($name))
            }
        }

        impl Drop for $name {
            #[inline]
            fn drop(&mut self) {
                #[cfg(feature = "zeroize")]
                unsafe {
                    zeroize::zeroize_flat_type(self);
                }
            }
        }

        #[cfg(feature = "zeroize")]
        impl zeroize::ZeroizeOnDrop for $name {}

        #[doc=$doc]
        #[doc = "block cipher (encrypt-only)"]
        #[derive(Clone)]
        pub struct $name_enc {
            backend: $name_back_enc,
        }

        impl $name_enc {
            #[inline(always)]
            pub(crate) fn get_enc_backend(&self) -> &$name_back_enc {
                &self.backend
            }
        }

        impl KeySizeUser for $name_enc {
            type KeySize = $key_size;
        }

        impl KeyInit for $name_enc {
            #[inline]
            fn new(key: &Key<Self>) -> Self {
                let backend = $name_back_enc::new(key);
                Self { backend }
            }

            #[inline]
            fn weak_key_test(key: &Key<Self>) -> Result<(), WeakKeyError> {
                crate::weak_key_test(&key.0)
            }
        }

        impl BlockSizeUser for $name_enc {
            type BlockSize = U16;
        }

        impl BlockCipherEncrypt for $name_enc {
            fn encrypt_with_backend(&self, f: impl BlockCipherEncClosure<BlockSize = U16>) {
                f.call(&self.backend)
            }
        }

        impl fmt::Debug for $name_enc {
            fn fmt(&self, f: &mut fmt::Formatter<'_>) -> Result<(), fmt::Error> {
                f.write_str(concat!(stringify!($name_enc), " { .. }"))
            }
        }

        impl AlgorithmName for $name_enc {
            fn write_alg_name(f: &mut fmt::Formatter<'_>) -> fmt::Result {
                f.write_str(stringify!($name_enc))
            }
        }

        impl Drop for $name_enc {
            #[inline]
            fn drop(&mut self) {
                #[cfg(feature = "zeroize")]
                unsafe {
                    zeroize::zeroize_flat_type(self);
                }
            }
        }

        #[cfg(feature = "zeroize")]
        impl zeroize::ZeroizeOnDrop for $name_enc {}

        #[doc=$doc]
        #[doc = "block cipher (decrypt-only)"]
        #[derive(Clone)]
        pub struct $name_dec {
            backend: $name_back_dec,
        }

        impl $name_dec {
            #[inline(always)]
            pub(crate) fn get_dec_backend(&self) -> &$name_back_dec {
                &self.backend
            }
        }

        impl KeySizeUser for $name_dec {
            type KeySize = $key_size;
        }

        impl KeyInit for $name_dec {
            #[inline]
            fn new(key: &Key<Self>) -> Self {
                let encrypt = $name_back_enc::new(key);
                let backend = encrypt.clone().into();
                Self { backend }
            }

            #[inline]
            fn weak_key_test(key: &Key<Self>) -> Result<(), WeakKeyError> {
                crate::weak_key_test(&key.0)
            }
        }

        impl From<$name_enc> for $name_dec {
            #[inline]
            fn from(enc: $name_enc) -> $name_dec {
                Self::from(&enc)
            }
        }

        impl From<&$name_enc> for $name_dec {
            fn from(encrypt: &$name_enc) -> $name_dec {
                let backend = encrypt.backend.clone().into();
                Self { backend }
            }
        }

        impl BlockSizeUser for $name_dec {
            type BlockSize = U16;
        }

        impl BlockCipherDecrypt for $name_dec {
            fn decrypt_with_backend(&self, f: impl BlockCipherDecClosure<BlockSize = U16>) {
                f.call(&self.backend);
            }
        }

        impl fmt::Debug for $name_dec {
            fn fmt(&self, f: &mut fmt::Formatter<'_>) -> Result<(), fmt::Error> {
                f.write_str(concat!(stringify!($name_dec), " { .. }"))
            }
        }

        impl AlgorithmName for $name_dec {
            fn write_alg_name(f: &mut fmt::Formatter<'_>) -> fmt::Result {
                f.write_str(stringify!($name_dec))
            }
        }

        impl Drop for $name_dec {
            #[inline]
            fn drop(&mut self) {
                #[cfg(feature = "zeroize")]
                unsafe {
                    zeroize::zeroize_flat_type(self);
                }
            }
        }

        #[cfg(feature = "zeroize")]
        impl zeroize::ZeroizeOnDrop for $name_dec {}
    };
}

define_aes_impl!(
    Aes128,
    Aes128Enc,
    Aes128Dec,
    Aes128BackEnc,
    Aes128BackDec,
    U16,
    11,
    "AES-128",
);
define_aes_impl!(
    Aes192,
    Aes192Enc,
    Aes192Dec,
    Aes192BackEnc,
    Aes192BackDec,
    U24,
    13,
    "AES-192",
);
define_aes_impl!(
    Aes256,
    Aes256Enc,
    Aes256Dec,
    Aes256BackEnc,
    Aes256BackDec,
    U32,
    15,
    "AES-256",
);
