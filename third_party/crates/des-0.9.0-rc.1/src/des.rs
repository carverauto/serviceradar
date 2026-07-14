//! Data Encryption Standard (DES) block cipher.

#![allow(clippy::unreadable_literal)]

use cipher::{
    AlgorithmName, Block, BlockCipherDecBackend, BlockCipherDecClosure, BlockCipherDecrypt,
    BlockCipherEncBackend, BlockCipherEncClosure, BlockCipherEncrypt, BlockSizeUser, InOut, Key,
    KeyInit, KeySizeUser, ParBlocksSizeUser,
    consts::{U1, U8},
    crypto_common::WeakKeyError,
};
use core::fmt;

#[cfg(feature = "zeroize")]
use cipher::zeroize::{Zeroize, ZeroizeOnDrop};

use crate::utils::{fp, gen_keys, ip, round};

/// Data Encryption Standard (DES) block cipher.
#[derive(Clone)]
pub struct Des {
    pub(crate) keys: [u64; 16],
}

impl Des {
    pub(crate) fn encrypt(&self, mut data: u64) -> u64 {
        data = ip(data);
        for key in &self.keys {
            data = round(data, *key);
        }
        fp(data.rotate_right(32))
    }

    pub(crate) fn decrypt(&self, mut data: u64) -> u64 {
        data = ip(data);
        for key in self.keys.iter().rev() {
            data = round(data, *key);
        }
        fp(data.rotate_right(32))
    }
}

impl KeySizeUser for Des {
    type KeySize = U8;
}

impl KeyInit for Des {
    #[inline]
    fn new(key: &Key<Self>) -> Self {
        let keys = gen_keys(u64::from_be_bytes(key.0));
        Self { keys }
    }

    #[inline]
    fn weak_key_test(key: &Key<Self>) -> Result<(), WeakKeyError> {
        let key = u64::from_ne_bytes(key.0);
        match super::weak_key_test(key) {
            0 => Ok(()),
            _ => Err(WeakKeyError),
        }
    }
}

impl BlockSizeUser for Des {
    type BlockSize = U8;
}

impl ParBlocksSizeUser for Des {
    type ParBlocksSize = U1;
}

impl BlockCipherEncrypt for Des {
    #[inline]
    fn encrypt_with_backend(&self, f: impl BlockCipherEncClosure<BlockSize = Self::BlockSize>) {
        f.call(self)
    }
}

impl BlockCipherEncBackend for Des {
    #[inline]
    fn encrypt_block(&self, mut block: InOut<'_, '_, Block<Self>>) {
        let mut data = u64::from_be_bytes(block.clone_in().into());
        data = self.encrypt(data);
        block.get_out().copy_from_slice(&data.to_be_bytes());
    }
}

impl BlockCipherDecrypt for Des {
    #[inline]
    fn decrypt_with_backend(&self, f: impl BlockCipherDecClosure<BlockSize = Self::BlockSize>) {
        f.call(self)
    }
}

impl BlockCipherDecBackend for Des {
    #[inline]
    fn decrypt_block(&self, mut block: InOut<'_, '_, Block<Self>>) {
        let mut data = u64::from_be_bytes(block.clone_in().into());
        data = self.decrypt(data);
        block.get_out().copy_from_slice(&data.to_be_bytes());
    }
}

impl fmt::Debug for Des {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("Des { ... }")
    }
}

impl AlgorithmName for Des {
    fn write_alg_name(f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("Des")
    }
}

impl Drop for Des {
    fn drop(&mut self) {
        #[cfg(feature = "zeroize")]
        self.keys.zeroize();
    }
}

#[cfg(feature = "zeroize")]
impl ZeroizeOnDrop for Des {}
