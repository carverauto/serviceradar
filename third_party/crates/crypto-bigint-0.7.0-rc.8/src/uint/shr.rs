//! [`Uint`] bitwise right shift operations.

use crate::{ConstChoice, ConstCtOption, Limb, NonZero, ShrVartime, Uint, WrappingShr};
use core::ops::{Shr, ShrAssign};
use subtle::CtOption;

impl<const LIMBS: usize> Uint<LIMBS> {
    /// Computes `self >> shift`.
    ///
    /// Panics if `shift >= Self::BITS`.
    pub const fn shr(&self, shift: u32) -> Self {
        self.overflowing_shr(shift)
            .expect("`shift` within the bit size of the integer")
    }

    /// Computes `self >> shift` in variable time.
    ///
    /// Panics if `shift >= Self::BITS`.
    pub const fn shr_vartime(&self, shift: u32) -> Self {
        self.overflowing_shr_vartime(shift)
            .expect("`shift` within the bit size of the integer")
    }

    /// Computes `self >> shift`.
    ///
    /// Returns `None` if `shift >= Self::BITS`.
    #[inline]
    pub const fn overflowing_shr(&self, shift: u32) -> ConstCtOption<Self> {
        let overflow = ConstChoice::from_u32_lt(shift, Self::BITS).not();
        let result = self.bounded_wrapping_shr(shift % Self::BITS, Self::BITS);
        ConstCtOption::new(Uint::select(&result, &Self::ZERO, overflow), overflow.not())
    }

    /// Computes `self >> shift` where `shift < `shift_upper_bound`, returning zero
    /// if the shift exceeds the precision. The runtime is determined by `shift_upper_bound`
    /// which may be smaller than `Self::BITS`.
    pub(crate) const fn bounded_wrapping_shr(&self, shift: u32, shift_upper_bound: u32) -> Self {
        assert!(shift < shift_upper_bound);
        // `floor(log2(BITS - 1))` is the number of bits in the representation of `shift`
        // (which lies in range `0 <= shift < BITS`).
        let shift_bits = u32::BITS - (shift_upper_bound - 1).leading_zeros();
        let limb_bits = if shift_bits < Limb::LOG2_BITS {
            shift_bits
        } else {
            Limb::LOG2_BITS
        };
        let mut result = *self;
        let mut i = 0;
        while i < limb_bits {
            let bit = ConstChoice::from_u32_lsb((shift >> i) & 1);
            result = result.conditional_shr_limb_nonzero(NonZero(1 << i), bit).0;
            i += 1;
        }
        while i < shift_bits {
            let bit = ConstChoice::from_u32_lsb((shift >> i) & 1);
            result = Uint::select(
                &result,
                &result.wrapping_shr_by_limbs_vartime(1 << (i - Limb::LOG2_BITS)),
                bit,
            );
            i += 1;
        }
        result
    }

    /// Computes `self >> (shift * Limb::BITS)` in a panic-free manner, returning zero if the
    /// shift exceeds the precision.
    ///
    /// NOTE: this operation is variable time with respect to `shift` *ONLY*.
    ///
    /// When used with a fixed `shift`, this function is constant-time with respect to `self`.
    #[inline(always)]
    pub(crate) const fn wrapping_shr_by_limbs_vartime(&self, shift: u32) -> Self {
        let shift = shift as usize;
        let mut limbs = [Limb::ZERO; LIMBS];
        let mut i = 0;
        while i < LIMBS.saturating_sub(shift) {
            limbs[i] = self.limbs[i + shift];
            i += 1;
        }
        Self { limbs }
    }

    /// Computes `self >> (shift * Limb::BITS)` in a panic-free manner, returning zero if the
    /// shift exceeds the precision.
    #[inline(always)]
    pub(crate) const fn wrapping_shr_by_limbs(&self, shift: u32) -> Self {
        let overflow = ConstChoice::from_u32_le(LIMBS as u32, shift);
        let shift_limbs = u32::BITS - (LIMBS as u32 - 1).leading_zeros();
        let mut result = Uint::select(self, &Uint::ZERO, overflow);
        let mut i = 0;
        while i < shift_limbs {
            let bit = ConstChoice::from_u32_lsb((shift >> i) & 1);
            result = Uint::select(&result, &result.wrapping_shr_by_limbs_vartime(1 << i), bit);
            i += 1;
        }
        result
    }

    /// Computes `self >> shift`.
    ///
    /// Returns `None` if `shift >= Self::BITS`.
    ///
    /// NOTE: this operation is variable time with respect to `shift` *ONLY*.
    ///
    /// When used with a fixed `shift`, this function is constant-time with respect to `self`.
    #[inline(always)]
    pub const fn overflowing_shr_vartime(&self, shift: u32) -> ConstCtOption<Self> {
        if shift >= Self::BITS {
            return ConstCtOption::none(Self::ZERO);
        }

        let shift_num = shift / Limb::BITS;
        let mut res = self.wrapping_shr_by_limbs_vartime(shift_num);
        let rem = shift % Limb::BITS;

        if rem != 0 {
            let mut carry = Limb::ZERO;
            let mut i = LIMBS.saturating_sub(shift_num as usize);
            while i > 0 {
                i -= 1;
                (res.limbs[i], carry) = (
                    res.limbs[i].shr(rem).bitor(carry),
                    res.limbs[i].shl(Limb::BITS - rem),
                );
            }
        }

        ConstCtOption::some(res)
    }

    /// Computes a right shift on a wide input as `(lo, hi)`.
    ///
    /// Returns `None` if `shift >= Self::BITS`.
    ///
    /// NOTE: this operation is variable time with respect to `shift` *ONLY*.
    ///
    /// When used with a fixed `shift`, this function is constant-time with respect
    /// to `self`.
    #[inline(always)]
    pub const fn overflowing_shr_vartime_wide(
        lower_upper: (Self, Self),
        shift: u32,
    ) -> ConstCtOption<(Self, Self)> {
        let (lower, upper) = lower_upper;
        if shift >= 2 * Self::BITS {
            ConstCtOption::none((Self::ZERO, Self::ZERO))
        } else if shift >= Self::BITS {
            let lower = upper
                .overflowing_shr_vartime(shift - Self::BITS)
                .expect("shift within range");
            ConstCtOption::some((lower, Self::ZERO))
        } else {
            let new_upper = upper
                .overflowing_shr_vartime(shift)
                .expect("shift within range");
            let lower_hi = upper
                .overflowing_shl_vartime(Self::BITS - shift)
                .expect("shift within range");
            let lower_lo = lower
                .overflowing_shr_vartime(shift)
                .expect("shift within range");
            ConstCtOption::some((lower_lo.bitor(&lower_hi), new_upper))
        }
    }

    /// Computes `self >> shift` in a panic-free manner, returning zero if the shift exceeds the
    /// precision.
    pub const fn wrapping_shr(&self, shift: u32) -> Self {
        self.overflowing_shr(shift).unwrap_or(Self::ZERO)
    }

    /// Computes `self >> shift` in variable-time in a panic-free manner, returning zero if the
    /// shift exceeds the precision.
    pub const fn wrapping_shr_vartime(&self, shift: u32) -> Self {
        self.overflowing_shr_vartime(shift).unwrap_or(Self::ZERO)
    }

    /// Computes `self >> 1` in constant-time.
    pub(crate) const fn shr1(&self) -> Self {
        self.shr1_with_carry().0
    }

    /// Computes `self >> 1` in constant-time, returning [`ConstChoice::TRUE`]
    /// if the least significant bit was set, and [`ConstChoice::FALSE`] otherwise.
    #[inline(always)]
    pub(crate) const fn shr1_with_carry(&self) -> (Self, ConstChoice) {
        let mut ret = Self::ZERO;
        let mut i = LIMBS;
        let mut carry = Limb::ZERO;
        while i > 0 {
            i -= 1;
            let (shifted, new_carry) = self.limbs[i].shr1();
            ret.limbs[i] = shifted.bitor(carry);
            carry = new_carry;
        }

        (ret, ConstChoice::from_word_lsb(carry.0 >> Limb::HI_BIT))
    }

    /// Conditionally right-shifts by `shift` bits where `0 < shift < Limb::BITS`, returning
    /// the carry.
    ///
    /// Panics if `shift >= Limb::BITS`.
    #[inline(always)]
    pub(crate) const fn conditional_shr_limb_nonzero(
        &self,
        shift: NonZero<u32>,
        choice: ConstChoice,
    ) -> (Self, Limb) {
        assert!(shift.0 < Limb::BITS);

        let mut limbs = [Limb::ZERO; LIMBS];
        let rshift = shift.0;
        let lshift = Limb::BITS - shift.0;
        let mut carry = Limb::ZERO;

        let mut i = LIMBS;
        while i > 0 {
            i -= 1;
            (limbs[i], carry) = (
                Limb::select(
                    self.limbs[i],
                    self.limbs[i].shr(rshift).bitor(carry),
                    choice,
                ),
                self.limbs[i].shl(lshift),
            );
        }

        (Self { limbs }, Limb::select(Limb::ZERO, carry, choice))
    }

    /// Computes `self >> shift` where `0 <= shift < Limb::BITS`,
    /// returning the result and the carry.
    ///
    /// Panics if `shift >= Limb::BITS`.
    pub(crate) const fn shr_limb(&self, shift: u32) -> (Self, Limb) {
        let nz = ConstChoice::from_u32_nonzero(shift);
        self.conditional_shr_limb_nonzero(NonZero(nz.select_u32(1, shift)), nz)
    }
}

macro_rules! impl_shr {
    ($($shift:ty),+) => {
        $(
            impl<const LIMBS: usize> Shr<$shift> for Uint<LIMBS> {
                type Output = Uint<LIMBS>;

                #[inline]
                fn shr(self, shift: $shift) -> Uint<LIMBS> {
                    <&Self>::shr(&self, shift)
                }
            }

            impl<const LIMBS: usize> Shr<$shift> for &Uint<LIMBS> {
                type Output = Uint<LIMBS>;

                #[inline]
                fn shr(self, shift: $shift) -> Uint<LIMBS> {
                    Uint::<LIMBS>::shr(self, u32::try_from(shift).expect("invalid shift"))
                }
            }

            impl<const LIMBS: usize> ShrAssign<$shift> for Uint<LIMBS> {
                fn shr_assign(&mut self, shift: $shift) {
                    *self = self.shr(shift)
                }
            }
        )+
    };
}

impl_shr!(i32, u32, usize);

impl<const LIMBS: usize> WrappingShr for Uint<LIMBS> {
    fn wrapping_shr(&self, shift: u32) -> Uint<LIMBS> {
        self.wrapping_shr(shift)
    }
}

impl<const LIMBS: usize> ShrVartime for Uint<LIMBS> {
    fn overflowing_shr_vartime(&self, shift: u32) -> CtOption<Self> {
        self.overflowing_shr(shift).into()
    }
    fn wrapping_shr_vartime(&self, shift: u32) -> Self {
        self.wrapping_shr(shift)
    }
}

#[cfg(test)]
mod tests {
    use crate::{Limb, U128, U256, Uint};

    const N: U256 =
        U256::from_be_hex("FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141");

    const N_2: U256 =
        U256::from_be_hex("7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A0");

    #[test]
    fn shr1() {
        assert_eq!(N.shr1(), N_2);
        assert_eq!(N >> 1, N_2);
    }

    #[test]
    fn shr256_const() {
        assert!(N.overflowing_shr(256).is_none().is_true_vartime());
        assert!(N.overflowing_shr_vartime(256).is_none().is_true_vartime());
    }

    #[test]
    #[should_panic(expected = "`shift` within the bit size of the integer")]
    fn shr256() {
        let _ = N >> 256;
    }

    #[test]
    fn shr_wide_1_1_128() {
        assert_eq!(
            Uint::overflowing_shr_vartime_wide((U128::ONE, U128::ONE), 128).unwrap(),
            (U128::ONE, U128::ZERO)
        );
    }

    #[test]
    fn shr_wide_0_max_1() {
        assert_eq!(
            Uint::overflowing_shr_vartime_wide((U128::ZERO, U128::MAX), 1).unwrap(),
            (U128::ONE << 127, U128::MAX >> 1)
        );
    }

    #[test]
    fn shr_wide_max_max_256() {
        assert!(
            Uint::overflowing_shr_vartime_wide((U128::MAX, U128::MAX), 256)
                .is_none()
                .is_true_vartime()
        );
    }

    #[test]
    #[should_panic]
    fn shr_limb_shift_too_large() {
        let _ = U128::ONE.shr_limb(Limb::BITS);
    }

    #[test]
    fn shr_limb() {
        let val = U128::from_be_hex("876543210FEDCBA90123456FEDCBA987");

        // Shift by zero
        let (res, carry) = val.shr_limb(0);
        assert_eq!(res, val);
        assert_eq!(carry, Limb::ZERO);

        // Shift by one
        let (res, carry) = val.shr_limb(1);
        assert_eq!(res, val.shr_vartime(1));
        assert_eq!(carry, val.limbs[0].shl(Limb::BITS - 1));

        // Shift by any
        let (res, carry) = val.shr_limb(13);
        assert_eq!(res, val.shr_vartime(13));
        assert_eq!(carry, val.limbs[0].shl(Limb::BITS - 13));

        // Shift by max
        let (res, carry) = val.shr_limb(Limb::BITS - 1);
        assert_eq!(res, val.shr_vartime(Limb::BITS - 1));
        assert_eq!(carry, val.limbs[0].shl(1));
    }

    #[test]
    fn wrapping_shr_by_limbs_vartime() {
        let val = Uint::<2>::from_words([1, 99]);

        assert_eq!(val.wrapping_shr_by_limbs_vartime(0).as_words(), &[1, 99]);
        assert_eq!(val.wrapping_shr_by_limbs_vartime(1).as_words(), &[99, 0]);
        assert_eq!(val.wrapping_shr_by_limbs_vartime(2).as_words(), &[0, 0]);
    }
}
