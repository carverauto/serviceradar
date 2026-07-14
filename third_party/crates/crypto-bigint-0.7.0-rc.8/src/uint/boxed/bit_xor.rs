//! [`BoxedUint`] bitwise XOR operations.

use super::BoxedUint;
use crate::Wrapping;
use core::ops::{BitXor, BitXorAssign};
use subtle::{Choice, CtOption};

impl BoxedUint {
    /// Computes bitwise `a ^ b`.
    #[inline(always)]
    pub fn bitxor(&self, rhs: &Self) -> Self {
        Self::map_limbs(self, rhs, |a, b| a.bitxor(b))
    }

    /// Perform wrapping bitwise `XOR``.
    ///
    /// There's no way wrapping could ever happen.
    /// This function exists so that all operations are accounted for in the wrapping operations
    pub fn wrapping_xor(&self, rhs: &Self) -> Self {
        self.bitxor(rhs)
    }

    /// Perform checked bitwise `XOR`, returning a [`CtOption`] which `is_some` always
    pub fn checked_xor(&self, rhs: &Self) -> CtOption<Self> {
        let result = self.bitxor(rhs);
        CtOption::new(result, Choice::from(1))
    }
}

impl BitXor for BoxedUint {
    type Output = Self;

    fn bitxor(self, rhs: Self) -> BoxedUint {
        self.bitxor(&rhs)
    }
}

impl BitXor<&BoxedUint> for BoxedUint {
    type Output = BoxedUint;

    fn bitxor(self, rhs: &BoxedUint) -> BoxedUint {
        Self::bitxor(&self, rhs)
    }
}

impl BitXor<BoxedUint> for &BoxedUint {
    type Output = BoxedUint;

    fn bitxor(self, rhs: BoxedUint) -> BoxedUint {
        self.bitxor(&rhs)
    }
}

impl BitXor<&BoxedUint> for &BoxedUint {
    type Output = BoxedUint;

    fn bitxor(self, rhs: &BoxedUint) -> BoxedUint {
        self.bitxor(rhs)
    }
}

impl BitXorAssign for BoxedUint {
    fn bitxor_assign(&mut self, other: Self) {
        *self = Self::bitxor(self, &other);
    }
}

impl BitXorAssign<&BoxedUint> for BoxedUint {
    fn bitxor_assign(&mut self, other: &Self) {
        *self = Self::bitxor(self, other);
    }
}

impl BitXor for Wrapping<BoxedUint> {
    type Output = Self;

    fn bitxor(self, rhs: Self) -> Wrapping<BoxedUint> {
        Wrapping(self.0.bitxor(&rhs.0))
    }
}

impl BitXor<&Wrapping<BoxedUint>> for Wrapping<BoxedUint> {
    type Output = Wrapping<BoxedUint>;

    fn bitxor(self, rhs: &Wrapping<BoxedUint>) -> Wrapping<BoxedUint> {
        Wrapping(self.0.bitxor(&rhs.0))
    }
}

impl BitXor<Wrapping<BoxedUint>> for &Wrapping<BoxedUint> {
    type Output = Wrapping<BoxedUint>;

    fn bitxor(self, rhs: Wrapping<BoxedUint>) -> Wrapping<BoxedUint> {
        Wrapping(BoxedUint::bitxor(&self.0, &rhs.0))
    }
}

impl BitXor<&Wrapping<BoxedUint>> for &Wrapping<BoxedUint> {
    type Output = Wrapping<BoxedUint>;

    fn bitxor(self, rhs: &Wrapping<BoxedUint>) -> Wrapping<BoxedUint> {
        Wrapping(BoxedUint::bitxor(&self.0, &rhs.0))
    }
}

impl BitXorAssign for Wrapping<BoxedUint> {
    fn bitxor_assign(&mut self, other: Self) {
        *self = Wrapping(BoxedUint::bitxor(&self.0, &other.0));
    }
}

impl BitXorAssign<&Wrapping<BoxedUint>> for Wrapping<BoxedUint> {
    fn bitxor_assign(&mut self, other: &Self) {
        *self = Wrapping(BoxedUint::bitxor(&self.0, &other.0));
    }
}

#[cfg(test)]
mod tests {
    use crate::U128;

    #[test]
    fn checked_xor_ok() {
        let result = U128::ZERO.checked_xor(&U128::ONE);
        assert_eq!(result.unwrap(), U128::ONE);
    }

    #[test]
    fn overlapping_xor_ok() {
        let result = U128::ZERO.wrapping_xor(&U128::ONE);
        assert_eq!(result, U128::ONE);
    }
}
