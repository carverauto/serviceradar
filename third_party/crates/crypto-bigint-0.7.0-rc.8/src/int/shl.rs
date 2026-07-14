//! [`Int`] bitwise left shift operations.

use core::ops::{Shl, ShlAssign};

use subtle::CtOption;

use crate::{ConstCtOption, Int, ShlVartime, Uint, WrappingShl};

impl<const LIMBS: usize> Int<LIMBS> {
    /// Computes `self << shift`.
    ///
    /// Panics if `shift >= Self::BITS`.
    pub const fn shl(&self, shift: u32) -> Self {
        Self(Uint::shl(&self.0, shift))
    }

    /// Computes `self << shift` in variable time.
    ///
    /// Panics if `shift >= Self::BITS`.
    pub const fn shl_vartime(&self, shift: u32) -> Self {
        Self(Uint::shl_vartime(&self.0, shift))
    }

    /// Computes `self << shift`.
    ///
    /// Returns `None` if `shift >= Self::BITS`.
    pub const fn overflowing_shl(&self, shift: u32) -> ConstCtOption<Self> {
        self.0.overflowing_shl(shift).as_int()
    }

    /// Computes `self << shift`.
    ///
    /// Returns `None` if `shift >= Self::BITS`.
    ///
    /// NOTE: this operation is variable time with respect to `shift` *ONLY*.
    ///
    /// When used with a fixed `shift`, this function is constant-time with respect
    /// to `self`.
    #[inline(always)]
    pub const fn overflowing_shl_vartime(&self, shift: u32) -> ConstCtOption<Self> {
        self.0.overflowing_shl_vartime(shift).as_int()
    }

    /// Computes `self << shift` in a panic-free manner, returning zero if the shift exceeds the
    /// precision.
    pub const fn wrapping_shl(&self, shift: u32) -> Self {
        Self(self.0.wrapping_shl(shift))
    }

    /// Computes `self << shift` in variable-time in a panic-free manner, returning zero if the
    /// shift exceeds the precision.
    pub const fn wrapping_shl_vartime(&self, shift: u32) -> Self {
        Self(self.0.wrapping_shl_vartime(shift))
    }
}

macro_rules! impl_shl {
    ($($shift:ty),+) => {
        $(
            impl<const LIMBS: usize> Shl<$shift> for Int<LIMBS> {
                type Output = Int<LIMBS>;

                #[inline]
                fn shl(self, shift: $shift) -> Int<LIMBS> {
                    <&Self>::shl(&self, shift)
                }
            }

            impl<const LIMBS: usize> Shl<$shift> for &Int<LIMBS> {
                type Output = Int<LIMBS>;

                #[inline]
                fn shl(self, shift: $shift) -> Int<LIMBS> {
                    Int::<LIMBS>::shl(self, u32::try_from(shift).expect("invalid shift"))
                }
            }

            impl<const LIMBS: usize> ShlAssign<$shift> for Int<LIMBS> {
                fn shl_assign(&mut self, shift: $shift) {
                    *self = self.shl(shift)
                }
            }
        )+
    };
}

impl_shl!(i32, u32, usize);

impl<const LIMBS: usize> WrappingShl for Int<LIMBS> {
    fn wrapping_shl(&self, shift: u32) -> Int<LIMBS> {
        self.wrapping_shl(shift)
    }
}

impl<const LIMBS: usize> ShlVartime for Int<LIMBS> {
    fn overflowing_shl_vartime(&self, shift: u32) -> CtOption<Self> {
        self.overflowing_shl(shift).into()
    }
    fn wrapping_shl_vartime(&self, shift: u32) -> Self {
        self.wrapping_shl(shift)
    }
}

#[cfg(test)]
mod tests {
    use crate::I256;

    const N: I256 =
        I256::from_be_hex("FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141");

    const TWO_N: I256 =
        I256::from_be_hex("FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFD755DB9CD5E9140777FA4BD19A06C8282");

    const FOUR_N: I256 =
        I256::from_be_hex("FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFAEABB739ABD2280EEFF497A3340D90504");

    const SIXTY_FIVE: I256 =
        I256::from_be_hex("FFFFFFFFFFFFFFFD755DB9CD5E9140777FA4BD19A06C82820000000000000000");

    const EIGHTY_EIGHT: I256 =
        I256::from_be_hex("FFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD03641410000000000000000000000");

    const SIXTY_FOUR: I256 =
        I256::from_be_hex("FFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD03641410000000000000000");

    #[test]
    fn shl_simple() {
        let mut t = I256::from(1i8);
        assert_eq!(t << 1, I256::from(2i8));
        t = I256::from(3i8);
        assert_eq!(t << 8, I256::from(0x300i16));
    }

    #[test]
    fn shl1() {
        assert_eq!(N << 1, TWO_N);
    }

    #[test]
    fn shl2() {
        assert_eq!(N << 2, FOUR_N);
    }

    #[test]
    fn shl65() {
        assert_eq!(N << 65, SIXTY_FIVE);
    }

    #[test]
    fn shl88() {
        assert_eq!(N << 88, EIGHTY_EIGHT);
    }

    #[test]
    fn shl256_const() {
        assert!(N.overflowing_shl(256).is_none().is_true_vartime());
        assert!(N.overflowing_shl_vartime(256).is_none().is_true_vartime());
    }

    #[test]
    #[should_panic(expected = "`shift` within the bit size of the integer")]
    fn shl256() {
        let _ = N << 256;
    }

    #[test]
    fn shl64() {
        assert_eq!(N << 64, SIXTY_FOUR);
    }
}
