//! Implementation of constant-time division via reciprocal precomputation, as described in
//! "Improved Division by Invariant Integers" by Niels Möller and Torbjorn Granlund
//! (DOI: 10.1109/TC.2010.143, <https://gmplib.org/~tege/division-paper.pdf>).
use subtle::{Choice, ConditionallySelectable};

use crate::{
    ConstChoice, Limb, NonZero, Uint, WideWord, Word,
    primitives::{addhilo, widening_mul},
};

/// Calculates the reciprocal of the given 32-bit divisor with the highmost bit set.
#[cfg(target_pointer_width = "32")]
pub const fn reciprocal(d: Word) -> Word {
    debug_assert!(d >= (1 << (Word::BITS - 1)));

    let d0 = d & 1;
    let d10 = d >> 22;
    let d21 = (d >> 11) + 1;
    let d31 = (d >> 1) + d0;
    let v0 = short_div((1 << 24) - (1 << 14) + (1 << 9), 24, d10, 10);
    let (_lo, hi) = widening_mul(v0 * v0, d21);
    let v1 = (v0 << 4) - hi - 1;

    // Checks that the expression for `e` can be simplified in the way we did below.
    debug_assert!(widening_mul(v1, d31).1 == (1 << 16) - 1);
    let e = Word::MAX - v1.wrapping_mul(d31) + 1 + (v1 >> 1) * d0;

    let (_lo, hi) = widening_mul(v1, e);
    // Note: the paper does not mention a wrapping add here,
    // but the 64-bit version has it at this stage, and the function panics without it
    // when calculating a reciprocal for `Word::MAX`.
    let v2 = (v1 << 15).wrapping_add(hi >> 1);

    // The paper has `(v2 + 1) * d / 2^32` (there's another 2^32, but it's accounted for later).
    // If `v2 == 2^32-1` this should give `d`, but we can't achieve this in our wrapping arithmetic.
    // Hence the `ct_select()`.
    let x = v2.wrapping_add(1);
    let (_lo, hi) = widening_mul(x, d);
    let hi = ConstChoice::from_u32_nonzero(x).select_word(d, hi);

    v2.wrapping_sub(hi).wrapping_sub(d)
}

/// Calculates the reciprocal of the given 64-bit divisor with the highmost bit set.
#[cfg(target_pointer_width = "64")]
pub const fn reciprocal(d: Word) -> Word {
    debug_assert!(d >= (1 << (Word::BITS - 1)));

    let d0 = d & 1;
    let d9 = d >> 55;
    let d40 = (d >> 24) + 1;
    let d63 = (d >> 1) + d0;
    let v0 = short_div((1 << 19) - 3 * (1 << 8), 19, d9 as u32, 9) as u64;
    let v1 = (v0 << 11) - ((v0 * v0 * d40) >> 40) - 1;
    let v2 = (v1 << 13) + ((v1 * ((1 << 60) - v1 * d40)) >> 47);

    // Checks that the expression for `e` can be simplified in the way we did below.
    debug_assert!(widening_mul(v2, d63).1 == (1 << 32) - 1);
    let e = Word::MAX - v2.wrapping_mul(d63) + 1 + (v2 >> 1) * d0;

    let (_lo, hi) = widening_mul(v2, e);
    let v3 = (v2 << 31).wrapping_add(hi >> 1);

    // The paper has `(v3 + 1) * d / 2^64` (there's another 2^64, but it's accounted for later).
    // If `v3 == 2^64-1` this should give `d`, but we can't achieve this in our wrapping arithmetic.
    // Hence the `ct_select()`.
    let x = v3.wrapping_add(1);
    let (_lo, hi) = widening_mul(x, d);
    let hi = ConstChoice::from_word_nonzero(x).select_word(d, hi);

    v3.wrapping_sub(hi).wrapping_sub(d)
}

/// Returns `u32::MAX` if `a < b` and `0` otherwise.
#[inline]
const fn lt(a: u32, b: u32) -> u32 {
    // TODO: Move to using ConstChoice::le
    let bit = (((!a) & b) | (((!a) | b) & (a.wrapping_sub(b)))) >> (u32::BITS - 1);
    bit.wrapping_neg()
}

/// Returns `a` if `c == 0` and `b` if `c == u32::MAX`.
#[inline(always)]
const fn select(a: u32, b: u32, c: u32) -> u32 {
    // TODO: Move to using ConstChoice::select
    a ^ (c & (a ^ b))
}

/// Calculates `dividend / divisor`, given `dividend` and `divisor`
/// along with their maximum bitsizes.
#[inline(always)]
const fn short_div(dividend: u32, dividend_bits: u32, divisor: u32, divisor_bits: u32) -> u32 {
    // TODO: this may be sped up even more using the fact that `dividend` is a known constant.

    // In the paper this is a table lookup, but since we want it to be constant-time,
    // we have to access all the elements of the table, which is quite large.
    // So this shift-and-subtract approach is actually faster.

    // Passing `dividend_bits` and `divisor_bits` because calling `.leading_zeros()`
    // causes a significant slowdown, and we know those values anyway.

    let mut dividend = dividend;
    let mut divisor = divisor << (dividend_bits - divisor_bits);
    let mut quotient: u32 = 0;
    let mut i = dividend_bits - divisor_bits + 1;

    while i > 0 {
        i -= 1;
        let bit = lt(dividend, divisor);
        dividend = select(dividend.wrapping_sub(divisor), dividend, bit);
        divisor >>= 1;
        let inv_bit = !bit;
        quotient |= (inv_bit >> (u32::BITS - 1)) << i;
    }

    quotient
}

/// Calculate the quotient and the remainder of the division of a wide word
/// (supplied as high and low words) by `d`, with a precalculated reciprocal `v`.
#[inline(always)]
pub(crate) const fn div2by1(u1: Word, u0: Word, reciprocal: &Reciprocal) -> (Word, Word) {
    let d = reciprocal.divisor_normalized;

    debug_assert!(d >= (1 << (Word::BITS - 1)));
    debug_assert!(u1 < d);

    let (q0, q1) = widening_mul(reciprocal.reciprocal, u1);
    let (q0, q1) = addhilo(q0, q1, u0, u1);
    let q1 = q1.wrapping_add(1);
    let r = u0.wrapping_sub(q1.wrapping_mul(d));

    let r_gt_q0 = ConstChoice::from_word_lt(q0, r);
    let q1 = r_gt_q0.select_word(q1, q1.wrapping_sub(1));
    let r = r_gt_q0.select_word(r, r.wrapping_add(d));

    // If this was a normal `if`, we wouldn't need wrapping ops, because there would be no overflow.
    // But since we calculate both results either way, we have to wrap.
    // Added an assert to still check the lack of overflow in debug mode.
    debug_assert!(r < d || q1 < Word::MAX);
    let r_ge_d = ConstChoice::from_word_le(d, r);
    let q1 = r_ge_d.select_word(q1, q1.wrapping_add(1));
    let r = r_ge_d.select_word(r, r.wrapping_sub(d));

    (q1, r)
}

/// Given two long integers `u = (..., u0, u1, u2)` and `v = (..., v0, v1)`
/// (where `u2` and `v1` are the most significant limbs), where `floor(u / v) <= Limb::MAX`,
/// calculates `q` such that `q - 1 <= floor(u / v) <= q`.
/// In place of `v1` takes its reciprocal, and assumes that `v` was already pre-shifted
/// so that v1 has its most significant bit set (that is, the reciprocal's `shift` is 0).
#[inline(always)]
pub(crate) const fn div3by2(
    u2: Word,
    u1: Word,
    u0: Word,
    v1_reciprocal: &Reciprocal,
    v0: Word,
) -> Word {
    debug_assert!(v1_reciprocal.shift == 0);
    debug_assert!(u2 <= v1_reciprocal.divisor_normalized);

    // This method corresponds to Algorithm Q:
    // https://janmr.com/blog/2014/04/basic-multiple-precision-long-division/

    let q_maxed = ConstChoice::from_word_eq(u2, v1_reciprocal.divisor_normalized);
    let (mut quo, rem) = div2by1(q_maxed.select_word(u2, 0), u1, v1_reciprocal);
    // When the leading dividend word equals the leading divisor word, cap the quotient
    // at Word::MAX and set the remainder to the sum of the top dividend words.
    quo = q_maxed.select_word(quo, Word::MAX);
    let mut rem = q_maxed.select_wide_word(rem as WideWord, (u2 as WideWord) + (u1 as WideWord));

    let mut i = 0;
    while i < 2 {
        let qy = (quo as WideWord) * (v0 as WideWord);
        let rx = (rem << Word::BITS) | (u0 as WideWord);
        // If r < b and q*y[-2] > r*x[-1], then set q = q - 1 and r = r + v1
        let done = ConstChoice::from_word_nonzero((rem >> Word::BITS) as Word)
            .or(ConstChoice::from_wide_word_le(qy, rx));
        quo = done.select_word(quo.wrapping_sub(1), quo);
        rem = done.select_wide_word(rem + (v1_reciprocal.divisor_normalized as WideWord), rem);
        i += 1;
    }

    quo
}

/// A pre-calculated reciprocal for division by a single limb.
#[derive(Copy, Clone, Debug, PartialEq, Eq)]
pub struct Reciprocal {
    divisor_normalized: Word,
    shift: u32,
    reciprocal: Word,
}

impl Reciprocal {
    /// Pre-calculates a reciprocal for a known divisor,
    /// to be used in the single-limb division later.
    pub const fn new(divisor: NonZero<Limb>) -> Self {
        let divisor = divisor.0;

        // Assuming this is constant-time for primitive types.
        let shift = divisor.0.leading_zeros();

        // Will not panic since divisor is non-zero
        let divisor_normalized = divisor.0 << shift;

        Self {
            divisor_normalized,
            shift,
            reciprocal: reciprocal(divisor_normalized),
        }
    }

    /// Returns a default instance of this object.
    /// It is a self-consistent `Reciprocal` that will not cause panics in functions that take it.
    ///
    /// NOTE: intended for using it as a placeholder during compile-time array generation,
    /// don't rely on the contents.
    pub const fn default() -> Self {
        Self {
            divisor_normalized: Word::MAX,
            shift: 0,
            // The result of calling `reciprocal(Word::MAX)`
            // This holds both for 32- and 64-bit versions.
            reciprocal: 1,
        }
    }

    #[cfg(feature = "alloc")]
    pub(crate) const fn divisor(&self) -> NonZero<Limb> {
        NonZero(Limb(self.divisor_normalized >> self.shift))
    }

    /// Get the shift value
    pub const fn shift(&self) -> u32 {
        self.shift
    }
}

impl ConditionallySelectable for Reciprocal {
    fn conditional_select(a: &Self, b: &Self, choice: Choice) -> Self {
        Self {
            divisor_normalized: Word::conditional_select(
                &a.divisor_normalized,
                &b.divisor_normalized,
                choice,
            ),
            shift: u32::conditional_select(&a.shift, &b.shift, choice),
            reciprocal: Word::conditional_select(&a.reciprocal, &b.reciprocal, choice),
        }
    }
}

// `CtOption.map()` needs this; for some reason it doesn't use the value it already has
// for the `None` branch.
impl Default for Reciprocal {
    fn default() -> Self {
        Self::default()
    }
}

/// Divides `u` by the divisor encoded in the `reciprocal`, and returns
/// the quotient and the remainder.
#[inline(always)]
pub(crate) const fn div_rem_limb_with_reciprocal<const L: usize>(
    u: &Uint<L>,
    reciprocal: &Reciprocal,
) -> (Uint<L>, Limb) {
    let (u_shifted, u_hi) = u.shl_limb(reciprocal.shift);
    let mut r = u_hi.0;
    let mut q = [Limb::ZERO; L];

    let mut j = L;
    while j > 0 {
        j -= 1;
        let (qj, rj) = div2by1(r, u_shifted.as_limbs()[j].0, reciprocal);
        q[j] = Limb(qj);
        r = rj;
    }
    (Uint::<L>::new(q), Limb(r >> reciprocal.shift))
}

/// Divides `u` by the divisor encoded in the `reciprocal`, and returns the remainder.
#[inline(always)]
pub(crate) const fn rem_limb_with_reciprocal<const L: usize>(
    u: &Uint<L>,
    reciprocal: &Reciprocal,
) -> Limb {
    let (u_shifted, u_hi) = u.shl_limb(reciprocal.shift);
    let mut r = u_hi.0;

    let mut j = L;
    while j > 0 {
        j -= 1;
        let (_, rj) = div2by1(r, u_shifted.as_limbs()[j].0, reciprocal);
        r = rj;
    }
    Limb(r >> reciprocal.shift)
}

/// Divides the wide `u` by the divisor encoded in the `reciprocal`, and returns the remainder.
#[inline(always)]
pub(crate) const fn rem_limb_with_reciprocal_wide<const L: usize>(
    lo_hi: (&Uint<L>, &Uint<L>),
    reciprocal: &Reciprocal,
) -> Limb {
    let (lo_shifted, carry) = lo_hi.0.shl_limb(reciprocal.shift);
    let (mut hi_shifted, xhi) = lo_hi.1.shl_limb(reciprocal.shift);
    hi_shifted.limbs[0].0 |= carry.0;
    let mut r = xhi.0;

    let mut j = L;
    while j > 0 {
        j -= 1;
        let (_, rj) = div2by1(r, hi_shifted.as_limbs()[j].0, reciprocal);
        r = rj;
    }
    j = L;
    while j > 0 {
        j -= 1;
        let (_, rj) = div2by1(r, lo_shifted.as_limbs()[j].0, reciprocal);
        r = rj;
    }
    Limb(r >> reciprocal.shift)
}

/// Computes `(a * b) % d`.
#[inline(always)]
pub(crate) const fn mul_rem(a: Limb, b: Limb, d: NonZero<Limb>) -> Limb {
    let rec = Reciprocal::new(d);
    let (lo, hi) = widening_mul(a.0, b.0);
    rem_limb_with_reciprocal(&Uint::from_words([lo, hi]), &rec)
}

#[cfg(test)]
mod tests {
    use super::{Reciprocal, div2by1};
    use crate::{Limb, NonZero, Word};
    #[test]
    fn div2by1_overflow() {
        // A regression test for a situation when in div2by1() an operation (`q1 + 1`)
        // that is protected from overflowing by a condition in the original paper (`r >= d`)
        // still overflows because we're calculating the results for both branches.
        let r = Reciprocal::new(NonZero::new(Limb(Word::MAX - 1)).unwrap());
        assert_eq!(
            div2by1(Word::MAX - 2, Word::MAX - 63, &r),
            (Word::MAX, Word::MAX - 65)
        );
    }
}
