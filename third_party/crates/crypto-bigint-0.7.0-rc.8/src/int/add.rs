//! [`Int`] addition operations.

use core::ops::{Add, AddAssign};

use num_traits::WrappingAdd;
use subtle::CtOption;

use crate::{Checked, CheckedAdd, ConstChoice, ConstCtOption, Int, Wrapping};

impl<const LIMBS: usize> Int<LIMBS> {
    /// Perform checked addition. Returns `none` when the addition overflowed.
    pub const fn checked_add(&self, rhs: &Self) -> ConstCtOption<Self> {
        let (value, overflow) = self.overflowing_add(rhs);
        ConstCtOption::new(value, overflow.not())
    }

    /// Perform addition, raising the `overflow` flag on overflow.
    pub const fn overflowing_add(&self, rhs: &Self) -> (Self, ConstChoice) {
        // Step 1. add operands
        let res = Self(self.0.wrapping_add(&rhs.0));

        // Step 2. determine whether overflow happened.
        // Note:
        // - overflow can only happen when the inputs have the same sign, and then
        // - overflow occurs if and only if the result has the opposite sign of both inputs.
        //
        // We can thus express the overflow flag as: (self.msb == rhs.msb) & (self.msb != res.msb)
        let self_msb = self.is_negative();
        let overflow = self_msb
            .eq(rhs.is_negative())
            .and(self_msb.ne(res.is_negative()));

        // Step 3. Construct result
        (res, overflow)
    }

    /// Perform wrapping addition, discarding overflow.
    pub const fn wrapping_add(&self, rhs: &Self) -> Self {
        Self(self.0.wrapping_add(&rhs.0))
    }
}

impl<const LIMBS: usize> Add for Int<LIMBS> {
    type Output = Self;

    fn add(self, rhs: Self) -> Self {
        self.add(&rhs)
    }
}

impl<const LIMBS: usize> Add<&Int<LIMBS>> for Int<LIMBS> {
    type Output = Self;

    fn add(self, rhs: &Self) -> Self {
        CtOption::from(self.checked_add(rhs)).expect("attempted to add with overflow")
    }
}

impl<const LIMBS: usize> AddAssign for Int<LIMBS> {
    fn add_assign(&mut self, other: Self) {
        *self += &other;
    }
}

impl<const LIMBS: usize> AddAssign<&Int<LIMBS>> for Int<LIMBS> {
    fn add_assign(&mut self, other: &Self) {
        *self = *self + other;
    }
}

impl<const LIMBS: usize> AddAssign for Wrapping<Int<LIMBS>> {
    fn add_assign(&mut self, other: Self) {
        *self = *self + other;
    }
}

impl<const LIMBS: usize> AddAssign<&Wrapping<Int<LIMBS>>> for Wrapping<Int<LIMBS>> {
    fn add_assign(&mut self, other: &Self) {
        *self = *self + other;
    }
}

impl<const LIMBS: usize> AddAssign for Checked<Int<LIMBS>> {
    fn add_assign(&mut self, other: Self) {
        *self = *self + other;
    }
}

impl<const LIMBS: usize> AddAssign<&Checked<Int<LIMBS>>> for Checked<Int<LIMBS>> {
    fn add_assign(&mut self, other: &Self) {
        *self = *self + other;
    }
}

impl<const LIMBS: usize> CheckedAdd for Int<LIMBS> {
    fn checked_add(&self, rhs: &Self) -> CtOption<Self> {
        self.checked_add(rhs).into()
    }
}

impl<const LIMBS: usize> WrappingAdd for Int<LIMBS> {
    fn wrapping_add(&self, v: &Self) -> Self {
        self.wrapping_add(v)
    }
}

#[cfg(test)]
mod tests {
    use crate::{ConstChoice, I128, U128};

    #[test]
    fn checked_add() {
        let min_plus_one = I128 {
            0: I128::MIN.0.wrapping_add(&I128::ONE.0),
        };
        let max_minus_one = I128 {
            0: I128::MAX.0.wrapping_sub(&I128::ONE.0),
        };
        let two = I128 {
            0: U128::from(2u32),
        };

        // lhs = MIN

        let result = I128::MIN.checked_add(&I128::MIN);
        assert!(bool::from(result.is_none()));

        let result = I128::MIN.checked_add(&I128::MINUS_ONE);
        assert!(bool::from(result.is_none()));

        let result = I128::MIN.checked_add(&I128::ZERO);
        assert_eq!(result.unwrap(), I128::MIN);

        let result = I128::MIN.checked_add(&I128::ONE);
        assert_eq!(result.unwrap(), min_plus_one);

        let result = I128::MIN.checked_add(&I128::MAX);
        assert_eq!(result.unwrap(), I128::MINUS_ONE);

        // lhs = -1

        let result = I128::MINUS_ONE.checked_add(&I128::MIN);
        assert!(bool::from(result.is_none()));

        let result = I128::MINUS_ONE.checked_add(&I128::MINUS_ONE);
        assert_eq!(result.unwrap(), two.checked_neg().unwrap());

        let result = I128::MINUS_ONE.checked_add(&I128::ZERO);
        assert_eq!(result.unwrap(), I128::MINUS_ONE);

        let result = I128::MINUS_ONE.checked_add(&I128::ONE);
        assert_eq!(result.unwrap(), I128::ZERO);

        let result = I128::MINUS_ONE.checked_add(&I128::MAX);
        assert_eq!(result.unwrap(), max_minus_one);

        // lhs = 0

        let result = I128::ZERO.checked_add(&I128::MIN);
        assert_eq!(result.unwrap(), I128::MIN);

        let result = I128::ZERO.checked_add(&I128::MINUS_ONE);
        assert_eq!(result.unwrap(), I128::MINUS_ONE);

        let result = I128::ZERO.checked_add(&I128::ZERO);
        assert_eq!(result.unwrap(), I128::ZERO);

        let result = I128::ZERO.checked_add(&I128::ONE);
        assert_eq!(result.unwrap(), I128::ONE);

        let result = I128::ZERO.checked_add(&I128::MAX);
        assert_eq!(result.unwrap(), I128::MAX);

        // lhs = 1

        let result = I128::ONE.checked_add(&I128::MIN);
        assert_eq!(result.unwrap(), min_plus_one);

        let result = I128::ONE.checked_add(&I128::MINUS_ONE);
        assert_eq!(result.unwrap(), I128::ZERO);

        let result = I128::ONE.checked_add(&I128::ZERO);
        assert_eq!(result.unwrap(), I128::ONE);

        let result = I128::ONE.checked_add(&I128::ONE);
        assert_eq!(result.unwrap(), two);

        let result = I128::ONE.checked_add(&I128::MAX);
        assert!(bool::from(result.is_none()));

        // lhs = MAX

        let result = I128::MAX.checked_add(&I128::MIN);
        assert_eq!(result.unwrap(), I128::MINUS_ONE);

        let result = I128::MAX.checked_add(&I128::MINUS_ONE);
        assert_eq!(result.unwrap(), max_minus_one);

        let result = I128::MAX.checked_add(&I128::ZERO);
        assert_eq!(result.unwrap(), I128::MAX);

        let result = I128::MAX.checked_add(&I128::ONE);
        assert!(bool::from(result.is_none()));

        let result = I128::MAX.checked_add(&I128::MAX);
        assert!(bool::from(result.is_none()));
    }

    #[test]
    fn overflowing_add() {
        let min_plus_one = I128 {
            0: I128::MIN.0.wrapping_add(&I128::ONE.0),
        };
        let max_minus_one = I128 {
            0: I128::MAX.0.wrapping_sub(&I128::ONE.0),
        };
        let two = I128 {
            0: U128::from(2u32),
        };

        // lhs = MIN

        let (_val, overflow) = I128::MIN.overflowing_add(&I128::MIN);
        assert_eq!(overflow, ConstChoice::TRUE);

        let (_val, overflow) = I128::MIN.overflowing_add(&I128::MINUS_ONE);
        assert_eq!(overflow, ConstChoice::TRUE);

        let (val, overflow) = I128::MIN.overflowing_add(&I128::ZERO);
        assert_eq!(overflow, ConstChoice::FALSE);
        assert_eq!(val, I128::MIN);

        let (val, overflow) = I128::MIN.overflowing_add(&I128::ONE);
        assert_eq!(overflow, ConstChoice::FALSE);
        assert_eq!(val, min_plus_one);

        let (val, overflow) = I128::MIN.overflowing_add(&I128::MAX);
        assert_eq!(overflow, ConstChoice::FALSE);
        assert_eq!(val, I128::MINUS_ONE);

        // lhs = -1

        let (_val, overflow) = I128::MINUS_ONE.overflowing_add(&I128::MIN);
        assert_eq!(overflow, ConstChoice::TRUE);

        let (val, overflow) = I128::MINUS_ONE.overflowing_add(&I128::MINUS_ONE);
        assert_eq!(overflow, ConstChoice::FALSE);
        assert_eq!(val, two.wrapping_neg());

        let (val, overflow) = I128::MINUS_ONE.overflowing_add(&I128::ZERO);
        assert_eq!(overflow, ConstChoice::FALSE);
        assert_eq!(val, I128::MINUS_ONE);

        let (val, overflow) = I128::MINUS_ONE.overflowing_add(&I128::ONE);
        assert_eq!(overflow, ConstChoice::FALSE);
        assert_eq!(val, I128::ZERO);

        let (val, overflow) = I128::MINUS_ONE.overflowing_add(&I128::MAX);
        assert_eq!(overflow, ConstChoice::FALSE);
        assert_eq!(val, max_minus_one);

        // lhs = 0

        let (val, overflow) = I128::ZERO.overflowing_add(&I128::MIN);
        assert_eq!(overflow, ConstChoice::FALSE);
        assert_eq!(val, I128::MIN);

        let (val, overflow) = I128::ZERO.overflowing_add(&I128::MINUS_ONE);
        assert_eq!(overflow, ConstChoice::FALSE);
        assert_eq!(val, I128::MINUS_ONE);

        let (val, overflow) = I128::ZERO.overflowing_add(&I128::ZERO);
        assert_eq!(overflow, ConstChoice::FALSE);
        assert_eq!(val, I128::ZERO);

        let (val, overflow) = I128::ZERO.overflowing_add(&I128::ONE);
        assert_eq!(overflow, ConstChoice::FALSE);
        assert_eq!(val, I128::ONE);

        let (val, overflow) = I128::ZERO.overflowing_add(&I128::MAX);
        assert_eq!(overflow, ConstChoice::FALSE);
        assert_eq!(val, I128::MAX);

        // lhs = 1

        let (val, overflow) = I128::ONE.overflowing_add(&I128::MIN);
        assert_eq!(overflow, ConstChoice::FALSE);
        assert_eq!(val, min_plus_one);

        let (val, overflow) = I128::ONE.overflowing_add(&I128::MINUS_ONE);
        assert_eq!(overflow, ConstChoice::FALSE);
        assert_eq!(val, I128::ZERO);

        let (val, overflow) = I128::ONE.overflowing_add(&I128::ZERO);
        assert_eq!(overflow, ConstChoice::FALSE);
        assert_eq!(val, I128::ONE);

        let (val, overflow) = I128::ONE.overflowing_add(&I128::ONE);
        assert_eq!(overflow, ConstChoice::FALSE);
        assert_eq!(val, two);

        let (_val, overflow) = I128::ONE.overflowing_add(&I128::MAX);
        assert_eq!(overflow, ConstChoice::TRUE);

        // lhs = MAX

        let (val, overflow) = I128::MAX.overflowing_add(&I128::MIN);
        assert_eq!(overflow, ConstChoice::FALSE);
        assert_eq!(val, I128::MINUS_ONE);

        let (val, overflow) = I128::MAX.overflowing_add(&I128::MINUS_ONE);
        assert_eq!(overflow, ConstChoice::FALSE);
        assert_eq!(val, max_minus_one);

        let (val, overflow) = I128::MAX.overflowing_add(&I128::ZERO);
        assert_eq!(overflow, ConstChoice::FALSE);
        assert_eq!(val, I128::MAX);

        let (_val, overflow) = I128::MAX.overflowing_add(&I128::ONE);
        assert_eq!(overflow, ConstChoice::TRUE);

        let (_val, overflow) = I128::MAX.overflowing_add(&I128::MAX);
        assert_eq!(overflow, ConstChoice::TRUE);
    }
}
