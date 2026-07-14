//! [`BoxedUint`] division operations.

use crate::{
    BoxedUint, CheckedDiv, ConstChoice, ConstantTimeSelect, DivRemLimb, DivVartime, Limb, NonZero,
    Reciprocal, RemLimb, RemMixed, Wrapping,
    const_choice::u32_min,
    uint::{
        boxed,
        div_limb::{div2by1, div3by2},
    },
};
use core::ops::{Div, DivAssign, Rem, RemAssign};
use subtle::CtOption;

impl BoxedUint {
    /// Computes `self / rhs` using a pre-made reciprocal,
    /// returns the quotient (q) and remainder (r).
    pub fn div_rem_limb_with_reciprocal(&self, reciprocal: &Reciprocal) -> (Self, Limb) {
        boxed::div_limb::div_rem_limb_with_reciprocal(self, reciprocal)
    }

    /// Computes `self / rhs`, returns the quotient (q) and remainder (r).
    pub fn div_rem_limb(&self, rhs: NonZero<Limb>) -> (Self, Limb) {
        boxed::div_limb::div_rem_limb_with_reciprocal(self, &Reciprocal::new(rhs))
    }

    /// Computes `self % rhs` using a pre-made reciprocal.
    #[inline(always)]
    pub fn rem_limb_with_reciprocal(&self, reciprocal: &Reciprocal) -> Limb {
        boxed::div_limb::rem_limb_with_reciprocal(self, reciprocal)
    }

    /// Computes `self % rhs`.
    #[inline(always)]
    pub fn rem_limb(&self, rhs: NonZero<Limb>) -> Limb {
        boxed::div_limb::rem_limb_with_reciprocal(self, &Reciprocal::new(rhs))
    }

    /// Computes self / rhs, returns the quotient, remainder.
    pub fn div_rem(&self, rhs: &NonZero<Self>) -> (Self, Self) {
        // Since `rhs` is nonzero, this should always hold.
        self.div_rem_unchecked(rhs.as_ref())
    }

    /// Computes self % rhs, returns the remainder.
    pub fn rem(&self, rhs: &NonZero<Self>) -> Self {
        self.div_rem(rhs).1
    }

    /// Computes self / rhs, returns the quotient, remainder.
    ///
    /// Variable-time with respect to `rhs`
    pub fn div_rem_vartime(&self, rhs: &NonZero<Self>) -> (Self, Self) {
        let yc = rhs.0.bits_vartime().div_ceil(Limb::BITS) as usize;

        match yc {
            0 => panic!("zero divisor"),
            1 => {
                // Perform limb division
                let (quo, rem_limb) =
                    self.div_rem_limb(rhs.0.limbs[0].to_nz().expect("zero divisor"));
                let mut rem = Self::zero_with_precision(rhs.bits_precision());
                rem.limbs[0] = rem_limb;
                (quo, rem)
            }
            _ => {
                let mut quo = self.clone();
                let mut rem = rhs.0.clone();
                div_rem_vartime_in_place(&mut quo.limbs, &mut rem.limbs[..yc]);
                (quo, rem)
            }
        }
    }

    /// Computes self % rhs, returns the remainder.
    ///
    /// Variable-time with respect to `rhs`.
    pub fn rem_vartime(&self, rhs: &NonZero<Self>) -> Self {
        let yc = rhs.0.bits_vartime().div_ceil(Limb::BITS) as usize;

        match yc {
            0 => panic!("zero divisor"),
            1 => {
                // Perform limb division
                let rem_limb = self.rem_limb(rhs.0.limbs[0].to_nz().expect("zero divisor"));
                let mut rem = Self::zero_with_precision(rhs.bits_precision());
                rem.limbs[0] = rem_limb;
                rem
            }
            _ if yc > self.limbs.len() => {
                let mut rem = Self::zero_with_precision(rhs.bits_precision());
                rem.limbs[..self.limbs.len()].copy_from_slice(&self.limbs);
                rem
            }
            _ => {
                let mut quo = self.clone();
                let mut rem = rhs.0.clone();
                div_rem_vartime_in_place(&mut quo.limbs, &mut rem.limbs[..yc]);
                rem
            }
        }
    }

    /// Wrapped division is just normal division i.e. `self` / `rhs`
    /// There’s no way wrapping could ever happen.
    ///
    /// This function exists, so that all operations are accounted for in the wrapping operations.
    ///
    /// Panics if `rhs == 0`.
    pub fn wrapping_div(&self, rhs: &NonZero<Self>) -> Self {
        self.div_rem(rhs).0
    }

    /// Wrapped division is just normal division i.e. `self` / `rhs`
    ///
    /// There’s no way wrapping could ever happen.
    /// This function exists, so that all operations are accounted for in the wrapping operations
    pub fn wrapping_div_vartime(&self, rhs: &NonZero<Self>) -> Self {
        self.div_rem_vartime(rhs).0
    }

    /// Perform checked division, returning a [`CtOption`] which `is_some`
    /// only if the rhs != 0
    pub fn checked_div(&self, rhs: &Self) -> CtOption<Self> {
        let is_nz = rhs.is_nonzero();
        let nz = NonZero(Self::ct_select(
            &Self::one_with_precision(self.bits_precision()),
            rhs,
            is_nz,
        ));
        let q = self.div_rem_unchecked(&nz).0;
        CtOption::new(q, is_nz)
    }

    fn div_rem_unchecked(&self, rhs: &Self) -> (Self, Self) {
        // Based on Section 4.3.1, of The Art of Computer Programming, Volume 2, by Donald E. Knuth.
        // Further explanation at https://janmr.com/blog/2014/04/basic-multiple-precision-long-division/

        let xsize = self.nlimbs();
        let ysize = rhs.nlimbs();

        // Short circuit for single-word divisor
        if ysize == 1 {
            let (quo, rem_limb) = self.div_rem_limb(rhs.limbs[0].to_nz().expect("zero divisor"));
            let mut rem = Self::zero_with_precision(rhs.bits_precision());
            rem.limbs[0] = rem_limb;
            return (quo, rem);
        }

        // Compute the size of the divisor
        let ybits = rhs.bits();
        assert!(ybits > 0, "zero divisor");
        let ywords = ybits.div_ceil(Limb::BITS);

        // Shift the entire divisor such that the high bit is set
        let mut y = rhs.shl(rhs.bits_precision() - ybits).to_limbs();

        // Shift the dividend to align the words
        let lshift = (Limb::BITS - (ybits % Limb::BITS)) % Limb::BITS;
        let (x, mut x_hi) = self.shl_limb(lshift);
        let mut x = x.to_limbs();

        // Calculate a reciprocal from the highest word of the divisor
        let reciprocal = Reciprocal::new(y[ysize - 1].to_nz().expect("zero divisor"));

        let mut xi = xsize - 1;
        let mut x_lo = x[xi];
        let mut i;
        let mut carry;

        while xi > 0 {
            // Divide high dividend words by the high divisor word to estimate the quotient word
            let mut quo = div3by2(x_hi.0, x_lo.0, x[xi - 1].0, &reciprocal, y[ysize - 2].0);

            // This loop is a no-op once xi is smaller than the number of words in the divisor
            let done = ConstChoice::from_u32_lt(xi as u32, ywords - 1);
            quo = done.select_word(quo, 0);

            // Subtract q*divisor from the dividend
            let borrow = {
                carry = Limb::ZERO;
                let mut borrow = Limb::ZERO;
                let mut tmp;
                i = (xi + 1).saturating_sub(ysize);
                while i <= xi {
                    (tmp, carry) =
                        y[ysize + i - xi - 1].carrying_mul_add(Limb(quo), carry, Limb::ZERO);
                    (x[i], borrow) = x[i].borrowing_sub(tmp, borrow);
                    i += 1;
                }
                (_, borrow) = x_hi.borrowing_sub(carry, borrow);
                borrow
            };

            // If the subtraction borrowed, then decrement q and add back the divisor
            // The probability of this being needed is very low, about 2/(Limb::MAX+1)
            quo = {
                let ct_borrow = ConstChoice::from_word_mask(borrow.0);
                carry = Limb::ZERO;
                i = (xi + 1).saturating_sub(ysize);
                while i <= xi {
                    (x[i], carry) = x[i].carrying_add(
                        Limb::select(Limb::ZERO, y[ysize + i - xi - 1], ct_borrow),
                        carry,
                    );
                    i += 1;
                }
                ct_borrow.select_word(quo, quo.saturating_sub(1))
            };

            // Store the quotient within dividend and set x_hi to the current highest word
            x_hi = Limb::select(x[xi], x_hi, done);
            x[xi] = Limb::select(Limb(quo), x[xi], done);
            x_lo = Limb::select(x[xi - 1], x_lo, done);
            xi -= 1;
        }

        // Calculate quotient and remainder for the case where the divisor is a single word.
        let limb_div = ConstChoice::from_u32_eq(1, ywords);
        // Note that `div2by1()` will panic if `x_hi >= reciprocal.divisor_normalized`,
        // but this can only be the case if `limb_div` is falsy, in which case we discard
        // the result anyway, so we conditionally set `x_hi` to zero for this branch.
        let x_hi_adjusted = Limb::select(Limb::ZERO, x_hi, limb_div);
        let (quo2, rem2) = div2by1(x_hi_adjusted.0, x_lo.0, &reciprocal);

        // Adjust the quotient for single limb division
        x[0] = Limb::select(x[0], Limb(quo2), limb_div);

        // Copy out the low limb of the remainder
        y[0] = Limb::select(x[0], Limb(rem2), limb_div);

        // Note: branching only based on the size of the operands, which is not secret
        let min = if xsize < ysize { xsize } else { ysize };
        let hi_pos = u32_min(xsize as u32, ywords - 1);
        i = 1;
        while i < min {
            y[i] = Limb::select(Limb::ZERO, x[i], ConstChoice::from_u32_lt(i as u32, ywords));
            y[i] = Limb::select(y[i], x_hi, ConstChoice::from_u32_eq(i as u32, hi_pos));
            i += 1;
        }
        while i < ysize {
            y[i] = Limb::select(Limb::ZERO, x_hi, ConstChoice::from_u32_eq(i as u32, hi_pos));
            i += 1;
        }

        let mut x = Self { limbs: x };
        x.wrapping_shr_assign((ywords - 1) * Limb::BITS);
        let mut y = Self { limbs: y };
        y.shr_assign_limb(lshift);
        (x, y)
    }
}

impl CheckedDiv for BoxedUint {
    fn checked_div(&self, rhs: &BoxedUint) -> CtOption<Self> {
        self.checked_div(rhs)
    }
}

impl Div<&NonZero<BoxedUint>> for &BoxedUint {
    type Output = BoxedUint;

    fn div(self, rhs: &NonZero<BoxedUint>) -> Self::Output {
        self.wrapping_div(rhs)
    }
}

impl Div<&NonZero<BoxedUint>> for BoxedUint {
    type Output = BoxedUint;

    fn div(self, rhs: &NonZero<BoxedUint>) -> Self::Output {
        self.wrapping_div(rhs)
    }
}

impl Div<NonZero<BoxedUint>> for &BoxedUint {
    type Output = BoxedUint;

    fn div(self, rhs: NonZero<BoxedUint>) -> Self::Output {
        self.wrapping_div(&rhs)
    }
}

impl Div<NonZero<BoxedUint>> for BoxedUint {
    type Output = BoxedUint;

    fn div(self, rhs: NonZero<BoxedUint>) -> Self::Output {
        self.div_rem(&rhs).0
    }
}

impl DivAssign<&NonZero<BoxedUint>> for BoxedUint {
    fn div_assign(&mut self, rhs: &NonZero<BoxedUint>) {
        *self = self.wrapping_div(rhs);
    }
}

impl DivAssign<NonZero<BoxedUint>> for BoxedUint {
    fn div_assign(&mut self, rhs: NonZero<BoxedUint>) {
        *self = self.wrapping_div(&rhs);
    }
}

impl DivVartime for BoxedUint {
    fn div_vartime(&self, rhs: &NonZero<BoxedUint>) -> Self {
        self.div_rem_vartime(rhs).0
    }
}

impl Div<NonZero<BoxedUint>> for Wrapping<BoxedUint> {
    type Output = Wrapping<BoxedUint>;

    fn div(self, rhs: NonZero<BoxedUint>) -> Self::Output {
        Wrapping(self.0 / rhs)
    }
}

impl Div<NonZero<BoxedUint>> for &Wrapping<BoxedUint> {
    type Output = Wrapping<BoxedUint>;

    fn div(self, rhs: NonZero<BoxedUint>) -> Self::Output {
        Wrapping(self.0.wrapping_div(&rhs))
    }
}

impl Div<&NonZero<BoxedUint>> for &Wrapping<BoxedUint> {
    type Output = Wrapping<BoxedUint>;

    fn div(self, rhs: &NonZero<BoxedUint>) -> Self::Output {
        Wrapping(self.0.wrapping_div(rhs))
    }
}

impl Div<&NonZero<BoxedUint>> for Wrapping<BoxedUint> {
    type Output = Wrapping<BoxedUint>;

    fn div(self, rhs: &NonZero<BoxedUint>) -> Self::Output {
        Wrapping(self.0.wrapping_div(rhs))
    }
}

impl DivAssign<&NonZero<BoxedUint>> for Wrapping<BoxedUint> {
    fn div_assign(&mut self, rhs: &NonZero<BoxedUint>) {
        *self = Wrapping(&self.0 / rhs);
    }
}

impl DivAssign<NonZero<BoxedUint>> for Wrapping<BoxedUint> {
    fn div_assign(&mut self, rhs: NonZero<BoxedUint>) {
        *self /= &rhs;
    }
}

impl Rem<&NonZero<BoxedUint>> for &BoxedUint {
    type Output = BoxedUint;

    #[inline]
    fn rem(self, rhs: &NonZero<BoxedUint>) -> Self::Output {
        self.rem(rhs)
    }
}

impl Rem<&NonZero<BoxedUint>> for BoxedUint {
    type Output = BoxedUint;

    #[inline]
    fn rem(self, rhs: &NonZero<BoxedUint>) -> Self::Output {
        Self::rem(&self, rhs)
    }
}

impl Rem<NonZero<BoxedUint>> for &BoxedUint {
    type Output = BoxedUint;

    #[inline]
    fn rem(self, rhs: NonZero<BoxedUint>) -> Self::Output {
        self.rem(&rhs)
    }
}

impl Rem<NonZero<BoxedUint>> for BoxedUint {
    type Output = BoxedUint;

    #[inline]
    fn rem(self, rhs: NonZero<BoxedUint>) -> Self::Output {
        self.rem(&rhs)
    }
}

impl RemAssign<&NonZero<BoxedUint>> for BoxedUint {
    fn rem_assign(&mut self, rhs: &NonZero<BoxedUint>) {
        *self = Self::rem(self, rhs)
    }
}

impl RemAssign<NonZero<BoxedUint>> for BoxedUint {
    fn rem_assign(&mut self, rhs: NonZero<BoxedUint>) {
        *self = Self::rem(self, &rhs)
    }
}

impl DivRemLimb for BoxedUint {
    fn div_rem_limb_with_reciprocal(&self, reciprocal: &Reciprocal) -> (Self, Limb) {
        Self::div_rem_limb_with_reciprocal(self, reciprocal)
    }
}

impl RemLimb for BoxedUint {
    fn rem_limb_with_reciprocal(&self, reciprocal: &Reciprocal) -> Limb {
        Self::rem_limb_with_reciprocal(self, reciprocal)
    }
}

impl RemMixed<BoxedUint> for BoxedUint {
    fn rem_mixed(&self, reductor: &NonZero<BoxedUint>) -> BoxedUint {
        Self::div_rem_vartime(self, reductor).1
    }
}

/// Computes `limbs << shift` inplace, where `0 <= shift < Limb::BITS`, returning the carry.
fn shl_limb_vartime(limbs: &mut [Limb], shift: u32) -> Limb {
    if shift == 0 {
        return Limb::ZERO;
    }

    let lshift = shift;
    let rshift = Limb::BITS - shift;
    let limbs_num = limbs.len();

    let carry = limbs[limbs_num - 1] >> rshift;
    for i in (1..limbs_num).rev() {
        limbs[i] = (limbs[i] << lshift) | (limbs[i - 1] >> rshift);
    }
    limbs[0] <<= lshift;

    carry
}

/// Computes `limbs >> shift` inplace, where `0 <= shift < Limb::BITS`.
fn shr_limb_vartime(limbs: &mut [Limb], shift: u32) {
    if shift == 0 {
        return;
    }

    let lshift = Limb::BITS - shift;
    let rshift = shift;

    let limbs_num = limbs.len();

    for i in 0..limbs_num - 1 {
        limbs[i] = (limbs[i] >> rshift) | (limbs[i + 1] << lshift);
    }
    limbs[limbs_num - 1] >>= rshift;
}

/// Computes `x` / `y`, returning the quotient in `x` and the remainder in `y`.
///
/// This function operates in variable-time. It will panic if the divisor is zero
/// or the leading word of the divisor is zero.
pub(crate) fn div_rem_vartime_in_place(x: &mut [Limb], y: &mut [Limb]) {
    let xc = x.len();
    let yc = y.len();
    assert!(
        yc > 0 && y[yc - 1].0 != 0,
        "divisor must have a non-zero leading word"
    );

    if xc == 0 {
        // If the quotient is empty, set the remainder to zero and return.
        y.fill(Limb::ZERO);
        return;
    } else if yc > xc {
        // Divisor is greater than dividend. Return zero and the dividend as the
        // quotient and remainder
        y[..xc].copy_from_slice(&x[..xc]);
        y[xc..].fill(Limb::ZERO);
        x.fill(Limb::ZERO);
        return;
    }

    let lshift = y[yc - 1].leading_zeros();

    // Shift divisor such that it has no leading zeros
    // This means that div2by1 requires no extra shifts, and ensures that the high word >= b/2
    shl_limb_vartime(y, lshift);

    // Shift the dividend to match
    let mut x_hi = shl_limb_vartime(x, lshift);

    let reciprocal = Reciprocal::new(y[yc - 1].to_nz().expect("zero divisor"));

    for xi in (yc - 1..xc).rev() {
        // Divide high dividend words by the high divisor word to estimate the quotient word
        let mut quo = div3by2(x_hi.0, x[xi].0, x[xi - 1].0, &reciprocal, y[yc - 2].0);

        // Subtract q*divisor from the dividend
        let borrow = {
            let mut carry = Limb::ZERO;
            let mut borrow = Limb::ZERO;
            let mut tmp;
            for i in 0..yc {
                (tmp, carry) = y[i].carrying_mul_add(Limb(quo), carry, Limb::ZERO);
                (x[xi + i + 1 - yc], borrow) = x[xi + i + 1 - yc].borrowing_sub(tmp, borrow);
            }
            (_, borrow) = x_hi.borrowing_sub(carry, borrow);
            borrow
        };

        // If the subtraction borrowed, then decrement q and add back the divisor
        // The probability of this being needed is very low, about 2/(Limb::MAX+1)
        quo = {
            let ct_borrow = ConstChoice::from_word_mask(borrow.0);
            let mut carry = Limb::ZERO;
            for i in 0..yc {
                (x[xi + i + 1 - yc], carry) = x[xi + i + 1 - yc]
                    .carrying_add(Limb::select(Limb::ZERO, y[i], ct_borrow), carry);
            }
            ct_borrow.select_word(quo, quo.wrapping_sub(1))
        };

        // Store the quotient within dividend and set x_hi to the current highest word
        x_hi = x[xi];
        x[xi] = Limb(quo);
    }

    // Copy the remainder to divisor
    y[..yc - 1].copy_from_slice(&x[..yc - 1]);
    y[yc - 1] = x_hi;

    // Unshift the remainder from the earlier adjustment
    shr_limb_vartime(y, lshift);

    // Shift the quotient to the low limbs within dividend
    // let x_size = xc - yc + 1;
    x.copy_within(yc - 1..xc, 0);
    x[xc - yc + 1..].fill(Limb::ZERO);
}

#[cfg(test)]
mod tests {
    use crate::{DivVartime, Resize, Zero};

    use super::{BoxedUint, Limb, NonZero};

    #[test]
    fn rem() {
        let n = BoxedUint::from(0xFFEECCBBAA99887766u128);
        let p = NonZero::new(BoxedUint::from(997u128)).unwrap();
        assert_eq!(BoxedUint::from(648u128), n.rem(&p));
    }

    #[test]
    fn div_rem_larger_denominator() {
        // 1 = len(x) < len(y) and x < y
        let x = BoxedUint::from_be_hex("8000000000000000", 64).unwrap();
        let y = BoxedUint::from_be_hex("00000000000000010000000000000000", 128)
            .unwrap()
            .to_nz()
            .unwrap();
        let (quo, rem) = x.div_rem(&y);
        assert_eq!(quo, BoxedUint::zero_with_precision(64));
        assert_eq!(rem, x.resize_unchecked(128));

        // 1 = len(x) < len(y) and x > y
        let x = BoxedUint::from_be_hex("8000000000000000", 64).unwrap();
        let y = BoxedUint::from_be_hex("00000000000000000000000000001000", 128)
            .unwrap()
            .to_nz()
            .unwrap();
        let (quo, rem) = x.div_rem(&y);
        assert_eq!(quo, BoxedUint::from_be_hex("0008000000000000", 64).unwrap());
        assert_eq!(rem, BoxedUint::zero_with_precision(128));

        // 2 = len(x) < len(y) and x < y
        let x = BoxedUint::from_be_hex("80000000000000008000000000000000", 128).unwrap();
        let y = BoxedUint::from_be_hex(
            "0000000000000001000000000000000000000000000000010000000000000000",
            256,
        )
        .unwrap()
        .to_nz()
        .unwrap();
        let (quo, rem) = x.div_rem(&y);
        assert_eq!(quo, BoxedUint::zero_with_precision(128));
        assert_eq!(rem, x.resize_unchecked(256));

        // 2 = len(x) < len(y) and x > y
        let x = BoxedUint::from_be_hex("80000000000000008000000000000000", 128).unwrap();
        let y = BoxedUint::from_be_hex(
            "0000000000000000000000000000000000000000000000000000000000110000",
            256,
        )
        .unwrap()
        .to_nz()
        .unwrap();
        let (quo, rem) = x.div_rem(&y);
        assert_eq!(
            quo,
            BoxedUint::from_be_hex("000007878787878787878f0f0f0f0f0f", 128).unwrap()
        );
        assert_eq!(
            rem,
            BoxedUint::from_be_hex(
                "0000000000000000000000000000000000000000000000000000000000010000",
                256
            )
            .unwrap()
        );
    }

    #[test]
    fn rem_vartime() {
        let n = BoxedUint::from(0xFFEECCBBAA99887766u128);
        let p = NonZero::new(BoxedUint::from(997u128)).unwrap();
        assert_eq!(BoxedUint::from(648u128), n.rem_vartime(&p));
    }

    #[test]
    fn rem_limb() {
        let n = BoxedUint::from(0xFFEECCBBAA99887766u128);
        let pl = NonZero::new(Limb(997)).unwrap();
        let p = NonZero::new(BoxedUint::from(997u128)).unwrap();
        assert_eq!(n.rem(&p).limbs[0], n.rem_limb(pl));
    }

    #[test]
    fn div_vartime_through_trait() {
        struct A<T> {
            x: T,
            y: T,
        }
        impl<T: DivVartime + Clone + Zero> A<T> {
            fn divide_x_by_y(&self) -> T {
                let rhs = &NonZero::new(self.y.clone()).unwrap();
                self.x.div_vartime(rhs)
            }
        }

        let a = A {
            x: BoxedUint::from(1234567890u64),
            y: BoxedUint::from(456u64),
        };
        assert_eq!(a.divide_x_by_y(), BoxedUint::from(2707385u64));
    }
}
