//! 32-bit secp256r1 scalar field algorithms.

use super::MODULUS;
use elliptic_curve::bigint::{Limb, U256};

/// MU = floor(2^512 / n)
///    = 115792089264276142090721624801893421302707618245269942344307673200490803338238
///    = 0x100000000fffffffffffffffeffffffff43190552df1a6c21012ffd85eedf9bfe
const MU: [Limb; 9] = [
    Limb::from_u32(0xeedf_9bfe),
    Limb::from_u32(0x012f_fd85),
    Limb::from_u32(0xdf1a_6c21),
    Limb::from_u32(0x4319_0552),
    Limb::from_u32(0xffff_ffff),
    Limb::from_u32(0xffff_fffe),
    Limb::from_u32(0xffff_ffff),
    Limb::from_u32(0x0000_0000),
    Limb::from_u32(0x0000_0001),
];

/// Barrett Reduction
///
/// NOTE: this implementation is specialized to P-256's order! See #1155
///
/// The general algorithm is:
/// ```text
/// p = n = order of group
/// b = 2^64 = 64bit machine word
/// k = 4
/// a \in [0, 2^512]
/// mu := floor(b^{2k} / p)
/// q1 := floor(a / b^{k - 1})
/// q2 := q1 * mu
/// q3 := <- floor(a / b^{k - 1})
/// r1 := a mod b^{k + 1}
/// r2 := q3 * m mod b^{k + 1}
/// r := r1 - r2
///
/// if r < 0: r := r + b^{k + 1}
/// while r >= p: do r := r - p (at most twice)
/// ```
///
/// References:
/// - Handbook of Applied Cryptography, Chapter 14
///   Algorithm 14.42
///   http://cacr.uwaterloo.ca/hac/about/chap14.pdf
///
/// - Efficient and Secure Elliptic Curve Cryptography Implementation of Curve P-256
///   Algorithm 6) Barrett Reduction modulo p
///   https://csrc.nist.gov/csrc/media/events/workshop-on-elliptic-curve-cryptography-standards/documents/papers/session6-adalier-mehmet.pdf
#[inline]
#[allow(clippy::too_many_arguments)]
pub(super) const fn barrett_reduce(lo: U256, hi: U256) -> U256 {
    let lo = lo.as_limbs();
    let hi = hi.as_limbs();

    let a0 = lo[0];
    let a1 = lo[1];
    let a2 = lo[2];
    let a3 = lo[3];
    let a4 = lo[4];
    let a5 = lo[5];
    let a6 = lo[6];
    let a7 = lo[7];
    let a8 = hi[0];
    let a9 = hi[1];
    let a10 = hi[2];
    let a11 = hi[3];
    let a12 = hi[4];
    let a13 = hi[5];
    let a14 = hi[6];
    let a15 = hi[7];

    let q1: [Limb; 9] = [a7, a8, a9, a10, a11, a12, a13, a14, a15];
    let q3: [Limb; 9] = q1_times_mu_shift_nine(&q1);

    let r1: [Limb; 9] = [a0, a1, a2, a3, a4, a5, a6, a7, a8];
    let r2: [Limb; 9] = q3_times_n_keep_nine(&q3);
    let r: [Limb; 9] = sub_inner_nine(r1, r2);

    // Result is in range (0, 3*n - 1),
    // and 90% of the time, no subtraction will be needed.
    let r = subtract_n_if_necessary(r);

    U256::new([r[0], r[1], r[2], r[3], r[4], r[5], r[6], r[7]])
}

#[inline]
const fn q1_times_mu_shift_nine(q1: &[Limb; 9]) -> [Limb; 9] {
    // Schoolbook multiplication

    let (_w0, carry) = q1[0].carrying_mul_add(MU[0], Limb::ZERO, Limb::ZERO);
    let (w1, carry) = q1[0].carrying_mul_add(MU[1], Limb::ZERO, carry);
    let (w2, carry) = q1[0].carrying_mul_add(MU[2], Limb::ZERO, carry);
    let (w3, carry) = q1[0].carrying_mul_add(MU[3], Limb::ZERO, carry);
    let (w4, carry) = q1[0].carrying_mul_add(MU[4], Limb::ZERO, carry);
    let (w5, carry) = q1[0].carrying_mul_add(MU[5], Limb::ZERO, carry);
    let (w6, carry) = q1[0].carrying_mul_add(MU[6], Limb::ZERO, carry);
    // NOTE MU[7] == 0
    // let (w7, carry) = q1[0].carrying_mul_add(MU[7], Limb::ZERO, carry);
    let (w7, _carry) = (carry, Limb::ZERO);
    // NOTE MU[8] == 1
    // let (w8, w9) = q1[0].carrying_mul_add(MU[8], Limb::ZERO, carry);
    let (w8, w9) = (q1[0], Limb::ZERO);

    let (_w1, carry) = q1[1].carrying_mul_add(MU[0], w1, Limb::ZERO);
    let (w2, carry) = q1[1].carrying_mul_add(MU[1], w2, carry);
    let (w3, carry) = q1[1].carrying_mul_add(MU[2], w3, carry);
    let (w4, carry) = q1[1].carrying_mul_add(MU[3], w4, carry);
    let (w5, carry) = q1[1].carrying_mul_add(MU[4], w5, carry);
    let (w6, carry) = q1[1].carrying_mul_add(MU[5], w6, carry);
    let (w7, carry) = q1[1].carrying_mul_add(MU[6], w7, carry);
    // NOTE MU[7] == 0
    // let (w8, carry) = q1[1].carrying_mul_add(MU[7], w8, carry);
    let (w8, carry) = w8.carrying_add(Limb::ZERO, carry);
    // NOTE MU[8] == 1
    // let (w9, w10) = q1[1].carrying_mul_add(MU[8], w9, carry);
    let (w9, w10) = w9.carrying_add(q1[1], carry);

    let (_w2, carry) = q1[2].carrying_mul_add(MU[0], w2, Limb::ZERO);
    let (w3, carry) = q1[2].carrying_mul_add(MU[1], w3, carry);
    let (w4, carry) = q1[2].carrying_mul_add(MU[2], w4, carry);
    let (w5, carry) = q1[2].carrying_mul_add(MU[3], w5, carry);
    let (w6, carry) = q1[2].carrying_mul_add(MU[4], w6, carry);
    let (w7, carry) = q1[2].carrying_mul_add(MU[5], w7, carry);
    let (w8, carry) = q1[2].carrying_mul_add(MU[6], w8, carry);
    // let (w9, carry) = q1[2].carrying_mul_add(MU[7], w9, carry);
    let (w9, carry) = w9.carrying_add(Limb::ZERO, carry);
    // let (w10, w11) = q1[2].carrying_mul_add(MU[8], w10, carry);
    let (w10, w11) = w10.carrying_add(q1[2], carry);

    let (_w3, carry) = q1[3].carrying_mul_add(MU[0], w3, Limb::ZERO);
    let (w4, carry) = q1[3].carrying_mul_add(MU[1], w4, carry);
    let (w5, carry) = q1[3].carrying_mul_add(MU[2], w5, carry);
    let (w6, carry) = q1[3].carrying_mul_add(MU[3], w6, carry);
    let (w7, carry) = q1[3].carrying_mul_add(MU[4], w7, carry);
    let (w8, carry) = q1[3].carrying_mul_add(MU[5], w8, carry);
    let (w9, carry) = q1[3].carrying_mul_add(MU[6], w9, carry);
    // let (w10, carry) = q1[3].carrying_mul_add(MU[7], w10, carry);
    let (w10, carry) = w10.carrying_add(Limb::ZERO, carry);
    // let (w11, w12) = q1[3].carrying_mul_add(MU[8], w11, carry);
    let (w11, w12) = w11.carrying_add(q1[3], carry);

    let (_w4, carry) = q1[4].carrying_mul_add(MU[0], w4, Limb::ZERO);
    let (w5, carry) = q1[4].carrying_mul_add(MU[1], w5, carry);
    let (w6, carry) = q1[4].carrying_mul_add(MU[2], w6, carry);
    let (w7, carry) = q1[4].carrying_mul_add(MU[3], w7, carry);
    let (w8, carry) = q1[4].carrying_mul_add(MU[4], w8, carry);
    let (w9, carry) = q1[4].carrying_mul_add(MU[5], w9, carry);
    let (w10, carry) = q1[4].carrying_mul_add(MU[6], w10, carry);
    // let (w11, carry) = q1[4].carrying_mul_add(MU[7], w11, carry);
    let (w11, carry) = w11.carrying_add(Limb::ZERO, carry);
    // let (w12, w13) = q1[4].carrying_mul_add(MU[8], w12, carry);
    let (w12, w13) = w12.carrying_add(q1[4], carry);

    let (_w5, carry) = q1[5].carrying_mul_add(MU[0], w5, Limb::ZERO);
    let (w6, carry) = q1[5].carrying_mul_add(MU[1], w6, carry);
    let (w7, carry) = q1[5].carrying_mul_add(MU[2], w7, carry);
    let (w8, carry) = q1[5].carrying_mul_add(MU[3], w8, carry);
    let (w9, carry) = q1[5].carrying_mul_add(MU[4], w9, carry);
    let (w10, carry) = q1[5].carrying_mul_add(MU[5], w10, carry);
    let (w11, carry) = q1[5].carrying_mul_add(MU[6], w11, carry);
    // let (w12, carry) = q1[5].carrying_mul_add(MU[7], w12, carry);
    let (w12, carry) = w12.carrying_add(Limb::ZERO, carry);
    // let (w13, w14) = q1[5].carrying_mul_add(MU[8], w13, carry);
    let (w13, w14) = w13.carrying_add(q1[5], carry);

    let (_w6, carry) = q1[6].carrying_mul_add(MU[0], w6, Limb::ZERO);
    let (w7, carry) = q1[6].carrying_mul_add(MU[1], w7, carry);
    let (w8, carry) = q1[6].carrying_mul_add(MU[2], w8, carry);
    let (w9, carry) = q1[6].carrying_mul_add(MU[3], w9, carry);
    let (w10, carry) = q1[6].carrying_mul_add(MU[4], w10, carry);
    let (w11, carry) = q1[6].carrying_mul_add(MU[5], w11, carry);
    let (w12, carry) = q1[6].carrying_mul_add(MU[6], w12, carry);
    // let (w13, carry) = q1[6].carrying_mul_add(MU[7], w13, carry);
    let (w13, carry) = w13.carrying_add(Limb::ZERO, carry);
    // let (w14, w15) = q1[6].carrying_mul_add(MU[8], w14, carry);
    let (w14, w15) = w14.carrying_add(q1[6], carry);

    let (_w7, carry) = q1[7].carrying_mul_add(MU[0], w7, Limb::ZERO);
    let (w8, carry) = q1[7].carrying_mul_add(MU[1], w8, carry);
    let (w9, carry) = q1[7].carrying_mul_add(MU[2], w9, carry);
    let (w10, carry) = q1[7].carrying_mul_add(MU[3], w10, carry);
    let (w11, carry) = q1[7].carrying_mul_add(MU[4], w11, carry);
    let (w12, carry) = q1[7].carrying_mul_add(MU[5], w12, carry);
    let (w13, carry) = q1[7].carrying_mul_add(MU[6], w13, carry);
    // let (w14, carry) = q1[7].carrying_mul_add(MU[7], w14, carry);
    let (w14, carry) = w14.carrying_add(Limb::ZERO, carry);
    // let (w15, w16) = q1[7].carrying_mul_add(MU[8], w15, carry);
    let (w15, w16) = w15.carrying_add(q1[7], carry);

    let (_w8, carry) = q1[8].carrying_mul_add(MU[0], w8, Limb::ZERO);
    let (w9, carry) = q1[8].carrying_mul_add(MU[1], w9, carry);
    let (w10, carry) = q1[8].carrying_mul_add(MU[2], w10, carry);
    let (w11, carry) = q1[8].carrying_mul_add(MU[3], w11, carry);
    let (w12, carry) = q1[8].carrying_mul_add(MU[4], w12, carry);
    let (w13, carry) = q1[8].carrying_mul_add(MU[5], w13, carry);
    let (w14, carry) = q1[8].carrying_mul_add(MU[6], w14, carry);
    // let (w15, carry) = w15, q1[8].carrying_mul_add(MU[7], w15, carry);
    let (w15, carry) = w15.carrying_add(Limb::ZERO, carry);
    // let (w16, w17) = w16, q1[8].carrying_mul_add(MU[8], w16, carry);
    let (w16, w17) = w16.carrying_add(q1[8], carry);

    // let q2 = [_w0, _w1, _w2, _w3, _w4, _w5, _w6, _w7, _w8, w9, w10, w11, w12, w13, w14, w15, w16, w17];
    [w9, w10, w11, w12, w13, w14, w15, w16, w17]
}

#[inline]
const fn q3_times_n_keep_nine(q3: &[Limb; 9]) -> [Limb; 9] {
    // Schoolbook multiplication

    let modulus = MODULUS.as_ref().as_limbs();

    /* NOTE
     * modulus[7] = 2^32 - 1
     * modulus[6] = 0
     * modulus[5] = 2^32 - 1
     * modulus[4] = 2^32 - 1
     */

    let (w0, carry) = q3[0].carrying_mul_add(modulus[0], Limb::ZERO, Limb::ZERO);
    let (w1, carry) = q3[0].carrying_mul_add(modulus[1], Limb::ZERO, carry);
    let (w2, carry) = q3[0].carrying_mul_add(modulus[2], Limb::ZERO, carry);
    let (w3, carry) = q3[0].carrying_mul_add(modulus[3], Limb::ZERO, carry);
    let (w4, carry) = q3[0].carrying_mul_add(modulus[4], Limb::ZERO, carry);
    let (w5, carry) = q3[0].carrying_mul_add(modulus[5], Limb::ZERO, carry);
    // NOTE modulus[6] = 0
    // let (w6, carry) = q3[0].carrying_mul_add(modulus[6], Limb::ZERO, carry);
    let (w6, carry) = (carry, Limb::ZERO);
    let (w7, carry) = q3[0].carrying_mul_add(modulus[7], Limb::ZERO, carry);
    // let (w8, _) = q3[0].carrying_mul_add(Limb::ZERO, Limb::ZERO, carry);
    let (w8, _) = (carry, Limb::ZERO);

    let (w1, carry) = q3[1].carrying_mul_add(modulus[0], w1, Limb::ZERO);
    let (w2, carry) = q3[1].carrying_mul_add(modulus[1], w2, carry);
    let (w3, carry) = q3[1].carrying_mul_add(modulus[2], w3, carry);
    let (w4, carry) = q3[1].carrying_mul_add(modulus[3], w4, carry);
    let (w5, carry) = q3[1].carrying_mul_add(modulus[4], w5, carry);
    let (w6, carry) = q3[1].carrying_mul_add(modulus[5], w6, carry);
    // let (w7, carry) = q3[1].carrying_mul_add(modulus[6], w7, carry);
    let (w7, carry) = w7.carrying_add(Limb::ZERO, carry);
    let (w8, _) = q3[1].carrying_mul_add(modulus[7], w8, carry);

    let (w2, carry) = q3[2].carrying_mul_add(modulus[0], w2, Limb::ZERO);
    let (w3, carry) = q3[2].carrying_mul_add(modulus[1], w3, carry);
    let (w4, carry) = q3[2].carrying_mul_add(modulus[2], w4, carry);
    let (w5, carry) = q3[2].carrying_mul_add(modulus[3], w5, carry);
    let (w6, carry) = q3[2].carrying_mul_add(modulus[4], w6, carry);
    let (w7, carry) = q3[2].carrying_mul_add(modulus[5], w7, carry);
    // let (w8, _) = q3[2].carrying_mul_add(modulus[6], w8, carry);
    let (w8, _) = w8.carrying_add(Limb::ZERO, carry);

    let (w3, carry) = q3[3].carrying_mul_add(modulus[0], w3, Limb::ZERO);
    let (w4, carry) = q3[3].carrying_mul_add(modulus[1], w4, carry);
    let (w5, carry) = q3[3].carrying_mul_add(modulus[2], w5, carry);
    let (w6, carry) = q3[3].carrying_mul_add(modulus[3], w6, carry);
    let (w7, carry) = q3[3].carrying_mul_add(modulus[4], w7, carry);
    let (w8, _) = q3[3].carrying_mul_add(modulus[5], w8, carry);

    let (w4, carry) = q3[4].carrying_mul_add(modulus[0], w4, Limb::ZERO);
    let (w5, carry) = q3[4].carrying_mul_add(modulus[1], w5, carry);
    let (w6, carry) = q3[4].carrying_mul_add(modulus[2], w6, carry);
    let (w7, carry) = q3[4].carrying_mul_add(modulus[3], w7, carry);
    let (w8, _) = q3[4].carrying_mul_add(modulus[4], w8, carry);

    let (w5, carry) = q3[5].carrying_mul_add(modulus[0], w5, Limb::ZERO);
    let (w6, carry) = q3[5].carrying_mul_add(modulus[1], w6, carry);
    let (w7, carry) = q3[5].carrying_mul_add(modulus[2], w7, carry);
    let (w8, _) = q3[5].carrying_mul_add(modulus[3], w8, carry);

    let (w6, carry) = q3[6].carrying_mul_add(modulus[0], w6, Limb::ZERO);
    let (w7, carry) = q3[6].carrying_mul_add(modulus[1], w7, carry);
    let (w8, _) = q3[6].carrying_mul_add(modulus[2], w8, carry);

    let (w7, carry) = q3[7].carrying_mul_add(modulus[0], w7, Limb::ZERO);
    let (w8, _) = q3[7].carrying_mul_add(modulus[1], w8, carry);

    let (w8, _) = q3[8].carrying_mul_add(modulus[0], w8, Limb::ZERO);

    [w0, w1, w2, w3, w4, w5, w6, w7, w8]
}

#[inline]
#[allow(clippy::too_many_arguments)]
const fn sub_inner_nine(l: [Limb; 9], r: [Limb; 9]) -> [Limb; 9] {
    let (w0, borrow) = l[0].borrowing_sub(r[0], Limb::ZERO);
    let (w1, borrow) = l[1].borrowing_sub(r[1], borrow);
    let (w2, borrow) = l[2].borrowing_sub(r[2], borrow);
    let (w3, borrow) = l[3].borrowing_sub(r[3], borrow);
    let (w4, borrow) = l[4].borrowing_sub(r[4], borrow);
    let (w5, borrow) = l[5].borrowing_sub(r[5], borrow);
    let (w6, borrow) = l[6].borrowing_sub(r[6], borrow);
    let (w7, borrow) = l[7].borrowing_sub(r[7], borrow);
    let (w8, _borrow) = l[8].borrowing_sub(r[8], borrow);

    // If underflow occurred in the final limb - don't care (= add b^{k+1}).
    [w0, w1, w2, w3, w4, w5, w6, w7, w8]
}

#[inline]
#[allow(clippy::too_many_arguments)]
const fn subtract_n_if_necessary(r: [Limb; 9]) -> [Limb; 9] {
    let modulus = MODULUS.as_ref().as_limbs();

    let (w0, borrow) = r[0].borrowing_sub(modulus[0], Limb::ZERO);
    let (w1, borrow) = r[1].borrowing_sub(modulus[1], borrow);
    let (w2, borrow) = r[2].borrowing_sub(modulus[2], borrow);
    let (w3, borrow) = r[3].borrowing_sub(modulus[3], borrow);
    let (w4, borrow) = r[4].borrowing_sub(modulus[4], borrow);
    let (w5, borrow) = r[5].borrowing_sub(modulus[5], borrow);
    let (w6, borrow) = r[6].borrowing_sub(modulus[6], borrow);
    let (w7, borrow) = r[7].borrowing_sub(modulus[7], borrow);
    let (w8, borrow) = r[8].borrowing_sub(Limb::ZERO, borrow);

    // If underflow occurred in the final limb, borrow = 0xfff...fff, otherwise
    // borrow = 0x000...000. Thus, we use it as a mask to conditionally add
    // the modulus.
    let (w0, carry) = w0.carrying_add(modulus[0].bitand(borrow), Limb::ZERO);
    let (w1, carry) = w1.carrying_add(modulus[1].bitand(borrow), carry);
    let (w2, carry) = w2.carrying_add(modulus[2].bitand(borrow), carry);
    let (w3, carry) = w3.carrying_add(modulus[3].bitand(borrow), carry);
    let (w4, carry) = w4.carrying_add(modulus[4].bitand(borrow), carry);
    let (w5, carry) = w5.carrying_add(modulus[5].bitand(borrow), carry);
    let (w6, carry) = w6.carrying_add(modulus[6].bitand(borrow), carry);
    let (w7, carry) = w7.carrying_add(modulus[7].bitand(borrow), carry);
    let (w8, _carry) = w8.carrying_add(Limb::ZERO, carry);

    [w0, w1, w2, w3, w4, w5, w6, w7, w8]
}
