//! Autodetection for CPU intrinsics, with fallback to the "soft" backend when
//! they are unavailable.

use crate::{Key, Tag, backend::soft};
use core::mem::ManuallyDrop;
use universal_hash::{
    KeyInit, Reset, UhfClosure, UniversalHash,
    array::ArraySize,
    consts::U16,
    crypto_common::{BlockSizeUser, KeySizeUser},
    typenum::{Const, ToUInt, U},
};

#[cfg(target_arch = "aarch64")]
use super::pmull as intrinsics;

#[cfg(any(target_arch = "x86_64", target_arch = "x86"))]
use super::clmul as intrinsics;

#[cfg(target_arch = "aarch64")]
cpufeatures::new!(mul_intrinsics, "aes"); // `aes` implies PMULL

#[cfg(any(target_arch = "x86_64", target_arch = "x86"))]
cpufeatures::new!(mul_intrinsics, "pclmulqdq");

/// **POLYVAL**: GHASH-like universal hash over GF(2^128).
///
/// Paramaterized on a constant that determines how many
/// blocks to process at once: higher numbers use more memory,
/// and require more time to re-key, but process data significantly
/// faster.
///
/// (This constant is not used when acceleration is not enabled.)
pub struct Polyval<const N: usize = 8> {
    inner: Inner<N>,
    token: mul_intrinsics::InitToken,
}

union Inner<const N: usize> {
    intrinsics: ManuallyDrop<intrinsics::Polyval<N>>,
    soft: ManuallyDrop<soft::Polyval<N>>,
}

impl<const N: usize> KeySizeUser for Polyval<N> {
    type KeySize = U16;
}

impl<const N: usize> Polyval<N> {
    /// Initialize POLYVAL with the given `H` field element and initial block
    pub fn new_with_init_block(h: &Key, init_block: u128) -> Self {
        let (token, has_intrinsics) = mul_intrinsics::init_get();

        let inner = if has_intrinsics {
            Inner {
                intrinsics: ManuallyDrop::new(intrinsics::Polyval::new_with_init_block(
                    h, init_block,
                )),
            }
        } else {
            Inner {
                soft: ManuallyDrop::new(soft::Polyval::new_with_init_block(h, init_block)),
            }
        };

        Self { inner, token }
    }
}

impl<const N: usize> KeyInit for Polyval<N> {
    /// Initialize POLYVAL with the given `H` field element
    fn new(h: &Key) -> Self {
        Self::new_with_init_block(h, 0)
    }
}

impl<const N: usize> BlockSizeUser for Polyval<N> {
    type BlockSize = U16;
}

impl<const N: usize> UniversalHash for Polyval<N>
where
    U<N>: ArraySize,
    Const<N>: ToUInt,
{
    fn update_with_backend(&mut self, f: impl UhfClosure<BlockSize = Self::BlockSize>) {
        unsafe {
            if self.token.get() {
                f.call(&mut *self.inner.intrinsics)
            } else {
                f.call(&mut *self.inner.soft)
            }
        }
    }

    /// Get POLYVAL result (i.e. computed `S` field element)
    fn finalize(self) -> Tag {
        unsafe {
            if self.token.get() {
                ManuallyDrop::into_inner(self.inner.intrinsics).finalize()
            } else {
                ManuallyDrop::into_inner(self.inner.soft).finalize()
            }
        }
    }
}

impl<const N: usize> Clone for Polyval<N> {
    fn clone(&self) -> Self {
        let inner = if self.token.get() {
            Inner {
                intrinsics: ManuallyDrop::new(unsafe { (*self.inner.intrinsics).clone() }),
            }
        } else {
            Inner {
                soft: ManuallyDrop::new(unsafe { (*self.inner.soft).clone() }),
            }
        };

        Self {
            inner,
            token: self.token,
        }
    }
}

impl<const N: usize> Reset for Polyval<N> {
    fn reset(&mut self) {
        if self.token.get() {
            unsafe { (*self.inner.intrinsics).reset() }
        } else {
            unsafe { (*self.inner.soft).reset() }
        }
    }
}
