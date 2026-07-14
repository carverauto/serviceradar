use core::ops::Mul;
use subtle::CtOption;

use crate::{CheckedMul, ConcatMixed, ConstChoice, ConstCtOption, Int, Uint};

impl<const LIMBS: usize> Int<LIMBS> {
    /// Compute "wide" multiplication between an [`Int`] and [`Uint`] as 3-tuple `(lo, hi, negate)`.
    /// The `(lo, hi)` components contain the _magnitude of the product_, with sizes
    /// corresponding to the sizes of the operands; `negate` indicates whether the result should be
    /// negated when converted from [`Uint`] to [`Int`].
    ///
    /// Note: even if `negate` is truthy, the magnitude might be zero!
    #[deprecated(since = "0.7.0", note = "please use `widening_mul_uint` instead")]
    pub const fn split_mul_uint<const RHS_LIMBS: usize>(
        &self,
        rhs: &Uint<RHS_LIMBS>,
    ) -> (Uint<{ LIMBS }>, Uint<{ RHS_LIMBS }>, ConstChoice) {
        self.widening_mul_uint(rhs)
    }

    /// Compute "wide" multiplication between an [`Int`] and [`Uint`] as 3-tuple `(lo, hi, negate)`.
    /// The `(lo, hi)` components contain the _magnitude of the product_, with sizes
    /// corresponding to the sizes of the operands; `negate` indicates whether the result should be
    /// negated when converted from [`Uint`] to [`Int`].
    ///
    /// Note: even if `negate` is truthy, the magnitude might be zero!
    pub const fn widening_mul_uint<const RHS_LIMBS: usize>(
        &self,
        rhs: &Uint<RHS_LIMBS>,
    ) -> (Uint<{ LIMBS }>, Uint<{ RHS_LIMBS }>, ConstChoice) {
        // Step 1. split self into its sign and magnitude.
        let (lhs_abs, lhs_sgn) = self.abs_sign();

        // Step 2. Multiply the magnitudes
        let (lo, hi) = lhs_abs.widening_mul(rhs);

        // Step 3. negate if and only if self has a negative sign.
        (lo, hi, lhs_sgn)
    }

    /// Compute "wide" multiplication between an [`Int`] and [`Uint`] as 3-tuple `(lo, hi, negate)`.
    /// The `(lo, hi)` components contain the _magnitude of the product_, with sizes
    /// corresponding to the sizes of the operands, in reversed order; `negate` indicates whether
    /// the result should be negated when converted from [`Uint`] to [`Int`].
    ///
    /// Note: even if `negate` is truthy, the magnitude might be zero!
    #[deprecated(since = "0.7.0", note = "please use `Uint::widening_mul_int` instead")]
    pub const fn split_mul_uint_right<const RHS_LIMBS: usize>(
        &self,
        rhs: &Uint<RHS_LIMBS>,
    ) -> (Uint<{ RHS_LIMBS }>, Uint<{ LIMBS }>, ConstChoice) {
        rhs.widening_mul_int(self)
    }

    /// Compute "wide" multiplication between an [`Int`] and [`Uint`] as 3-tuple `(lo, hi, negate)`.
    /// The `(lo, hi)` components contain the _magnitude of the product_, with sizes
    /// corresponding to the sizes of the operands, in reversed order; `negate` indicates whether
    /// the result should be negated when converted from [`Uint`] to [`Int`].
    ///
    /// Note: even if `negate` is truthy, the magnitude might be zero!
    #[deprecated(since = "0.7.0", note = "please use `Uint::widening_mul_int` instead")]
    pub const fn widening_mul_uint_right<const RHS_LIMBS: usize>(
        &self,
        rhs: &Uint<RHS_LIMBS>,
    ) -> (Uint<{ RHS_LIMBS }>, Uint<{ LIMBS }>, ConstChoice) {
        rhs.widening_mul_int(self)
    }

    /// Multiply `self` by [`Uint`] `rhs`, returning a concatenated "wide" result.
    pub const fn concatenating_mul_uint<const RHS_LIMBS: usize, const WIDE_LIMBS: usize>(
        &self,
        rhs: &Uint<RHS_LIMBS>,
    ) -> Int<WIDE_LIMBS>
    where
        Uint<LIMBS>: ConcatMixed<Uint<RHS_LIMBS>, MixedOutput = Uint<WIDE_LIMBS>>,
    {
        let (lhs_abs, lhs_sign) = self.abs_sign();
        let product_abs = lhs_abs.concatenating_mul(rhs);

        // always fits
        *product_abs.wrapping_neg_if(lhs_sign).as_int()
    }

    /// Checked multiplication of self with an [`Uint<RHS_LIMBS>`], where the result is to be stored
    /// in an [`Int<RHS_LIMBS>`].
    #[deprecated(since = "0.7.0", note = "please use `Uint::checked_mul(_int)` instead")]
    pub fn checked_mul_uint_right<const RHS_LIMBS: usize>(
        &self,
        rhs: &Uint<RHS_LIMBS>,
    ) -> CtOption<Int<RHS_LIMBS>> {
        rhs.checked_mul_int(self).into()
    }

    /// Checked multiplication with a [`Uint`].
    pub fn checked_mul_uint<const RHS_LIMBS: usize>(
        &self,
        rhs: &Uint<RHS_LIMBS>,
    ) -> ConstCtOption<Int<LIMBS>> {
        let (lo, hi, is_negative) = self.widening_mul_uint(rhs);
        Self::new_from_abs_sign(lo, is_negative).and_choice(hi.is_nonzero().not())
    }
}

impl<const LIMBS: usize, const RHS_LIMBS: usize> CheckedMul<Uint<RHS_LIMBS>> for Int<LIMBS> {
    #[inline]
    fn checked_mul(&self, rhs: &Uint<RHS_LIMBS>) -> CtOption<Self> {
        self.checked_mul_uint(rhs).into()
    }
}

impl<const LIMBS: usize, const RHS_LIMBS: usize> Mul<Uint<RHS_LIMBS>> for Int<LIMBS> {
    type Output = Int<LIMBS>;

    fn mul(self, rhs: Uint<RHS_LIMBS>) -> Self {
        self.mul(&rhs)
    }
}

impl<const LIMBS: usize, const RHS_LIMBS: usize> Mul<&Uint<RHS_LIMBS>> for Int<LIMBS> {
    type Output = Int<LIMBS>;

    fn mul(self, rhs: &Uint<RHS_LIMBS>) -> Self {
        (&self).mul(rhs)
    }
}

impl<const LIMBS: usize, const RHS_LIMBS: usize> Mul<Uint<RHS_LIMBS>> for &Int<LIMBS> {
    type Output = Int<LIMBS>;

    fn mul(self, rhs: Uint<RHS_LIMBS>) -> Self::Output {
        self.mul(&rhs)
    }
}

impl<const LIMBS: usize, const RHS_LIMBS: usize> Mul<&Uint<RHS_LIMBS>> for &Int<LIMBS> {
    type Output = Int<LIMBS>;

    fn mul(self, rhs: &Uint<RHS_LIMBS>) -> Self::Output {
        self.checked_mul(rhs)
            .expect("attempted to multiply with overflow")
    }
}

#[cfg(test)]
mod tests {
    use crate::{I128, I256, U128, U256};

    #[test]
    fn test_checked_mul_uint() {
        // lhs = min

        let result = I128::MIN.checked_mul_uint(&U128::ZERO);
        assert_eq!(result.unwrap(), I128::ZERO);

        let result = I128::MIN.checked_mul_uint(&U128::ONE);
        assert_eq!(result.unwrap(), I128::MIN);

        let result = I128::MIN.checked_mul_uint(&U128::MAX);
        assert!(bool::from(result.is_none()));

        // lhs = -1

        let result = I128::MINUS_ONE.checked_mul_uint(&U128::ZERO);
        assert_eq!(result.unwrap(), I128::ZERO);

        let result = I128::MINUS_ONE.checked_mul_uint(&U128::ONE);
        assert_eq!(result.unwrap(), I128::MINUS_ONE);

        let result = I128::MINUS_ONE.checked_mul_uint(&U128::MAX);
        assert!(bool::from(result.is_none()));

        // lhs = 0

        let result = I128::ZERO.checked_mul_uint(&U128::ZERO);
        assert_eq!(result.unwrap(), I128::ZERO);

        let result = I128::ZERO.checked_mul_uint(&U128::ONE);
        assert_eq!(result.unwrap(), I128::ZERO);

        let result = I128::ZERO.checked_mul_uint(&U128::MAX);
        assert_eq!(result.unwrap(), I128::ZERO);

        // lhs = 1

        let result = I128::ONE.checked_mul_uint(&U128::ZERO);
        assert_eq!(result.unwrap(), I128::ZERO);

        let result = I128::ONE.checked_mul_uint(&U128::ONE);
        assert_eq!(result.unwrap(), I128::ONE);

        let result = I128::ONE.checked_mul_uint(&U128::MAX);
        assert!(bool::from(result.is_none()));

        // lhs = max

        let result = I128::MAX.checked_mul_uint(&U128::ZERO);
        assert_eq!(result.unwrap(), I128::ZERO);

        let result = I128::MAX.checked_mul_uint(&U128::ONE);
        assert_eq!(result.unwrap(), I128::MAX);

        let result = I128::MAX.checked_mul_uint(&U128::MAX);
        assert!(bool::from(result.is_none()));
    }

    #[test]
    #[allow(deprecated)]
    fn test_checked_mul_uint_right() {
        // rhs = 0
        let result = I256::MIN.checked_mul_uint_right(&U128::ZERO);
        assert!(bool::from(result.is_some()));
        assert_eq!(result.unwrap(), I128::ZERO);

        let result = I128::MIN.checked_mul_uint_right(&U256::ZERO);
        assert!(bool::from(result.is_some()));
        assert_eq!(result.unwrap(), I256::ZERO);

        // rhs = 1
        let result = I256::MIN.checked_mul_uint_right(&U128::ONE);
        assert!(bool::from(result.is_none()));

        let result = I128::MIN.checked_mul_uint_right(&U256::ONE);
        assert!(bool::from(result.is_some()));
        assert_eq!(result.unwrap(), I128::MIN.resize());

        // rhs > 1
        let result = I256::ONE.checked_mul_uint_right(I128::MAX.as_uint());
        assert!(bool::from(result.is_some()));
        assert_eq!(result.unwrap(), I128::MAX.resize());

        let result = I128::ONE.checked_mul_uint_right(I256::MAX.as_uint());
        assert!(bool::from(result.is_some()));
        assert_eq!(result.unwrap(), I256::MAX);

        // rhs = MAX
        let result = I256::ONE.checked_mul_uint_right(&U128::MAX);
        assert!(bool::from(result.is_none()));

        let result = I128::MIN.checked_mul_uint_right(&U256::MAX);
        assert!(bool::from(result.is_none()));
    }

    #[test]
    fn test_concatenating_mul_uint() {
        assert_eq!(I128::MIN.concatenating_mul_uint(&U128::ZERO), I256::ZERO);
        assert_eq!(
            I128::MIN.concatenating_mul_uint(&U128::ONE),
            I256::from_be_hex("FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF80000000000000000000000000000000")
        );
        assert_eq!(
            I128::MIN.concatenating_mul_uint(&U128::MAX),
            I256::from_be_hex("8000000000000000000000000000000080000000000000000000000000000000")
        );

        assert_eq!(
            I128::MINUS_ONE.concatenating_mul_uint(&U128::ZERO),
            I256::ZERO
        );
        assert_eq!(
            I128::MINUS_ONE.concatenating_mul_uint(&U128::ONE),
            I256::MINUS_ONE
        );
        assert_eq!(
            I128::MINUS_ONE.concatenating_mul_uint(&U128::MAX),
            I256::from_be_hex("FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF00000000000000000000000000000001")
        );

        assert_eq!(I128::ZERO.concatenating_mul_uint(&U128::ZERO), I256::ZERO);
        assert_eq!(I128::ZERO.concatenating_mul_uint(&U128::ONE), I256::ZERO);
        assert_eq!(I128::ZERO.concatenating_mul_uint(&U128::MAX), I256::ZERO);

        assert_eq!(I128::ONE.concatenating_mul_uint(&U128::ZERO), I256::ZERO);
        assert_eq!(I128::ONE.concatenating_mul_uint(&U128::ONE), I256::ONE);
        assert_eq!(
            I128::ONE.concatenating_mul_uint(&U128::MAX),
            I256::from_be_hex("00000000000000000000000000000000FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF")
        );

        assert_eq!(I128::MAX.concatenating_mul_uint(&U128::ZERO), I256::ZERO);
        assert_eq!(
            I128::MAX.concatenating_mul_uint(&U128::ONE),
            I256::from_be_hex("000000000000000000000000000000007FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF")
        );
        assert_eq!(
            I128::MAX.concatenating_mul_uint(&U128::MAX),
            I256::from_be_hex("7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFE80000000000000000000000000000001")
        );
    }
}
