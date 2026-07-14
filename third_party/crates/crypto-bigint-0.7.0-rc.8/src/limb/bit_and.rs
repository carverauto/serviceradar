//! Limb bit and operations.

use super::Limb;
use core::ops::{BitAnd, BitAndAssign};

impl Limb {
    /// Calculates `a & b`.
    #[inline(always)]
    pub const fn bitand(self, rhs: Self) -> Self {
        Limb(self.0 & rhs.0)
    }
}

impl BitAnd for Limb {
    type Output = Limb;

    #[inline(always)]
    fn bitand(self, rhs: Self) -> Self::Output {
        self.bitand(rhs)
    }
}

impl BitAndAssign for Limb {
    fn bitand_assign(&mut self, rhs: Self) {
        self.0 &= rhs.0;
    }
}

impl BitAndAssign<&Limb> for Limb {
    fn bitand_assign(&mut self, rhs: &Limb) {
        self.0 &= rhs.0;
    }
}
