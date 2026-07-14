//! Triple DES (3DES) block ciphers.

use crate::{Des, utils::gen_keys};
use cipher::{
    AlgorithmName, Block, BlockCipherDecBackend, BlockCipherDecClosure, BlockCipherDecrypt,
    BlockCipherEncBackend, BlockCipherEncClosure, BlockCipherEncrypt, BlockSizeUser, InOut, Key,
    KeyInit, KeySizeUser, ParBlocksSizeUser,
    consts::{U1, U8, U16, U24},
    crypto_common::WeakKeyError,
};
use core::fmt;

#[cfg(feature = "zeroize")]
use cipher::zeroize::ZeroizeOnDrop;

#[inline]
fn weak_key_test2(key: &[u8; 16]) -> Result<(), WeakKeyError> {
    let k1 = u64::from_ne_bytes(key[..8].try_into().unwrap());
    let k2 = u64::from_ne_bytes(key[8..16].try_into().unwrap());

    let mut is_weak = 0u8;
    is_weak |= super::weak_key_test(k1);
    is_weak |= super::weak_key_test(k2);
    is_weak |= u8::from(k1 == k2);

    match is_weak {
        0 => Ok(()),
        _ => Err(WeakKeyError),
    }
}

#[inline]
fn weak_key_test3(key: &[u8; 24]) -> Result<(), WeakKeyError> {
    let k1 = u64::from_ne_bytes(key[..8].try_into().unwrap());
    let k2 = u64::from_ne_bytes(key[8..16].try_into().unwrap());
    let k3 = u64::from_ne_bytes(key[16..24].try_into().unwrap());

    let mut is_weak = 0u8;
    is_weak |= super::weak_key_test(k1);
    is_weak |= super::weak_key_test(k2);
    is_weak |= super::weak_key_test(k3);
    is_weak |= u8::from(k1 == k2);
    is_weak |= u8::from(k1 == k3);
    is_weak |= u8::from(k2 == k3);

    match is_weak {
        0 => Ok(()),
        _ => Err(WeakKeyError),
    }
}

/// Triple DES (3DES) block cipher.
#[derive(Clone)]
pub struct TdesEde3 {
    d1: Des,
    d2: Des,
    d3: Des,
}

impl KeySizeUser for TdesEde3 {
    type KeySize = U24;
}

impl KeyInit for TdesEde3 {
    #[inline]
    fn new(key: &Key<Self>) -> Self {
        let k1 = u64::from_be_bytes(key[0..8].try_into().unwrap());
        let k2 = u64::from_be_bytes(key[8..16].try_into().unwrap());
        let k3 = u64::from_be_bytes(key[16..24].try_into().unwrap());
        let d1 = Des { keys: gen_keys(k1) };
        let d2 = Des { keys: gen_keys(k2) };
        let d3 = Des { keys: gen_keys(k3) };
        Self { d1, d2, d3 }
    }

    #[inline]
    fn weak_key_test(key: &Key<Self>) -> Result<(), WeakKeyError> {
        weak_key_test3(&key.0)
    }
}

impl BlockSizeUser for TdesEde3 {
    type BlockSize = U8;
}

impl ParBlocksSizeUser for TdesEde3 {
    type ParBlocksSize = U1;
}

impl BlockCipherEncrypt for TdesEde3 {
    #[inline]
    fn encrypt_with_backend(&self, f: impl BlockCipherEncClosure<BlockSize = Self::BlockSize>) {
        f.call(self)
    }
}

impl BlockCipherEncBackend for TdesEde3 {
    #[inline]
    fn encrypt_block(&self, mut block: InOut<'_, '_, Block<Self>>) {
        let mut data = u64::from_be_bytes(block.clone_in().into());
        data = self.d1.encrypt(data);
        data = self.d2.decrypt(data);
        data = self.d3.encrypt(data);
        block.get_out().copy_from_slice(&data.to_be_bytes());
    }
}

impl BlockCipherDecrypt for TdesEde3 {
    #[inline]
    fn decrypt_with_backend(&self, f: impl BlockCipherDecClosure<BlockSize = Self::BlockSize>) {
        f.call(self)
    }
}

impl BlockCipherDecBackend for TdesEde3 {
    #[inline]
    fn decrypt_block(&self, mut block: InOut<'_, '_, Block<Self>>) {
        let mut data = u64::from_be_bytes(block.clone_in().into());
        data = self.d3.decrypt(data);
        data = self.d2.encrypt(data);
        data = self.d1.decrypt(data);
        block.get_out().copy_from_slice(&data.to_be_bytes());
    }
}

impl fmt::Debug for TdesEde3 {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("TdesEee3 { ... }")
    }
}

impl AlgorithmName for TdesEde3 {
    fn write_alg_name(f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("TdesEde3")
    }
}

#[cfg(feature = "zeroize")]
impl ZeroizeOnDrop for TdesEde3 {}

/// Triple DES (3DES) block cipher.
#[derive(Clone)]
pub struct TdesEee3 {
    d1: Des,
    d2: Des,
    d3: Des,
}

impl KeySizeUser for TdesEee3 {
    type KeySize = U24;
}

impl KeyInit for TdesEee3 {
    #[inline]
    fn new(key: &Key<Self>) -> Self {
        let k1 = u64::from_be_bytes(key[0..8].try_into().unwrap());
        let k2 = u64::from_be_bytes(key[8..16].try_into().unwrap());
        let k3 = u64::from_be_bytes(key[16..24].try_into().unwrap());
        let d1 = Des { keys: gen_keys(k1) };
        let d2 = Des { keys: gen_keys(k2) };
        let d3 = Des { keys: gen_keys(k3) };
        Self { d1, d2, d3 }
    }

    #[inline]
    fn weak_key_test(key: &Key<Self>) -> Result<(), WeakKeyError> {
        weak_key_test3(&key.0)
    }
}

impl BlockSizeUser for TdesEee3 {
    type BlockSize = U8;
}

impl ParBlocksSizeUser for TdesEee3 {
    type ParBlocksSize = U1;
}

impl BlockCipherEncrypt for TdesEee3 {
    #[inline]
    fn encrypt_with_backend(&self, f: impl BlockCipherEncClosure<BlockSize = Self::BlockSize>) {
        f.call(self)
    }
}

impl BlockCipherEncBackend for TdesEee3 {
    #[inline]
    fn encrypt_block(&self, mut block: InOut<'_, '_, Block<Self>>) {
        let mut data = u64::from_be_bytes(block.clone_in().into());
        data = self.d1.encrypt(data);
        data = self.d2.encrypt(data);
        data = self.d3.encrypt(data);
        block.get_out().copy_from_slice(&data.to_be_bytes());
    }
}

impl BlockCipherDecrypt for TdesEee3 {
    #[inline]
    fn decrypt_with_backend(&self, f: impl BlockCipherDecClosure<BlockSize = Self::BlockSize>) {
        f.call(self)
    }
}

impl BlockCipherDecBackend for TdesEee3 {
    #[inline]
    fn decrypt_block(&self, mut block: InOut<'_, '_, Block<Self>>) {
        let mut data = u64::from_be_bytes(block.clone_in().into());
        data = self.d3.decrypt(data);
        data = self.d2.decrypt(data);
        data = self.d1.decrypt(data);
        block.get_out().copy_from_slice(&data.to_be_bytes());
    }
}

impl fmt::Debug for TdesEee3 {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("TdesEee3 { ... }")
    }
}

impl AlgorithmName for TdesEee3 {
    fn write_alg_name(f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("TdesEee3")
    }
}

#[cfg(feature = "zeroize")]
impl ZeroizeOnDrop for TdesEee3 {}

/// Triple DES (3DES) block cipher.
#[derive(Clone)]
pub struct TdesEde2 {
    d1: Des,
    d2: Des,
}

impl KeySizeUser for TdesEde2 {
    type KeySize = U16;
}

impl KeyInit for TdesEde2 {
    #[inline]
    fn new(key: &Key<Self>) -> Self {
        let k1 = u64::from_be_bytes(key[0..8].try_into().unwrap());
        let k2 = u64::from_be_bytes(key[8..16].try_into().unwrap());
        let d1 = Des { keys: gen_keys(k1) };
        let d2 = Des { keys: gen_keys(k2) };
        Self { d1, d2 }
    }

    #[inline]
    fn weak_key_test(key: &Key<Self>) -> Result<(), WeakKeyError> {
        weak_key_test2(&key.0)
    }
}

impl BlockSizeUser for TdesEde2 {
    type BlockSize = U8;
}

impl ParBlocksSizeUser for TdesEde2 {
    type ParBlocksSize = U1;
}

impl BlockCipherEncrypt for TdesEde2 {
    #[inline]
    fn encrypt_with_backend(&self, f: impl BlockCipherEncClosure<BlockSize = Self::BlockSize>) {
        f.call(self)
    }
}

impl BlockCipherEncBackend for TdesEde2 {
    #[inline]
    fn encrypt_block(&self, mut block: InOut<'_, '_, Block<Self>>) {
        let mut data = u64::from_be_bytes(block.clone_in().into());
        data = self.d1.encrypt(data);
        data = self.d2.decrypt(data);
        data = self.d1.encrypt(data);
        block.get_out().copy_from_slice(&data.to_be_bytes());
    }
}

impl BlockCipherDecrypt for TdesEde2 {
    #[inline]
    fn decrypt_with_backend(&self, f: impl BlockCipherDecClosure<BlockSize = Self::BlockSize>) {
        f.call(self)
    }
}

impl BlockCipherDecBackend for TdesEde2 {
    #[inline]
    fn decrypt_block(&self, mut block: InOut<'_, '_, Block<Self>>) {
        let mut data = u64::from_be_bytes(block.clone_in().into());
        data = self.d1.decrypt(data);
        data = self.d2.encrypt(data);
        data = self.d1.decrypt(data);
        block.get_out().copy_from_slice(&data.to_be_bytes());
    }
}

impl fmt::Debug for TdesEde2 {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("TdesEde2 { ... }")
    }
}

impl AlgorithmName for TdesEde2 {
    fn write_alg_name(f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("TdesEde2")
    }
}

#[cfg(feature = "zeroize")]
impl ZeroizeOnDrop for TdesEde2 {}

/// Triple DES (3DES) block cipher.
#[derive(Clone)]
pub struct TdesEee2 {
    d1: Des,
    d2: Des,
}

impl KeySizeUser for TdesEee2 {
    type KeySize = U16;
}

impl KeyInit for TdesEee2 {
    #[inline]
    fn new(key: &Key<Self>) -> Self {
        let k1 = u64::from_be_bytes(key[0..8].try_into().unwrap());
        let k2 = u64::from_be_bytes(key[8..16].try_into().unwrap());
        let d1 = Des { keys: gen_keys(k1) };
        let d2 = Des { keys: gen_keys(k2) };
        Self { d1, d2 }
    }

    #[inline]
    fn weak_key_test(key: &Key<Self>) -> Result<(), WeakKeyError> {
        weak_key_test2(&key.0)
    }
}

impl BlockSizeUser for TdesEee2 {
    type BlockSize = U8;
}

impl ParBlocksSizeUser for TdesEee2 {
    type ParBlocksSize = U1;
}

impl BlockCipherEncrypt for TdesEee2 {
    #[inline]
    fn encrypt_with_backend(&self, f: impl BlockCipherEncClosure<BlockSize = Self::BlockSize>) {
        f.call(self)
    }
}

impl BlockCipherEncBackend for TdesEee2 {
    #[inline]
    fn encrypt_block(&self, mut block: InOut<'_, '_, Block<Self>>) {
        let mut data = u64::from_be_bytes(block.clone_in().into());
        data = self.d1.encrypt(data);
        data = self.d2.encrypt(data);
        data = self.d1.encrypt(data);
        block.get_out().copy_from_slice(&data.to_be_bytes());
    }
}

impl BlockCipherDecrypt for TdesEee2 {
    #[inline]
    fn decrypt_with_backend(&self, f: impl BlockCipherDecClosure<BlockSize = Self::BlockSize>) {
        f.call(self)
    }
}

impl BlockCipherDecBackend for TdesEee2 {
    #[inline]
    fn decrypt_block(&self, mut block: InOut<'_, '_, Block<Self>>) {
        let mut data = u64::from_be_bytes(block.clone_in().into());
        data = self.d1.decrypt(data);
        data = self.d2.decrypt(data);
        data = self.d1.decrypt(data);
        block.get_out().copy_from_slice(&data.to_be_bytes());
    }
}

impl fmt::Debug for TdesEee2 {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("TdesEee2 { ... }")
    }
}

impl AlgorithmName for TdesEee2 {
    fn write_alg_name(f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("TdesEee2")
    }
}

#[cfg(feature = "zeroize")]
impl ZeroizeOnDrop for TdesEee2 {}
