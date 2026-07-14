//! [`Int`] negation-related operations.

use crate::{ConstChoice, ConstCtOption, Int, Uint};
use num_traits::WrappingNeg;

impl<const LIMBS: usize> Int<LIMBS> {
    /// Map this [`Int`] to its two's-complement negation:
    /// map `self` to `(self ^ 1111...1111) + 0000...0001`.
    ///
    /// Returns the negation, as well as whether the operation overflowed.
    /// The operation overflows when attempting to negate [`Int::MIN`]; the positive counterpart
    /// of this value cannot be represented.
    pub const fn overflowing_neg(&self) -> (Self, ConstChoice) {
        Self(self.0.bitxor(&Uint::MAX)).overflowing_add(&Int::ONE)
    }

    /// Wrapping negate this [`Int`].
    ///
    /// Warning: this operation maps [`Int::MIN`] to itself, since the positive counterpart of this
    /// value cannot be represented.
    pub const fn wrapping_neg(&self) -> Self {
        self.overflowing_neg().0
    }

    /// Wrapping negate this [`Int`] if `negate` is truthy; otherwise do nothing.
    ///
    /// Warning: this operation maps [`Int::MIN`] to itself, since the positive counterpart of this
    /// value cannot be represented.
    pub const fn wrapping_neg_if(&self, negate: ConstChoice) -> Int<LIMBS> {
        Self(self.0.wrapping_neg_if(negate))
    }

    /// Negate this [`Int`].
    ///
    /// Yields `None` when `self == Self::MIN`, since the positive counterpart of this value cannot
    /// be represented.
    pub const fn checked_neg(&self) -> ConstCtOption<Self> {
        let (value, overflow) = self.overflowing_neg();
        ConstCtOption::new(value, overflow.not())
    }
}

impl<const LIMBS: usize> WrappingNeg for Int<LIMBS> {
    #[inline]
    fn wrapping_neg(&self) -> Self {
        self.wrapping_neg()
    }
}

#[cfg(test)]
mod tests {
    use crate::{ConstChoice, I128};

    #[test]
    fn overflowing_neg() {
        let min_plus_one = I128 {
            0: I128::MIN.0.wrapping_add(&I128::ONE.0),
        };

        let (res, overflow) = I128::MIN.overflowing_neg();
        assert_eq!(res, I128::MIN);
        assert_eq!(overflow, ConstChoice::TRUE);

        let (res, overflow) = I128::MINUS_ONE.overflowing_neg();
        assert_eq!(res, I128::ONE);
        assert_eq!(overflow, ConstChoice::FALSE);

        let (res, overflow) = I128::ZERO.overflowing_neg();
        assert_eq!(res, I128::ZERO);
        assert_eq!(overflow, ConstChoice::FALSE);

        let (res, overflow) = I128::ONE.overflowing_neg();
        assert_eq!(res, I128::MINUS_ONE);
        assert_eq!(overflow, ConstChoice::FALSE);

        let (res, overflow) = I128::MAX.overflowing_neg();
        assert_eq!(res, min_plus_one);
        assert_eq!(overflow, ConstChoice::FALSE);
    }

    #[test]
    fn wrapping_neg_if() {
        let min_plus_one = I128 {
            0: I128::MIN.0.wrapping_add(&I128::ONE.0),
        };

        let do_negate = ConstChoice::TRUE;
        assert_eq!(I128::MIN.wrapping_neg_if(do_negate), I128::MIN);
        assert_eq!(I128::MINUS_ONE.wrapping_neg_if(do_negate), I128::ONE);
        assert_eq!(I128::ZERO.wrapping_neg_if(do_negate), I128::ZERO);
        assert_eq!(I128::ONE.wrapping_neg_if(do_negate), I128::MINUS_ONE);
        assert_eq!(I128::MAX.wrapping_neg_if(do_negate), min_plus_one);

        let do_not_negate = ConstChoice::FALSE;
        assert_eq!(I128::MIN.wrapping_neg_if(do_not_negate), I128::MIN);
        assert_eq!(
            I128::MINUS_ONE.wrapping_neg_if(do_not_negate),
            I128::MINUS_ONE
        );
        assert_eq!(I128::ZERO.wrapping_neg_if(do_not_negate), I128::ZERO);
        assert_eq!(I128::ONE.wrapping_neg_if(do_not_negate), I128::ONE);
        assert_eq!(I128::MAX.wrapping_neg_if(do_not_negate), I128::MAX);
    }

    #[test]
    fn checked_neg() {
        assert_eq!(I128::MIN.checked_neg().is_none(), ConstChoice::TRUE);
        assert_eq!(I128::MINUS_ONE.checked_neg().unwrap(), I128::ONE);
        assert_eq!(I128::ZERO.checked_neg().unwrap(), I128::ZERO);
        assert_eq!(I128::ONE.checked_neg().unwrap(), I128::MINUS_ONE);
        assert_eq!(
            I128::MAX.checked_neg().unwrap(),
            I128::from_be_hex("80000000000000000000000000000001")
        );

        let negative = I128::from_be_hex("91113333555577779999BBBBDDDDFFFF");
        let positive = I128::from_be_hex("6EEECCCCAAAA88886666444422220001");
        assert_eq!(negative.checked_neg().unwrap(), positive);
        assert_eq!(positive.checked_neg().unwrap(), negative);
        assert_eq!(
            positive.checked_neg().unwrap().checked_neg().unwrap(),
            positive
        );
    }
}
