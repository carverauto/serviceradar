//! 64-bit secp256r1 scalar field algorithms.

use super::MODULUS;
use elliptic_curve::bigint::{Limb, U256};

/// MU = floor(2^512 / n)
///    = 115792089264276142090721624801893421302707618245269942344307673200490803338238
///    = 0x100000000fffffffffffffffeffffffff43190552df1a6c21012ffd85eedf9bfe
const MU: [Limb; 5] = [
    Limb::from_u64(0x012f_fd85_eedf_9bfe),
    Limb::from_u64(0x4319_0552_df1a_6c21),
    Limb::from_u64(0xffff_fffe_ffff_ffff),
    Limb::from_u64(0x0000_0000_ffff_ffff),
    Limb::from_u64(0x0000_0000_0000_0001),
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
    let a4 = hi[0];
    let a5 = hi[1];
    let a6 = hi[2];
    let a7 = hi[3];
    let q1 = [a3, a4, a5, a6, a7];
    let q3 = q1_times_mu_shift_five(&q1);

    let r1 = [a0, a1, a2, a3, a4];
    let r2 = q3_times_n_keep_five(&q3);
    let r = sub_inner_five(r1, r2);

    // Result is in range (0, 3*n - 1),
    // and 90% of the time, no subtraction will be needed.
    let r = subtract_n_if_necessary(r);
    U256::new([r[0], r[1], r[2], r[3]])
}

#[inline]
const fn q1_times_mu_shift_five(q1: &[Limb; 5]) -> [Limb; 5] {
    // Schoolbook multiplication

    let (_w0, carry) = q1[0].carrying_mul_add(MU[0], Limb::ZERO, Limb::ZERO);
    let (w1, carry) = q1[0].carrying_mul_add(MU[1], Limb::ZERO, carry);
    let (w2, carry) = q1[0].carrying_mul_add(MU[2], Limb::ZERO, carry);
    let (w3, carry) = q1[0].carrying_mul_add(MU[3], Limb::ZERO, carry);
    // NOTE MU[4] == 1
    // let (w4, w5) = q1[0].carrying_mul_add(MU[4], Limb::ZERO, carry);
    let (w4, w5) = Limb::ZERO.carrying_add(q1[0], carry);

    let (_w1, carry) = q1[1].carrying_mul_add(MU[0], w1, Limb::ZERO);
    let (w2, carry) = q1[1].carrying_mul_add(MU[1], w2, carry);
    let (w3, carry) = q1[1].carrying_mul_add(MU[2], w3, carry);
    let (w4, carry) = q1[1].carrying_mul_add(MU[3], w4, carry);
    // let (w5, w6) = mac(w5, q1[1], MU[4], carry);
    let (w5, w6) = w5.carrying_add(q1[1], carry);

    let (_w2, carry) = q1[2].carrying_mul_add(MU[0], w2, Limb::ZERO);
    let (w3, carry) = q1[2].carrying_mul_add(MU[1], w3, carry);
    let (w4, carry) = q1[2].carrying_mul_add(MU[2], w4, carry);
    let (w5, carry) = q1[2].carrying_mul_add(MU[3], w5, carry);
    // let (w6, w7) = q1[2].carrying_mul_add(MU[4], w6, carry);
    let (w6, w7) = w6.carrying_add(q1[2], carry);

    let (_w3, carry) = q1[3].carrying_mul_add(MU[0], w3, Limb::ZERO);
    let (w4, carry) = q1[3].carrying_mul_add(MU[1], w4, carry);
    let (w5, carry) = q1[3].carrying_mul_add(MU[2], w5, carry);
    let (w6, carry) = q1[3].carrying_mul_add(MU[3], w6, carry);
    // let (w7, w8) = q1[3].carrying_mul_add(MU[4], w7, carry);
    let (w7, w8) = w7.carrying_add(q1[3], carry);

    let (_w4, carry) = q1[4].carrying_mul_add(MU[0], w4, Limb::ZERO);
    let (w5, carry) = q1[4].carrying_mul_add(MU[1], w5, carry);
    let (w6, carry) = q1[4].carrying_mul_add(MU[2], w6, carry);
    let (w7, carry) = q1[4].carrying_mul_add(MU[3], w7, carry);
    // let (w8, w9) = q1[4].carrying_mul_add(MU[4], w8, carry);
    let (w8, w9) = w8.carrying_add(q1[4], carry);

    // let q2 = [_w0, _w1, _w2, _w3, _w4, w5, w6, w7, w8, w9];
    [w5, w6, w7, w8, w9]
}

#[inline]
const fn q3_times_n_keep_five(q3: &[Limb; 5]) -> [Limb; 5] {
    // Schoolbook multiplication.

    let modulus = MODULUS.as_ref().as_limbs();

    let (w0, carry) = q3[0].carrying_mul_add(modulus[0], Limb::ZERO, Limb::ZERO);
    let (w1, carry) = q3[0].carrying_mul_add(modulus[1], Limb::ZERO, carry);
    let (w2, carry) = q3[0].carrying_mul_add(modulus[2], Limb::ZERO, carry);
    let (w3, carry) = q3[0].carrying_mul_add(modulus[3], Limb::ZERO, carry);
    // let (w4, _) = q3[0].carrying_mul_add(0, Limb::ZERO, carry);
    let (w4, _) = (carry, Limb::ZERO);

    let (w1, carry) = q3[1].carrying_mul_add(modulus[0], w1, Limb::ZERO);
    let (w2, carry) = q3[1].carrying_mul_add(modulus[1], w2, carry);
    let (w3, carry) = q3[1].carrying_mul_add(modulus[2], w3, carry);
    let (w4, _) = q3[1].carrying_mul_add(modulus[3], w4, carry);

    let (w2, carry) = q3[2].carrying_mul_add(modulus[0], w2, Limb::ZERO);
    let (w3, carry) = q3[2].carrying_mul_add(modulus[1], w3, carry);
    let (w4, _) = q3[2].carrying_mul_add(modulus[2], w4, carry);

    let (w3, carry) = q3[3].carrying_mul_add(modulus[0], w3, Limb::ZERO);
    let (w4, _) = q3[3].carrying_mul_add(modulus[1], w4, carry);

    let (w4, _) = q3[4].carrying_mul_add(modulus[0], w4, Limb::ZERO);

    [w0, w1, w2, w3, w4]
}

#[inline]
#[allow(clippy::too_many_arguments)]
const fn sub_inner_five(l: [Limb; 5], r: [Limb; 5]) -> [Limb; 5] {
    let (w0, borrow) = l[0].borrowing_sub(r[0], Limb::ZERO);
    let (w1, borrow) = l[1].borrowing_sub(r[1], borrow);
    let (w2, borrow) = l[2].borrowing_sub(r[2], borrow);
    let (w3, borrow) = l[3].borrowing_sub(r[3], borrow);
    let (w4, _borrow) = l[4].borrowing_sub(r[4], borrow);

    // If underflow occurred on the final limb - don't care (= add b^{k+1}).
    [w0, w1, w2, w3, w4]
}

#[inline]
#[allow(clippy::too_many_arguments)]
const fn subtract_n_if_necessary(r: [Limb; 5]) -> [Limb; 5] {
    let modulus = MODULUS.as_ref().as_limbs();

    let (w0, borrow) = r[0].borrowing_sub(modulus[0], Limb::ZERO);
    let (w1, borrow) = r[1].borrowing_sub(modulus[1], borrow);
    let (w2, borrow) = r[2].borrowing_sub(modulus[2], borrow);
    let (w3, borrow) = r[3].borrowing_sub(modulus[3], borrow);
    let (w4, borrow) = r[4].borrowing_sub(Limb::ZERO, borrow);

    // If underflow occurred on the final limb, borrow = 0xfff...fff, otherwise
    // borrow = 0x000...000. Thus, we use it as a mask to conditionally add the
    // modulus.
    let (w0, carry) = w0.carrying_add(modulus[0].bitand(borrow), Limb::ZERO);
    let (w1, carry) = w1.carrying_add(modulus[1].bitand(borrow), carry);
    let (w2, carry) = w2.carrying_add(modulus[2].bitand(borrow), carry);
    let (w3, carry) = w3.carrying_add(modulus[3].bitand(borrow), carry);
    let (w4, _carry) = w4.carrying_add(Limb::ZERO, carry);

    [w0, w1, w2, w3, w4]
}
