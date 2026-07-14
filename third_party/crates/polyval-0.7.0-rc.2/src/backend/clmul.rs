//! Intel `CLMUL`-accelerated implementation for modern x86/x86_64 CPUs
//! (i.e. Intel Sandy Bridge-compatible or newer)
//!
//! Based on implementation by Eric Lagergren
//! at <https://github.com/ericlagergren/polyval-rs/>.

#[cfg(target_arch = "x86")]
use core::arch::x86::*;
#[cfg(target_arch = "x86_64")]
use core::arch::x86_64::*;

use universal_hash::{
    KeyInit, ParBlocks, Reset, UhfBackend,
    array::ArraySize,
    consts::U16,
    crypto_common::{BlockSizeUser, KeySizeUser, ParBlocksSizeUser},
    typenum::{Const, ToUInt, U},
};

use crate::{Block, Key, Tag, backend::common};
use core::ptr;

/// **POLYVAL**: GHASH-like universal hash over GF(2^128).
///
/// Paramaterized on a constant that determines how many
/// blocks to process at once: higher numbers use more memory,
/// and require more time to re-key, but process data significantly
/// faster.
///
/// (This constant is not used when acceleration is not enabled.)
#[derive(Clone)]
pub struct Polyval<const N: usize = 8> {
    /// Powers of H in descending order.
    ///
    /// (H^N, H^(N-1)...H)
    h: [__m128i; N],
    y: __m128i,
}

impl<const N: usize> KeySizeUser for Polyval<N> {
    type KeySize = U16;
}

impl<const N: usize> Polyval<N> {
    /// Initialize POLYVAL with the given `H` field element and initial block
    pub fn new_with_init_block(h: &Key, init_block: u128) -> Self {
        unsafe {
            // `_mm_loadu_si128` performs an unaligned load
            #[allow(clippy::cast_ptr_alignment)]
            let h = _mm_loadu_si128(h.as_ptr() as *const __m128i);

            Self {
                // introducing a closure here because polymul is unsafe.
                h: common::powers_of_h(h, |a, b| polymul(a, b)),
                y: _mm_loadu_si128(&init_block.to_be_bytes()[..] as *const _ as *const __m128i),
            }
        }
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

impl<const N: usize> ParBlocksSizeUser for Polyval<N>
where
    U<N>: ArraySize,
    Const<N>: ToUInt,
{
    type ParBlocksSize = U<N>;
}

impl<const N: usize> UhfBackend for Polyval<N>
where
    U<N>: ArraySize,
    Const<N>: ToUInt,
{
    fn proc_par_blocks(&mut self, blocks: &ParBlocks<Self>) {
        unsafe {
            self.mul_par_blocks(blocks);
        }
    }

    fn proc_block(&mut self, x: &Block) {
        unsafe {
            self.mul(x);
        }
    }
}

impl<const N: usize> Polyval<N> {
    /// Get Polyval output
    pub(crate) fn finalize(self) -> Tag {
        unsafe { core::mem::transmute(self.y) }
    }
}

impl<const N: usize> Polyval<N>
where
    U<N>: ArraySize,
    Const<N>: ToUInt,
{
    #[inline]
    #[target_feature(enable = "pclmulqdq")]
    unsafe fn mul_par_blocks(&mut self, blocks: &ParBlocks<Self>) {
        unsafe {
            let mut h = _mm_setzero_si128();
            let mut m = _mm_setzero_si128();
            let mut l = _mm_setzero_si128();

            // Note: Manually unrolling this loop did not help in benchmarks.
            for i in (0..N).rev() {
                let mut x = _mm_loadu_si128(blocks[i].as_ptr().cast());
                if i == 0 {
                    x = _mm_xor_si128(x, self.y);
                }
                let y = self.h[i];
                let (hh, mm, ll) = karatsuba1(x, y);
                h = _mm_xor_si128(h, hh);
                m = _mm_xor_si128(m, mm);
                l = _mm_xor_si128(l, ll);
            }

            let (h, l) = karatsuba2(h, m, l);
            self.y = mont_reduce(h, l);
        }
    }

    #[inline]
    #[target_feature(enable = "pclmulqdq")]
    #[allow(unsafe_op_in_unsafe_fn)]
    unsafe fn mul(&mut self, x: &Block) {
        let x = _mm_loadu_si128(x.as_ptr().cast());
        self.y = polymul(_mm_xor_si128(self.y, x), self.h[N - 1]);
    }
}

impl<const N: usize> Reset for Polyval<N> {
    fn reset(&mut self) {
        unsafe {
            self.y = _mm_setzero_si128();
        }
    }
}

#[cfg(feature = "zeroize")]
impl<const N: usize> Drop for Polyval<N> {
    fn drop(&mut self) {
        use zeroize::Zeroize;
        self.h.zeroize();
        self.y.zeroize();
    }
}

/// # Safety
///
/// The SSE2 and pclmulqdq target features must be enabled.
#[inline]
#[target_feature(enable = "sse2,pclmulqdq")]
#[allow(unused_unsafe)]
#[allow(clippy::undocumented_unsafe_blocks, reason = "Too many unsafe blocks.")]
unsafe fn polymul(x: __m128i, y: __m128i) -> __m128i {
    let (h, m, l) = unsafe { karatsuba1(x, y) };
    let (h, l) = unsafe { karatsuba2(h, m, l) };
    unsafe {
        mont_reduce(h, l) // d
    }
}

/// Karatsuba decomposition for `x*y`.
#[inline]
#[target_feature(enable = "sse2,pclmulqdq")]
#[allow(unused_unsafe)]
#[allow(clippy::undocumented_unsafe_blocks, reason = "Too many unsafe blocks.")]
unsafe fn karatsuba1(x: __m128i, y: __m128i) -> (__m128i, __m128i, __m128i) {
    // First Karatsuba step: decompose x and y.
    //
    // (x1*y0 + x0*y1) = (x1+x0) * (y1+x0) + (x1*y1) + (x0*y0)
    //        M                                 H         L
    //
    // m = x.hi^x.lo * y.hi^y.lo
    let m = unsafe {
        pmull(
            _mm_xor_si128(x, _mm_shuffle_epi32(x, 0xee)),
            _mm_xor_si128(y, _mm_shuffle_epi32(y, 0xee)),
        )
    };
    let h = unsafe { pmull2(y, x) }; // h = x.hi * y.hi
    let l = unsafe { pmull(y, x) }; // l = x.lo * y.lo
    (h, m, l)
}

/// Karatsuba combine.
#[inline]
#[target_feature(enable = "sse2,pclmulqdq")]
#[allow(unused_unsafe)]
#[allow(clippy::undocumented_unsafe_blocks, reason = "Too many unsafe blocks.")]
unsafe fn karatsuba2(h: __m128i, m: __m128i, l: __m128i) -> (__m128i, __m128i) {
    // Second Karatsuba step: combine into a 2n-bit product.
    //
    // m0 ^= l0 ^ h0 // = m0^(l0^h0)
    // m1 ^= l1 ^ h1 // = m1^(l1^h1)
    // l1 ^= m0      // = l1^(m0^l0^h0)
    // h0 ^= l0 ^ m1 // = h0^(l0^m1^l1^h1)
    // h1 ^= l1      // = h1^(l1^m0^l0^h0)
    let t = unsafe {
        //   {m0, m1} ^ {l1, h0}
        // = {m0^l1, m1^h0}
        let t0 = {
            _mm_xor_si128(
                m,
                _mm_castps_si128(_mm_shuffle_ps(
                    _mm_castsi128_ps(l),
                    _mm_castsi128_ps(h),
                    0x4e,
                )),
            )
        };

        //   {h0, h1} ^ {l0, l1}
        // = {h0^l0, h1^l1}
        let t1 = _mm_xor_si128(h, l);

        //   {m0^l1, m1^h0} ^ {h0^l0, h1^l1}
        // = {m0^l1^h0^l0, m1^h0^h1^l1}
        _mm_xor_si128(t0, t1)
    };

    // {m0^l1^h0^l0, l0}
    let x01 = unsafe { _mm_unpacklo_epi64(l, t) };

    // {h1, m1^h0^h1^l1}
    let x23 = unsafe { _mm_castps_si128(_mm_movehl_ps(_mm_castsi128_ps(h), _mm_castsi128_ps(t))) };

    (x23, x01)
}

/// # Safety
///
/// The SSE2 and pclmulqdq target features must be enavled.
#[inline]
#[target_feature(enable = "sse2,pclmulqdq")]
#[allow(unused_unsafe)]
#[allow(clippy::undocumented_unsafe_blocks, reason = "Too many unsafe blocks.")]
unsafe fn mont_reduce(x23: __m128i, x01: __m128i) -> __m128i {
    // Perform the Montgomery reduction over the 256-bit X.
    //    [A1:A0] = X0 • poly
    //    [B1:B0] = [X0 ⊕ A1 : X1 ⊕ A0]
    //    [C1:C0] = B0 • poly
    //    [D1:D0] = [B0 ⊕ C1 : B1 ⊕ C0]
    // Output: [D1 ⊕ X3 : D0 ⊕ X2]
    static POLY: u128 = (1 << 127) | (1 << 126) | (1 << 121) | (1 << 63) | (1 << 62) | (1 << 57);
    let poly = unsafe { _mm_loadu_si128(ptr::addr_of!(POLY).cast()) };
    let a = unsafe { pmull(x01, poly) };
    let b = unsafe { _mm_xor_si128(x01, _mm_shuffle_epi32(a, 0x4e)) };
    let c = unsafe { pmull2(b, poly) };
    unsafe { _mm_xor_si128(x23, _mm_xor_si128(c, b)) }
}

/// Multiplies the low bits in `a` and `b`.
///
/// # Safety
///
/// The SSE2 and pclmulqdq target features must be enabled.
#[inline]
#[allow(unused_unsafe)]
#[target_feature(enable = "sse2,pclmulqdq")]
unsafe fn pmull(a: __m128i, b: __m128i) -> __m128i {
    // SAFETY: This requires the `sse2` and `pclmulqdq` features
    // which we have.
    unsafe { _mm_clmulepi64_si128(a, b, 0x00) }
}

/// Multiplies the high bits in `a` and `b`.
///
/// # Safety
///
/// The SSE2 and pclmulqdq target features must be enavled.
#[inline]
#[allow(unused_unsafe)]
#[target_feature(enable = "sse2,pclmulqdq")]
unsafe fn pmull2(a: __m128i, b: __m128i) -> __m128i {
    // SAFETY: This requires the `sse2` and `pclmulqdq` features
    // which we have.
    unsafe { _mm_clmulepi64_si128(a, b, 0x11) }
}
