use crate::{ConstChoice, ConstCtOption, Int, Limb, Uint};

pub(crate) struct ExtendedUint<const LIMBS: usize, const EXTENSION_LIMBS: usize>(
    Uint<LIMBS>,
    Uint<EXTENSION_LIMBS>,
);

impl<const LIMBS: usize, const EXTRA: usize> ExtendedUint<LIMBS, EXTRA> {
    /// Construct an [`ExtendedUint`] from the product of a [`Uint<LIMBS>`] and an [`Uint<EXTRA>`].
    ///
    /// Assumes the top bit of the product is not set.
    #[inline]
    pub const fn from_product(lhs: Uint<LIMBS>, rhs: Uint<EXTRA>) -> Self {
        let (lo, hi) = lhs.widening_mul(&rhs);
        ExtendedUint(lo, hi)
    }

    /// Wrapping multiply `self` with `rhs`
    pub const fn wrapping_mul<const RHS_LIMBS: usize>(&self, rhs: &Uint<RHS_LIMBS>) -> Self {
        let (lo, hi) = self.0.widening_mul(rhs);
        let hi = self.1.wrapping_mul(rhs).wrapping_add(&hi.resize::<EXTRA>());
        Self(lo, hi)
    }

    /// Interpret `self` as an [`ExtendedInt`]
    #[inline]
    pub const fn as_extended_int(&self) -> ExtendedInt<LIMBS, EXTRA> {
        ExtendedInt(self.0, self.1)
    }

    /// Whether this form is `Self::ZERO`.
    #[inline]
    pub const fn is_zero(&self) -> ConstChoice {
        self.0.is_nonzero().not().and(self.1.is_nonzero().not())
    }

    /// Drop the extension.
    #[inline]
    pub const fn checked_drop_extension(&self) -> ConstCtOption<Uint<LIMBS>> {
        ConstCtOption::new(self.0, self.1.is_nonzero().not())
    }

    /// Construction the binary negation of `self`, i.e., map `self` to `!self + 1`.
    ///
    /// Note: maps `0` to itself.
    #[inline]
    pub const fn wrapping_neg(&self) -> Self {
        let (lhs, carry) = self.0.carrying_neg();
        let mut rhs = self.1.not();
        rhs = Uint::select(&rhs, &rhs.wrapping_add(&Uint::ONE), carry);
        Self(lhs, rhs)
    }

    /// Negate `self` if `negate` is truthy. Otherwise returns `self`.
    #[inline]
    pub const fn wrapping_neg_if(&self, negate: ConstChoice) -> Self {
        let neg = self.wrapping_neg();
        Self(
            Uint::select(&self.0, &neg.0, negate),
            Uint::select(&self.1, &neg.1, negate),
        )
    }

    /// Shift `self` right by `shift` bits.
    ///
    /// Panics if `shift ≥ UPPER_BOUND`.
    #[inline]
    pub const fn bounded_shr<const UPPER_BOUND: u32>(&self, shift: u32) -> Self {
        debug_assert!(shift <= UPPER_BOUND);

        let shift_is_zero = ConstChoice::from_u32_eq(shift, 0);
        let left_shift = shift_is_zero.select_u32(Uint::<EXTRA>::BITS - shift, 0);

        let hi = self
            .1
            .bounded_overflowing_shr::<UPPER_BOUND>(shift)
            .expect("shift ≤ UPPER_BOUND");
        // TODO: replace with carrying_shl
        let carry = Uint::select(&self.1, &Uint::ZERO, shift_is_zero).shl(left_shift);
        let mut lo = self
            .0
            .bounded_overflowing_shr::<UPPER_BOUND>(shift)
            .expect("shift ≤ UPPER_BOUND");

        // Apply carry
        let limb_diff = LIMBS.wrapping_sub(EXTRA) as u32;
        // safe to vartime; shr_vartime is variable in the value of shift only. Since this shift
        // is a public constant, the constant time property of this algorithm is not impacted.
        let carry = carry.resize::<LIMBS>().shl_vartime(limb_diff * Limb::BITS);
        lo = lo.bitxor(&carry);

        Self(lo, hi)
    }

    /// Shift `self` right by `shift` bits.
    ///
    /// Panics if `shift ≥ Uint::<EXTRA>::BITS`.
    #[inline]
    pub const fn shr_vartime(&self, shift: u32) -> Self {
        debug_assert!(shift <= Uint::<EXTRA>::BITS);

        let shift_is_zero = ConstChoice::from_u32_eq(shift, 0);
        let left_shift = shift_is_zero.select_u32(Uint::<EXTRA>::BITS - shift, 0);

        let hi = self.1.shr_vartime(shift);
        // TODO: replace with carrying_shl
        let carry = Uint::select(&self.1, &Uint::ZERO, shift_is_zero).shl_vartime(left_shift);
        let mut lo = self.0.shr_vartime(shift);

        // Apply carry
        let limb_diff = LIMBS.wrapping_sub(EXTRA) as u32;
        // safe to vartime; shr_vartime is variable in the value of shift only. Since this shift
        // is a public constant, the constant time property of this algorithm is not impacted.
        let carry = carry.resize::<LIMBS>().shl_vartime(limb_diff * Limb::BITS);
        lo = lo.bitxor(&carry);

        Self(lo, hi)
    }
}

#[derive(Debug, PartialEq, Clone, Copy)]
pub(crate) struct ExtendedInt<const LIMBS: usize, const EXTENSION_LIMBS: usize>(
    Uint<LIMBS>,
    Uint<EXTENSION_LIMBS>,
);

impl<const LIMBS: usize, const EXTRA: usize> ExtendedInt<LIMBS, EXTRA> {
    pub(super) const ZERO: Self = Self(Uint::ZERO, Uint::ZERO);
    pub(super) const ONE: Self = Self(Uint::ONE, Uint::ZERO);

    /// Construct an [`ExtendedInt`] from the product of a [`Uint<LIMBS>`] and a [`Uint<EXTRA>`].
    ///
    /// Assumes the top bit of the product is not set.
    #[inline]
    pub const fn from_product(lhs: Uint<LIMBS>, rhs: Uint<EXTRA>) -> Self {
        ExtendedUint::from_product(lhs, rhs).as_extended_int()
    }

    /// Wrapping multiply `self` with `rhs`, which is passed as a
    pub(crate) const fn wrapping_mul<const RHS_LIMBS: usize>(
        &self,
        rhs: (&Uint<RHS_LIMBS>, &ConstChoice),
    ) -> Self {
        let (abs_self, self_is_negative) = self.abs_sign();
        let (abs_rhs, rhs_is_negative) = rhs;
        let mut abs_val = abs_self.wrapping_mul(abs_rhs);

        // Make sure the top bit of `abs_val` is not set
        abs_val.1 = abs_val.1.bitand(Int::<EXTRA>::SIGN_MASK.not().as_uint());

        let val_is_negative = self_is_negative.xor(*rhs_is_negative);
        abs_val.wrapping_neg_if(val_is_negative).as_extended_int()
    }

    /// Interpret this as an [`ExtendedUint`].
    #[inline]
    pub const fn as_extended_uint(&self) -> ExtendedUint<LIMBS, EXTRA> {
        ExtendedUint(self.0, self.1)
    }

    /// Return the negation of `self` if `negate` is truthy. Otherwise, return `self`.
    #[inline]
    pub const fn wrapping_neg_if(&self, negate: ConstChoice) -> Self {
        self.as_extended_uint()
            .wrapping_neg_if(negate)
            .as_extended_int()
    }

    #[inline]
    pub(crate) const fn wrapping_add(&self, rhs: &Self) -> Self {
        let (lo, carry) = self.0.carrying_add(&rhs.0, Limb::ZERO);
        let (hi, _) = self.1.carrying_add(&rhs.1, carry);
        Self(lo, hi)
    }

    /// Compute `self - rhs`, wrapping any underflow.
    #[inline]
    pub const fn wrapping_sub(&self, rhs: &Self) -> Self {
        let (lo, borrow) = self.0.borrowing_sub(&rhs.0, Limb::ZERO);
        let (hi, _) = self.1.borrowing_sub(&rhs.1, borrow);
        Self(lo, hi)
    }

    /// Returns the absolute value and sign of `self`, without the extension.
    #[inline]
    pub const fn dropped_abs_sign(&self) -> (Uint<LIMBS>, ConstChoice) {
        let (abs, sgn) = self.abs_sign();
        (abs.0, sgn)
    }

    /// Decompose `self` into is absolute value and signum.
    #[inline]
    pub const fn abs_sign(&self) -> (ExtendedUint<LIMBS, EXTRA>, ConstChoice) {
        let is_negative = self.1.as_int().is_negative();
        (
            self.wrapping_neg_if(is_negative).as_extended_uint(),
            is_negative,
        )
    }

    /// Divide self by `2^k`, rounding towards zero.
    ///
    /// Panics if `k ≥ UPPER_BOUND`.
    #[inline]
    pub const fn bounded_div_2k<const UPPER_BOUND: u32>(&self, k: u32) -> Self {
        let (abs, sgn) = self.abs_sign();
        abs.bounded_shr::<UPPER_BOUND>(k)
            .wrapping_neg_if(sgn)
            .as_extended_int()
    }

    /// Divide self by `2^k`, rounding towards zero.
    #[inline]
    pub const fn div_2k_vartime(&self, k: u32) -> Self {
        let (abs, sgn) = self.abs_sign();
        abs.shr_vartime(k).wrapping_neg_if(sgn).as_extended_int()
    }
}

impl<const LIMBS: usize> Uint<LIMBS> {
    /// Computes `self >> shift`.
    ///
    /// Returns `None` if `shift >= UPPER_BOUND`; panics if `UPPER_BOUND > Self::BITS`.
    pub const fn bounded_overflowing_shr<const UPPER_BOUND: u32>(
        &self,
        shift: u32,
    ) -> ConstCtOption<Self> {
        assert!(UPPER_BOUND <= Self::BITS);

        // `floor(log2(BITS - 1))` is the number of bits in the representation of `shift`
        // (which lies in range `0 <= shift < BITS`).
        let shift_bits = u32::BITS - (UPPER_BOUND - 1).leading_zeros();
        let overflow = ConstChoice::from_u32_lt(shift, UPPER_BOUND).not();

        let shift = shift % UPPER_BOUND;
        let mut result = *self;
        let mut i = 0;
        while i < shift_bits {
            let bit = ConstChoice::from_u32_lsb((shift >> i) & 1);
            result = Uint::select(
                &result,
                &result
                    .overflowing_shr_vartime(1 << i)
                    .expect("shift within range"),
                bit,
            );
            i += 1;
        }

        ConstCtOption::new(Uint::select(&result, &Self::ZERO, overflow), overflow.not())
    }
}

#[cfg(test)]
mod tests {
    use crate::Uint;
    use crate::modular::bingcd::extension::ExtendedUint;

    impl<const LIMBS: usize, const EXTRA: usize> ExtendedUint<LIMBS, EXTRA> {
        /// Decompose `self` into the bottom and top limbs.
        #[inline]
        const fn as_elements(&self) -> (Uint<LIMBS>, Uint<EXTRA>) {
            (self.0, self.1)
        }
    }
    mod test_extended_uint {
        use crate::U64;
        use crate::modular::bingcd::extension::ExtendedUint;

        const A: ExtendedUint<{ U64::LIMBS }, { U64::LIMBS }> = ExtendedUint::from_product(
            U64::from_u64(68146184546341u64),
            U64::from_u64(873817114763u64),
        );
        const B: ExtendedUint<{ U64::LIMBS }, { U64::LIMBS }> = ExtendedUint::from_product(
            U64::from_u64(7772181434148543u64),
            U64::from_u64(6665138352u64),
        );

        #[test]
        fn bounded_overflowing_shr() {
            let res = U64::MAX.bounded_overflowing_shr::<32>(20);
            assert!(bool::from(res.is_some()));
            assert_eq!(res.unwrap(), U64::MAX.overflowing_shr(20).unwrap());

            let res = U64::MAX.bounded_overflowing_shr::<32>(32);
            assert!(bool::from(res.is_none()));
        }

        #[test]
        fn test_from_product() {
            assert_eq!(
                A.as_elements(),
                (U64::from(13454091406951429143u64), U64::from(3228065u64))
            );
            assert_eq!(
                B.as_elements(),
                (U64::from(1338820589698724688u64), U64::from(2808228u64))
            );
        }

        #[test]
        fn test_wrapping_sub() {
            assert_eq!(
                A.as_extended_int()
                    .wrapping_sub(&B.as_extended_int())
                    .as_extended_uint()
                    .as_elements(),
                (U64::from(12115270817252704455u64), U64::from(419837u64))
            )
        }
    }

    mod test_extended_int {

        #[test]
        fn test_wrapping_sub() {}
    }
}
