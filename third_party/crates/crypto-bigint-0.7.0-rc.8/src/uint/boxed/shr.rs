//! [`BoxedUint`] bitwise right shift operations.

use crate::{BoxedUint, ConstChoice, Limb, ShrVartime, WrappingShr};
use core::ops::{Shr, ShrAssign};
use subtle::{Choice, CtOption};

impl BoxedUint {
    /// Computes `self >> shift`.
    ///
    /// Panics if `shift >= Self::BITS`.
    pub fn shr(&self, shift: u32) -> BoxedUint {
        let (result, overflow) = self.overflowing_shr(shift);
        assert!(
            !bool::from(overflow),
            "attempt to shift right with overflow"
        );
        result
    }

    /// Computes `self >>= shift`.
    ///
    /// Panics if `shift >= Self::BITS`.
    pub fn shr_assign(&mut self, shift: u32) {
        let overflow = self.overflowing_shr_assign(shift);
        assert!(
            !bool::from(overflow),
            "attempt to shift right with overflow"
        );
    }

    /// Computes `self >> shift`.
    ///
    /// Returns a zero and a truthy `Choice` if `shift >= self.bits_precision()`,
    /// or the result and a falsy `Choice` otherwise.
    pub fn overflowing_shr(&self, shift: u32) -> (Self, Choice) {
        let mut result = self.clone();
        let overflow = result.overflowing_shr_assign(shift);
        (result, overflow)
    }

    /// Computes `self >> shift` in variable-time.
    ///
    /// Returns a zero and a truthy `Choice` if `shift >= self.bits_precision()`,
    /// or the result and a falsy `Choice` otherwise.
    pub fn overflowing_shr_vartime(&self, shift: u32) -> (Self, Choice) {
        let mut result = self.clone();
        let overflow = result.overflowing_shr_assign_vartime(shift);
        (result, overflow)
    }

    /// Computes `self >>= shift`.
    ///
    /// Returns a truthy `Choice` if `shift >= self.bits_precision()` or a falsy `Choice` otherwise.
    pub fn overflowing_shr_assign(&mut self, shift: u32) -> Choice {
        self.as_mut_uint_ref().overflowing_shr_assign(shift)
    }

    /// Computes `self >>= shift` in variable-time.
    ///
    /// Returns a truthy `Choice` if `shift >= self.bits_precision()` or a falsy `Choice` otherwise.
    pub fn overflowing_shr_assign_vartime(&mut self, shift: u32) -> Choice {
        self.as_mut_uint_ref().overflowing_shr_assign_vartime(shift)
    }

    /// Computes `self >> shift` in a panic-free manner, masking off bits of `shift` which would cause the shift to
    /// exceed the type's width.
    pub fn wrapping_shr(&self, shift: u32) -> Self {
        self.overflowing_shr(shift).0
    }

    /// Computes `self >>= shift` in a panic-free manner, masking off bits of `shift` which would cause the shift to
    /// exceed the type's width.
    pub fn wrapping_shr_assign(&mut self, shift: u32) {
        // self is zeroed in the case of an overflowing shift
        self.overflowing_shr_assign(shift);
    }

    /// Computes `self >> shift` in variable-time in a panic-free manner, masking off bits of `shift` which would cause
    /// the shift to exceed the type's width.
    pub fn wrapping_shr_vartime(&self, shift: u32) -> Self {
        let mut result = self.clone();
        result.wrapping_shr_assign_vartime(shift);
        result
    }

    /// Computes `self >>= shift` in variable-time in a panic-free manner, producing zero in the case of overflow.
    pub fn wrapping_shr_assign_vartime(&mut self, shift: u32) {
        self.as_mut_uint_ref().wrapping_shr_assign_vartime(shift);
    }

    /// Computes `self >> shift`.
    /// Returns `None` if `shift >= self.bits_precision()`.
    ///
    /// NOTE: this operation is variable time with respect to `shift` *ONLY*.
    ///
    /// When used with a fixed `shift`, this function is constant-time with respect to `self`.
    #[inline(always)]
    pub fn shr_vartime(&self, shift: u32) -> Option<Self> {
        // This could use `UintRef::wrapping_shr_assign_vartime`, but it is faster to operate
        // on a zero'ed clone and let the compiler reuse the memory allocation when possible.

        let nbits = self.bits_precision();
        if shift >= nbits {
            return None;
        }

        let mut dest = Self::zero_with_precision(nbits);
        let nlimbs = self.nlimbs();
        let shift_limbs = (shift / Limb::BITS) as usize;
        let rem = shift % Limb::BITS;
        let top = nlimbs - shift_limbs;

        for i in 0..top {
            dest.limbs[i] = self.limbs[i + shift_limbs];
        }

        if rem > 0 {
            dest.as_mut_uint_ref_range(0..top).shr_assign_limb(rem);
        }

        Some(dest)
    }

    /// Computes `self >> 1` in constant-time.
    pub(crate) fn shr1(&self) -> (Self, Limb) {
        let mut ret = self.clone();
        let carry = Limb::select(Limb::ZERO, Limb::ONE, ret.shr1_assign());
        (ret, carry)
    }

    /// Computes `self >>= 1` in-place in constant-time.
    pub(crate) fn shr1_assign(&mut self) -> ConstChoice {
        self.as_mut_uint_ref().shr1_assign()
    }

    /// Computes `self >>= shift` where `0 <= shift < Limb::BITS` in constant time.
    pub(crate) fn shr_assign_limb(&mut self, shift: u32) -> Limb {
        self.as_mut_uint_ref().shr_assign_limb(shift)
    }
}

macro_rules! impl_shr {
    ($($shift:ty),+) => {
        $(
            impl Shr<$shift> for BoxedUint {
                type Output = BoxedUint;

                #[inline]
                fn shr(self, shift: $shift) -> BoxedUint {
                    <&Self>::shr(&self, shift)
                }
            }

            impl Shr<$shift> for &BoxedUint {
                type Output = BoxedUint;

                #[inline]
                fn shr(self, shift: $shift) -> BoxedUint {
                    BoxedUint::shr(self, u32::try_from(shift).expect("invalid shift"))
                }
            }

            impl ShrAssign<$shift> for BoxedUint {
                fn shr_assign(&mut self, shift: $shift) {
                    BoxedUint::shr_assign(self, u32::try_from(shift).expect("invalid shift"))
                }
            }
        )+
    };
}

impl_shr!(i32, u32, usize);

impl WrappingShr for BoxedUint {
    fn wrapping_shr(&self, shift: u32) -> BoxedUint {
        self.wrapping_shr(shift)
    }
}

impl ShrVartime for BoxedUint {
    fn overflowing_shr_vartime(&self, shift: u32) -> CtOption<Self> {
        let (result, overflow) = self.overflowing_shr(shift);
        CtOption::new(result, !overflow)
    }
    fn wrapping_shr_vartime(&self, shift: u32) -> Self {
        self.wrapping_shr(shift)
    }
}

#[cfg(test)]
mod tests {
    use super::BoxedUint;

    #[test]
    fn shr1_assign() {
        let mut n = BoxedUint::from(0x3c442b21f19185fe433f0a65af902b8fu128);
        let n_shr1 = BoxedUint::from(0x1e221590f8c8c2ff219f8532d7c815c7u128);
        n.shr1_assign();
        assert_eq!(n, n_shr1);
    }

    #[test]
    fn shr() {
        let n = BoxedUint::from(0x80000000000000000u128);
        assert_eq!(BoxedUint::zero(), &n >> 68);
        assert_eq!(BoxedUint::one(), &n >> 67);
        assert_eq!(BoxedUint::from(2u8), &n >> 66);
        assert_eq!(BoxedUint::from(4u8), &n >> 65);
    }

    #[test]
    fn shr_vartime() {
        let n = BoxedUint::from(0x80000000000000000u128);
        assert_eq!(BoxedUint::zero(), n.shr_vartime(68).unwrap());
        assert_eq!(BoxedUint::one(), n.shr_vartime(67).unwrap());
        assert_eq!(BoxedUint::from(2u8), n.shr_vartime(66).unwrap());
        assert_eq!(BoxedUint::from(4u8), n.shr_vartime(65).unwrap());
    }
}
