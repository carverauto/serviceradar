//! ARMv8 `PMULL`-accelerated implementation of POLYVAL.
//!
//! Based on this C intrinsics implementation:
//! <https://github.com/noloader/AES-Intrinsics/blob/master/clmul-arm.c>
//!
//! Original C written and placed in public domain by Jeffrey Walton.
//! Based on code from ARM, and by Johannes Schneiders, Skip Hovsmith and
//! Barry O'Rourke for the mbedTLS project.
//!
//! Incorporates performance improvements from Eric Lagergren
//! at <https://github.com/ericlagergren/polyval-rs/>.
//!
//! For more information about PMULL, see:
//! - <https://developer.arm.com/documentation/100069/0608/A64-SIMD-Vector-Instructions/PMULL--PMULL2--vector->
//! - <https://eprint.iacr.org/2015/688.pdf>
#![allow(unsafe_op_in_unsafe_fn)]

use core::{arch::aarch64::*, mem};

use universal_hash::{
    KeyInit, ParBlocks, Reset, UhfBackend,
    array::ArraySize,
    consts::U16,
    crypto_common::{BlockSizeUser, KeySizeUser, ParBlocksSizeUser},
    typenum::{Const, ToUInt, U},
};

use crate::{Block, Key, Tag, backend::common};

/// Montgomery reduction polynomial
const POLY: u128 = (1 << 127) | (1 << 126) | (1 << 121) | (1 << 63) | (1 << 62) | (1 << 57);

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
    h: [uint8x16_t; N],
    y: uint8x16_t,
}

impl<const N: usize> KeySizeUser for Polyval<N> {
    type KeySize = U16;
}

impl<const N: usize> Polyval<N> {
    /// Initialize POLYVAL with the given `H` field element and initial block
    pub fn new_with_init_block(h: &Key, init_block: u128) -> Self {
        unsafe {
            let h = vld1q_u8(h.as_ptr());
            Self {
                // introducing a closure here because polymul is unsafe.
                h: common::powers_of_h(h, |a, b| polymul(a, b)),
                y: vld1q_u8(init_block.to_be_bytes()[..].as_ptr()),
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
            let mut h = vdupq_n_u8(0);
            let mut m = vdupq_n_u8(0);
            let mut l = vdupq_n_u8(0);

            // Note: Manually unrolling this loop did not help in benchmarks.
            for i in (0..N).rev() {
                let mut x = vld1q_u8(blocks[i].as_ptr());
                if i == 0 {
                    x = veorq_u8(x, self.y);
                }
                let y = self.h[i];
                let (hh, mm, ll) = karatsuba1(x, y);
                h = veorq_u8(h, hh);
                m = veorq_u8(m, mm);
                l = veorq_u8(l, ll);
            }

            let (h, l) = karatsuba2(h, m, l);
            self.y = mont_reduce(h, l);
        }
    }

    fn proc_block(&mut self, x: &Block) {
        unsafe {
            let y = veorq_u8(self.y, vld1q_u8(x.as_ptr()));
            self.y = polymul(y, self.h[N - 1]);
        }
    }
}

impl<const N: usize> Reset for Polyval<N> {
    fn reset(&mut self) {
        unsafe {
            self.y = vdupq_n_u8(0);
        }
    }
}

impl<const N: usize> Polyval<N> {
    /// Get POLYVAL output.
    pub(crate) fn finalize(self) -> Tag {
        unsafe { mem::transmute(self.y) }
    }
}

/// Multipy "y" by "h" and return the result.
// TODO(tarcieri): investigate ordering optimizations and fusions e.g.`fuse-crypto-eor`
#[inline]
#[target_feature(enable = "neon")]
unsafe fn polymul(y: uint8x16_t, h: uint8x16_t) -> uint8x16_t {
    let (h, m, l) = karatsuba1(h, y);
    let (h, l) = karatsuba2(h, m, l);
    mont_reduce(h, l)
}

/// Karatsuba decomposition for `x*y`.
#[inline]
#[target_feature(enable = "neon")]
unsafe fn karatsuba1(x: uint8x16_t, y: uint8x16_t) -> (uint8x16_t, uint8x16_t, uint8x16_t) {
    // First Karatsuba step: decompose x and y.
    //
    // (x1*y0 + x0*y1) = (x1+x0) * (y1+y0) + (x1*y1) + (x0*y0)
    //        M                                 H         L
    //
    // m = x.hi^x.lo * y.hi^y.lo
    let m = pmull(
        veorq_u8(x, vextq_u8(x, x, 8)), // x.hi^x.lo
        veorq_u8(y, vextq_u8(y, y, 8)), // y.hi^y.lo
    );
    let h = pmull2(x, y); // h = x.hi * y.hi
    let l = pmull(x, y); // l = x.lo * y.lo
    (h, m, l)
}

/// Karatsuba combine.
#[inline]
#[target_feature(enable = "neon")]
unsafe fn karatsuba2(h: uint8x16_t, m: uint8x16_t, l: uint8x16_t) -> (uint8x16_t, uint8x16_t) {
    // Second Karatsuba step: combine into a 2n-bit product.
    //
    // m0 ^= l0 ^ h0 // = m0^(l0^h0)
    // m1 ^= l1 ^ h1 // = m1^(l1^h1)
    // l1 ^= m0      // = l1^(m0^l0^h0)
    // h0 ^= l0 ^ m1 // = h0^(l0^m1^l1^h1)
    // h1 ^= l1      // = h1^(l1^m0^l0^h0)
    let t = {
        //   {m0, m1} ^ {l1, h0}
        // = {m0^l1, m1^h0}
        let t0 = veorq_u8(m, vextq_u8(l, h, 8));

        //   {h0, h1} ^ {l0, l1}
        // = {h0^l0, h1^l1}
        let t1 = veorq_u8(h, l);

        //   {m0^l1, m1^h0} ^ {h0^l0, h1^l1}
        // = {m0^l1^h0^l0, m1^h0^h1^l1}
        veorq_u8(t0, t1)
    };

    // {m0^l1^h0^l0, l0}
    let x01 = vextq_u8(
        vextq_u8(l, l, 8), // {l1, l0}
        t,
        8,
    );

    // {h1, m1^h0^h1^l1}
    let x23 = vextq_u8(
        t,
        vextq_u8(h, h, 8), // {h1, h0}
        8,
    );

    (x23, x01)
}

#[inline]
#[target_feature(enable = "neon")]
unsafe fn mont_reduce(x23: uint8x16_t, x01: uint8x16_t) -> uint8x16_t {
    // Perform the Montgomery reduction over the 256-bit X.
    //    [A1:A0] = X0 • poly
    //    [B1:B0] = [X0 ⊕ A1 : X1 ⊕ A0]
    //    [C1:C0] = B0 • poly
    //    [D1:D0] = [B0 ⊕ C1 : B1 ⊕ C0]
    // Output: [D1 ⊕ X3 : D0 ⊕ X2]
    let poly = vreinterpretq_u8_p128(POLY);
    let a = pmull(x01, poly);
    let b = veorq_u8(x01, vextq_u8(a, a, 8));
    let c = pmull2(b, poly);
    veorq_u8(x23, veorq_u8(c, b))
}

/// Multiplies the low bits in `a` and `b`.
#[inline]
#[target_feature(enable = "neon")]
unsafe fn pmull(a: uint8x16_t, b: uint8x16_t) -> uint8x16_t {
    mem::transmute(vmull_p64(
        vgetq_lane_u64(vreinterpretq_u64_u8(a), 0),
        vgetq_lane_u64(vreinterpretq_u64_u8(b), 0),
    ))
}

/// Multiplies the high bits in `a` and `b`.
#[inline]
#[target_feature(enable = "neon")]
unsafe fn pmull2(a: uint8x16_t, b: uint8x16_t) -> uint8x16_t {
    mem::transmute(vmull_p64(
        vgetq_lane_u64(vreinterpretq_u64_u8(a), 1),
        vgetq_lane_u64(vreinterpretq_u64_u8(b), 1),
    ))
}
// TODO(tarcieri): zeroize support
// #[cfg(feature = "zeroize")]
// impl Drop for Polyval<N> {
//     fn drop(&mut self) {
//         use zeroize::Zeroize;
//         self.h.zeroize();
//         self.y.zeroize();
//     }
// }
