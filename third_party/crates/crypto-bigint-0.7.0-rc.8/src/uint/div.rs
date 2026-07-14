//! [`Uint`] division operations.

use super::div_limb::{
    Reciprocal, div_rem_limb_with_reciprocal, div2by1, div3by2, rem_limb_with_reciprocal,
    rem_limb_with_reciprocal_wide,
};
use crate::{
    CheckedDiv, ConstChoice, DivRemLimb, DivVartime, Limb, NonZero, RemLimb, Uint, Wrapping,
    const_choice::u32_min,
};
use core::ops::{Div, DivAssign, Rem, RemAssign};

use subtle::CtOption;

impl<const LIMBS: usize> Uint<LIMBS> {
    /// Computes `self / rhs` using a pre-made reciprocal,
    /// returns the quotient (q) and remainder (r).
    #[inline(always)]
    pub const fn div_rem_limb_with_reciprocal(&self, reciprocal: &Reciprocal) -> (Self, Limb) {
        div_rem_limb_with_reciprocal(self, reciprocal)
    }

    /// Computes `self / rhs`, returns the quotient (q) and remainder (r).
    #[inline(always)]
    pub const fn div_rem_limb(&self, rhs: NonZero<Limb>) -> (Self, Limb) {
        div_rem_limb_with_reciprocal(self, &Reciprocal::new(rhs))
    }

    /// Computes `self % rhs` using a pre-made reciprocal.
    #[inline(always)]
    pub const fn rem_limb_with_reciprocal(&self, reciprocal: &Reciprocal) -> Limb {
        rem_limb_with_reciprocal(self, reciprocal)
    }

    /// Computes `self % rhs`.
    #[inline(always)]
    pub const fn rem_limb(&self, rhs: NonZero<Limb>) -> Limb {
        rem_limb_with_reciprocal(self, &Reciprocal::new(rhs))
    }

    /// Computes `self` / `rhs`, returns the quotient (q) and the remainder (r)
    ///
    /// This function is constant-time with respect to both `self` and `rhs`.
    pub const fn div_rem<const RHS_LIMBS: usize>(
        &self,
        rhs: &NonZero<Uint<RHS_LIMBS>>,
    ) -> (Self, Uint<RHS_LIMBS>) {
        // Based on Section 4.3.1, of The Art of Computer Programming, Volume 2, by Donald E. Knuth.
        // Further explanation at https://janmr.com/blog/2014/04/basic-multiple-precision-long-division/

        // Statically determined short circuit for a single-limb sized divisor
        if RHS_LIMBS == 1 {
            let (quo, rem_limb) = self.div_rem_limb(rhs.0.limbs[0].to_nz().expect("zero divisor"));
            let mut rem = Uint::<RHS_LIMBS>::ZERO;
            rem.limbs[0] = rem_limb;
            return (quo, rem);
        }

        let dbits = rhs.0.bits();
        assert!(dbits > 0, "zero divisor");
        let dwords = dbits.div_ceil(Limb::BITS);

        // Shift the entire divisor such that the high bit is set
        let mut y = rhs.0.shl(Uint::<RHS_LIMBS>::BITS - dbits).to_limbs();

        // Shift the dividend to align the words
        let lshift = (Limb::BITS - (dbits % Limb::BITS)) % Limb::BITS;
        let (x, mut x_hi) = self.shl_limb(lshift);
        let mut x = x.to_limbs();

        // Calculate a reciprocal from the highest word of the divisor
        let reciprocal = Reciprocal::new(y[RHS_LIMBS - 1].to_nz().expect("zero divisor"));

        let mut xi = LIMBS - 1;
        let mut x_lo = x[xi];
        let mut i;
        let mut carry;

        while xi > 0 {
            // Divide high dividend words by the high divisor word to estimate the quotient word
            let mut quo = div3by2(x_hi.0, x_lo.0, x[xi - 1].0, &reciprocal, y[RHS_LIMBS - 2].0);

            // This loop is a no-op once xi is smaller than the number of words in the divisor
            let done = ConstChoice::from_u32_lt(xi as u32, dwords - 1);
            quo = done.select_word(quo, 0);

            // Subtract q*divisor from the dividend
            let borrow = {
                carry = Limb::ZERO;
                let mut borrow = Limb::ZERO;
                let mut tmp;
                i = (xi + 1).saturating_sub(RHS_LIMBS);
                while i <= xi {
                    (tmp, carry) =
                        y[RHS_LIMBS + i - xi - 1].carrying_mul_add(Limb(quo), carry, Limb::ZERO);
                    (x[i], borrow) = x[i].borrowing_sub(tmp, borrow);
                    i += 1;
                }
                x_hi.borrowing_sub(carry, borrow).1
            };

            // If the subtraction borrowed, then decrement q and add back the divisor
            // The probability of this being needed is very low, about 2/(Limb::MAX+1)
            quo = {
                let ct_borrow = ConstChoice::from_word_mask(borrow.0);
                carry = Limb::ZERO;
                i = (xi + 1).saturating_sub(RHS_LIMBS);
                while i <= xi {
                    (x[i], carry) = x[i].carrying_add(
                        Limb::select(Limb::ZERO, y[RHS_LIMBS + i - xi - 1], ct_borrow),
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

        // Calculate quotient and remainder for the case where the divisor is a single word
        let limb_div = ConstChoice::from_u32_eq(1, dwords);
        // Note that `div2by1()` will panic if `x_hi >= reciprocal.divisor_normalized`,
        // but this can only be the case if `limb_div` is falsy, in which case we discard
        // the result anyway, so we conditionally set `x_hi` to zero for this branch
        let x_hi_adjusted = Limb::select(Limb::ZERO, x_hi, limb_div);
        let (quo2, rem2) = div2by1(x_hi_adjusted.0, x_lo.0, &reciprocal);

        // Adjust the quotient for single limb division
        x[0] = Limb::select(x[0], Limb(quo2), limb_div);

        // Copy out the low limb of the remainder
        y[0] = Limb::select(x[0], Limb(rem2), limb_div);

        // Note: this does not invalidate the constant time contract; branching on constants
        let min = if LIMBS < RHS_LIMBS { LIMBS } else { RHS_LIMBS };
        let hi_pos = u32_min(LIMBS as u32, dwords - 1);
        i = 1;
        while i < min {
            y[i] = Limb::select(Limb::ZERO, x[i], ConstChoice::from_u32_lt(i as u32, dwords));
            y[i] = Limb::select(y[i], x_hi, ConstChoice::from_u32_eq(i as u32, hi_pos));
            i += 1;
        }
        while i < RHS_LIMBS {
            y[i] = Limb::select(Limb::ZERO, x_hi, ConstChoice::from_u32_eq(i as u32, hi_pos));
            i += 1;
        }

        (
            Uint::new(x).wrapping_shr_by_limbs(dwords - 1),
            Uint::new(y).shr_limb(lshift).0,
        )
    }

    /// Computes `self << shift` where `0 <= shift < Limb::BITS`,
    /// returning the result and the carry.
    ///
    /// Note: assumes that `self` only has `limb_num` lowest non-zero limbs.
    const fn shl_limb_vartime(&self, shift: u32, limbs_num: usize) -> (Self, Limb) {
        if shift == 0 {
            return (*self, Limb::ZERO);
        }

        let mut limbs = [Limb::ZERO; LIMBS];

        let lshift = shift;
        let rshift = Limb::BITS - shift;

        let carry = self.limbs[limbs_num - 1].0 >> rshift;
        let mut i = limbs_num - 1;
        while i > 0 {
            limbs[i] = Limb((self.limbs[i].0 << lshift) | (self.limbs[i - 1].0 >> rshift));
            i -= 1;
        }
        limbs[0] = Limb(self.limbs[0].0 << lshift);

        (Uint::<LIMBS>::new(limbs), Limb(carry))
    }

    /// Computes `self >> shift` where `0 <= shift < Limb::BITS`.
    ///
    /// Note: assumes that `self` only has `limb_num` lowest non-zero limbs.
    const fn shr_limb_vartime(&self, shift: u32, limbs_num: usize) -> Self {
        if shift == 0 {
            return *self;
        }

        let mut limbs = [Limb::ZERO; LIMBS];

        let lshift = Limb::BITS - shift;
        let rshift = shift;

        let mut i = 0;
        while i < limbs_num - 1 {
            limbs[i] = Limb((self.limbs[i].0 >> rshift) | (self.limbs[i + 1].0 << lshift));
            i += 1;
        }
        limbs[limbs_num - 1] = Limb(self.limbs[limbs_num - 1].0 >> rshift);

        Uint::<LIMBS>::new(limbs)
    }

    /// Computes `self` / `rhs`, returns the quotient (q) and the remainder (r)
    ///
    /// This is variable only with respect to `rhs`.
    ///
    /// When used with a fixed `rhs`, this function is constant-time with respect
    /// to `self`.
    pub const fn div_rem_vartime<const RHS_LIMBS: usize>(
        &self,
        rhs: &NonZero<Uint<RHS_LIMBS>>,
    ) -> (Self, Uint<RHS_LIMBS>) {
        // Based on Section 4.3.1, of The Art of Computer Programming, Volume 2, by Donald E. Knuth.
        // Further explanation at https://janmr.com/blog/2014/04/basic-multiple-precision-long-division/

        let dbits = rhs.0.bits_vartime();
        let yc = dbits.div_ceil(Limb::BITS) as usize;

        // Short circuit for small or extra large divisors
        if yc == 1 {
            // If the divisor is a single limb, use limb division
            let (q, r) = div_rem_limb_with_reciprocal(
                self,
                &Reciprocal::new(rhs.0.limbs[0].to_nz().expect("zero divisor")),
            );
            return (q, Uint::from_word(r.0));
        }
        if yc > LIMBS {
            // Divisor is greater than dividend. Return zero and the dividend as the
            // quotient and remainder
            return (Uint::ZERO, self.resize());
        }

        // The shift needed to set the MSB of the highest nonzero limb of the divisor.
        // 2^shift == d in the algorithm above.
        let shift = (Limb::BITS - (dbits % Limb::BITS)) % Limb::BITS;

        let (x, mut x_hi) = self.shl_limb_vartime(shift, LIMBS);
        let mut x = x.to_limbs();
        let (y, _) = rhs.0.shl_limb_vartime(shift, yc);
        let mut y = y.to_limbs();

        let reciprocal = Reciprocal::new(y[yc - 1].to_nz().expect("zero divisor"));

        let mut i;

        let mut xi = LIMBS - 1;

        loop {
            // Divide high dividend words by the high divisor word to estimate the quotient word
            let mut quo = div3by2(x_hi.0, x[xi].0, x[xi - 1].0, &reciprocal, y[yc - 2].0);

            // Subtract q*divisor from the dividend
            let borrow = {
                let mut carry = Limb::ZERO;
                let mut borrow = Limb::ZERO;
                let mut tmp;
                i = 0;
                while i < yc {
                    (tmp, carry) = y[i].carrying_mul_add(Limb(quo), carry, Limb::ZERO);
                    (x[xi + i + 1 - yc], borrow) = x[xi + i + 1 - yc].borrowing_sub(tmp, borrow);
                    i += 1;
                }
                (_, borrow) = x_hi.borrowing_sub(carry, borrow);
                borrow
            };

            // If the subtraction borrowed, then decrement q and add back the divisor
            // The probability of this being needed is very low, about 2/(Limb::MAX+1)
            quo = {
                let ct_borrow = ConstChoice::from_word_mask(borrow.0);
                let mut carry = Limb::ZERO;
                i = 0;
                while i < yc {
                    (x[xi + i + 1 - yc], carry) = x[xi + i + 1 - yc]
                        .carrying_add(Limb::select(Limb::ZERO, y[i], ct_borrow), carry);
                    i += 1;
                }
                ct_borrow.select_word(quo, quo.wrapping_sub(1))
            };

            // Store the quotient within dividend and set x_hi to the current highest word
            x_hi = x[xi];
            x[xi] = Limb(quo);

            if xi == yc - 1 {
                break;
            }
            xi -= 1;
        }

        // Copy the remainder to divisor
        i = 0;
        while i < yc - 1 {
            y[i] = x[i];
            i += 1;
        }
        y[yc - 1] = x_hi;

        // Unshift the remainder from the earlier adjustment
        let y = Uint::new(y).shr_limb_vartime(shift, yc);

        // Shift the quotient to the low limbs within dividend
        i = 0;
        while i < LIMBS {
            if i <= (LIMBS - yc) {
                x[i] = x[i + yc - 1];
            } else {
                x[i] = Limb::ZERO;
            }
            i += 1;
        }

        (Uint::new(x), y)
    }

    /// Computes `self` % `rhs`, returns the remainder.
    pub const fn rem<const RHS_LIMBS: usize>(
        &self,
        rhs: &NonZero<Uint<RHS_LIMBS>>,
    ) -> Uint<RHS_LIMBS> {
        self.div_rem(rhs).1
    }

    /// Computes `self` % `rhs`, returns the remainder in variable-time with respect to `rhs`.
    ///
    /// When used with a fixed `rhs`, this function is constant-time with respect
    /// to `self`.
    pub const fn rem_vartime(&self, rhs: &NonZero<Self>) -> Self {
        self.div_rem_vartime(rhs).1
    }

    /// Computes `self` % `rhs`, returns the remainder.
    pub const fn rem_wide(lower_upper: (Self, Self), rhs: &NonZero<Self>) -> Self {
        // Statically determined short circuit for Uint<1>
        if LIMBS == 1 {
            let r = rem_limb_with_reciprocal_wide(
                (&lower_upper.0, &lower_upper.1),
                &Reciprocal::new(rhs.0.limbs[0].to_nz().expect("zero divisor")),
            );
            return Uint::from_word(r.0);
        }

        let dbits = rhs.0.bits();
        let dwords = dbits.div_ceil(Limb::BITS);
        let lshift = (Limb::BITS - (dbits % Limb::BITS)) % Limb::BITS;

        // Shift entire divisor such that the high bit is set
        let y = rhs.0.shl(Uint::<LIMBS>::BITS - dbits).to_limbs();
        // Shift the dividend to align the words
        let (x_lo, x_lo_carry) = lower_upper.0.shl_limb(lshift);
        let (x, mut x_hi) = lower_upper.1.shl_limb(lshift);
        let mut x = x.to_limbs();
        x[0] = Limb(x[0].0 | x_lo_carry.0);

        let mut xi = LIMBS - 1;
        let mut extra_limbs = LIMBS;
        let mut i;
        let mut carry;

        let reciprocal = Reciprocal::new(y[LIMBS - 1].to_nz().expect("zero divisor"));

        // We proceed similarly to `div_rem_vartime()` applied to the high half of
        // the dividend, fetching the limbs from the lower part as we go.

        while xi > 0 {
            // Divide high dividend words by the high divisor word to estimate the quotient word
            let mut quo = div3by2(x_hi.0, x[xi].0, x[xi - 1].0, &reciprocal, y[LIMBS - 2].0);

            // This loop is a no-op once xi is smaller than the number of words in the divisor
            let done = ConstChoice::from_u32_lt(xi as u32, dwords - 1);
            quo = done.select_word(quo, 0);

            // Subtract q*divisor from the dividend
            let borrow = {
                carry = Limb::ZERO;
                let mut borrow = Limb::ZERO;
                let mut tmp;
                i = (xi + 1).saturating_sub(LIMBS);
                while i <= xi {
                    (tmp, carry) =
                        y[LIMBS + i - xi - 1].carrying_mul_add(Limb(quo), carry, Limb::ZERO);
                    (x[i], borrow) = x[i].borrowing_sub(tmp, borrow);
                    i += 1;
                }
                (_, borrow) = x_hi.borrowing_sub(carry, borrow);
                borrow
            };

            // If the subtraction borrowed, then add back the divisor
            // The probability of this being needed is very low, about 2/(Limb::MAX+1)
            {
                let ct_borrow = ConstChoice::from_word_mask(borrow.0);
                carry = Limb::ZERO;
                i = (xi + 1).saturating_sub(LIMBS);
                while i <= xi {
                    (x[i], carry) = x[i].carrying_add(
                        Limb::select(Limb::ZERO, y[LIMBS + i - xi - 1], ct_borrow),
                        carry,
                    );
                    i += 1;
                }
            }

            // If we have lower limbs remaining, shift the divisor words one word left
            if extra_limbs > 0 {
                extra_limbs -= 1;
                x_hi = x[xi];
                i = LIMBS - 1;
                while i > 0 {
                    x[i] = x[i - 1];
                    i -= 1;
                }
                x[0] = x_lo.limbs[extra_limbs];
            } else {
                x_hi = Limb::select(x[xi], x_hi, done);
                x[xi] = Limb::select(
                    Limb::ZERO,
                    x[xi],
                    ConstChoice::from_u32_lt(xi as u32, dwords),
                );
                x[xi] = Limb::select(x[xi], x_hi, ConstChoice::from_u32_eq(xi as u32, dwords - 1));
                xi -= 1;
            }
        }

        // Calculate quotient and remainder for the case where the divisor is a single word
        // Note that `div2by1()` will panic if `x_hi >= reciprocal.divisor_normalized`,
        // but this can only be the case if `limb_div` is falsy,
        // in which case we discard the result anyway,
        // so we conditionally set `x_hi` to zero for this branch.
        let limb_div = ConstChoice::from_u32_eq(1, dwords);
        let x_hi_adjusted = Limb::select(Limb::ZERO, x_hi, limb_div);
        let (_, rem) = div2by1(x_hi_adjusted.0, x[0].0, &reciprocal);
        x[0] = Limb::select(x[0], Limb(rem), limb_div);

        // Unshift the remainder from the earlier adjustment
        Uint::new(x).shr_limb(lshift).0
    }

    /// Computes `self` % `rhs`, returns the remainder.
    ///
    /// This is variable only with respect to `rhs`.
    ///
    /// When used with a fixed `rhs`, this function is constant-time with respect
    /// to `self`.
    pub const fn rem_wide_vartime(lower_upper: (Self, Self), rhs: &NonZero<Self>) -> Self {
        let dbits = rhs.0.bits_vartime();
        let yc = dbits.div_ceil(Limb::BITS) as usize;

        // If the divisor is a single limb, use limb division
        if yc == 1 {
            let r = rem_limb_with_reciprocal_wide(
                (&lower_upper.0, &lower_upper.1),
                &Reciprocal::new(rhs.0.limbs[0].to_nz().expect("zero divisor")),
            );
            return Uint::from_word(r.0);
        }

        // The shift needed to set the MSB of the highest nonzero limb of the divisor.
        // 2^shift == d in the algorithm above.
        let shift = (Limb::BITS - (dbits % Limb::BITS)) % Limb::BITS;

        let (y, _) = rhs.0.shl_limb_vartime(shift, yc);
        let y = y.to_limbs();

        let (x_lo, x_lo_carry) = lower_upper.0.shl_limb_vartime(shift, LIMBS);
        let (x, mut x_hi) = lower_upper.1.shl_limb_vartime(shift, LIMBS);
        let mut x = x.to_limbs();
        if shift > 0 {
            x[0] = Limb(x[0].0 | x_lo_carry.0);
        }

        let reciprocal = Reciprocal::new(y[yc - 1].to_nz().expect("zero divisor"));

        let mut xi = LIMBS - 1;
        let mut extra_limbs = LIMBS;
        let mut i;

        // Note that in the algorithm we only ever need to access the highest `yc` limbs
        // of the dividend, and since `yc < LIMBS`, we only need to access
        // the high half of the dividend.
        //
        // So we proceed similarly to `div_rem_vartime()` applied to the high half of the dividend,
        // fetching the limbs from the lower part as we go.

        loop {
            // Divide high dividend words by the high divisor word to estimate the quotient word
            let quo = div3by2(x_hi.0, x[xi].0, x[xi - 1].0, &reciprocal, y[yc - 2].0);

            // Subtract q*divisor from the dividend
            let borrow = {
                let mut carry = Limb::ZERO;
                let mut borrow = Limb::ZERO;
                let mut tmp;
                i = 0;
                while i < yc {
                    (tmp, carry) = y[i].carrying_mul_add(Limb(quo), carry, Limb::ZERO);
                    (x[xi + i + 1 - yc], borrow) = x[xi + i + 1 - yc].borrowing_sub(tmp, borrow);
                    i += 1;
                }
                (_, borrow) = x_hi.borrowing_sub(carry, borrow);
                borrow
            };

            // If the subtraction borrowed, then add back the divisor
            // The probability of this being needed is very low, about 2/(Limb::MAX+1)
            {
                let ct_borrow = ConstChoice::from_word_mask(borrow.0);
                let mut carry = Limb::ZERO;
                i = 0;
                while i < yc {
                    (x[xi + i + 1 - yc], carry) = x[xi + i + 1 - yc]
                        .carrying_add(Limb::select(Limb::ZERO, y[i], ct_borrow), carry);
                    i += 1;
                }
            }

            // Set x_hi to the current highest word
            x_hi = x[xi];

            // If we have lower limbs remaining, shift the divisor words one word left
            if extra_limbs > 0 {
                extra_limbs -= 1;
                i = LIMBS - 1;
                while i > 0 {
                    x[i] = x[i - 1];
                    i -= 1;
                }
                x[0] = x_lo.limbs[extra_limbs];
            } else {
                if xi == yc - 1 {
                    break;
                }
                x[xi] = Limb::ZERO;
                xi -= 1;
            }
        }

        // Unshift the remainder from the earlier adjustment
        Uint::new(x).shr_limb_vartime(shift, yc)
    }

    /// Computes `self` % 2^k. Faster than reduce since its a power of 2.
    /// Limited to 2^16-1 since Uint doesn't support higher.
    ///
    /// ### Usage:
    /// ```
    /// use crypto_bigint::{U448, Limb};
    ///
    /// let a = U448::from(10_u64);
    /// let k = 3; // 2^3 = 8
    /// let remainder = a.rem2k_vartime(k);
    ///
    /// // As 10 % 8 = 2
    /// assert_eq!(remainder, U448::from(2_u64));
    /// ```
    pub const fn rem2k_vartime(&self, k: u32) -> Self {
        let highest = (LIMBS - 1) as u32;
        let index = k / Limb::BITS;
        let le = ConstChoice::from_u32_le(index, highest);
        let limb_num = le.select_u32(highest, index) as usize;

        let base = k % Limb::BITS;
        let mask = (1 << base) - 1;
        let mut out = *self;

        let outmask = Limb(out.limbs[limb_num].0 & mask);

        out.limbs[limb_num] = Limb::select(out.limbs[limb_num], outmask, le);

        // TODO: this is not constant-time.
        let mut i = limb_num + 1;
        while i < LIMBS {
            out.limbs[i] = Limb::ZERO;
            i += 1;
        }

        out
    }

    /// Wrapped division is just normal division i.e. `self` / `rhs`
    ///
    /// There’s no way wrapping could ever happen.
    /// This function exists, so that all operations are accounted for in the wrapping operations.
    pub const fn wrapping_div(&self, rhs: &NonZero<Self>) -> Self {
        self.div_rem(rhs).0
    }

    /// Wrapped division is just normal division i.e. `self` / `rhs`
    ///
    /// There’s no way wrapping could ever happen.
    /// This function exists, so that all operations are accounted for in the wrapping operations.
    pub const fn wrapping_div_vartime<const RHS: usize>(&self, rhs: &NonZero<Uint<RHS>>) -> Self {
        self.div_rem_vartime(rhs).0
    }

    /// Perform checked division, returning a [`CtOption`] which `is_some`
    /// only if the rhs != 0
    ///
    /// ### Usage:
    /// ```
    /// use crypto_bigint::{U448, NonZero, subtle::{CtOption, Choice}};
    ///
    /// let a = U448::from(8_u64);
    /// let result = NonZero::new(U448::from(4_u64))
    ///     .map(|b| a.div_rem(&b))
    ///     .expect("Division by zero");
    ///
    /// assert_eq!(result.0, U448::from(2_u64));
    ///
    /// // Check division by zero
    /// let zero = U448::from(0_u64);
    /// assert!(bool::from(a.checked_div(&zero).is_none()), "Should be None for division by zero");
    /// ```
    pub fn checked_div<const RHS_LIMBS: usize>(&self, rhs: &Uint<RHS_LIMBS>) -> CtOption<Self> {
        NonZero::new(*rhs).map(|rhs| {
            let (q, _r) = self.div_rem(&rhs);
            q
        })
    }

    /// This function exists, so that all operations are accounted for in the wrapping operations.
    /// Panics if `rhs == 0`.
    ///
    /// ### Usage:
    /// ```
    /// use crypto_bigint::U448;
    ///
    /// let a = U448::from(10_u64);
    /// let b = U448::from(3_u64);
    /// let remainder = a.wrapping_rem_vartime(&b);
    ///
    /// assert_eq!(remainder, U448::from(1_u64));
    /// ```
    pub const fn wrapping_rem_vartime(&self, rhs: &Self) -> Self {
        let nz_rhs = rhs.to_nz().expect("non-zero divisor");
        self.rem_vartime(&nz_rhs)
    }

    /// Perform checked reduction, returning a [`CtOption`] which `is_some`
    /// only if the rhs != 0
    ///
    /// ### Usage:
    /// ```
    /// use crypto_bigint::{U448, NonZero, subtle::{Choice,CtOption}};
    ///
    /// let a = U448::from(10_u64);
    /// let remainder_option = NonZero::new(U448::from(3_u64))
    ///     .map(|b| a.rem(&b));
    ///
    /// assert!(bool::from(remainder_option.is_some()));
    ///
    /// // Check reduction by zero
    /// let zero = U448::from(0_u64);
    ///
    /// assert!(bool::from(a.checked_rem(&zero).is_none()), "Should be None for reduction by zero");
    /// ```
    pub fn checked_rem<const RHS_LIMBS: usize>(
        &self,
        rhs: &Uint<RHS_LIMBS>,
    ) -> CtOption<Uint<RHS_LIMBS>> {
        NonZero::new(*rhs).map(|rhs| self.rem(&rhs))
    }
}

//
// Division by a single limb
//

impl<const LIMBS: usize> Div<&NonZero<Limb>> for &Uint<LIMBS> {
    type Output = Uint<LIMBS>;

    fn div(self, rhs: &NonZero<Limb>) -> Self::Output {
        *self / *rhs
    }
}

impl<const LIMBS: usize> Div<&NonZero<Limb>> for Uint<LIMBS> {
    type Output = Uint<LIMBS>;

    fn div(self, rhs: &NonZero<Limb>) -> Self::Output {
        self / *rhs
    }
}

impl<const LIMBS: usize> Div<NonZero<Limb>> for &Uint<LIMBS> {
    type Output = Uint<LIMBS>;

    fn div(self, rhs: NonZero<Limb>) -> Self::Output {
        *self / rhs
    }
}

impl<const LIMBS: usize> Div<NonZero<Limb>> for Uint<LIMBS> {
    type Output = Uint<LIMBS>;

    fn div(self, rhs: NonZero<Limb>) -> Self::Output {
        let (q, _) = self.div_rem_limb(rhs);
        q
    }
}

impl<const LIMBS: usize> DivAssign<&NonZero<Limb>> for Uint<LIMBS> {
    fn div_assign(&mut self, rhs: &NonZero<Limb>) {
        *self /= *rhs;
    }
}

impl<const LIMBS: usize> DivAssign<NonZero<Limb>> for Uint<LIMBS> {
    fn div_assign(&mut self, rhs: NonZero<Limb>) {
        *self = *self / rhs;
    }
}

impl<const LIMBS: usize> Div<NonZero<Limb>> for Wrapping<Uint<LIMBS>> {
    type Output = Wrapping<Uint<LIMBS>>;

    fn div(self, rhs: NonZero<Limb>) -> Self::Output {
        Wrapping(self.0 / rhs)
    }
}

impl<const LIMBS: usize> Div<NonZero<Limb>> for &Wrapping<Uint<LIMBS>> {
    type Output = Wrapping<Uint<LIMBS>>;

    fn div(self, rhs: NonZero<Limb>) -> Self::Output {
        *self / rhs
    }
}

impl<const LIMBS: usize> Div<&NonZero<Limb>> for &Wrapping<Uint<LIMBS>> {
    type Output = Wrapping<Uint<LIMBS>>;

    fn div(self, rhs: &NonZero<Limb>) -> Self::Output {
        *self / *rhs
    }
}

impl<const LIMBS: usize> Div<&NonZero<Limb>> for Wrapping<Uint<LIMBS>> {
    type Output = Wrapping<Uint<LIMBS>>;

    fn div(self, rhs: &NonZero<Limb>) -> Self::Output {
        self / *rhs
    }
}

impl<const LIMBS: usize> DivAssign<&NonZero<Limb>> for Wrapping<Uint<LIMBS>> {
    fn div_assign(&mut self, rhs: &NonZero<Limb>) {
        *self = Wrapping(self.0 / rhs)
    }
}

impl<const LIMBS: usize> DivAssign<NonZero<Limb>> for Wrapping<Uint<LIMBS>> {
    fn div_assign(&mut self, rhs: NonZero<Limb>) {
        *self /= &rhs;
    }
}

impl<const LIMBS: usize> Rem<&NonZero<Limb>> for &Uint<LIMBS> {
    type Output = Limb;

    fn rem(self, rhs: &NonZero<Limb>) -> Self::Output {
        *self % *rhs
    }
}

impl<const LIMBS: usize> Rem<&NonZero<Limb>> for Uint<LIMBS> {
    type Output = Limb;

    fn rem(self, rhs: &NonZero<Limb>) -> Self::Output {
        self % *rhs
    }
}

impl<const LIMBS: usize> Rem<NonZero<Limb>> for &Uint<LIMBS> {
    type Output = Limb;

    fn rem(self, rhs: NonZero<Limb>) -> Self::Output {
        *self % rhs
    }
}

impl<const LIMBS: usize> Rem<NonZero<Limb>> for Uint<LIMBS> {
    type Output = Limb;

    fn rem(self, rhs: NonZero<Limb>) -> Self::Output {
        let (_, r) = self.div_rem_limb(rhs);
        r
    }
}

impl<const LIMBS: usize> RemAssign<&NonZero<Limb>> for Uint<LIMBS> {
    fn rem_assign(&mut self, rhs: &NonZero<Limb>) {
        *self = (*self % rhs).into();
    }
}

impl<const LIMBS: usize> RemAssign<NonZero<Limb>> for Uint<LIMBS> {
    fn rem_assign(&mut self, rhs: NonZero<Limb>) {
        *self %= &rhs;
    }
}

impl<const LIMBS: usize> Rem<NonZero<Limb>> for Wrapping<Uint<LIMBS>> {
    type Output = Wrapping<Limb>;

    fn rem(self, rhs: NonZero<Limb>) -> Self::Output {
        Wrapping(self.0 % rhs)
    }
}

impl<const LIMBS: usize> Rem<NonZero<Limb>> for &Wrapping<Uint<LIMBS>> {
    type Output = Wrapping<Limb>;

    fn rem(self, rhs: NonZero<Limb>) -> Self::Output {
        *self % rhs
    }
}

impl<const LIMBS: usize> Rem<&NonZero<Limb>> for &Wrapping<Uint<LIMBS>> {
    type Output = Wrapping<Limb>;

    fn rem(self, rhs: &NonZero<Limb>) -> Self::Output {
        *self % *rhs
    }
}

impl<const LIMBS: usize> Rem<&NonZero<Limb>> for Wrapping<Uint<LIMBS>> {
    type Output = Wrapping<Limb>;

    fn rem(self, rhs: &NonZero<Limb>) -> Self::Output {
        self % *rhs
    }
}

impl<const LIMBS: usize> RemAssign<NonZero<Limb>> for Wrapping<Uint<LIMBS>> {
    fn rem_assign(&mut self, rhs: NonZero<Limb>) {
        *self %= &rhs;
    }
}

impl<const LIMBS: usize> RemAssign<&NonZero<Limb>> for Wrapping<Uint<LIMBS>> {
    fn rem_assign(&mut self, rhs: &NonZero<Limb>) {
        *self = Wrapping((self.0 % rhs).into())
    }
}

//
// Division by an Uint
//

impl<const LIMBS: usize, const RHS_LIMBS: usize> CheckedDiv<Uint<RHS_LIMBS>> for Uint<LIMBS> {
    fn checked_div(&self, rhs: &Uint<RHS_LIMBS>) -> CtOption<Self> {
        self.checked_div(rhs)
    }
}

impl<const LIMBS: usize, const RHS_LIMBS: usize> Div<&NonZero<Uint<RHS_LIMBS>>> for &Uint<LIMBS> {
    type Output = Uint<LIMBS>;

    fn div(self, rhs: &NonZero<Uint<RHS_LIMBS>>) -> Self::Output {
        *self / *rhs
    }
}

impl<const LIMBS: usize, const RHS_LIMBS: usize> Div<&NonZero<Uint<RHS_LIMBS>>> for Uint<LIMBS> {
    type Output = Uint<LIMBS>;

    fn div(self, rhs: &NonZero<Uint<RHS_LIMBS>>) -> Self::Output {
        self / *rhs
    }
}

impl<const LIMBS: usize, const RHS_LIMBS: usize> Div<NonZero<Uint<RHS_LIMBS>>> for &Uint<LIMBS> {
    type Output = Uint<LIMBS>;

    fn div(self, rhs: NonZero<Uint<RHS_LIMBS>>) -> Self::Output {
        *self / rhs
    }
}

impl<const LIMBS: usize, const RHS_LIMBS: usize> Div<NonZero<Uint<RHS_LIMBS>>> for Uint<LIMBS> {
    type Output = Uint<LIMBS>;

    fn div(self, rhs: NonZero<Uint<RHS_LIMBS>>) -> Self::Output {
        let (q, _) = self.div_rem(&rhs);
        q
    }
}

impl<const LIMBS: usize> DivAssign<&NonZero<Uint<LIMBS>>> for Uint<LIMBS> {
    fn div_assign(&mut self, rhs: &NonZero<Uint<LIMBS>>) {
        *self /= *rhs
    }
}

impl<const LIMBS: usize> DivAssign<NonZero<Uint<LIMBS>>> for Uint<LIMBS> {
    fn div_assign(&mut self, rhs: NonZero<Uint<LIMBS>>) {
        *self = *self / rhs;
    }
}

impl<const LIMBS: usize, const RHS_LIMBS: usize> Div<NonZero<Uint<RHS_LIMBS>>>
    for Wrapping<Uint<LIMBS>>
{
    type Output = Wrapping<Uint<LIMBS>>;

    fn div(self, rhs: NonZero<Uint<RHS_LIMBS>>) -> Self::Output {
        Wrapping(self.0 / rhs)
    }
}

impl<const LIMBS: usize, const RHS_LIMBS: usize> Div<NonZero<Uint<RHS_LIMBS>>>
    for &Wrapping<Uint<LIMBS>>
{
    type Output = Wrapping<Uint<LIMBS>>;

    fn div(self, rhs: NonZero<Uint<RHS_LIMBS>>) -> Self::Output {
        *self / rhs
    }
}

impl<const LIMBS: usize, const RHS_LIMBS: usize> Div<&NonZero<Uint<RHS_LIMBS>>>
    for &Wrapping<Uint<LIMBS>>
{
    type Output = Wrapping<Uint<LIMBS>>;

    fn div(self, rhs: &NonZero<Uint<RHS_LIMBS>>) -> Self::Output {
        *self / *rhs
    }
}

impl<const LIMBS: usize, const RHS_LIMBS: usize> Div<&NonZero<Uint<RHS_LIMBS>>>
    for Wrapping<Uint<LIMBS>>
{
    type Output = Wrapping<Uint<LIMBS>>;

    fn div(self, rhs: &NonZero<Uint<RHS_LIMBS>>) -> Self::Output {
        self / *rhs
    }
}

impl<const LIMBS: usize, const RHS_LIMBS: usize> Div<Uint<RHS_LIMBS>> for &Uint<LIMBS> {
    type Output = Uint<LIMBS>;

    #[inline]
    fn div(self, rhs: Uint<RHS_LIMBS>) -> Self::Output {
        self / NonZero::new(rhs).expect("attempt to divide with a divisor of zero")
    }
}

impl<const LIMBS: usize, const RHS_LIMBS: usize> Div<Uint<RHS_LIMBS>> for Uint<LIMBS> {
    type Output = Uint<LIMBS>;

    #[inline]
    fn div(self, rhs: Uint<RHS_LIMBS>) -> Self::Output {
        &self / rhs
    }
}

impl<const LIMBS: usize, const RHS_LIMBS: usize> DivAssign<&NonZero<Uint<RHS_LIMBS>>>
    for Wrapping<Uint<LIMBS>>
{
    fn div_assign(&mut self, rhs: &NonZero<Uint<RHS_LIMBS>>) {
        *self = Wrapping(self.0 / rhs);
    }
}

impl<const LIMBS: usize, const RHS_LIMBS: usize> DivAssign<NonZero<Uint<RHS_LIMBS>>>
    for Wrapping<Uint<LIMBS>>
{
    fn div_assign(&mut self, rhs: NonZero<Uint<RHS_LIMBS>>) {
        *self /= &rhs;
    }
}

impl<const LIMBS: usize> DivVartime for Uint<LIMBS> {
    fn div_vartime(&self, rhs: &NonZero<Uint<LIMBS>>) -> Self {
        self.div_rem_vartime(rhs).0
    }
}

impl<const LIMBS: usize, const RHS_LIMBS: usize> Rem<&NonZero<Uint<RHS_LIMBS>>> for &Uint<LIMBS> {
    type Output = Uint<RHS_LIMBS>;

    fn rem(self, rhs: &NonZero<Uint<RHS_LIMBS>>) -> Self::Output {
        *self % *rhs
    }
}

impl<const LIMBS: usize, const RHS_LIMBS: usize> Rem<&NonZero<Uint<RHS_LIMBS>>> for Uint<LIMBS> {
    type Output = Uint<RHS_LIMBS>;

    fn rem(self, rhs: &NonZero<Uint<RHS_LIMBS>>) -> Self::Output {
        self % *rhs
    }
}

impl<const LIMBS: usize, const RHS_LIMBS: usize> Rem<NonZero<Uint<RHS_LIMBS>>> for &Uint<LIMBS> {
    type Output = Uint<RHS_LIMBS>;

    fn rem(self, rhs: NonZero<Uint<RHS_LIMBS>>) -> Self::Output {
        *self % rhs
    }
}

impl<const LIMBS: usize, const RHS_LIMBS: usize> Rem<NonZero<Uint<RHS_LIMBS>>> for Uint<LIMBS> {
    type Output = Uint<RHS_LIMBS>;

    fn rem(self, rhs: NonZero<Uint<RHS_LIMBS>>) -> Self::Output {
        Self::rem(&self, &rhs)
    }
}

impl<const LIMBS: usize, const RHS_LIMBS: usize> Rem<Uint<RHS_LIMBS>> for &Uint<LIMBS> {
    type Output = Uint<RHS_LIMBS>;

    #[inline]
    fn rem(self, rhs: Uint<RHS_LIMBS>) -> Self::Output {
        self % NonZero::new(rhs).expect("attempt to calculate the remainder with a divisor of zero")
    }
}

impl<const LIMBS: usize, const RHS_LIMBS: usize> Rem<Uint<RHS_LIMBS>> for Uint<LIMBS> {
    type Output = Uint<RHS_LIMBS>;

    #[inline]
    fn rem(self, rhs: Uint<RHS_LIMBS>) -> Self::Output {
        &self % rhs
    }
}

impl<const LIMBS: usize> RemAssign<&NonZero<Uint<LIMBS>>> for Uint<LIMBS> {
    fn rem_assign(&mut self, rhs: &NonZero<Uint<LIMBS>>) {
        *self %= *rhs
    }
}

impl<const LIMBS: usize> RemAssign<NonZero<Uint<LIMBS>>> for Uint<LIMBS> {
    fn rem_assign(&mut self, rhs: NonZero<Uint<LIMBS>>) {
        *self = *self % rhs;
    }
}

impl<const LIMBS: usize, const RHS_LIMBS: usize> Rem<NonZero<Uint<RHS_LIMBS>>>
    for Wrapping<Uint<LIMBS>>
{
    type Output = Wrapping<Uint<RHS_LIMBS>>;

    fn rem(self, rhs: NonZero<Uint<RHS_LIMBS>>) -> Self::Output {
        Wrapping(self.0 % rhs)
    }
}

impl<const LIMBS: usize, const RHS_LIMBS: usize> Rem<NonZero<Uint<RHS_LIMBS>>>
    for &Wrapping<Uint<LIMBS>>
{
    type Output = Wrapping<Uint<RHS_LIMBS>>;

    fn rem(self, rhs: NonZero<Uint<RHS_LIMBS>>) -> Self::Output {
        *self % rhs
    }
}

impl<const LIMBS: usize, const RHS_LIMBS: usize> Rem<&NonZero<Uint<RHS_LIMBS>>>
    for &Wrapping<Uint<LIMBS>>
{
    type Output = Wrapping<Uint<RHS_LIMBS>>;

    fn rem(self, rhs: &NonZero<Uint<RHS_LIMBS>>) -> Self::Output {
        *self % *rhs
    }
}

impl<const LIMBS: usize, const RHS_LIMBS: usize> Rem<&NonZero<Uint<RHS_LIMBS>>>
    for Wrapping<Uint<LIMBS>>
{
    type Output = Wrapping<Uint<RHS_LIMBS>>;

    fn rem(self, rhs: &NonZero<Uint<RHS_LIMBS>>) -> Self::Output {
        self % *rhs
    }
}

impl<const LIMBS: usize> RemAssign<NonZero<Uint<LIMBS>>> for Wrapping<Uint<LIMBS>> {
    fn rem_assign(&mut self, rhs: NonZero<Uint<LIMBS>>) {
        *self %= &rhs;
    }
}

impl<const LIMBS: usize> RemAssign<&NonZero<Uint<LIMBS>>> for Wrapping<Uint<LIMBS>> {
    fn rem_assign(&mut self, rhs: &NonZero<Uint<LIMBS>>) {
        *self = Wrapping(self.0 % rhs)
    }
}

impl<const LIMBS: usize> DivRemLimb for Uint<LIMBS> {
    fn div_rem_limb_with_reciprocal(&self, reciprocal: &Reciprocal) -> (Self, Limb) {
        Self::div_rem_limb_with_reciprocal(self, reciprocal)
    }
}

impl<const LIMBS: usize> RemLimb for Uint<LIMBS> {
    fn rem_limb_with_reciprocal(&self, reciprocal: &Reciprocal) -> Limb {
        Self::rem_limb_with_reciprocal(self, reciprocal)
    }
}

#[cfg(test)]
mod tests {
    use crate::{
        DivVartime, Limb, NonZero, RemMixed, U64, U128, U256, U512, U896, U1024, Uint, Word, Zero,
    };

    #[cfg(feature = "rand")]
    use {
        crate::{CheckedMul, Random},
        rand_chacha::ChaChaRng,
        rand_core::RngCore,
        rand_core::SeedableRng,
    };

    #[test]
    fn div_word() {
        for (n, d, e, ee) in &[
            (200u64, 2u64, 100u64, 0),
            (100u64, 25u64, 4u64, 0),
            (100u64, 10u64, 10u64, 0),
            (1024u64, 8u64, 128u64, 0),
            (27u64, 13u64, 2u64, 1u64),
            (26u64, 13u64, 2u64, 0u64),
            (14u64, 13u64, 1u64, 1u64),
            (13u64, 13u64, 1u64, 0u64),
            (12u64, 13u64, 0u64, 12u64),
            (1u64, 13u64, 0u64, 1u64),
        ] {
            let lhs = U256::from(*n);
            let rhs = NonZero::new(U256::from(*d)).unwrap();
            let (q, r) = lhs.div_rem(&rhs);
            assert_eq!(U256::from(*e), q);
            assert_eq!(U256::from(*ee), r);
            let (q, r) = lhs.div_rem_vartime(&rhs);
            assert_eq!(U256::from(*e), q);
            assert_eq!(U256::from(*ee), r);
        }
    }

    #[cfg(feature = "rand")]
    #[test]
    fn div() {
        let mut rng = ChaChaRng::from_seed([7u8; 32]);
        for _ in 0..25 {
            let num = U256::random(&mut rng).overflowing_shr_vartime(128).unwrap();
            let den =
                NonZero::new(U256::random(&mut rng).overflowing_shr_vartime(128).unwrap()).unwrap();
            let n = num.checked_mul(den.as_ref());
            if n.is_some().into() {
                let (q, _) = n.unwrap().div_rem(&den);
                assert_eq!(q, num);
                let (q, _) = n.unwrap().div_rem_vartime(&den);
                assert_eq!(q, num);
            }
        }
    }

    #[test]
    fn div_max() {
        let mut a = U256::ZERO;
        let mut b = U256::ZERO;
        b.limbs[b.limbs.len() - 1] = Limb(Word::MAX);
        let q = a.wrapping_div(&NonZero::new(b).unwrap());
        assert_eq!(q, Uint::ZERO);
        a.limbs[a.limbs.len() - 1] = Limb(1 << (Limb::HI_BIT - 7));
        b.limbs[b.limbs.len() - 1] = Limb(0x82 << (Limb::HI_BIT - 7));
        let q = a.wrapping_div(&NonZero::new(b).unwrap());
        assert_eq!(q, Uint::ZERO);
    }

    #[test]
    fn div_one() {
        let (q, r) = U256::from(10u8).div_rem(&NonZero::new(U256::ONE).unwrap());
        assert_eq!(q, U256::from(10u8));
        assert_eq!(r, U256::ZERO);
        let (q, r) = U256::from(10u8).div_rem_vartime(&NonZero::new(U256::ONE).unwrap());
        assert_eq!(q, U256::from(10u8));
        assert_eq!(r, U256::ZERO);
    }

    #[test]
    fn div_edge() {
        let lo = U128::from_be_hex("00000000000000000000000000000001");
        let hi = U128::from_be_hex("00000000000000000000000000000001");
        let y = U128::from_be_hex("00000000000000010000000000000001");
        let x = U256::from((lo, hi));
        let expect = (U64::MAX.resize::<{ U256::LIMBS }>(), U256::from(2u64));

        let (q1, r1) = Uint::div_rem(&x, &NonZero::new(y.resize()).unwrap());
        assert_eq!((q1, r1), expect);
        let (q2, r2) = Uint::div_rem_vartime(&x, &NonZero::new(y).unwrap());
        assert_eq!((q2, r2.resize()), expect);
        let r3 = Uint::rem(&x, &NonZero::new(y.resize()).unwrap());
        assert_eq!(r3, expect.1);
        let r4 = Uint::rem_vartime(&x, &NonZero::new(y.resize()).unwrap());
        assert_eq!(r4, expect.1);
        let r5 = Uint::rem_wide((lo, hi), &NonZero::new(y).unwrap());
        assert_eq!(r5.resize(), expect.1);
        let r6 = Uint::rem_wide_vartime((lo, hi), &NonZero::new(y).unwrap());
        assert_eq!(r6.resize(), expect.1);
    }

    #[test]
    fn div_rem_larger_denominator() {
        // 1 = len(x) < len(y) and x < y
        let x = U64::from_be_hex("8000000000000000");
        let y = U128::from_be_hex("00000000000000010000000000000000")
            .to_nz()
            .unwrap();
        let (quo, rem) = x.div_rem(&y);
        assert_eq!(quo, Uint::ZERO);
        assert_eq!(rem, x.resize());

        // 1 = len(x) < len(y) and x > y
        let x = U64::from_be_hex("8000000000000000");
        let y = U128::from_be_hex("00000000000000000000000000001000")
            .to_nz()
            .unwrap();
        let (quo, rem) = x.div_rem(&y);
        assert_eq!(quo, U64::from_be_hex("0008000000000000"));
        assert_eq!(rem, U128::ZERO);

        // 2 = len(x) < len(y) and x < y
        let x = U128::from_be_hex("80000000000000008000000000000000");
        let y =
            U256::from_be_hex("0000000000000001000000000000000000000000000000010000000000000000")
                .to_nz()
                .unwrap();
        let (quo, rem) = x.div_rem(&y);
        assert_eq!(quo, U128::ZERO);
        assert_eq!(rem, x.resize());

        // 2 = len(x) < len(y) and x > y
        let x = U128::from_be_hex("80000000000000008000000000000000");
        let y =
            U256::from_be_hex("0000000000000000000000000000000000000000000000000000000000110000")
                .to_nz()
                .unwrap();
        let (quo, rem) = x.div_rem(&y);
        assert_eq!(quo, U128::from_be_hex("000007878787878787878f0f0f0f0f0f"));
        assert_eq!(
            rem,
            U256::from_be_hex("0000000000000000000000000000000000000000000000000000000000010000",)
        );
    }

    #[test]
    fn div_rem_larger_numerator() {
        let denom = U128::from_be_hex("AAAA0000FFFF11117777333344449999");
        let (full_q, full_r) =
            U1024::MAX.div_rem(&denom.resize::<{ U1024::LIMBS }>().to_nz().unwrap());

        let (q, r) = U1024::MAX.div_rem(&denom.to_nz().unwrap());
        assert_eq!(full_q, q);
        assert_eq!(full_r.resize(), r);
    }

    #[test]
    fn reduce_one() {
        let r = U256::from(10u8).rem_vartime(&NonZero::new(U256::ONE).unwrap());
        assert_eq!(r, U256::ZERO);
    }

    #[test]
    fn reduce_tests() {
        let r = U256::from(10u8).rem_vartime(&NonZero::new(U256::from(2u8)).unwrap());
        assert_eq!(r, U256::ZERO);
        let r = U256::from(10u8).rem_vartime(&NonZero::new(U256::from(3u8)).unwrap());
        assert_eq!(r, U256::ONE);
        let r = U256::from(10u8).rem_vartime(&NonZero::new(U256::from(7u8)).unwrap());
        assert_eq!(r, U256::from(3u8));
    }

    #[test]
    fn reduce_tests_wide_zero_padded() {
        let r = U256::rem_wide_vartime(
            (U256::from(10u8), U256::ZERO),
            &NonZero::new(U256::from(2u8)).unwrap(),
        );
        assert_eq!(r, U256::ZERO);
        let r = U256::rem_wide_vartime(
            (U256::from(10u8), U256::ZERO),
            &NonZero::new(U256::from(3u8)).unwrap(),
        );
        assert_eq!(r, U256::ONE);
        let r = U256::rem_wide_vartime(
            (U256::from(10u8), U256::ZERO),
            &NonZero::new(U256::from(7u8)).unwrap(),
        );
        assert_eq!(r, U256::from(3u8));
        let r = U256::rem_wide_vartime(
            (U256::from(10u8), U256::ZERO),
            &NonZero::new(U256::MAX).unwrap(),
        );
        assert_eq!(r, U256::from(10u8));
    }

    #[test]
    fn rem_wide_corner_case() {
        let modulus = "0000000000000000000000000000000081000000000000000000000000000001";
        let modulus = NonZero::new(U256::from_be_hex(modulus)).expect("it's odd and not zero");
        let lo_hi = (
            U256::from_be_hex("1000000000000000000000000000000000000000000000000000000000000001"),
            U256::ZERO,
        );
        let rem = U256::rem_wide(lo_hi, &modulus);
        // Lower half is zero
        assert_eq!(rem.to_be_bytes()[0..16], U128::ZERO.to_be_bytes());
        // Upper half
        let expected = U128::from_be_hex("203F80FE03F80FE03F80FE03F80FE041");
        assert_eq!(rem.to_be_bytes()[16..], expected.to_be_bytes());

        let remv = U256::rem_wide_vartime(lo_hi, &modulus);
        assert_eq!(rem, remv);
    }

    #[test]
    fn reduce_max() {
        let mut a = U256::ZERO;
        let mut b = U256::ZERO;
        b.limbs[b.limbs.len() - 1] = Limb(Word::MAX);
        let r = a.wrapping_rem_vartime(&b);
        assert_eq!(r, Uint::ZERO);
        a.limbs[a.limbs.len() - 1] = Limb(1 << (Limb::HI_BIT - 7));
        b.limbs[b.limbs.len() - 1] = Limb(0x82 << (Limb::HI_BIT - 7));
        let r = a.wrapping_rem_vartime(&b);
        assert_eq!(r, a);
    }

    #[cfg(feature = "rand")]
    #[test]
    fn rem2krand() {
        let mut rng = ChaChaRng::from_seed([7u8; 32]);
        for _ in 0..25 {
            let num = U256::random(&mut rng);
            let k = rng.next_u32() % 256;
            let den = U256::ONE.overflowing_shl_vartime(k).unwrap();

            let a = num.rem2k_vartime(k);
            let e = num.wrapping_rem_vartime(&den);
            assert_eq!(a, e);
        }
    }

    #[allow(clippy::op_ref)]
    #[test]
    fn rem_trait() {
        let a = U256::from(10u64);
        let b = NonZero::new(U256::from(3u64)).unwrap();
        let c = U256::from(1u64);

        assert_eq!(a % b, c);
        assert_eq!(a % &b, c);
        assert_eq!(&a % b, c);
        assert_eq!(&a % &b, c);
    }

    #[test]
    fn rem_mixed() {
        let x = U1024::from_be_hex(concat![
            "3740C11DB8F260753BC6B97DD2B8746D3E2694412772AC6ABD975119EE0A6190",
            "F27F6F0969BCA069D8D151031AF83EE2283CC2E3E4FADBBDB9EEDBF0B8F4C1FD",
            "51912C0D329FDC37D49176DB0A1A2D17E5E6D4F9F6B217FE9412EAA2F881F702",
            "7A831C1B06D31D3618D218D6E667DBD85BFC7B6B6B93422D52516989376AA29A",
        ]);
        let y = U128::from_u64(1234567890987654321);
        let rem = x.rem_mixed(&y.to_nz().unwrap());

        let y2: U1024 = U128::concat_mixed(&y, &U896::ZERO);
        let rem_control = x.rem(&NonZero::new(y2).unwrap());

        assert_eq!(rem.bits(), rem_control.bits());
        assert_eq!(rem.as_words(), &rem_control.as_words()[0..U128::LIMBS]);
        assert!(
            rem_control.as_words()[U128::LIMBS..]
                .iter()
                .all(|w| *w == 0)
        );
    }

    #[test]
    fn rem_mixed_even() {
        let x = U1024::from_be_hex(concat![
            "3740C11DB8F260753BC6B97DD2B8746D3E2694412772AC6ABD975119EE0A6190",
            "F27F6F0969BCA069D8D151031AF83EE2283CC2E3E4FADBBDB9EEDBF0B8F4C1FD",
            "51912C0D329FDC37D49176DB0A1A2D17E5E6D4F9F6B217FE9412EAA2F881F702",
            "7A831C1B06D31D3618D218D6E667DBD85BFC7B6B6B93422D52516989376AA29A",
        ]);
        let y = U512::from_u64(1234567890987654321);
        let rem: U512 = x.rem_mixed(&y.to_nz().unwrap());

        let y_wide = U512::concat_mixed(&y, &U512::ZERO);
        let rem_control: U1024 = x.rem(&NonZero::new(y_wide).unwrap());

        assert_eq!(rem.bits(), rem_control.bits());
        assert_eq!(rem.as_words(), &rem_control.as_words()[0..U512::LIMBS]);
        assert!(
            rem_control.as_words()[U512::LIMBS..]
                .iter()
                .all(|w| *w == 0)
        );
    }

    #[test]
    fn rem_mixed_through_traits() {
        struct A<T, U> {
            t: T,
            u: U,
        }
        impl<T, U> A<T, U>
        where
            T: RemMixed<U>,
            U: Clone + Zero,
        {
            fn reduce_t_by_u(&self) -> U {
                let rhs = &NonZero::new(self.u.clone()).unwrap();
                self.t.rem_mixed(rhs)
            }
        }

        let a = A {
            t: U1024::from(1234567890u64),
            u: U128::from(456u64),
        };
        assert_eq!(a.reduce_t_by_u(), U128::from(330u64));
    }

    #[test]
    fn div_vartime_through_traits() {
        struct A<T> {
            x: T,
            y: T,
        }
        impl<T> A<T>
        where
            T: DivVartime + Clone + Zero,
        {
            fn divide_x_by_y(&self) -> T {
                let rhs = &NonZero::new(self.y.clone()).unwrap();
                self.x.div_vartime(rhs)
            }
        }

        let a = A {
            x: U1024::from(1234567890u64),
            y: U1024::from(456u64),
        };
        assert_eq!(a.divide_x_by_y(), U1024::from(2707385u64));
    }
}
