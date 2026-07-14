//! Wrapper type for non-zero integers.

use crate::{Bounded, ConstChoice, Int, Integer, Limb, NonZero, One, Uint, UintRef};
use core::{
    cmp::Ordering,
    fmt,
    ops::{Deref, Mul},
};
use num_traits::ConstOne;
use subtle::{Choice, ConditionallySelectable, ConstantTimeEq, CtOption};

#[cfg(feature = "alloc")]
use crate::{BoxedUint, Resize};

#[cfg(feature = "rand_core")]
use crate::{Random, rand_core::TryRngCore};

#[cfg(all(feature = "alloc", feature = "rand_core"))]
use crate::RandomBits;

#[cfg(feature = "serde")]
use crate::Zero;
#[cfg(feature = "serde")]
use serdect::serde::{
    Deserialize, Deserializer, Serialize, Serializer,
    de::{Error, Unexpected},
};

/// Non-zero unsigned integer.
pub type OddUint<const LIMBS: usize> = Odd<Uint<LIMBS>>;

/// Non-zero signed integer.
pub type OddInt<const LIMBS: usize> = Odd<Int<LIMBS>>;

/// Non-zero boxed unsigned integer.
#[cfg(feature = "alloc")]
pub type OddBoxedUint = Odd<BoxedUint>;

/// Wrapper type for odd integers.
///
/// These are frequently used in cryptography, e.g. as a modulus.
#[derive(Clone, Copy, Debug, Default, Eq, Hash, PartialEq, PartialOrd, Ord)]
#[repr(transparent)]
pub struct Odd<T: ?Sized>(pub(crate) T);

impl<T> Odd<T> {
    /// Create a new odd integer.
    pub fn new(n: T) -> CtOption<Self>
    where
        T: Integer,
    {
        let is_odd = n.is_odd();
        CtOption::new(Self(n), is_odd)
    }

    /// Returns the inner value.
    pub fn get(self) -> T {
        self.0
    }
}

impl<T: ?Sized> Odd<T> {
    /// Provides access to the contents of [`Odd`] in a `const` context.
    pub const fn as_ref(&self) -> &T {
        &self.0
    }

    /// All odd integers are definitionally non-zero, so we can also obtain a reference to [`NonZero`].
    pub const fn as_nz_ref(&self) -> &NonZero<T> {
        #[allow(trivial_casts, unsafe_code)]
        unsafe {
            &*(&self.0 as *const T as *const NonZero<T>)
        }
    }
}

impl<T> Odd<T>
where
    T: Bounded + ?Sized,
{
    /// Total size of the represented integer in bits.
    pub const BITS: u32 = T::BITS;

    /// Total size of the represented integer in bytes.
    pub const BYTES: usize = T::BYTES;
}

impl<const LIMBS: usize> Odd<Uint<LIMBS>> {
    /// Create a new [`Odd<Uint<LIMBS>>`] from the provided big endian hex string.
    ///
    /// Panics if the hex is malformed or not zero-padded accordingly for the size, or if the value is even.
    pub const fn from_be_hex(hex: &str) -> Self {
        let uint = Uint::<LIMBS>::from_be_hex(hex);
        assert!(uint.is_odd().is_true_vartime(), "number must be odd");
        Odd(uint)
    }

    /// Create a new [`Odd<Uint<LIMBS>>`] from the provided little endian hex string.
    ///
    /// Panics if the hex is malformed or not zero-padded accordingly for the size, or if the value is even.
    pub const fn from_le_hex(hex: &str) -> Self {
        let uint = Uint::<LIMBS>::from_be_hex(hex);
        assert!(uint.is_odd().is_true_vartime(), "number must be odd");
        Odd(uint)
    }

    /// Borrow the limbs of this [`Odd<Uint>`] as a [`Odd<UintRef>`].
    pub(crate) const fn as_uint_ref(&self) -> &Odd<UintRef> {
        // SAFETY: `Odd` is a `repr(transparent)` newtype.
        #[allow(trivial_casts, unsafe_code)]
        unsafe {
            &*(self.0.as_uint_ref() as *const UintRef as *const Odd<UintRef>)
        }
    }

    /// Construct an [`Odd<Uint<T>>`] from the unsigned integer value,
    /// truncating the upper bits if the value is too large to be
    /// represented.
    pub const fn resize<const T: usize>(&self) -> Odd<Uint<T>> {
        Odd(self.0.resize())
    }
}

impl<const LIMBS: usize> Odd<Int<LIMBS>> {
    /// The sign and magnitude of this [`Odd<Int<{LIMBS}>>`].
    pub const fn abs_sign(&self) -> (Odd<Uint<LIMBS>>, ConstChoice) {
        // Absolute value of an odd value is odd
        let (abs, sgn) = Int::abs_sign(self.as_ref());
        (Odd(abs), sgn)
    }

    /// The magnitude of this [`Odd<Int<{LIMBS}>>`].
    pub const fn abs(&self) -> Odd<Uint<LIMBS>> {
        self.abs_sign().0
    }
}

impl<T: ?Sized> AsRef<T> for Odd<T> {
    fn as_ref(&self) -> &T {
        &self.0
    }
}

impl<T> AsRef<[Limb]> for Odd<T>
where
    T: AsRef<[Limb]>,
{
    fn as_ref(&self) -> &[Limb] {
        self.0.as_ref()
    }
}

impl<T: ?Sized> AsRef<NonZero<T>> for Odd<T> {
    fn as_ref(&self) -> &NonZero<T> {
        self.as_nz_ref()
    }
}

impl<T> ConditionallySelectable for Odd<T>
where
    T: ConditionallySelectable,
{
    fn conditional_select(a: &Self, b: &Self, choice: Choice) -> Self {
        Self(T::conditional_select(&a.0, &b.0, choice))
    }
}

impl<T> ConstantTimeEq for Odd<T>
where
    T: ConstantTimeEq + ?Sized,
{
    fn ct_eq(&self, other: &Self) -> Choice {
        self.0.ct_eq(&other.0)
    }
}

impl<T: ?Sized> Deref for Odd<T> {
    type Target = T;

    fn deref(&self) -> &T {
        &self.0
    }
}

impl<T> ConstOne for Odd<T>
where
    T: ConstOne + One,
{
    const ONE: Self = Self(T::ONE);
}

impl<T> One for Odd<T>
where
    T: One,
{
    #[inline]
    fn one() -> Self {
        Self(T::one())
    }
}

impl<T> num_traits::One for Odd<T>
where
    T: One + Mul<T, Output = T>,
{
    #[inline]
    fn one() -> Self {
        Self(T::one())
    }

    fn is_one(&self) -> bool {
        self.0.is_one().into()
    }
}

/// Any odd integer multiplied by another odd integer is definitionally odd.
impl<T> Mul<Self> for Odd<T>
where
    T: Mul<T, Output = T>,
{
    type Output = Self;

    fn mul(self, rhs: Self) -> Self {
        Self(self.0 * rhs.0)
    }
}

impl<const LIMBS: usize> PartialEq<Odd<Uint<LIMBS>>> for Uint<LIMBS> {
    fn eq(&self, other: &Odd<Uint<LIMBS>>) -> bool {
        self.eq(&other.0)
    }
}

impl<const LIMBS: usize> PartialOrd<Odd<Uint<LIMBS>>> for Uint<LIMBS> {
    fn partial_cmp(&self, other: &Odd<Uint<LIMBS>>) -> Option<Ordering> {
        Some(self.cmp(&other.0))
    }
}

impl Odd<UintRef> {
    /// Construct an [`Odd<Uint<T>>`] from the unsigned integer value,
    /// truncating the upper bits if the value is too large to be
    /// represented.
    pub const fn to_uint_resize<const T: usize>(&self) -> Odd<Uint<T>> {
        Odd(self.0.to_uint_resize())
    }
}

#[cfg(feature = "alloc")]
impl Odd<BoxedUint> {
    /// Borrow the limbs of this [`Odd<BoxedUint>`] as a [`Odd<UintRef>`].
    pub(crate) const fn as_uint_ref(&self) -> &Odd<UintRef> {
        // SAFETY: `Odd` is a `repr(transparent)` newtype.
        #[allow(trivial_casts, unsafe_code)]
        unsafe {
            &*(self.0.as_uint_ref() as *const UintRef as *const Odd<UintRef>)
        }
    }
}

#[cfg(feature = "alloc")]
impl PartialEq<Odd<BoxedUint>> for BoxedUint {
    fn eq(&self, other: &Odd<BoxedUint>) -> bool {
        self.eq(&other.0)
    }
}

#[cfg(feature = "alloc")]
impl PartialOrd<Odd<BoxedUint>> for BoxedUint {
    fn partial_cmp(&self, other: &Odd<BoxedUint>) -> Option<Ordering> {
        Some(self.cmp(&other.0))
    }
}

#[cfg(feature = "alloc")]
impl Resize for Odd<BoxedUint> {
    type Output = Self;

    fn resize_unchecked(self, at_least_bits_precision: u32) -> Self::Output {
        Odd(self.0.resize_unchecked(at_least_bits_precision))
    }

    fn try_resize(self, at_least_bits_precision: u32) -> Option<Self::Output> {
        self.0.try_resize(at_least_bits_precision).map(Odd)
    }
}

#[cfg(feature = "alloc")]
impl Resize for &Odd<BoxedUint> {
    type Output = Odd<BoxedUint>;

    fn resize_unchecked(self, at_least_bits_precision: u32) -> Self::Output {
        Odd((&self.0).resize_unchecked(at_least_bits_precision))
    }

    fn try_resize(self, at_least_bits_precision: u32) -> Option<Self::Output> {
        (&self.0).try_resize(at_least_bits_precision).map(Odd)
    }
}

#[cfg(feature = "rand_core")]
impl<const LIMBS: usize> Random for Odd<Uint<LIMBS>> {
    /// Generate a random `Odd<Uint<T>>`.
    fn try_random<R: TryRngCore + ?Sized>(rng: &mut R) -> Result<Self, R::Error> {
        let mut ret = Uint::try_random(rng)?;
        ret.limbs[0] |= Limb::ONE;
        Ok(Odd(ret))
    }
}

#[cfg(all(feature = "alloc", feature = "rand_core"))]
impl Odd<BoxedUint> {
    /// Generate a random `Odd<Uint<T>>`.
    pub fn random<R: TryRngCore + ?Sized>(rng: &mut R, bit_length: u32) -> Self {
        let mut ret = BoxedUint::random_bits(rng, bit_length);
        ret.limbs[0] |= Limb::ONE;
        Odd(ret)
    }
}

impl<T> fmt::Display for Odd<T>
where
    T: fmt::Display + ?Sized,
{
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        fmt::Display::fmt(&self.0, f)
    }
}

impl<T> fmt::Binary for Odd<T>
where
    T: fmt::Binary + ?Sized,
{
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        fmt::Binary::fmt(&self.0, f)
    }
}

impl<T> fmt::Octal for Odd<T>
where
    T: fmt::Octal + ?Sized,
{
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        fmt::Octal::fmt(&self.0, f)
    }
}

impl<T> fmt::LowerHex for Odd<T>
where
    T: fmt::LowerHex + ?Sized,
{
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        fmt::LowerHex::fmt(&self.0, f)
    }
}

impl<T> fmt::UpperHex for Odd<T>
where
    T: fmt::UpperHex + ?Sized,
{
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        fmt::UpperHex::fmt(&self.0, f)
    }
}

#[cfg(feature = "serde")]
impl<'de, T: Deserialize<'de> + Integer + Zero> Deserialize<'de> for Odd<T> {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: Deserializer<'de>,
    {
        let value: T = T::deserialize(deserializer)?;
        Option::<Self>::from(Self::new(value)).ok_or(D::Error::invalid_value(
            Unexpected::Other("even"),
            &"a non-zero odd value",
        ))
    }
}

#[cfg(feature = "serde")]
impl<T: Serialize + Zero> Serialize for Odd<T> {
    fn serialize<S>(&self, serializer: S) -> Result<S::Ok, S::Error>
    where
        S: Serializer,
    {
        self.0.serialize(serializer)
    }
}
#[cfg(feature = "zeroize")]
impl<T: zeroize::Zeroize> zeroize::Zeroize for Odd<T> {
    fn zeroize(&mut self) {
        self.0.zeroize();
    }
}

#[cfg(test)]
mod tests {
    #[cfg(feature = "alloc")]
    use super::BoxedUint;
    use super::{Odd, Uint};

    #[test]
    fn not_odd_numbers() {
        let zero = Odd::new(Uint::<4>::ZERO);
        assert!(bool::from(zero.is_none()));
        let two = Odd::new(Uint::<4>::from(2u8));
        assert!(bool::from(two.is_none()));
    }

    #[cfg(feature = "alloc")]
    #[test]
    fn not_odd_numbers_boxed() {
        let zero = Odd::new(BoxedUint::zero());
        assert!(bool::from(zero.is_none()));
        let two = Odd::new(BoxedUint::from(2u8));
        assert!(bool::from(two.is_none()));
    }

    #[cfg(feature = "serde")]
    mod serde_tests {
        use crate::{Odd, U64, U128};

        #[test]
        fn roundtrip() {
            let uint = Odd::new(U64::from_u64(0x00123)).unwrap();
            let ser = bincode::serde::encode_to_vec(uint, bincode::config::standard()).unwrap();
            let deser =
                bincode::serde::decode_from_slice::<Odd<U64>, _>(&ser, bincode::config::standard())
                    .unwrap()
                    .0;

            assert_eq!(uint, deser);
        }

        #[test]
        fn even_values_do_not_deserialize() {
            let two = U128::from_u64(0x2);
            let two_ser = bincode::serde::encode_to_vec(two, bincode::config::standard()).unwrap();
            assert!(
                bincode::serde::decode_from_slice::<Odd<U128>, _>(
                    &two_ser,
                    bincode::config::standard()
                )
                .is_err()
            );
        }

        #[test]
        fn zero_does_not_deserialize() {
            let zero = U64::ZERO;
            let zero_ser =
                bincode::serde::encode_to_vec(zero, bincode::config::standard()).unwrap();
            assert!(
                bincode::serde::decode_from_slice::<Odd<U64>, _>(
                    &zero_ser,
                    bincode::config::standard()
                )
                .is_err()
            );
        }
    }
}
