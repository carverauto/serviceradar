//! [`Int`] bitwise NOT operations.

use core::ops::Not;

use crate::{Uint, Wrapping};

use super::Int;

impl<const LIMBS: usize> Int<LIMBS> {
    /// Computes bitwise `!a`.
    #[inline(always)]
    pub const fn not(&self) -> Self {
        Self(Uint::not(&self.0))
    }
}

impl<const LIMBS: usize> Not for Int<LIMBS> {
    type Output = Self;

    fn not(self) -> Self {
        Self::not(&self)
    }
}

impl<const LIMBS: usize> Not for Wrapping<Int<LIMBS>> {
    type Output = Self;

    fn not(self) -> <Self as Not>::Output {
        Wrapping(self.0.not())
    }
}

#[cfg(test)]
mod tests {
    use crate::I128;

    #[test]
    fn bitnot_ok() {
        assert_eq!(I128::ZERO.not(), I128::MINUS_ONE);
        assert_eq!(I128::MAX.not(), I128::MIN);
    }
}
