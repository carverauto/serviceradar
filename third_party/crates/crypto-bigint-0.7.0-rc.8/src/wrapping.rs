//! Wrapping arithmetic.

use crate::{
    One, WrappingAdd, WrappingMul, WrappingNeg, WrappingShl, WrappingShr, WrappingSub, Zero,
};
use core::{
    fmt,
    ops::{Add, Mul, Neg, Shl, Shr, Sub},
};
use subtle::{Choice, ConditionallySelectable, ConstantTimeEq};

#[cfg(feature = "rand_core")]
use {crate::Random, rand_core::TryRngCore};

#[cfg(feature = "serde")]
use serdect::serde::{Deserialize, Deserializer, Serialize, Serializer};

/// Provides intentionally-wrapped arithmetic on `T`.
///
/// This is analogous to [`core::num::Wrapping`] but allows this crate to
/// define trait impls for this type.
#[derive(Copy, Clone, Debug, Default, Eq, PartialEq, PartialOrd, Ord)]
pub struct Wrapping<T>(pub T);

impl<T: WrappingAdd> Add<Self> for Wrapping<T> {
    type Output = Wrapping<T>;

    #[inline]
    fn add(self, rhs: Self) -> Self::Output {
        Wrapping(self.0.wrapping_add(&rhs.0))
    }
}

impl<T: WrappingAdd> Add<&Self> for Wrapping<T> {
    type Output = Wrapping<T>;

    #[inline]
    fn add(self, rhs: &Self) -> Self::Output {
        Wrapping(self.0.wrapping_add(&rhs.0))
    }
}

impl<T: WrappingAdd> Add<Wrapping<T>> for &Wrapping<T> {
    type Output = Wrapping<T>;

    #[inline]
    fn add(self, rhs: Wrapping<T>) -> Self::Output {
        Wrapping(self.0.wrapping_add(&rhs.0))
    }
}

impl<T: WrappingAdd> Add<&Wrapping<T>> for &Wrapping<T> {
    type Output = Wrapping<T>;

    #[inline]
    fn add(self, rhs: &Wrapping<T>) -> Self::Output {
        Wrapping(self.0.wrapping_add(&rhs.0))
    }
}

impl<T: WrappingSub> Sub<Self> for Wrapping<T> {
    type Output = Wrapping<T>;

    #[inline]
    fn sub(self, rhs: Self) -> Self::Output {
        Wrapping(self.0.wrapping_sub(&rhs.0))
    }
}

impl<T: WrappingSub> Sub<&Self> for Wrapping<T> {
    type Output = Wrapping<T>;

    #[inline]
    fn sub(self, rhs: &Self) -> Self::Output {
        Wrapping(self.0.wrapping_sub(&rhs.0))
    }
}

impl<T: WrappingSub> Sub<Wrapping<T>> for &Wrapping<T> {
    type Output = Wrapping<T>;

    #[inline]
    fn sub(self, rhs: Wrapping<T>) -> Self::Output {
        Wrapping(self.0.wrapping_sub(&rhs.0))
    }
}

impl<T: WrappingSub> Sub<&Wrapping<T>> for &Wrapping<T> {
    type Output = Wrapping<T>;

    #[inline]
    fn sub(self, rhs: &Wrapping<T>) -> Self::Output {
        Wrapping(self.0.wrapping_sub(&rhs.0))
    }
}

impl<T: WrappingMul> Mul<Self> for Wrapping<T> {
    type Output = Wrapping<T>;

    #[inline]
    fn mul(self, rhs: Self) -> Self::Output {
        Wrapping(self.0.wrapping_mul(&rhs.0))
    }
}

impl<T: WrappingMul> Mul<&Self> for Wrapping<T> {
    type Output = Wrapping<T>;

    #[inline]
    fn mul(self, rhs: &Self) -> Self::Output {
        Wrapping(self.0.wrapping_mul(&rhs.0))
    }
}

impl<T: WrappingMul> Mul<Wrapping<T>> for &Wrapping<T> {
    type Output = Wrapping<T>;

    #[inline]
    fn mul(self, rhs: Wrapping<T>) -> Self::Output {
        Wrapping(self.0.wrapping_mul(&rhs.0))
    }
}

impl<T: WrappingMul> Mul<&Wrapping<T>> for &Wrapping<T> {
    type Output = Wrapping<T>;

    #[inline]
    fn mul(self, rhs: &Wrapping<T>) -> Self::Output {
        Wrapping(self.0.wrapping_mul(&rhs.0))
    }
}

impl<T: WrappingNeg> Neg for Wrapping<T> {
    type Output = Wrapping<T>;

    #[inline]
    fn neg(self) -> Self::Output {
        Wrapping(self.0.wrapping_neg())
    }
}

impl<T: WrappingNeg> Neg for &Wrapping<T> {
    type Output = Wrapping<T>;

    #[inline]
    fn neg(self) -> Self::Output {
        Wrapping(self.0.wrapping_neg())
    }
}

impl<T: WrappingShl> Shl<u32> for Wrapping<T> {
    type Output = Wrapping<T>;

    #[inline]
    fn shl(self, rhs: u32) -> Self::Output {
        Wrapping(self.0.wrapping_shl(rhs))
    }
}

impl<T: WrappingShl> Shl<u32> for &Wrapping<T> {
    type Output = Wrapping<T>;

    #[inline]
    fn shl(self, rhs: u32) -> Self::Output {
        Wrapping(self.0.wrapping_shl(rhs))
    }
}

impl<T: WrappingShr> Shr<u32> for Wrapping<T> {
    type Output = Wrapping<T>;

    #[inline]
    fn shr(self, rhs: u32) -> Self::Output {
        Wrapping(self.0.wrapping_shr(rhs))
    }
}

impl<T: WrappingShr> Shr<u32> for &Wrapping<T> {
    type Output = Wrapping<T>;

    #[inline]
    fn shr(self, rhs: u32) -> Self::Output {
        Wrapping(self.0.wrapping_shr(rhs))
    }
}

impl<T: ConditionallySelectable> ConditionallySelectable for Wrapping<T> {
    #[inline]
    fn conditional_select(a: &Self, b: &Self, choice: Choice) -> Self {
        Wrapping(T::conditional_select(&a.0, &b.0, choice))
    }
}

impl<T: ConstantTimeEq> ConstantTimeEq for Wrapping<T> {
    #[inline]
    fn ct_eq(&self, other: &Self) -> Choice {
        self.0.ct_eq(&other.0)
    }
}

impl<T: Zero> Zero for Wrapping<T> {
    #[inline]
    fn zero() -> Self {
        Wrapping(T::zero())
    }
}

impl<T: One> One for Wrapping<T> {
    #[inline]
    fn one() -> Self {
        Wrapping(T::one())
    }
}

impl<T: num_traits::Zero + WrappingAdd> num_traits::Zero for Wrapping<T> {
    #[inline]
    fn zero() -> Self {
        Wrapping(T::zero())
    }

    #[inline]
    fn is_zero(&self) -> bool {
        self.0.is_zero()
    }
}

impl<T: num_traits::One + WrappingMul + PartialEq> num_traits::One for Wrapping<T> {
    #[inline]
    fn one() -> Self {
        Wrapping(T::one())
    }

    #[inline]
    fn is_one(&self) -> bool {
        self.0.is_one()
    }
}

impl<T: fmt::Display> fmt::Display for Wrapping<T> {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        self.0.fmt(f)
    }
}

impl<T: fmt::Binary> fmt::Binary for Wrapping<T> {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        self.0.fmt(f)
    }
}

impl<T: fmt::Octal> fmt::Octal for Wrapping<T> {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        self.0.fmt(f)
    }
}

impl<T: fmt::LowerHex> fmt::LowerHex for Wrapping<T> {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        self.0.fmt(f)
    }
}

impl<T: fmt::UpperHex> fmt::UpperHex for Wrapping<T> {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        self.0.fmt(f)
    }
}

#[cfg(feature = "rand_core")]
impl<T: Random> Random for Wrapping<T> {
    fn try_random<R: TryRngCore + ?Sized>(rng: &mut R) -> Result<Self, R::Error> {
        Ok(Wrapping(Random::try_random(rng)?))
    }
}

#[cfg(feature = "serde")]
impl<'de, T: Deserialize<'de>> Deserialize<'de> for Wrapping<T> {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: Deserializer<'de>,
    {
        Ok(Self(T::deserialize(deserializer)?))
    }
}

#[cfg(feature = "serde")]
impl<T: Serialize> Serialize for Wrapping<T> {
    fn serialize<S>(&self, serializer: S) -> Result<S::Ok, S::Error>
    where
        S: Serializer,
    {
        self.0.serialize(serializer)
    }
}

#[cfg(all(test, feature = "serde"))]
#[allow(clippy::unwrap_used)]
mod tests {
    use crate::{U64, Wrapping};

    #[test]
    fn serde() {
        const TEST: Wrapping<U64> = Wrapping(U64::from_u64(0x0011223344556677));

        let serialized = bincode::serde::encode_to_vec(TEST, bincode::config::standard()).unwrap();
        let deserialized: Wrapping<U64> =
            bincode::serde::decode_from_slice(&serialized, bincode::config::standard())
                .unwrap()
                .0;

        assert_eq!(TEST, deserialized);
    }
}
