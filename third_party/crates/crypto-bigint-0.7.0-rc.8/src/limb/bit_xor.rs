//! Limb bit xor operations.

use super::Limb;
use core::ops::{BitXor, BitXorAssign};

impl Limb {
    /// Calculates `a ^ b`.
    #[inline(always)]
    pub const fn bitxor(self, rhs: Self) -> Self {
        Limb(self.0 ^ rhs.0)
    }
}

impl BitXor for Limb {
    type Output = Limb;

    fn bitxor(self, rhs: Self) -> Self::Output {
        self.bitxor(rhs)
    }
}

impl BitXorAssign for Limb {
    fn bitxor_assign(&mut self, rhs: Self) {
        self.0 ^= rhs.0;
    }
}
