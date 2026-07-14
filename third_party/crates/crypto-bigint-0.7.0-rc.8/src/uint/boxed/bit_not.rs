//! [`BoxedUint`] bitwise NOT operations.

use super::BoxedUint;
use crate::{Limb, Wrapping};
use core::ops::Not;

impl BoxedUint {
    /// Computes bitwise `!a`.
    pub fn not(&self) -> Self {
        let mut limbs = vec![Limb::ZERO; self.nlimbs()];

        for i in 0..self.nlimbs() {
            limbs[i] = self.limbs[i].not();
        }

        limbs.into()
    }
}

impl Not for BoxedUint {
    type Output = Self;

    fn not(self) -> Self {
        BoxedUint::not(&self)
    }
}

impl Not for Wrapping<BoxedUint> {
    type Output = Self;

    fn not(self) -> <Self as Not>::Output {
        Wrapping(self.0.not())
    }
}

#[cfg(test)]
mod tests {
    use crate::BoxedUint;

    #[test]
    fn bitnot_ok() {
        assert_eq!(
            BoxedUint::zero_with_precision(128).not(),
            BoxedUint::max(128)
        );
        assert_eq!(
            BoxedUint::max(128).not(),
            BoxedUint::zero_with_precision(128)
        );
    }
}
