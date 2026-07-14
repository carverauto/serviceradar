//! 64-bit secp256r1 field element algorithms.

use elliptic_curve::bigint::{Limb, U256, modular::ConstMontyParams};

const MODULUS: &[Limb; 4] = super::FieldParams::PARAMS.modulus().as_ref().as_limbs();

pub(super) const fn add(a: &U256, b: &U256) -> U256 {
    let a = a.as_limbs();
    let b = b.as_limbs();

    // Bit 256 of p is set, so addition can result in five words.
    let (w0, carry) = a[0].carrying_add(b[0], Limb::ZERO);
    let (w1, carry) = a[1].carrying_add(b[1], carry);
    let (w2, carry) = a[2].carrying_add(b[2], carry);
    let (w3, w4) = a[3].carrying_add(b[3], carry);

    // Attempt to subtract the modulus, to ensure the result is in the field
    let (result, _) = sub_inner(
        [w0, w1, w2, w3, w4],
        [MODULUS[0], MODULUS[1], MODULUS[2], MODULUS[3], Limb::ZERO],
    );
    U256::new([result[0], result[1], result[2], result[3]])
}

pub(super) const fn sub(a: &U256, b: &U256) -> U256 {
    let a = a.as_limbs();
    let b = b.as_limbs();

    let (result, _) = sub_inner(
        [a[0], a[1], a[2], a[3], Limb::ZERO],
        [b[0], b[1], b[2], b[3], Limb::ZERO],
    );
    U256::new([result[0], result[1], result[2], result[3]])
}

#[inline]
pub(super) const fn to_canonical(a: &U256) -> U256 {
    montgomery_reduce(a, &U256::ZERO)
}

/// Montgomery Reduction
///
/// The general algorithm is:
/// ```text
/// A <- input (2n b-limbs)
/// for i in 0..n {
///     k <- A[i] p' mod b
///     A <- A + k p b^i
/// }
/// A <- A / b^n
/// if A >= p {
///     A <- A - p
/// }
/// ```
///
/// For secp256r1, with a 64-bit arithmetic, we have the following
/// simplifications:
///
/// - `p'` is 1, so our multiplicand is simply the first limb of the intermediate A.
///
/// - The first limb of p is 2^64 - 1; multiplications by this limb can be simplified
///   to a shift and subtraction:
///   ```text
///       a_i * (2^64 - 1) = a_i * 2^64 - a_i = (a_i << 64) - a_i
///   ```
///   However, because `p' = 1`, the first limb of p is multiplied by limb i of the
///   intermediate A and then immediately added to that same limb, so we simply
///   initialize the carry to limb i of the intermediate.
///
/// - The third limb of p is zero, so we can ignore any multiplications by it and just
///   add the carry.
///
/// References:
/// - Handbook of Applied Cryptography, Chapter 14
///   Algorithm 14.32
///   http://cacr.uwaterloo.ca/hac/about/chap14.pdf
///
/// - Efficient and Secure Elliptic Curve Cryptography Implementation of Curve P-256
///   Algorithm 7) Montgomery Word-by-Word Reduction
///   https://csrc.nist.gov/csrc/media/events/workshop-on-elliptic-curve-cryptography-standards/documents/papers/session6-adalier-mehmet.pdf
#[inline]
#[allow(clippy::too_many_arguments)]
pub(super) const fn montgomery_reduce(lo: &U256, hi: &U256) -> U256 {
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

    let (a1, carry) = a0.carrying_mul_add(MODULUS[1], a1, a0);
    let (a2, carry) = a2.carrying_add(Limb::ZERO, carry);
    let (a3, carry) = a0.carrying_mul_add(MODULUS[3], a3, carry);
    let (a4, carry2) = a4.carrying_add(Limb::ZERO, carry);

    let (a2, carry) = a1.carrying_mul_add(MODULUS[1], a2, a1);
    let (a3, carry) = a3.carrying_add(Limb::ZERO, carry);
    let (a4, carry) = a1.carrying_mul_add(MODULUS[3], a4, carry);
    let (a5, carry2) = a5.carrying_add(carry2, carry);

    let (a3, carry) = a2.carrying_mul_add(MODULUS[1], a3, a2);
    let (a4, carry) = a4.carrying_add(Limb::ZERO, carry);
    let (a5, carry) = a2.carrying_mul_add(MODULUS[3], a5, carry);
    let (a6, carry2) = a6.carrying_add(carry2, carry);

    let (a4, carry) = a3.carrying_mul_add(MODULUS[1], a4, a3);
    let (a5, carry) = a5.carrying_add(Limb::ZERO, carry);
    let (a6, carry) = a3.carrying_mul_add(MODULUS[3], a6, carry);
    let (a7, a8) = a7.carrying_add(carry2, carry);

    // Result may be within MODULUS of the correct value
    let (result, _) = sub_inner(
        [a4, a5, a6, a7, a8],
        [MODULUS[0], MODULUS[1], MODULUS[2], MODULUS[3], Limb::ZERO],
    );

    U256::new([result[0], result[1], result[2], result[3]])
}

#[inline]
#[allow(clippy::too_many_arguments)]
const fn sub_inner(l: [Limb; 5], r: [Limb; 5]) -> ([Limb; 4], Limb) {
    let (w0, borrow) = l[0].borrowing_sub(r[0], Limb::ZERO);
    let (w1, borrow) = l[1].borrowing_sub(r[1], borrow);
    let (w2, borrow) = l[2].borrowing_sub(r[2], borrow);
    let (w3, borrow) = l[3].borrowing_sub(r[3], borrow);
    let (_, borrow) = l[4].borrowing_sub(r[4], borrow);

    // If underflow occurred on the final limb, borrow = 0xfff...fff, otherwise
    // borrow = 0x000...000. Thus, we use it as a mask to conditionally add the
    // modulus.

    let (w0, carry) = w0.carrying_add(MODULUS[0].bitand(borrow), Limb::ZERO);
    let (w1, carry) = w1.carrying_add(MODULUS[1].bitand(borrow), carry);
    let (w2, carry) = w2.carrying_add(MODULUS[2].bitand(borrow), carry);
    let (w3, _) = w3.carrying_add(MODULUS[3].bitand(borrow), carry);

    ([w0, w1, w2, w3], borrow)
}
