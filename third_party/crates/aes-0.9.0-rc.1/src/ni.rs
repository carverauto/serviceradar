//! AES block ciphers implementation using AES-NI instruction set.
//!
//! Ciphers functionality is accessed using `BlockCipher` trait from the
//! [`cipher`](https://docs.rs/cipher) crate.
//!
//! # Vulnerability
//! Lazy FP state restory vulnerability can allow local process to leak content
//! of the FPU register, in which round keys are stored. This vulnerability
//! can be mitigated at the operating system level by installing relevant
//! patches. (i.e. keep your OS updated!) More info:
//! - [Intel advisory](https://www.intel.com/content/www/us/en/security-center/advisory/intel-sa-00145.html)
//! - [Wikipedia](https://en.wikipedia.org/wiki/Lazy_FP_state_restore)
//!
//! # Related documents
//! - [Intel AES-NI whitepaper](https://software.intel.com/sites/default/files/article/165683/aes-wp-2012-09-22-v01.pdf)
//! - [Use of the AES Instruction Set](https://www.cosic.esat.kuleuven.be/ecrypt/AESday/slides/Use_of_the_AES_Instruction_Set.pdf)

mod encdec;
mod expand;
#[cfg(test)]
mod test_expand;

#[cfg(feature = "hazmat")]
pub(crate) mod hazmat;

#[cfg(target_arch = "x86")]
use core::arch::x86 as arch;
#[cfg(target_arch = "x86_64")]
use core::arch::x86_64 as arch;

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
    par_size = consts::U9,
    expand_keys = expand::aes128_expand_key,
    inv_keys = expand::inv_keys,
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
    par_size = consts::U9,
    expand_keys = expand::aes192_expand_key,
    inv_keys = expand::inv_keys,
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
    par_size = consts::U9,
    expand_keys = expand::aes256_expand_key,
    inv_keys = expand::inv_keys,
    encrypt = encdec::encrypt,
    encrypt_par = encdec::encrypt_par,
    decrypt = encdec::decrypt,
    decrypt_par = encdec::decrypt_par,
);

macro_rules! define_aes_impl {
    (
        $name:tt,
        $name_enc:ident,
        $name_dec:ident,
        $name_back_enc:ident,
        $name_back_dec:ident,
        $key_size:ty,
        $doc:expr $(,)?
    ) => {
        #[doc=$doc]
        #[doc = "block cipher"]
        #[derive(Clone)]
        pub struct $name {
            encrypt: $name_enc,
            decrypt: $name_dec,
        }

        impl $name {
            #[inline(always)]
            pub(crate) fn get_enc_backend(&self) -> &$name_back_enc {
                self.encrypt.get_enc_backend()
            }

            #[inline(always)]
            pub(crate) fn get_dec_backend(&self) -> &$name_back_dec {
                self.decrypt.get_dec_backend()
            }
        }

        impl KeySizeUser for $name {
            type KeySize = $key_size;
        }

        impl KeyInit for $name {
            #[inline]
            fn new(key: &Key<Self>) -> Self {
                let encrypt = $name_enc::new(key);
                let decrypt = $name_dec::from(&encrypt);
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
                let decrypt = (&encrypt).into();
                Self { encrypt, decrypt }
            }
        }

        impl From<&$name_enc> for $name {
            #[inline]
            fn from(encrypt: &$name_enc) -> $name {
                let decrypt = encrypt.into();
                let encrypt = encrypt.clone();
                Self { encrypt, decrypt }
            }
        }

        impl BlockSizeUser for $name {
            type BlockSize = U16;
        }

        impl BlockCipherEncrypt for $name {
            fn encrypt_with_backend(&self, f: impl BlockCipherEncClosure<BlockSize = U16>) {
                self.encrypt.encrypt_with_backend(f)
            }
        }

        impl BlockCipherDecrypt for $name {
            fn decrypt_with_backend(&self, f: impl BlockCipherDecClosure<BlockSize = U16>) {
                self.decrypt.decrypt_with_backend(f)
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
                Self {
                    backend: $name_back_enc::new(key),
                }
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
                    zeroize::zeroize_flat_type(&mut self.backend)
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
                $name_enc::new(key).into()
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
            #[inline]
            fn from(enc: &$name_enc) -> $name_dec {
                Self {
                    backend: enc.backend.clone().into(),
                }
            }
        }

        impl BlockSizeUser for $name_dec {
            type BlockSize = U16;
        }

        impl BlockCipherDecrypt for $name_dec {
            fn decrypt_with_backend(&self, f: impl BlockCipherDecClosure<BlockSize = U16>) {
                f.call(self.get_dec_backend());
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
                    zeroize::zeroize_flat_type(&mut self.backend)
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
    "AES-128",
);

define_aes_impl!(
    Aes192,
    Aes192Enc,
    Aes192Dec,
    Aes192BackEnc,
    Aes192BackDec,
    U24,
    "AES-192",
);

define_aes_impl!(
    Aes256,
    Aes256Enc,
    Aes256Dec,
    Aes256BackEnc,
    Aes256BackDec,
    U32,
    "AES-256",
);
