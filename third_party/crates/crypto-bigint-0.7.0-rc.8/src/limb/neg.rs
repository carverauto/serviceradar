//! Limb negation

use crate::Limb;
use num_traits::WrappingNeg;

impl Limb {
    /// Perform wrapping negation.
    #[inline(always)]
    pub const fn wrapping_neg(self) -> Self {
        Limb(self.0.wrapping_neg())
    }
}

impl WrappingNeg for Limb {
    #[inline]
    fn wrapping_neg(&self) -> Self {
        Self(self.0.wrapping_neg())
    }
}
