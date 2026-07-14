//! Limb bit or operations.

use super::Limb;
use core::ops::{BitOr, BitOrAssign};

impl Limb {
    /// Calculates `a | b`.
    #[inline(always)]
    pub const fn bitor(self, rhs: Self) -> Self {
        Limb(self.0 | rhs.0)
    }
}

impl BitOr for Limb {
    type Output = Limb;

    fn bitor(self, rhs: Self) -> Self::Output {
        self.bitor(rhs)
    }
}

impl BitOrAssign for Limb {
    fn bitor_assign(&mut self, other: Self) {
        *self = self.bitor(other);
    }
}

impl BitOrAssign<&Limb> for Limb {
    fn bitor_assign(&mut self, other: &Self) {
        *self = self.bitor(*other);
    }
}
