//! Triple DES (3DES) block ciphers.

use crate::des::{gen_keys, Des};
use cipher::{
    consts::{U16, U24, U8},
    AlgorithmName, BlockCipher, Key, KeyInit, KeySizeUser,
};
use core::fmt;

#[cfg(feature = "zeroize")]
use cipher::zeroize::ZeroizeOnDrop;

/// Triple DES (3DES) block cipher.
#[derive(Clone)]
pub struct TdesEde3 {
    d1: Des,
    d2: Des,
    d3: Des,
}

impl BlockCipher for TdesEde3 {}

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
#[cfg_attr(docsrs, doc(cfg(feature = "zeroize")))]
impl ZeroizeOnDrop for TdesEde3 {}

cipher::impl_simple_block_encdec!(
    TdesEde3, U8, cipher, block,
    encrypt: {
        let mut data = u64::from_be_bytes(block.clone_in().into());
        data = cipher.d1.encrypt(data);
        data = cipher.d2.decrypt(data);
        data = cipher.d3.encrypt(data);
        block.get_out().copy_from_slice(&data.to_be_bytes());
    }
    decrypt: {
        let mut data = u64::from_be_bytes(block.clone_in().into());
        data = cipher.d3.decrypt(data);
        data = cipher.d2.encrypt(data);
        data = cipher.d1.decrypt(data);
        block.get_out().copy_from_slice(&data.to_be_bytes());
    }
);

/// Triple DES (3DES) block cipher.
#[derive(Clone)]
pub struct TdesEee3 {
    d1: Des,
    d2: Des,
    d3: Des,
}

impl BlockCipher for TdesEee3 {}

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
#[cfg_attr(docsrs, doc(cfg(feature = "zeroize")))]
impl ZeroizeOnDrop for TdesEee3 {}

cipher::impl_simple_block_encdec!(
    TdesEee3, U8, cipher, block,
    encrypt: {
        let mut data = u64::from_be_bytes(block.clone_in().into());
        data = cipher.d1.encrypt(data);
        data = cipher.d2.encrypt(data);
        data = cipher.d3.encrypt(data);
        block.get_out().copy_from_slice(&data.to_be_bytes());
    }
    decrypt: {
        let mut data = u64::from_be_bytes(block.clone_in().into());
        data = cipher.d3.decrypt(data);
        data = cipher.d2.decrypt(data);
        data = cipher.d1.decrypt(data);
        block.get_out().copy_from_slice(&data.to_be_bytes());
    }
);

/// Triple DES (3DES) block cipher.
#[derive(Clone)]
pub struct TdesEde2 {
    d1: Des,
    d2: Des,
}

impl BlockCipher for TdesEde2 {}

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
#[cfg_attr(docsrs, doc(cfg(feature = "zeroize")))]
impl ZeroizeOnDrop for TdesEde2 {}

cipher::impl_simple_block_encdec!(
    TdesEde2, U8, cipher, block,
    encrypt: {
        let mut data = u64::from_be_bytes(block.clone_in().into());
        data = cipher.d1.encrypt(data);
        data = cipher.d2.decrypt(data);
        data = cipher.d1.encrypt(data);
        block.get_out().copy_from_slice(&data.to_be_bytes());
    }
    decrypt: {
        let mut data = u64::from_be_bytes(block.clone_in().into());
        data = cipher.d1.decrypt(data);
        data = cipher.d2.encrypt(data);
        data = cipher.d1.decrypt(data);
        block.get_out().copy_from_slice(&data.to_be_bytes());
    }
);

/// Triple DES (3DES) block cipher.
#[derive(Clone)]
pub struct TdesEee2 {
    d1: Des,
    d2: Des,
}

impl BlockCipher for TdesEee2 {}

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
#[cfg_attr(docsrs, doc(cfg(feature = "zeroize")))]
impl ZeroizeOnDrop for TdesEee2 {}

cipher::impl_simple_block_encdec!(
    TdesEee2, U8, cipher, block,
    encrypt: {
        let mut data = u64::from_be_bytes(block.clone_in().into());
        data = cipher.d1.encrypt(data);
        data = cipher.d2.encrypt(data);
        data = cipher.d1.encrypt(data);
        block.get_out().copy_from_slice(&data.to_be_bytes());
    }
    decrypt: {
        let mut data = u64::from_be_bytes(block.clone_in().into());
        data = cipher.d1.decrypt(data);
        data = cipher.d2.decrypt(data);
        data = cipher.d1.decrypt(data);
        block.get_out().copy_from_slice(&data.to_be_bytes());
    }
);
