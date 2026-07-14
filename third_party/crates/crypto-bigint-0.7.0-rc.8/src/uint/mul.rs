//! [`Uint`] multiplication operations.

use core::ops::{Mul, MulAssign};

use subtle::CtOption;

use crate::{
    Checked, CheckedMul, Concat, ConcatMixed, ConcatenatingMul, ConstCtOption, Uint, Wrapping,
    WrappingMul, Zero,
};

pub(crate) mod karatsuba;
pub(crate) mod schoolbook;

impl<const LIMBS: usize> Uint<LIMBS> {
    /// Multiply `self` by `rhs`, returning a concatenated "wide" result.
    pub const fn concatenating_mul<const RHS_LIMBS: usize, const WIDE_LIMBS: usize>(
        &self,
        rhs: &Uint<RHS_LIMBS>,
    ) -> Uint<WIDE_LIMBS>
    where
        Self: ConcatMixed<Uint<RHS_LIMBS>, MixedOutput = Uint<WIDE_LIMBS>>,
    {
        let (lo, hi) = self.widening_mul(rhs);
        Uint::concat_mixed(&lo, &hi)
    }

    /// Compute "wide" multiplication as a 2-tuple containing the `(lo, hi)` components of the product, whose sizes
    /// correspond to the sizes of the operands.
    #[deprecated(since = "0.7.0", note = "please use `widening_mul` instead")]
    pub const fn split_mul<const RHS_LIMBS: usize>(
        &self,
        rhs: &Uint<RHS_LIMBS>,
    ) -> (Self, Uint<RHS_LIMBS>) {
        self.widening_mul(rhs)
    }

    /// Compute "wide" multiplication as a 2-tuple containing the `(lo, hi)` components of the product, whose sizes
    /// correspond to the sizes of the operands.
    #[inline(always)]
    pub const fn widening_mul<const RHS_LIMBS: usize>(
        &self,
        rhs: &Uint<RHS_LIMBS>,
    ) -> (Self, Uint<RHS_LIMBS>) {
        karatsuba::widening_mul_fixed(self.as_uint_ref(), rhs.as_uint_ref())
    }

    /// Perform wrapping multiplication, discarding overflow.
    // #[inline(always)]
    pub const fn wrapping_mul<const RHS_LIMBS: usize>(&self, rhs: &Uint<RHS_LIMBS>) -> Self {
        karatsuba::wrapping_mul_fixed::<LIMBS>(self.as_uint_ref(), rhs.as_uint_ref()).0
    }

    /// Perform saturating multiplication, returning `MAX` on overflow.
    pub const fn saturating_mul<const RHS_LIMBS: usize>(&self, rhs: &Uint<RHS_LIMBS>) -> Self {
        let (res, overflow) = self.widening_mul(rhs);
        Self::select(&res, &Self::MAX, overflow.is_nonzero())
    }
}

/// Squaring operations
impl<const LIMBS: usize> Uint<LIMBS> {
    /// Square self, returning a "wide" result in two parts as (lo, hi).
    #[inline(always)]
    pub const fn square_wide(&self) -> (Self, Self) {
        karatsuba::widening_square_fixed(self.as_uint_ref())
    }

    /// Square self, returning a concatenated "wide" result.
    pub const fn widening_square<const WIDE_LIMBS: usize>(&self) -> Uint<WIDE_LIMBS>
    where
        Self: ConcatMixed<Uint<LIMBS>, MixedOutput = Uint<WIDE_LIMBS>>,
    {
        let (lo, hi) = self.square_wide();
        Uint::concat_mixed(&lo, &hi)
    }

    /// Square self, checking that the result fits in the original [`Uint`] size.
    pub const fn checked_square(&self) -> ConstCtOption<Uint<LIMBS>> {
        let (lo, hi) = self.square_wide();
        ConstCtOption::new(lo, Self::eq(&hi, &Self::ZERO))
    }

    /// Perform wrapping square, discarding overflow.
    // #[inline(always)]
    pub const fn wrapping_square(&self) -> Uint<LIMBS> {
        karatsuba::wrapping_square_fixed(self.as_uint_ref())
    }

    /// Perform saturating squaring, returning `MAX` on overflow.
    pub const fn saturating_square(&self) -> Self {
        let (res, overflow) = self.square_wide();
        Self::select(&res, &Self::MAX, overflow.is_nonzero())
    }
}

impl<const LIMBS: usize, const WIDE_LIMBS: usize> Uint<LIMBS>
where
    Self: Concat<Output = Uint<WIDE_LIMBS>>,
{
    /// Square self, returning a concatenated "wide" result.
    pub const fn square(&self) -> Uint<WIDE_LIMBS> {
        let (lo, hi) = self.square_wide();
        lo.concat(&hi)
    }
}

impl<const LIMBS: usize, const RHS_LIMBS: usize> CheckedMul<Uint<RHS_LIMBS>> for Uint<LIMBS> {
    #[inline]
    fn checked_mul(&self, rhs: &Uint<RHS_LIMBS>) -> CtOption<Self> {
        let (lo, hi) = self.widening_mul(rhs);
        CtOption::new(lo, hi.is_zero())
    }
}

impl<const LIMBS: usize, const RHS_LIMBS: usize> Mul<Uint<RHS_LIMBS>> for Uint<LIMBS> {
    type Output = Uint<LIMBS>;

    fn mul(self, rhs: Uint<RHS_LIMBS>) -> Self {
        self.mul(&rhs)
    }
}

impl<const LIMBS: usize, const RHS_LIMBS: usize> Mul<&Uint<RHS_LIMBS>> for Uint<LIMBS> {
    type Output = Uint<LIMBS>;

    fn mul(self, rhs: &Uint<RHS_LIMBS>) -> Self {
        (&self).mul(rhs)
    }
}

impl<const LIMBS: usize, const RHS_LIMBS: usize> Mul<Uint<RHS_LIMBS>> for &Uint<LIMBS> {
    type Output = Uint<LIMBS>;

    fn mul(self, rhs: Uint<RHS_LIMBS>) -> Self::Output {
        self.mul(&rhs)
    }
}

impl<const LIMBS: usize, const RHS_LIMBS: usize> Mul<&Uint<RHS_LIMBS>> for &Uint<LIMBS> {
    type Output = Uint<LIMBS>;

    fn mul(self, rhs: &Uint<RHS_LIMBS>) -> Self::Output {
        self.checked_mul(rhs)
            .expect("attempted to multiply with overflow")
    }
}

impl<const LIMBS: usize, const RHS_LIMBS: usize> MulAssign<Uint<RHS_LIMBS>> for Uint<LIMBS> {
    fn mul_assign(&mut self, rhs: Uint<RHS_LIMBS>) {
        *self = self.mul(&rhs)
    }
}

impl<const LIMBS: usize, const RHS_LIMBS: usize> MulAssign<&Uint<RHS_LIMBS>> for Uint<LIMBS> {
    fn mul_assign(&mut self, rhs: &Uint<RHS_LIMBS>) {
        *self = self.mul(rhs)
    }
}

impl<const LIMBS: usize> MulAssign<Wrapping<Uint<LIMBS>>> for Wrapping<Uint<LIMBS>> {
    fn mul_assign(&mut self, other: Wrapping<Uint<LIMBS>>) {
        *self = *self * other;
    }
}

impl<const LIMBS: usize> MulAssign<&Wrapping<Uint<LIMBS>>> for Wrapping<Uint<LIMBS>> {
    fn mul_assign(&mut self, other: &Wrapping<Uint<LIMBS>>) {
        *self = *self * other;
    }
}

impl<const LIMBS: usize> MulAssign<Checked<Uint<LIMBS>>> for Checked<Uint<LIMBS>> {
    fn mul_assign(&mut self, other: Checked<Uint<LIMBS>>) {
        *self = *self * other;
    }
}

impl<const LIMBS: usize> MulAssign<&Checked<Uint<LIMBS>>> for Checked<Uint<LIMBS>> {
    fn mul_assign(&mut self, other: &Checked<Uint<LIMBS>>) {
        *self = *self * other;
    }
}

impl<const LIMBS: usize, const RHS_LIMBS: usize, const WIDE_LIMBS: usize>
    ConcatenatingMul<Uint<RHS_LIMBS>> for Uint<LIMBS>
where
    Self: ConcatMixed<Uint<RHS_LIMBS>, MixedOutput = Uint<WIDE_LIMBS>>,
{
    type Output = <Self as ConcatMixed<Uint<RHS_LIMBS>>>::MixedOutput;

    #[inline]
    fn concatenating_mul(&self, rhs: Uint<RHS_LIMBS>) -> Self::Output {
        self.concatenating_mul(&rhs)
    }
}

impl<const LIMBS: usize, const RHS_LIMBS: usize, const WIDE_LIMBS: usize>
    ConcatenatingMul<&Uint<RHS_LIMBS>> for Uint<LIMBS>
where
    Self: ConcatMixed<Uint<RHS_LIMBS>, MixedOutput = Uint<WIDE_LIMBS>>,
{
    type Output = <Self as ConcatMixed<Uint<RHS_LIMBS>>>::MixedOutput;

    #[inline]
    fn concatenating_mul(&self, rhs: &Uint<RHS_LIMBS>) -> Self::Output {
        self.concatenating_mul(rhs)
    }
}

impl<const LIMBS: usize> WrappingMul for Uint<LIMBS> {
    fn wrapping_mul(&self, v: &Self) -> Self {
        self.wrapping_mul(v)
    }
}

#[cfg(test)]
mod tests {
    use crate::{CheckedMul, ConstChoice, U64, U128, U192, U256, Zero};

    #[test]
    fn widening_mul_zero_and_one() {
        assert_eq!(U64::ZERO.widening_mul(&U64::ZERO), (U64::ZERO, U64::ZERO));
        assert_eq!(U64::ZERO.widening_mul(&U64::ONE), (U64::ZERO, U64::ZERO));
        assert_eq!(U64::ONE.widening_mul(&U64::ZERO), (U64::ZERO, U64::ZERO));
        assert_eq!(U64::ONE.widening_mul(&U64::ONE), (U64::ONE, U64::ZERO));
    }

    #[test]
    fn widening_mul_lo_only() {
        let primes: &[u32] = &[3, 5, 17, 257, 65537];

        for &a_int in primes {
            for &b_int in primes {
                let (lo, hi) = U64::from_u32(a_int).widening_mul(&U64::from_u32(b_int));
                let expected = U64::from_u64(a_int as u64 * b_int as u64);
                assert_eq!(lo, expected);
                assert!(bool::from(hi.is_zero()));
                assert_eq!(lo, U64::from_u32(a_int).wrapping_mul(&U64::from_u32(b_int)));
            }
        }
    }

    #[test]
    fn mul_concat_even() {
        assert_eq!(U64::ZERO.concatenating_mul(&U64::MAX), U128::ZERO);
        assert_eq!(U64::MAX.concatenating_mul(&U64::ZERO), U128::ZERO);
        assert_eq!(
            U64::MAX.concatenating_mul(&U64::MAX),
            U128::from_u128(0xfffffffffffffffe_0000000000000001)
        );
        assert_eq!(
            U64::ONE.concatenating_mul(&U64::MAX),
            U128::from_u128(0x0000000000000000_ffffffffffffffff)
        );
    }

    #[test]
    fn mul_concat_mixed() {
        let a = U64::from_u64(0x0011223344556677);
        let b = U128::from_u128(0x8899aabbccddeeff_8899aabbccddeeff);
        let expected = U192::from(&b).saturating_mul(&a);
        assert_eq!(a.concatenating_mul(&b), expected);
        assert_eq!(b.concatenating_mul(&a), expected);
    }

    #[test]
    fn wrapping_mul_even() {
        assert_eq!(U64::ZERO.wrapping_mul(&U64::MAX), U64::ZERO);
        assert_eq!(U64::MAX.wrapping_mul(&U64::ZERO), U64::ZERO);
        assert_eq!(U64::MAX.wrapping_mul(&U64::MAX), U64::ONE);
        assert_eq!(U64::ONE.wrapping_mul(&U64::MAX), U64::MAX);
    }

    #[test]
    fn wrapping_mul_mixed() {
        let a = U64::from_u64(0x0011223344556677);
        let b = U128::from_u128(0x8899aabbccddeeff_8899aabbccddeeff);
        let expected = U192::from(&b).saturating_mul(&a);
        assert_eq!(b.wrapping_mul(&a), expected.resize());
        assert_eq!(a.wrapping_mul(&b), expected.resize());
    }

    #[test]
    fn checked_mul_ok() {
        let n = U64::from_u32(0xffff_ffff);
        assert_eq!(
            n.checked_mul(&n).unwrap(),
            U64::from_u64(0xffff_fffe_0000_0001)
        );
    }

    #[test]
    fn checked_mul_overflow() {
        let n = U64::from_u64(0xffff_ffff_ffff_ffff);
        assert!(bool::from(n.checked_mul(&n).is_none()));
    }

    #[test]
    fn saturating_mul_no_overflow() {
        let n = U64::from_u8(8);
        assert_eq!(n.saturating_mul(&n), U64::from_u8(64));
    }

    #[test]
    fn saturating_mul_overflow() {
        let a = U64::from(0xffff_ffff_ffff_ffffu64);
        let b = U64::from(2u8);
        assert_eq!(a.saturating_mul(&b), U64::MAX);
    }

    #[test]
    fn square() {
        let n = U64::from_u64(0xffff_ffff_ffff_ffff);
        let (lo, hi) = n.square().split();
        assert_eq!(lo, U64::from_u64(1));
        assert_eq!(hi, U64::from_u64(0xffff_ffff_ffff_fffe));
    }

    #[test]
    fn square_larger() {
        let n = U256::MAX;
        let (lo, hi) = n.square().split();
        assert_eq!(lo, U256::ONE);
        assert_eq!(hi, U256::MAX.wrapping_sub(&U256::ONE));
    }

    #[test]
    fn checked_square() {
        let n = U256::from_u64(u64::MAX).wrapping_add(&U256::ONE);
        let n2 = n.checked_square();
        assert_eq!(n2.is_some(), ConstChoice::TRUE);
        let n4 = n2.unwrap().checked_square();
        assert_eq!(n4.is_none(), ConstChoice::TRUE);
    }

    #[test]
    fn wrapping_square() {
        let n = U256::from_u64(u64::MAX).wrapping_add(&U256::ONE);
        let n2 = n.wrapping_square();
        assert_eq!(n2, U256::from_u128(u128::MAX).wrapping_add(&U256::ONE));
        let n4 = n2.wrapping_square();
        assert_eq!(n4, U256::ZERO);
    }

    #[test]
    fn saturating_square() {
        let n = U256::from_u64(u64::MAX).wrapping_add(&U256::ONE);
        let n2 = n.saturating_square();
        assert_eq!(n2, U256::from_u128(u128::MAX).wrapping_add(&U256::ONE));
        let n4 = n2.saturating_square();
        assert_eq!(n4, U256::MAX);
    }

    #[cfg(feature = "rand_core")]
    #[test]
    fn mul_cmp() {
        use crate::{Random, U4096};
        use rand_core::SeedableRng;
        let mut rng = rand_chacha::ChaCha8Rng::seed_from_u64(1);

        for _ in 0..50 {
            let a = U4096::random(&mut rng);
            assert_eq!(a.widening_mul(&a), a.square_wide(), "a = {a}");
            assert_eq!(a.wrapping_mul(&a), a.wrapping_square(), "a = {a}");
        }
    }
}
