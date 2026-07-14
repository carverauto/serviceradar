use crate::Word;

use super::Limb;

impl Limb {
    /// Calculate the number of bits needed to represent this number.
    #[inline(always)]
    pub const fn bits(self) -> u32 {
        Limb::BITS - self.0.leading_zeros()
    }

    /// Calculate the number of leading zeros in the binary representation of this number.
    #[inline(always)]
    pub const fn leading_zeros(self) -> u32 {
        self.0.leading_zeros()
    }

    /// Calculate the number of trailing zeros in the binary representation of this number.
    #[inline(always)]
    pub const fn trailing_zeros(self) -> u32 {
        self.0.trailing_zeros()
    }

    /// Calculate the number of trailing ones the binary representation of this number.
    #[inline(always)]
    pub const fn trailing_ones(self) -> u32 {
        self.0.trailing_ones()
    }

    /// Clear bits at or above the given bit position.
    pub const fn restrict_bits(self, len: u32) -> Self {
        #[allow(trivial_numeric_casts)]
        self.bitand(Limb((1 as Word).overflowing_shl(len).0 - 1))
    }
}
