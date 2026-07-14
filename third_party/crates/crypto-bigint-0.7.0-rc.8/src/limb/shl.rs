//! Limb left bitshift

use crate::Limb;
use core::ops::{Shl, ShlAssign};
use num_traits::WrappingShl;

impl Limb {
    /// Computes `self << shift`.
    /// Panics if `shift` overflows `Limb::BITS`.
    #[inline(always)]
    pub const fn shl(self, shift: u32) -> Self {
        Limb(self.0 << shift)
    }

    /// Computes `self << 1` and return the result and the carry (0 or 1).
    #[inline(always)]
    pub(crate) const fn shl1(self) -> (Self, Self) {
        (Self(self.0 << 1), Self(self.0 >> Self::HI_BIT))
    }
}

macro_rules! impl_shl {
    ($($shift:ty),+) => {
        $(
            impl Shl<$shift> for Limb {
                type Output = Limb;

                #[inline]
                fn shl(self, shift: $shift) -> Limb {
                     Self::shl(self, u32::try_from(shift).expect("invalid shift"))
                }
            }

            impl Shl<$shift> for &Limb {
                type Output = Limb;

                #[inline]
                fn shl(self, shift: $shift) -> Limb {
                   *self << shift
                }
            }

            impl ShlAssign<$shift> for Limb {
                #[inline]
                fn shl_assign(&mut self, shift: $shift) {
                    *self = *self << shift;
                }
            }
        )+
    };
}

impl_shl!(i32, u32, usize);

impl WrappingShl for Limb {
    #[inline]
    fn wrapping_shl(&self, shift: u32) -> Limb {
        Self(self.0.wrapping_shl(shift))
    }
}

#[cfg(test)]
mod tests {
    use crate::Limb;

    #[test]
    fn shl1() {
        assert_eq!(Limb(1) << 1, Limb(2));
    }

    #[test]
    fn shl2() {
        assert_eq!(Limb(1) << 2, Limb(4));
    }

    #[test]
    fn shl_assign1() {
        let mut l = Limb(1);
        l <<= 1;
        assert_eq!(l, Limb(2));
    }

    #[test]
    fn shl_assign2() {
        let mut l = Limb(1);
        l <<= 2;
        assert_eq!(l, Limb(4));
    }
}
