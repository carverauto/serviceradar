//! Checked arithmetic.

use crate::{CheckedAdd, CheckedDiv, CheckedMul, CheckedSub};
use core::ops::{Add, Div, Mul, Sub};
use subtle::{Choice, ConditionallySelectable, ConstantTimeEq, CtOption};

#[cfg(feature = "serde")]
use serdect::serde::{Deserialize, Deserializer, Serialize, Serializer};

/// Provides intentionally-checked arithmetic on `T`.
///
/// Internally this leverages the [`CtOption`] type from the [`subtle`] crate
/// in order to handle overflows.
#[derive(Copy, Clone, Debug)]
pub struct Checked<T>(pub CtOption<T>);

impl<T> Checked<T> {
    /// Create a new checked arithmetic wrapper for the given value.
    pub fn new(val: T) -> Self {
        Self(CtOption::new(val, Choice::from(1)))
    }
}

impl<T> Add<Self> for Checked<T>
where
    T: CheckedAdd + ConditionallySelectable + Default,
{
    type Output = Checked<T>;

    #[inline]
    fn add(self, rhs: Self) -> Self::Output {
        Checked(
            self.0
                .and_then(|lhs| rhs.0.and_then(|rhs| lhs.checked_add(&rhs))),
        )
    }
}

impl<T> Add<&Self> for Checked<T>
where
    T: CheckedAdd + ConditionallySelectable + Default,
{
    type Output = Checked<T>;

    #[inline]
    fn add(self, rhs: &Self) -> Self::Output {
        Checked(
            self.0
                .and_then(|lhs| rhs.0.and_then(|rhs| lhs.checked_add(&rhs))),
        )
    }
}

impl<T> Add<Checked<T>> for &Checked<T>
where
    T: CheckedAdd + ConditionallySelectable + Default,
{
    type Output = Checked<T>;

    #[inline]
    fn add(self, rhs: Checked<T>) -> Self::Output {
        Checked(
            self.0
                .and_then(|lhs| rhs.0.and_then(|rhs| lhs.checked_add(&rhs))),
        )
    }
}

impl<T> Add<&Checked<T>> for &Checked<T>
where
    T: CheckedAdd + ConditionallySelectable + Default,
{
    type Output = Checked<T>;

    #[inline]
    fn add(self, rhs: &Checked<T>) -> Self::Output {
        Checked(
            self.0
                .and_then(|lhs| rhs.0.and_then(|rhs| lhs.checked_add(&rhs))),
        )
    }
}

impl<T> Sub<Self> for Checked<T>
where
    T: CheckedSub + ConditionallySelectable + Default,
{
    type Output = Checked<T>;

    #[inline]
    fn sub(self, rhs: Self) -> Self::Output {
        Checked(
            self.0
                .and_then(|lhs| rhs.0.and_then(|rhs| lhs.checked_sub(&rhs))),
        )
    }
}

impl<T> Sub<&Self> for Checked<T>
where
    T: CheckedSub + ConditionallySelectable + Default,
{
    type Output = Checked<T>;

    #[inline]
    fn sub(self, rhs: &Self) -> Self::Output {
        Checked(
            self.0
                .and_then(|lhs| rhs.0.and_then(|rhs| lhs.checked_sub(&rhs))),
        )
    }
}

impl<T> Sub<Checked<T>> for &Checked<T>
where
    T: CheckedSub + ConditionallySelectable + Default,
{
    type Output = Checked<T>;

    #[inline]
    fn sub(self, rhs: Checked<T>) -> Self::Output {
        Checked(
            self.0
                .and_then(|lhs| rhs.0.and_then(|rhs| lhs.checked_sub(&rhs))),
        )
    }
}

impl<T> Sub<&Checked<T>> for &Checked<T>
where
    T: CheckedSub + ConditionallySelectable + Default,
{
    type Output = Checked<T>;

    #[inline]
    fn sub(self, rhs: &Checked<T>) -> Self::Output {
        Checked(
            self.0
                .and_then(|lhs| rhs.0.and_then(|rhs| lhs.checked_sub(&rhs))),
        )
    }
}

impl<T> Mul<Self> for Checked<T>
where
    T: CheckedMul + ConditionallySelectable + Default,
{
    type Output = Checked<T>;

    #[inline]
    fn mul(self, rhs: Self) -> Self::Output {
        Checked(
            self.0
                .and_then(|lhs| rhs.0.and_then(|rhs| lhs.checked_mul(&rhs))),
        )
    }
}

impl<T> Mul<&Self> for Checked<T>
where
    T: CheckedMul + ConditionallySelectable + Default,
{
    type Output = Checked<T>;

    #[inline]
    fn mul(self, rhs: &Self) -> Self::Output {
        Checked(
            self.0
                .and_then(|lhs| rhs.0.and_then(|rhs| lhs.checked_mul(&rhs))),
        )
    }
}

impl<T> Mul<Checked<T>> for &Checked<T>
where
    T: CheckedMul + ConditionallySelectable + Default,
{
    type Output = Checked<T>;

    #[inline]
    fn mul(self, rhs: Checked<T>) -> Self::Output {
        Checked(
            self.0
                .and_then(|lhs| rhs.0.and_then(|rhs| lhs.checked_mul(&rhs))),
        )
    }
}

impl<T> Mul<&Checked<T>> for &Checked<T>
where
    T: CheckedMul + ConditionallySelectable + Default,
{
    type Output = Checked<T>;

    #[inline]
    fn mul(self, rhs: &Checked<T>) -> Self::Output {
        Checked(
            self.0
                .and_then(|lhs| rhs.0.and_then(|rhs| lhs.checked_mul(&rhs))),
        )
    }
}

impl<T> Div<Self> for Checked<T>
where
    T: CheckedDiv + ConditionallySelectable + Default,
{
    type Output = Checked<T>;

    #[inline]
    fn div(self, rhs: Self) -> Self::Output {
        Checked(
            self.0
                .and_then(|lhs| rhs.0.and_then(|rhs| lhs.checked_div(&rhs))),
        )
    }
}

impl<T> Div<&Self> for Checked<T>
where
    T: CheckedDiv + ConditionallySelectable + Default,
{
    type Output = Checked<T>;

    #[inline]
    fn div(self, rhs: &Self) -> Self::Output {
        Checked(
            self.0
                .and_then(|lhs| rhs.0.and_then(|rhs| lhs.checked_div(&rhs))),
        )
    }
}

impl<T> Div<Checked<T>> for &Checked<T>
where
    T: CheckedDiv + ConditionallySelectable + Default,
{
    type Output = Checked<T>;

    #[inline]
    fn div(self, rhs: Checked<T>) -> Self::Output {
        Checked(
            self.0
                .and_then(|lhs| rhs.0.and_then(|rhs| lhs.checked_div(&rhs))),
        )
    }
}

impl<T> Div<&Checked<T>> for &Checked<T>
where
    T: CheckedDiv + ConditionallySelectable + Default,
{
    type Output = Checked<T>;

    #[inline]
    fn div(self, rhs: &Checked<T>) -> Self::Output {
        Checked(
            self.0
                .and_then(|lhs| rhs.0.and_then(|rhs| lhs.checked_div(&rhs))),
        )
    }
}

impl<T: ConditionallySelectable> ConditionallySelectable for Checked<T> {
    #[inline]
    fn conditional_select(a: &Self, b: &Self, choice: Choice) -> Self {
        Self(CtOption::conditional_select(&a.0, &b.0, choice))
    }
}

impl<T: ConstantTimeEq> ConstantTimeEq for Checked<T> {
    #[inline]
    fn ct_eq(&self, rhs: &Self) -> Choice {
        self.0.ct_eq(&rhs.0)
    }
}

impl<T> Default for Checked<T>
where
    T: Default,
{
    fn default() -> Self {
        Self::new(T::default())
    }
}

impl<T> From<Checked<T>> for CtOption<T> {
    fn from(checked: Checked<T>) -> CtOption<T> {
        checked.0
    }
}

impl<T> From<CtOption<T>> for Checked<T> {
    fn from(ct_option: CtOption<T>) -> Checked<T> {
        Checked(ct_option)
    }
}

impl<T> From<Checked<T>> for Option<T> {
    fn from(checked: Checked<T>) -> Option<T> {
        checked.0.into()
    }
}

#[cfg(feature = "serde")]
impl<'de, T: Default + Deserialize<'de>> Deserialize<'de> for Checked<T> {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: Deserializer<'de>,
    {
        let value = Option::<T>::deserialize(deserializer)?;
        let choice = Choice::from(value.is_some() as u8);
        Ok(Self(CtOption::new(value.unwrap_or_default(), choice)))
    }
}

#[cfg(feature = "serde")]
impl<T: Copy + Serialize> Serialize for Checked<T> {
    fn serialize<S>(&self, serializer: S) -> Result<S::Ok, S::Error>
    where
        S: Serializer,
    {
        Option::<T>::from(self.0).serialize(serializer)
    }
}

#[cfg(all(test, feature = "serde"))]
#[allow(clippy::unwrap_used)]
mod tests {

    use crate::{Checked, U64};
    use subtle::{Choice, ConstantTimeEq, CtOption};

    #[test]
    fn serde() {
        let test = Checked::new(U64::from_u64(0x0011223344556677));

        let serialized = bincode::serde::encode_to_vec(test, bincode::config::standard()).unwrap();
        let deserialized: Checked<U64> =
            bincode::serde::decode_from_slice(&serialized, bincode::config::standard())
                .unwrap()
                .0;

        assert!(bool::from(test.ct_eq(&deserialized)));

        let test = Checked::new(U64::ZERO) - Checked::new(U64::ONE);
        assert!(bool::from(
            test.ct_eq(&Checked(CtOption::new(U64::ZERO, Choice::from(0))))
        ));

        let serialized = bincode::serde::encode_to_vec(test, bincode::config::standard()).unwrap();
        let deserialized: Checked<U64> =
            bincode::serde::decode_from_slice(&serialized, bincode::config::standard())
                .unwrap()
                .0;

        assert!(bool::from(test.ct_eq(&deserialized)));
    }
}
