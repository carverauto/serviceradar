//! Limb subtraction

use crate::{Checked, CheckedSub, Limb, Wrapping, WrappingSub, Zero, primitives::borrowing_sub};
use core::ops::{Sub, SubAssign};
use subtle::CtOption;

impl Limb {
    /// Computes `self - (rhs + borrow)`, returning the result along with the new borrow.
    #[deprecated(since = "0.7.0", note = "please use `borrowing_sub` instead")]
    pub const fn sbb(self, rhs: Limb, borrow: Limb) -> (Limb, Limb) {
        self.borrowing_sub(rhs, borrow)
    }

    /// Computes `self - (rhs + borrow)`, returning the result along with the new borrow.
    #[inline(always)]
    pub const fn borrowing_sub(self, rhs: Limb, borrow: Limb) -> (Limb, Limb) {
        let (res, borrow) = borrowing_sub(self.0, rhs.0, borrow.0);
        (Limb(res), Limb(borrow))
    }

    /// Perform saturating subtraction.
    #[inline]
    pub const fn saturating_sub(&self, rhs: Self) -> Self {
        Limb(self.0.saturating_sub(rhs.0))
    }

    /// Perform wrapping subtraction, discarding underflow and wrapping around
    /// the boundary of the type.
    #[inline(always)]
    pub const fn wrapping_sub(&self, rhs: Self) -> Self {
        Limb(self.0.wrapping_sub(rhs.0))
    }
}

impl CheckedSub for Limb {
    #[inline]
    fn checked_sub(&self, rhs: &Self) -> CtOption<Self> {
        let (result, underflow) = self.borrowing_sub(*rhs, Limb::ZERO);
        CtOption::new(result, underflow.is_zero())
    }
}

impl Sub for Limb {
    type Output = Self;

    #[inline]
    fn sub(self, rhs: Self) -> Self {
        self.checked_sub(&rhs)
            .expect("attempted to subtract with underflow")
    }
}

impl Sub<&Self> for Limb {
    type Output = Self;

    #[inline]
    fn sub(self, rhs: &Self) -> Self {
        self - *rhs
    }
}

impl SubAssign for Wrapping<Limb> {
    #[inline]
    fn sub_assign(&mut self, other: Self) {
        *self = *self - other;
    }
}

impl SubAssign<&Wrapping<Limb>> for Wrapping<Limb> {
    #[inline]
    fn sub_assign(&mut self, other: &Self) {
        *self = *self - other;
    }
}

impl SubAssign for Checked<Limb> {
    #[inline]
    fn sub_assign(&mut self, other: Self) {
        *self = *self - other;
    }
}

impl SubAssign<&Checked<Limb>> for Checked<Limb> {
    #[inline]
    fn sub_assign(&mut self, other: &Self) {
        *self = *self - other;
    }
}

impl WrappingSub for Limb {
    #[inline]
    fn wrapping_sub(&self, v: &Self) -> Self {
        self.wrapping_sub(*v)
    }
}

#[cfg(test)]
mod tests {
    use crate::{CheckedSub, Limb};

    #[test]
    fn borrowing_sub_no_borrow() {
        let (res, borrow) = Limb::ONE.borrowing_sub(Limb::ONE, Limb::ZERO);
        assert_eq!(res, Limb::ZERO);
        assert_eq!(borrow, Limb::ZERO);
    }

    #[test]
    fn borrowing_sub_with_borrow() {
        let (res, borrow) = Limb::ZERO.borrowing_sub(Limb::ONE, Limb::ZERO);

        assert_eq!(res, Limb::MAX);
        assert_eq!(borrow, Limb::MAX);
    }

    #[test]
    fn wrapping_sub_no_borrow() {
        assert_eq!(Limb::ONE.wrapping_sub(Limb::ONE), Limb::ZERO);
    }

    #[test]
    fn wrapping_sub_with_borrow() {
        assert_eq!(Limb::ZERO.wrapping_sub(Limb::ONE), Limb::MAX);
    }

    #[test]
    fn checked_sub_ok() {
        let result = Limb::ONE.checked_sub(&Limb::ONE);
        assert_eq!(result.unwrap(), Limb::ZERO);
    }

    #[test]
    fn checked_sub_overflow() {
        let result = Limb::ZERO.checked_sub(&Limb::ONE);
        assert!(!bool::from(result.is_some()));
    }
}
