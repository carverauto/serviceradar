//! [`Uint`] bitwise left shift operations.

use super::UintRef;
use crate::{ConstChoice, Limb};

#[cfg(feature = "alloc")]
use crate::{BitOps, NonZero};

#[cfg(feature = "alloc")]
use subtle::{Choice, ConstantTimeLess};

impl UintRef {
    /// Left-shifts by `shift` bits in constant-time.
    ///
    /// Produces zero and returns truthy `Choice` if `shift >= self.bits_precision()`,
    /// or the result and a falsy `Choice` otherwise.
    #[cfg(feature = "alloc")]
    #[inline(always)]
    pub fn overflowing_shl_assign(&mut self, shift: u32) -> Choice {
        let bits = self.bits_precision();
        let overflow = !shift.ct_lt(&bits);
        self.bounded_wrapping_shl_assign(shift % bits, bits);
        self.conditional_set_zero(overflow.into());
        overflow
    }

    /// Left-shifts by `shift` bits in variable-time.
    ///
    /// Produces zero and returns truthy `Choice` if `shift >= self.bits_precision()`,
    /// or the result and a falsy `Choice` otherwise.
    ///
    /// NOTE: this operation is variable time with respect to `shift` *ONLY*.
    ///
    /// When used with a fixed `shift`, this function is constant-time with respect to `self`.
    #[cfg(feature = "alloc")]
    #[inline(always)]
    pub fn overflowing_shl_assign_vartime(&mut self, shift: u32) -> Choice {
        let bits = self.bits_precision();
        let overflow = !shift.ct_lt(&bits);
        self.wrapping_shl_assign_vartime(shift);
        overflow
    }

    /// Left-shifts by `shift` bits where `shift < `shift_upper_bound`, producing zero if
    /// the shift exceeds the precision. The runtime is determined by `shift_upper_bound`
    /// which may be smaller than `self.bits_precision()`.
    #[cfg(feature = "alloc")]
    pub(crate) const fn bounded_wrapping_shl_assign(&mut self, shift: u32, shift_upper_bound: u32) {
        assert!(shift < shift_upper_bound);
        // `floor(log2(BITS - 1))` is the number of bits in the representation of `shift`
        // (which lies in range `0 <= shift < BITS`).
        let shift_bits = u32::BITS - (shift_upper_bound - 1).leading_zeros();
        let limb_bits = if shift_bits < Limb::LOG2_BITS {
            shift_bits
        } else {
            Limb::LOG2_BITS
        };
        let mut i = 0;
        while i < limb_bits {
            let bit = ConstChoice::from_u32_lsb((shift >> i) & 1);
            self.conditional_shl_assign_limb_nonzero(NonZero(1 << i), bit);
            i += 1;
        }
        while i < shift_bits {
            let bit = ConstChoice::from_u32_lsb((shift >> i) & 1);
            self.conditional_shl_assign_by_limbs_vartime(1 << (i - Limb::LOG2_BITS), bit);
            i += 1;
        }
    }

    /// Conditionally left-shifts by `shift` limbs in a panic-free manner, producing zero
    /// if the shift exceeds the precision.
    ///
    /// NOTE: this operation is variable time with respect to `shift` *ONLY*.
    ///
    /// When used with a fixed `shift`, this function is constant-time with respect to `self`.
    #[cfg(feature = "alloc")]
    #[inline(always)]
    pub(crate) const fn conditional_shl_assign_by_limbs_vartime(
        &mut self,
        shift: u32,
        c: ConstChoice,
    ) {
        let shift = shift as usize;
        let mut i = self.0.len();
        while i > shift {
            i -= 1;
            self.0[i] = Limb::select(self.0[i], self.0[i - shift], c);
        }
        while i > 0 {
            i -= 1;
            self.0[i] = Limb::select(self.0[i], Limb::ZERO, c);
        }
    }

    /// Left-shifts by `shift` limbs in a panic-free manner, producing zero if the shift
    /// exceeds the precision.
    ///
    /// NOTE: this operation is variable time with respect to `shift` *ONLY*.
    ///
    /// When used with a fixed `shift`, this function is constant-time with respect to `self`.
    #[cfg(feature = "alloc")]
    #[inline(always)]
    pub(crate) const fn wrapping_shl_assign_by_limbs_vartime(&mut self, shift: u32) {
        let shift = shift as usize;
        let mut i = self.0.len();
        while i > shift {
            i -= 1;
            self.0[i] = self.0[i - shift];
        }
        while i > 0 {
            i -= 1;
            self.0[i] = Limb::ZERO;
        }
    }

    /// Left-shifts by `shift` bits in a panic-free manner, producing zero if the shift
    /// exceeds the precision.
    ///
    /// NOTE: this operation is variable time with respect to `shift` *ONLY*.
    ///
    /// When used with a fixed `shift`, this function is constant-time with respect to `self`.
    #[cfg(feature = "alloc")]
    #[inline(always)]
    pub const fn wrapping_shl_assign_vartime(&mut self, shift: u32) {
        let shift_limbs = shift / Limb::BITS;
        let rem = shift % Limb::BITS;

        self.wrapping_shl_assign_by_limbs_vartime(shift_limbs);

        if rem > 0 {
            let mut carry = Limb::ZERO;
            let mut i = shift_limbs as usize;
            while i < self.0.len() {
                (self.0[i], carry) = (
                    self.0[i].shl(rem).bitor(carry),
                    self.0[i].shr(Limb::BITS - rem),
                );
                i += 1;
            }
        }
    }

    /// Left-shifts by a single bit in constant-time, returning [`ConstChoice::TRUE`]
    /// if the least significant bit was set, and [`ConstChoice::FALSE`] otherwise.
    #[inline(always)]
    pub const fn shl1_assign(&mut self) -> ConstChoice {
        let mut carry = Limb::ZERO;
        let mut i = 0;
        while i < self.0.len() {
            let (limb, new_carry) = self.0[i].shl1();
            self.0[i] = limb.bitor(carry);
            carry = new_carry;
            i += 1;
        }
        ConstChoice::from_word_lsb(carry.0)
    }

    /// Conditionally left-shifts by `shift` bits where `0 < shift < Limb::BITS`, returning
    /// the carry.
    ///
    /// Panics if `shift >= Limb::BITS`.
    #[cfg(feature = "alloc")]
    #[inline]
    pub(crate) const fn conditional_shl_assign_limb_nonzero(
        &mut self,
        shift: NonZero<u32>,
        choice: ConstChoice,
    ) -> Limb {
        assert!(shift.0 < Limb::BITS);

        let lshift = shift.0;
        let rshift = Limb::BITS - shift.0;
        let mut carry = Limb::ZERO;

        let mut i = 0;
        while i < self.0.len() {
            (self.0[i], carry) = (
                Limb::select(self.0[i], self.0[i].shl(lshift).bitor(carry), choice),
                self.0[i].shr(rshift),
            );
            i += 1;
        }

        Limb::select(Limb::ZERO, carry, choice)
    }

    /// Left-shifts by `shift` bits where `0 < shift < Limb::BITS`, returning the carry.
    ///
    /// Panics if `shift >= Limb::BITS`.
    #[cfg(feature = "alloc")]
    pub const fn shl_assign_limb(&mut self, shift: u32) -> Limb {
        let nz = ConstChoice::from_u32_nonzero(shift);
        self.conditional_shl_assign_limb_nonzero(NonZero(nz.select_u32(1, shift)), nz)
    }
}

#[cfg(test)]
mod tests {
    use crate::{ConstChoice, U256};
    #[cfg(feature = "alloc")]
    use crate::{Limb, Uint};

    const N: U256 =
        U256::from_be_hex("FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141");

    const TWO_N: U256 =
        U256::from_be_hex("FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFD755DB9CD5E9140777FA4BD19A06C8282");

    #[test]
    fn shl1_assign() {
        let mut n = N;
        let carry = n.as_mut_uint_ref().shl1_assign();
        assert_eq!(n, TWO_N);
        assert_eq!(carry, ConstChoice::TRUE);

        let mut m = U256::MAX;
        let carry = m.as_mut_uint_ref().shl1_assign();
        assert_eq!(m, U256::MAX.shl_vartime(1));
        assert_eq!(carry, ConstChoice::TRUE);

        let mut z = U256::ZERO;
        let carry = z.as_mut_uint_ref().shl1_assign();
        assert_eq!(z, U256::ZERO);
        assert_eq!(carry, ConstChoice::FALSE);
    }

    #[cfg(feature = "alloc")]
    #[test]
    fn shl256() {
        let mut n = N;
        assert!(bool::from(n.as_mut_uint_ref().overflowing_shl_assign(256)));
        assert!(bool::from(
            n.as_mut_uint_ref().overflowing_shl_assign_vartime(256)
        ));
    }

    #[cfg(feature = "alloc")]
    #[test]
    fn shl_assign_limb() {
        // Shift by zero
        let mut val = N;
        let carry = val.as_mut_uint_ref().shl_assign_limb(0);
        assert_eq!(val, N);
        assert_eq!(carry, Limb::ZERO);

        // Shift by one
        let mut val = N;
        let carry = val.as_mut_uint_ref().shl_assign_limb(1);
        assert_eq!(val, N.shl_vartime(1));
        assert_eq!(carry, N.limbs[U256::LIMBS - 1].shr(Limb::BITS - 1));

        // Shift by any
        let mut val = N;
        let carry = val.as_mut_uint_ref().shl_assign_limb(13);
        assert_eq!(val, N.shl_vartime(13));
        assert_eq!(carry, N.limbs[U256::LIMBS - 1].shr(Limb::BITS - 13));

        // Shift by max
        let mut val = N;
        let carry = val.as_mut_uint_ref().shl_assign_limb(Limb::BITS - 1);
        assert_eq!(val, N.shl_vartime(Limb::BITS - 1));
        assert_eq!(carry, N.limbs[U256::LIMBS - 1].shr(1));
    }

    #[cfg(feature = "alloc")]
    #[test]
    fn wrapping_shl_by_limbs_vartime() {
        let refval = Uint::<2>::from_words([1, 99]);

        let mut val = refval;
        val.as_mut_uint_ref()
            .wrapping_shl_assign_by_limbs_vartime(0);
        assert_eq!(val.as_words(), &[1, 99]);

        let mut val = refval;
        val.as_mut_uint_ref()
            .wrapping_shl_assign_by_limbs_vartime(1);
        assert_eq!(val.as_words(), &[0, 1]);

        let mut val = refval;
        val.as_mut_uint_ref()
            .wrapping_shl_assign_by_limbs_vartime(2);
        assert_eq!(val.as_words(), &[0, 0]);
    }

    #[cfg(feature = "alloc")]
    #[test]
    fn compare_shl_assign() {
        for i in 0..256 {
            let (mut a, mut b) = (N, N);
            a.as_mut_uint_ref().bounded_wrapping_shl_assign(i, 256);
            b.as_mut_uint_ref().wrapping_shl_assign_vartime(i);
            assert_eq!(a, b);
        }
    }
}
