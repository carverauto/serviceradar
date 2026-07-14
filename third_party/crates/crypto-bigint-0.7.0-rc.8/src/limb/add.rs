//! Limb addition

use crate::{
    Checked, CheckedAdd, Limb, Wrapping, WrappingAdd, Zero,
    primitives::{carrying_add, overflowing_add},
};
use core::ops::{Add, AddAssign};
use subtle::CtOption;

impl Limb {
    /// Computes `self + rhs`, returning the result along with the carry.
    #[inline(always)]
    pub const fn overflowing_add(self, rhs: Limb) -> (Limb, Limb) {
        let (res, carry) = overflowing_add(self.0, rhs.0);
        (Limb(res), Limb(carry))
    }

    /// Computes `self + rhs + carry`, returning the result along with the new carry.
    #[deprecated(since = "0.7.0", note = "please use `carrying_add` instead")]
    pub const fn adc(self, rhs: Limb, carry: Limb) -> (Limb, Limb) {
        self.carrying_add(rhs, carry)
    }

    /// Computes `self + rhs + carry`, returning the result along with the new carry.
    #[inline(always)]
    pub const fn carrying_add(self, rhs: Limb, carry: Limb) -> (Limb, Limb) {
        let (res, carry) = carrying_add(self.0, rhs.0, carry.0);
        (Limb(res), Limb(carry))
    }

    /// Perform saturating addition.
    #[inline]
    pub const fn saturating_add(&self, rhs: Self) -> Self {
        Limb(self.0.saturating_add(rhs.0))
    }

    /// Perform wrapping addition, discarding overflow.
    #[inline(always)]
    pub const fn wrapping_add(&self, rhs: Self) -> Self {
        Limb(self.0.wrapping_add(rhs.0))
    }
}

impl Add for Limb {
    type Output = Self;

    #[inline]
    fn add(self, rhs: Self) -> Self {
        self.checked_add(&rhs)
            .expect("attempted to add with overflow")
    }
}

impl AddAssign for Wrapping<Limb> {
    #[inline]
    fn add_assign(&mut self, other: Self) {
        *self = *self + other;
    }
}

impl AddAssign<&Wrapping<Limb>> for Wrapping<Limb> {
    #[inline]
    fn add_assign(&mut self, other: &Self) {
        *self = *self + other;
    }
}

impl AddAssign for Checked<Limb> {
    #[inline]
    fn add_assign(&mut self, other: Self) {
        *self = *self + other;
    }
}

impl AddAssign<&Checked<Limb>> for Checked<Limb> {
    #[inline]
    fn add_assign(&mut self, other: &Self) {
        *self = *self + other;
    }
}

impl CheckedAdd for Limb {
    #[inline]
    fn checked_add(&self, rhs: &Self) -> CtOption<Self> {
        let (result, carry) = self.overflowing_add(*rhs);
        CtOption::new(result, carry.is_zero())
    }
}

impl WrappingAdd for Limb {
    #[inline]
    fn wrapping_add(&self, v: &Self) -> Self {
        self.wrapping_add(*v)
    }
}

#[cfg(test)]
mod tests {
    use crate::{CheckedAdd, Limb};

    #[test]
    fn carrying_add_no_carry() {
        let (res, carry) = Limb::ZERO.overflowing_add(Limb::ONE);
        assert_eq!(res, Limb::ONE);
        assert_eq!(carry, Limb::ZERO);
    }

    #[test]
    fn carrying_add_with_carry() {
        let (res, carry) = Limb::MAX.overflowing_add(Limb::ONE);
        assert_eq!(res, Limb::ZERO);
        assert_eq!(carry, Limb::ONE);
    }

    #[test]
    fn wrapping_add_no_carry() {
        assert_eq!(Limb::ZERO.wrapping_add(Limb::ONE), Limb::ONE);
    }

    #[test]
    fn wrapping_add_with_carry() {
        assert_eq!(Limb::MAX.wrapping_add(Limb::ONE), Limb::ZERO);
    }

    #[test]
    fn checked_add_ok() {
        let result = Limb::ZERO.checked_add(&Limb::ONE);
        assert_eq!(result.unwrap(), Limb::ONE);
    }

    #[test]
    fn checked_add_overflow() {
        let result = Limb::MAX.checked_add(&Limb::ONE);
        assert!(!bool::from(result.is_some()));
    }
}
