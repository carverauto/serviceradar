//! [`Uint`] subtraction operations.

use super::Uint;
use crate::{Checked, CheckedSub, ConstChoice, Limb, Wrapping, WrappingSub, Zero};
use core::ops::{Sub, SubAssign};
use subtle::CtOption;

impl<const LIMBS: usize> Uint<LIMBS> {
    /// Computes `self - (rhs + borrow)`, returning the result along with the new borrow.
    #[deprecated(since = "0.7.0", note = "please use `borrowing_sub` instead")]
    pub const fn sbb(&self, rhs: &Self, borrow: Limb) -> (Self, Limb) {
        self.borrowing_sub(rhs, borrow)
    }

    /// Computes `self - (rhs + borrow)`, returning the result along with the new borrow.
    #[inline(always)]
    pub const fn borrowing_sub(&self, rhs: &Self, mut borrow: Limb) -> (Self, Limb) {
        let mut limbs = [Limb::ZERO; LIMBS];
        let mut i = 0;

        while i < LIMBS {
            let (w, b) = self.limbs[i].borrowing_sub(rhs.limbs[i], borrow);
            limbs[i] = w;
            borrow = b;
            i += 1;
        }

        (Self { limbs }, borrow)
    }

    /// Perform saturating subtraction, returning `ZERO` on underflow.
    pub const fn saturating_sub(&self, rhs: &Self) -> Self {
        let (res, underflow) = self.borrowing_sub(rhs, Limb::ZERO);
        Self::select(&res, &Self::ZERO, ConstChoice::from_word_mask(underflow.0))
    }

    /// Perform wrapping subtraction, discarding underflow and wrapping around
    /// the boundary of the type.
    pub const fn wrapping_sub(&self, rhs: &Self) -> Self {
        self.borrowing_sub(rhs, Limb::ZERO).0
    }
}

impl<const LIMBS: usize> CheckedSub for Uint<LIMBS> {
    fn checked_sub(&self, rhs: &Self) -> CtOption<Self> {
        let (result, underflow) = self.borrowing_sub(rhs, Limb::ZERO);
        CtOption::new(result, underflow.is_zero())
    }
}

impl<const LIMBS: usize> Sub for Uint<LIMBS> {
    type Output = Self;

    fn sub(self, rhs: Self) -> Self {
        self.sub(&rhs)
    }
}

impl<const LIMBS: usize> Sub<&Uint<LIMBS>> for Uint<LIMBS> {
    type Output = Self;

    fn sub(self, rhs: &Self) -> Self {
        self.checked_sub(rhs)
            .expect("attempted to subtract with underflow")
    }
}

impl<const LIMBS: usize> SubAssign<Uint<LIMBS>> for Uint<LIMBS> {
    fn sub_assign(&mut self, rhs: Uint<LIMBS>) {
        *self = self.sub(&rhs)
    }
}

impl<const LIMBS: usize> SubAssign<&Uint<LIMBS>> for Uint<LIMBS> {
    fn sub_assign(&mut self, rhs: &Uint<LIMBS>) {
        *self = self.sub(rhs)
    }
}

impl<const LIMBS: usize> SubAssign for Wrapping<Uint<LIMBS>> {
    fn sub_assign(&mut self, other: Self) {
        *self = *self - other;
    }
}

impl<const LIMBS: usize> SubAssign<&Wrapping<Uint<LIMBS>>> for Wrapping<Uint<LIMBS>> {
    fn sub_assign(&mut self, other: &Self) {
        *self = *self - other;
    }
}

impl<const LIMBS: usize> SubAssign for Checked<Uint<LIMBS>> {
    fn sub_assign(&mut self, other: Self) {
        *self = *self - other;
    }
}

impl<const LIMBS: usize> SubAssign<&Checked<Uint<LIMBS>>> for Checked<Uint<LIMBS>> {
    fn sub_assign(&mut self, other: &Self) {
        *self = *self - other;
    }
}

impl<const LIMBS: usize> WrappingSub for Uint<LIMBS> {
    fn wrapping_sub(&self, v: &Self) -> Self {
        self.wrapping_sub(v)
    }
}

#[cfg(test)]
mod tests {
    use crate::{CheckedSub, Limb, U128};

    #[test]
    fn borrowing_sub_no_borrow() {
        let (res, borrow) = U128::ONE.borrowing_sub(&U128::ONE, Limb::ZERO);
        assert_eq!(res, U128::ZERO);
        assert_eq!(borrow, Limb::ZERO);
    }

    #[test]
    fn borrowing_sub_with_borrow() {
        let (res, borrow) = U128::ZERO.borrowing_sub(&U128::ONE, Limb::ZERO);

        assert_eq!(res, U128::MAX);
        assert_eq!(borrow, Limb::MAX);
    }

    #[test]
    fn saturating_sub_no_borrow() {
        assert_eq!(
            U128::from(5u64).saturating_sub(&U128::ONE),
            U128::from(4u64)
        );
    }

    #[test]
    fn saturating_sub_with_borrow() {
        assert_eq!(
            U128::from(4u64).saturating_sub(&U128::from(5u64)),
            U128::ZERO
        );
    }

    #[test]
    fn wrapping_sub_no_borrow() {
        assert_eq!(U128::ONE.wrapping_sub(&U128::ONE), U128::ZERO);
    }

    #[test]
    fn wrapping_sub_with_borrow() {
        assert_eq!(U128::ZERO.wrapping_sub(&U128::ONE), U128::MAX);
    }

    #[test]
    fn checked_sub_ok() {
        let result = U128::ONE.checked_sub(&U128::ONE);
        assert_eq!(result.unwrap(), U128::ZERO);
    }

    #[test]
    fn checked_sub_overflow() {
        let result = U128::ZERO.checked_sub(&U128::ONE);
        assert!(!bool::from(result.is_some()));
    }
}
