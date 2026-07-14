//! [`BoxedUint`] subtraction operations.

use crate::{BoxedUint, CheckedSub, Limb, U64, U128, Uint, Wrapping, WrappingSub, Zero};
use core::ops::{Sub, SubAssign};
use subtle::{Choice, ConditionallySelectable, CtOption};

impl BoxedUint {
    /// Computes `self - (rhs + borrow)`, returning the result along with the new borrow.
    #[deprecated(since = "0.7.0", note = "please use `borrowing_sub` instead")]
    pub fn sbb(&self, rhs: &Self, borrow: Limb) -> (Self, Limb) {
        self.borrowing_sub(rhs, borrow)
    }

    /// Computes `self - (rhs + borrow)`, returning the result along with the new borrow.
    #[inline(always)]
    pub fn borrowing_sub(&self, rhs: &Self, borrow: Limb) -> (Self, Limb) {
        Self::fold_limbs(self, rhs, borrow, |a, b, c| a.borrowing_sub(b, c))
    }

    /// Computes `a - (b + borrow)` in-place, returning the new borrow.
    ///
    /// Panics if `rhs` has a larger precision than `self`.
    #[deprecated(since = "0.7.0", note = "please use `borrowing_sub_assign` instead")]
    pub fn sbb_assign(&mut self, rhs: impl AsRef<[Limb]>, borrow: Limb) -> Limb {
        self.borrowing_sub_assign(rhs, borrow)
    }

    /// Computes `a - (b + borrow)` in-place, returning the new borrow.
    ///
    /// Panics if `rhs` has a larger precision than `self`.
    #[inline(always)]
    pub fn borrowing_sub_assign(&mut self, rhs: impl AsRef<[Limb]>, mut borrow: Limb) -> Limb {
        debug_assert!(self.bits_precision() >= (rhs.as_ref().len() as u32 * Limb::BITS));

        for i in 0..self.nlimbs() {
            let (limb, b) =
                self.limbs[i].borrowing_sub(*rhs.as_ref().get(i).unwrap_or(&Limb::ZERO), borrow);
            self.limbs[i] = limb;
            borrow = b;
        }

        borrow
    }

    /// Perform wrapping subtraction, discarding overflow.
    pub fn wrapping_sub(&self, rhs: &Self) -> Self {
        self.borrowing_sub(rhs, Limb::ZERO).0
    }

    /// Perform in-place wrapping subtraction, returning the truthy value as the second element of
    /// the tuple if an underflow has occurred.
    pub(crate) fn conditional_borrowing_sub_assign(
        &mut self,
        rhs: &Self,
        choice: Choice,
    ) -> Choice {
        debug_assert!(self.bits_precision() <= rhs.bits_precision());
        let mask = Limb::conditional_select(&Limb::ZERO, &Limb::MAX, choice);
        let mut borrow = Limb::ZERO;

        for i in 0..self.nlimbs() {
            let masked_rhs = *rhs.limbs.get(i).unwrap_or(&Limb::ZERO) & mask;
            let (limb, b) = self.limbs[i].borrowing_sub(masked_rhs, borrow);
            self.limbs[i] = limb;
            borrow = b;
        }

        Choice::from((borrow.0 & 1) as u8)
    }
}

impl CheckedSub for BoxedUint {
    fn checked_sub(&self, rhs: &Self) -> CtOption<Self> {
        let (result, carry) = self.borrowing_sub(rhs, Limb::ZERO);
        CtOption::new(result, carry.is_zero())
    }
}

impl Sub for BoxedUint {
    type Output = Self;

    fn sub(self, rhs: Self) -> Self {
        self.sub(&rhs)
    }
}

impl Sub<&BoxedUint> for BoxedUint {
    type Output = Self;

    fn sub(self, rhs: &Self) -> Self {
        Sub::sub(&self, rhs)
    }
}

impl Sub<BoxedUint> for &BoxedUint {
    type Output = BoxedUint;

    fn sub(self, rhs: BoxedUint) -> BoxedUint {
        Sub::sub(self, &rhs)
    }
}

impl Sub<&BoxedUint> for &BoxedUint {
    type Output = BoxedUint;

    fn sub(self, rhs: &BoxedUint) -> BoxedUint {
        self.checked_sub(rhs)
            .expect("attempted to subtract with underflow")
    }
}

impl SubAssign<BoxedUint> for BoxedUint {
    fn sub_assign(&mut self, rhs: BoxedUint) {
        self.sub_assign(&rhs)
    }
}

impl SubAssign<&BoxedUint> for BoxedUint {
    fn sub_assign(&mut self, rhs: &BoxedUint) {
        let carry = self.borrowing_sub_assign(rhs, Limb::ZERO);
        assert_eq!(
            carry.is_zero().unwrap_u8(),
            1,
            "attempted to subtract with underflow"
        );
    }
}

impl<const LIMBS: usize> Sub<Uint<LIMBS>> for BoxedUint {
    type Output = BoxedUint;

    fn sub(self, rhs: Uint<LIMBS>) -> BoxedUint {
        self.sub(&rhs)
    }
}

impl<const LIMBS: usize> Sub<&Uint<LIMBS>> for BoxedUint {
    type Output = BoxedUint;

    fn sub(mut self, rhs: &Uint<LIMBS>) -> BoxedUint {
        self -= rhs;
        self
    }
}

impl<const LIMBS: usize> Sub<Uint<LIMBS>> for &BoxedUint {
    type Output = BoxedUint;

    fn sub(self, rhs: Uint<LIMBS>) -> BoxedUint {
        self.clone().sub(rhs)
    }
}

impl<const LIMBS: usize> Sub<&Uint<LIMBS>> for &BoxedUint {
    type Output = BoxedUint;

    fn sub(self, rhs: &Uint<LIMBS>) -> BoxedUint {
        self.clone().sub(rhs)
    }
}

impl<const LIMBS: usize> SubAssign<Uint<LIMBS>> for BoxedUint {
    fn sub_assign(&mut self, rhs: Uint<LIMBS>) {
        *self -= &rhs;
    }
}

impl<const LIMBS: usize> SubAssign<&Uint<LIMBS>> for BoxedUint {
    fn sub_assign(&mut self, rhs: &Uint<LIMBS>) {
        let carry = self.borrowing_sub_assign(rhs.as_limbs(), Limb::ZERO);
        assert_eq!(carry.0, 0, "attempted to sub with overflow");
    }
}

impl SubAssign<Wrapping<BoxedUint>> for Wrapping<BoxedUint> {
    fn sub_assign(&mut self, other: Wrapping<BoxedUint>) {
        self.0.borrowing_sub_assign(&other.0, Limb::ZERO);
    }
}

impl SubAssign<&Wrapping<BoxedUint>> for Wrapping<BoxedUint> {
    fn sub_assign(&mut self, other: &Wrapping<BoxedUint>) {
        self.0.borrowing_sub_assign(&other.0, Limb::ZERO);
    }
}

impl WrappingSub for BoxedUint {
    fn wrapping_sub(&self, v: &Self) -> Self {
        self.wrapping_sub(v)
    }
}

macro_rules! impl_sub_primitive {
    ($($primitive:ty),+) => {
        $(
            impl Sub<$primitive> for BoxedUint {
                type Output = BoxedUint;

                #[inline]
                fn sub(self, rhs: $primitive) -> BoxedUint {
                     self - U64::from(rhs)
                }
            }

            impl Sub<$primitive> for &BoxedUint {
                type Output = BoxedUint;

                #[inline]
                fn sub(self, rhs: $primitive) -> BoxedUint {
                     self - U64::from(rhs)
                }
            }

            impl SubAssign<$primitive> for BoxedUint {
                fn sub_assign(&mut self, rhs: $primitive) {
                    *self -= U64::from(rhs);
                }
            }
        )+
    };
}

impl_sub_primitive!(u8, u16, u32, u64);

impl Sub<u128> for BoxedUint {
    type Output = BoxedUint;

    #[inline]
    fn sub(self, rhs: u128) -> BoxedUint {
        self - U128::from(rhs)
    }
}

impl Sub<u128> for &BoxedUint {
    type Output = BoxedUint;

    #[inline]
    fn sub(self, rhs: u128) -> BoxedUint {
        self - U128::from(rhs)
    }
}

impl SubAssign<u128> for BoxedUint {
    fn sub_assign(&mut self, rhs: u128) {
        *self -= U128::from(rhs);
    }
}

#[cfg(test)]
#[allow(clippy::unwrap_used)]
mod tests {
    use super::{BoxedUint, CheckedSub, Limb};
    use crate::Resize;

    #[test]
    fn borrowing_sub_no_borrow() {
        let (res, carry) = BoxedUint::one().borrowing_sub(&BoxedUint::one(), Limb::ZERO);
        assert_eq!(res, BoxedUint::zero());
        assert_eq!(carry, Limb::ZERO);

        let (res, carry) = BoxedUint::one().borrowing_sub(&BoxedUint::zero(), Limb::ZERO);
        assert_eq!(res, BoxedUint::one());
        assert_eq!(carry, Limb::ZERO);
    }

    #[test]
    fn borrowing_sub_with_borrow() {
        let (res, borrow) = BoxedUint::zero().borrowing_sub(&BoxedUint::one(), Limb::ZERO);
        assert_eq!(res, BoxedUint::max(Limb::BITS));
        assert_eq!(borrow, Limb::MAX);
    }

    #[test]
    fn sub_with_u32_rhs() {
        let a = BoxedUint::from(0x100000000u64);
        let b = a - u32::MAX;
        assert_eq!(b, BoxedUint::one());
    }

    #[test]
    fn checked_sub_ok() {
        let result = BoxedUint::one().checked_sub(&BoxedUint::one());
        assert_eq!(result.unwrap(), BoxedUint::zero());
    }

    #[test]
    fn checked_sub_overflow() {
        let result = BoxedUint::zero().checked_sub(&BoxedUint::one());
        assert!(!bool::from(result.is_some()));
    }

    #[test]
    fn sub_assign() {
        let mut h = BoxedUint::one().resize(1024);
        h -= BoxedUint::one();
    }
}
