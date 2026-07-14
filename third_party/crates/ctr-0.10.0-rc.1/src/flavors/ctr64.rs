//! 64-bit counter falvors.
use super::CtrFlavor;
use cipher::{
    array::{Array, ArraySize},
    typenum::{PartialDiv, PartialQuot, U8, Unsigned},
};
use core::fmt;

type ChunkSize = U8;
type Chunks<B> = PartialQuot<B, ChunkSize>;
const CS: usize = ChunkSize::USIZE;

#[derive(Clone)]
pub struct CtrNonce64<N: ArraySize> {
    ctr: u64,
    nonce: Array<u64, N>,
}

impl<N: ArraySize> fmt::Debug for CtrNonce64<N> {
    #[inline]
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("CtrNonce64 { ... }")
    }
}

impl<N: ArraySize> Drop for CtrNonce64<N> {
    fn drop(&mut self) {
        #[cfg(feature = "zeroize")]
        {
            use cipher::zeroize::Zeroize;
            self.ctr.zeroize();
            self.nonce.zeroize();
        }
    }
}

#[cfg(feature = "zeroize")]
impl<N: ArraySize> cipher::zeroize::ZeroizeOnDrop for CtrNonce64<N> {}

/// 64-bit big endian counter flavor.
#[derive(Debug)]
pub enum Ctr64BE {}

impl<B> CtrFlavor<B> for Ctr64BE
where
    B: ArraySize + PartialDiv<ChunkSize>,
    Chunks<B>: ArraySize,
{
    type CtrNonce = CtrNonce64<Chunks<B>>;
    type Backend = u64;
    const NAME: &'static str = "64BE";

    #[inline]
    fn remaining(cn: &Self::CtrNonce) -> Option<usize> {
        (u64::MAX - cn.ctr).try_into().ok()
    }

    #[inline(always)]
    fn current_block(cn: &Self::CtrNonce) -> Array<u8, B> {
        let mut block = Array::<u8, B>::default();
        for i in 0..Chunks::<B>::USIZE {
            let t = if i == Chunks::<B>::USIZE - 1 {
                cn.ctr.wrapping_add(cn.nonce[i]).to_be_bytes()
            } else {
                cn.nonce[i].to_ne_bytes()
            };
            block[CS * i..][..CS].copy_from_slice(&t);
        }
        block
    }

    #[inline]
    fn next_block(cn: &mut Self::CtrNonce) -> Array<u8, B> {
        let block = Self::current_block(cn);
        cn.ctr = cn.ctr.wrapping_add(1);
        block
    }

    #[inline]
    fn from_nonce(block: &Array<u8, B>) -> Self::CtrNonce {
        let mut nonce = Array::<u64, Chunks<B>>::default();
        for i in 0..Chunks::<B>::USIZE {
            let chunk = block[CS * i..][..CS].try_into().unwrap();
            nonce[i] = if i == Chunks::<B>::USIZE - 1 {
                u64::from_be_bytes(chunk)
            } else {
                u64::from_ne_bytes(chunk)
            }
        }
        let ctr = 0;
        Self::CtrNonce { ctr, nonce }
    }

    #[inline]
    fn as_backend(cn: &Self::CtrNonce) -> Self::Backend {
        cn.ctr
    }

    #[inline]
    fn set_from_backend(cn: &mut Self::CtrNonce, v: Self::Backend) {
        cn.ctr = v;
    }
}

/// 64-bit little endian counter flavor.
#[derive(Debug)]
pub enum Ctr64LE {}

impl<B> CtrFlavor<B> for Ctr64LE
where
    B: ArraySize + PartialDiv<ChunkSize>,
    Chunks<B>: ArraySize,
{
    type CtrNonce = CtrNonce64<Chunks<B>>;
    type Backend = u64;
    const NAME: &'static str = "64LE";

    #[inline]
    fn remaining(cn: &Self::CtrNonce) -> Option<usize> {
        (u64::MAX - cn.ctr).try_into().ok()
    }

    #[inline(always)]
    fn current_block(cn: &Self::CtrNonce) -> Array<u8, B> {
        let mut block = Array::<u8, B>::default();
        for i in 0..Chunks::<B>::USIZE {
            let t = if i == 0 {
                cn.ctr.wrapping_add(cn.nonce[i]).to_le_bytes()
            } else {
                cn.nonce[i].to_ne_bytes()
            };
            block[CS * i..][..CS].copy_from_slice(&t);
        }
        block
    }

    #[inline]
    fn next_block(cn: &mut Self::CtrNonce) -> Array<u8, B> {
        let block = Self::current_block(cn);
        cn.ctr = cn.ctr.wrapping_add(1);
        block
    }

    #[inline]
    fn from_nonce(block: &Array<u8, B>) -> Self::CtrNonce {
        let mut nonce = Array::<u64, Chunks<B>>::default();
        for i in 0..Chunks::<B>::USIZE {
            let chunk = block[CS * i..][..CS].try_into().unwrap();
            nonce[i] = if i == 0 {
                u64::from_le_bytes(chunk)
            } else {
                u64::from_ne_bytes(chunk)
            }
        }
        let ctr = 0;
        Self::CtrNonce { ctr, nonce }
    }

    #[inline]
    fn as_backend(cn: &Self::CtrNonce) -> Self::Backend {
        cn.ctr
    }

    #[inline]
    fn set_from_backend(cn: &mut Self::CtrNonce, v: Self::Backend) {
        cn.ctr = v;
    }
}
