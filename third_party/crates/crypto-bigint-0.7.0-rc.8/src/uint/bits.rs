use subtle::Choice;

use crate::{BitOps, ConstChoice, Uint};

impl<const LIMBS: usize> Uint<LIMBS> {
    /// Get the value of the bit at position `index`, as a truthy or falsy `ConstChoice`.
    /// Returns the falsy value for indices out of range.
    pub const fn bit(&self, index: u32) -> ConstChoice {
        self.as_uint_ref().bit(index)
    }

    /// Returns `true` if the bit at position `index` is set, `false` otherwise.
    ///
    /// # Remarks
    /// This operation is variable time with respect to `index` only.
    #[inline(always)]
    pub const fn bit_vartime(&self, index: u32) -> bool {
        self.as_uint_ref().bit_vartime(index)
    }

    /// Calculate the number of bits needed to represent this number.
    #[inline]
    pub const fn bits(&self) -> u32 {
        Self::BITS - self.leading_zeros()
    }

    /// Calculate the number of bits needed to represent this number in variable-time with respect
    /// to `self`.
    pub const fn bits_vartime(&self) -> u32 {
        self.as_uint_ref().bits_vartime()
    }

    /// Calculate the number of leading zeros in the binary representation of this number.
    pub const fn leading_zeros(&self) -> u32 {
        self.as_uint_ref().leading_zeros()
    }

    /// Calculate the number of leading zeros in the binary representation of this number in
    /// variable-time with respect to `self`.
    pub const fn leading_zeros_vartime(&self) -> u32 {
        Self::BITS - self.bits_vartime()
    }

    /// Calculate the number of trailing zeros in the binary representation of this number.
    pub const fn trailing_zeros(&self) -> u32 {
        self.as_uint_ref().trailing_zeros()
    }

    /// Calculate the number of trailing zeros in the binary representation of this number in
    /// variable-time with respect to `self`.
    pub const fn trailing_zeros_vartime(&self) -> u32 {
        self.as_uint_ref().trailing_zeros_vartime()
    }

    /// Calculate the number of trailing ones in the binary representation of this number.
    pub const fn trailing_ones(&self) -> u32 {
        self.as_uint_ref().trailing_ones()
    }

    /// Calculate the number of trailing ones in the binary representation of this number,
    /// variable time in `self`.
    pub const fn trailing_ones_vartime(&self) -> u32 {
        self.as_uint_ref().trailing_ones_vartime()
    }

    /// Sets the bit at `index` to 0 or 1 depending on the value of `bit_value`.
    pub(crate) const fn set_bit(self, index: u32, bit_value: ConstChoice) -> Self {
        let mut result = self;
        result.as_mut_uint_ref().set_bit(index, bit_value);
        result
    }

    /// Sets the bit at `index` to 0 or 1 depending on the value of `bit_value`,
    /// variable time in `self`.
    pub(crate) const fn set_bit_vartime(self, index: u32, bit_value: bool) -> Self {
        let mut result = self;
        result.as_mut_uint_ref().set_bit_vartime(index, bit_value);
        result
    }

    /// Clear any bits at or above a given bit position.
    pub(crate) const fn restrict_bits(mut self, len: u32) -> Self {
        self.as_mut_uint_ref().restrict_bits(len);
        self
    }
}

impl<const LIMBS: usize> BitOps for Uint<LIMBS> {
    fn bits_precision(&self) -> u32 {
        Self::BITS
    }

    fn bytes_precision(&self) -> usize {
        Self::BYTES
    }

    fn leading_zeros(&self) -> u32 {
        self.leading_zeros()
    }

    fn bit(&self, index: u32) -> Choice {
        self.bit(index).into()
    }

    fn set_bit(&mut self, index: u32, bit_value: Choice) {
        *self = Self::set_bit(*self, index, bit_value.into());
    }

    fn trailing_zeros(&self) -> u32 {
        self.trailing_zeros()
    }

    fn trailing_ones(&self) -> u32 {
        self.trailing_ones()
    }

    fn bit_vartime(&self, index: u32) -> bool {
        self.bit_vartime(index)
    }

    fn bits_vartime(&self) -> u32 {
        self.bits_vartime()
    }

    fn set_bit_vartime(&mut self, index: u32, bit_value: bool) {
        *self = Self::set_bit_vartime(*self, index, bit_value);
    }

    fn trailing_zeros_vartime(&self) -> u32 {
        self.trailing_zeros_vartime()
    }

    fn trailing_ones_vartime(&self) -> u32 {
        self.trailing_ones_vartime()
    }
}

#[cfg(test)]
mod tests {
    use crate::{ConstChoice, U256};

    fn uint_with_bits_at(positions: &[u32]) -> U256 {
        let mut result = U256::ZERO;
        for pos in positions {
            result |= U256::ONE << *pos;
        }
        result
    }

    #[test]
    fn bit_vartime() {
        let u = uint_with_bits_at(&[16, 48, 112, 127, 255]);
        assert!(!u.bit_vartime(0));
        assert!(!u.bit_vartime(1));
        assert!(u.bit_vartime(16));
        assert!(u.bit_vartime(127));
        assert!(u.bit_vartime(255));
        assert!(!u.bit_vartime(256));
        assert!(!u.bit_vartime(260));
    }

    #[test]
    fn bit() {
        let u = uint_with_bits_at(&[16, 48, 112, 127, 255]);
        assert!(!u.bit(0).is_true_vartime());
        assert!(!u.bit(1).is_true_vartime());
        assert!(u.bit(16).is_true_vartime());
        assert!(u.bit(127).is_true_vartime());
        assert!(u.bit(255).is_true_vartime());
        assert!(!u.bit(256).is_true_vartime());
        assert!(!u.bit(260).is_true_vartime());
    }

    #[test]
    fn leading_zeros() {
        let u = uint_with_bits_at(&[256 - 16, 256 - 79, 256 - 207]);
        assert_eq!(u.leading_zeros(), 15);

        let u = uint_with_bits_at(&[256 - 79, 256 - 207]);
        assert_eq!(u.leading_zeros(), 78);

        let u = uint_with_bits_at(&[256 - 207]);
        assert_eq!(u.leading_zeros(), 206);

        let u = uint_with_bits_at(&[256 - 1, 256 - 75, 256 - 150]);
        assert_eq!(u.leading_zeros(), 0);

        let u = U256::ZERO;
        assert_eq!(u.leading_zeros(), 256);
    }

    #[test]
    fn leading_zeros_vartime() {
        let u = uint_with_bits_at(&[256 - 16, 256 - 79, 256 - 207]);
        assert_eq!(u.leading_zeros_vartime(), 15);

        let u = uint_with_bits_at(&[256 - 79, 256 - 207]);
        assert_eq!(u.leading_zeros_vartime(), 78);

        let u = uint_with_bits_at(&[256 - 207]);
        assert_eq!(u.leading_zeros_vartime(), 206);

        let u = uint_with_bits_at(&[256 - 1, 256 - 75, 256 - 150]);
        assert_eq!(u.leading_zeros_vartime(), 0);

        let u = U256::ZERO;
        assert_eq!(u.leading_zeros_vartime(), 256);
    }

    #[test]
    fn trailing_zeros() {
        let u = uint_with_bits_at(&[16, 79, 150]);
        assert_eq!(u.trailing_zeros(), 16);

        let u = uint_with_bits_at(&[79, 150]);
        assert_eq!(u.trailing_zeros(), 79);

        let u = uint_with_bits_at(&[150, 207]);
        assert_eq!(u.trailing_zeros(), 150);

        let u = uint_with_bits_at(&[0, 150, 207]);
        assert_eq!(u.trailing_zeros(), 0);

        let u = U256::ZERO;
        assert_eq!(u.trailing_zeros(), 256);
    }

    #[test]
    fn trailing_zeros_vartime() {
        let u = uint_with_bits_at(&[16, 79, 150]);
        assert_eq!(u.trailing_zeros_vartime(), 16);

        let u = uint_with_bits_at(&[79, 150]);
        assert_eq!(u.trailing_zeros_vartime(), 79);

        let u = uint_with_bits_at(&[150, 207]);
        assert_eq!(u.trailing_zeros_vartime(), 150);

        let u = uint_with_bits_at(&[0, 150, 207]);
        assert_eq!(u.trailing_zeros_vartime(), 0);

        let u = U256::ZERO;
        assert_eq!(u.trailing_zeros_vartime(), 256);
    }

    #[test]
    fn trailing_ones() {
        let u = !uint_with_bits_at(&[16, 79, 150]);
        assert_eq!(u.trailing_ones(), 16);

        let u = !uint_with_bits_at(&[79, 150]);
        assert_eq!(u.trailing_ones(), 79);

        let u = !uint_with_bits_at(&[150, 207]);
        assert_eq!(u.trailing_ones(), 150);

        let u = !uint_with_bits_at(&[0, 150, 207]);
        assert_eq!(u.trailing_ones(), 0);

        let u = U256::MAX;
        assert_eq!(u.trailing_ones(), 256);
    }

    #[test]
    fn trailing_ones_vartime() {
        let u = !uint_with_bits_at(&[16, 79, 150]);
        assert_eq!(u.trailing_ones_vartime(), 16);

        let u = !uint_with_bits_at(&[79, 150]);
        assert_eq!(u.trailing_ones_vartime(), 79);

        let u = !uint_with_bits_at(&[150, 207]);
        assert_eq!(u.trailing_ones_vartime(), 150);

        let u = !uint_with_bits_at(&[0, 150, 207]);
        assert_eq!(u.trailing_ones_vartime(), 0);

        let u = U256::MAX;
        assert_eq!(u.trailing_ones_vartime(), 256);
    }

    #[test]
    fn set_bit() {
        let u = uint_with_bits_at(&[16, 79, 150]);
        assert_eq!(
            u.set_bit(127, ConstChoice::TRUE),
            uint_with_bits_at(&[16, 79, 127, 150])
        );

        let u = uint_with_bits_at(&[16, 79, 150]);
        assert_eq!(
            u.set_bit(150, ConstChoice::TRUE),
            uint_with_bits_at(&[16, 79, 150])
        );

        let u = uint_with_bits_at(&[16, 79, 150]);
        assert_eq!(
            u.set_bit(127, ConstChoice::FALSE),
            uint_with_bits_at(&[16, 79, 150])
        );

        let u = uint_with_bits_at(&[16, 79, 150]);
        assert_eq!(
            u.set_bit(150, ConstChoice::FALSE),
            uint_with_bits_at(&[16, 79])
        );
    }
}
