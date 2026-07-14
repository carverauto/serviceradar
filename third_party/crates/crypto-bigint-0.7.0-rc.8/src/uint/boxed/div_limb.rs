//! Implementation of constant-time division via reciprocal precomputation, as described in
//! "Improved Division by Invariant Integers" by Niels Möller and Torbjorn Granlund
//! (DOI: 10.1109/TC.2010.143, <https://gmplib.org/~tege/division-paper.pdf>).
use crate::{BoxedUint, ConstChoice, Limb, Reciprocal, uint::div_limb::div2by1};

/// Divides `u` by the divisor encoded in the `reciprocal`, and returns
/// the quotient and the remainder.
#[inline(always)]
pub(crate) fn div_rem_limb_with_reciprocal(
    u: &BoxedUint,
    reciprocal: &Reciprocal,
) -> (BoxedUint, Limb) {
    let (mut q, mut r) = u.shl_limb(reciprocal.shift());
    let mut j = u.limbs.len();
    while j > 0 {
        j -= 1;
        (q.limbs[j].0, r.0) = div2by1(r.0, q.limbs[j].0, reciprocal);
    }
    (q, r >> reciprocal.shift())
}

/// Divides `u` by the divisor encoded in the `reciprocal`, and returns the remainder.
#[inline(always)]
pub(crate) fn rem_limb_with_reciprocal(u: &BoxedUint, reciprocal: &Reciprocal) -> Limb {
    let lshift = reciprocal.shift();
    let nz = ConstChoice::from_u32_nonzero(lshift);
    let rshift = nz.if_true_u32(Limb::BITS - lshift);
    let mut hi = nz.if_true_word(
        u.limbs[u.limbs.len() - 1]
            .0
            .wrapping_shr(Limb::BITS - lshift),
    );
    let mut lo;
    let mut j = u.limbs.len();
    while j > 1 {
        j -= 1;
        lo = u.limbs[j].0 << lshift;
        lo |= nz.if_true_word(u.limbs[j - 1].0 >> rshift);
        (_, hi) = div2by1(hi, lo, reciprocal);
    }
    (_, hi) = div2by1(hi, u.limbs[0].0 << lshift, reciprocal);
    Limb(hi >> reciprocal.shift())
}
