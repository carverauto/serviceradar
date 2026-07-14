//! [`Int`] bitwise OR operations.

use core::ops::{BitOr, BitOrAssign};

use crate::{ConstCtOption, Uint, Wrapping};

use super::Int;

impl<const LIMBS: usize> Int<LIMBS> {
    /// Computes bitwise `a & b`.
    #[inline(always)]
    pub const fn bitor(&self, rhs: &Self) -> Self {
        Self(Uint::bitor(&self.0, &rhs.0))
    }

    /// Perform wrapping bitwise `OR`.
    ///
    /// There's no way wrapping could ever happen.
    /// This function exists so that all operations are accounted for in the wrapping operations
    pub const fn wrapping_or(&self, rhs: &Self) -> Self {
        self.bitor(rhs)
    }

    /// Perform checked bitwise `OR`, returning a [`ConstCtOption`] which `is_some` always
    pub const fn checked_or(&self, rhs: &Self) -> ConstCtOption<Self> {
        ConstCtOption::some(self.bitor(rhs))
    }
}

impl<const LIMBS: usize> BitOr for Int<LIMBS> {
    type Output = Self;

    fn bitor(self, rhs: Self) -> Int<LIMBS> {
        self.bitor(&rhs)
    }
}

impl<const LIMBS: usize> BitOr<&Int<LIMBS>> for Int<LIMBS> {
    type Output = Int<LIMBS>;

    #[allow(clippy::needless_borrow)]
    fn bitor(self, rhs: &Int<LIMBS>) -> Int<LIMBS> {
        (&self).bitor(rhs)
    }
}

impl<const LIMBS: usize> BitOr<Int<LIMBS>> for &Int<LIMBS> {
    type Output = Int<LIMBS>;

    fn bitor(self, rhs: Int<LIMBS>) -> Int<LIMBS> {
        self.bitor(&rhs)
    }
}

impl<const LIMBS: usize> BitOr<&Int<LIMBS>> for &Int<LIMBS> {
    type Output = Int<LIMBS>;

    fn bitor(self, rhs: &Int<LIMBS>) -> Int<LIMBS> {
        self.bitor(rhs)
    }
}

impl<const LIMBS: usize> BitOrAssign for Int<LIMBS> {
    fn bitor_assign(&mut self, other: Self) {
        *self = *self | other;
    }
}

impl<const LIMBS: usize> BitOrAssign<&Int<LIMBS>> for Int<LIMBS> {
    fn bitor_assign(&mut self, other: &Self) {
        *self = *self | other;
    }
}

impl<const LIMBS: usize> BitOr for Wrapping<Int<LIMBS>> {
    type Output = Self;

    fn bitor(self, rhs: Self) -> Wrapping<Int<LIMBS>> {
        Wrapping(self.0.bitor(&rhs.0))
    }
}

impl<const LIMBS: usize> BitOr<&Wrapping<Int<LIMBS>>> for Wrapping<Int<LIMBS>> {
    type Output = Wrapping<Int<LIMBS>>;

    fn bitor(self, rhs: &Wrapping<Int<LIMBS>>) -> Wrapping<Int<LIMBS>> {
        Wrapping(self.0.bitor(&rhs.0))
    }
}

impl<const LIMBS: usize> BitOr<Wrapping<Int<LIMBS>>> for &Wrapping<Int<LIMBS>> {
    type Output = Wrapping<Int<LIMBS>>;

    fn bitor(self, rhs: Wrapping<Int<LIMBS>>) -> Wrapping<Int<LIMBS>> {
        Wrapping(self.0.bitor(&rhs.0))
    }
}

impl<const LIMBS: usize> BitOr<&Wrapping<Int<LIMBS>>> for &Wrapping<Int<LIMBS>> {
    type Output = Wrapping<Int<LIMBS>>;

    fn bitor(self, rhs: &Wrapping<Int<LIMBS>>) -> Wrapping<Int<LIMBS>> {
        Wrapping(self.0.bitor(&rhs.0))
    }
}

impl<const LIMBS: usize> BitOrAssign for Wrapping<Int<LIMBS>> {
    fn bitor_assign(&mut self, other: Self) {
        *self = *self | other;
    }
}

impl<const LIMBS: usize> BitOrAssign<&Wrapping<Int<LIMBS>>> for Wrapping<Int<LIMBS>> {
    fn bitor_assign(&mut self, other: &Self) {
        *self = *self | other;
    }
}

#[cfg(test)]
mod tests {
    use crate::I128;

    #[test]
    fn checked_or_ok() {
        assert_eq!(I128::ZERO.checked_or(&I128::ONE).unwrap(), I128::ONE);
        assert_eq!(I128::ONE.checked_or(&I128::ONE).unwrap(), I128::ONE);
        assert_eq!(I128::MAX.checked_or(&I128::ONE).unwrap(), I128::MAX);
    }

    #[test]
    fn wrapping_or_ok() {
        assert_eq!(I128::ZERO.wrapping_or(&I128::ONE), I128::ONE);
        assert_eq!(I128::ONE.wrapping_or(&I128::ONE), I128::ONE);
        assert_eq!(I128::MAX.wrapping_or(&I128::ONE), I128::MAX);
    }
}
