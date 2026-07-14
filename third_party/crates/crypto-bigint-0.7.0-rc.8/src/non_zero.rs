//! Wrapper type for non-zero integers.

use crate::{
    Bounded, ConstChoice, ConstCtOption, Constants, Encoding, Int, Limb, Odd, One, Uint, Zero,
};
use core::{
    fmt,
    num::{NonZeroU8, NonZeroU16, NonZeroU32, NonZeroU64, NonZeroU128},
    ops::{Deref, Mul},
};
use num_traits::ConstOne;
use subtle::{Choice, ConditionallySelectable, ConstantTimeEq, CtOption};

#[cfg(feature = "alloc")]
use crate::BoxedUint;

#[cfg(feature = "hybrid-array")]
use crate::{ArrayEncoding, ByteArray};

#[cfg(feature = "rand_core")]
use {crate::Random, rand_core::TryRngCore};

#[cfg(feature = "serde")]
use serdect::serde::{
    Deserialize, Deserializer, Serialize, Serializer,
    de::{Error, Unexpected},
};

/// Non-zero unsigned integer.
pub type NonZeroUint<const LIMBS: usize> = NonZero<Uint<LIMBS>>;

/// Non-zero signed integer.
pub type NonZeroInt<const LIMBS: usize> = NonZero<Int<LIMBS>>;

/// Non-zero boxed unsigned integer.
#[cfg(feature = "alloc")]
pub type NonZeroBoxedUint = NonZero<BoxedUint>;

/// Wrapper type for non-zero integers.
#[derive(Clone, Copy, Debug, Eq, Hash, PartialEq, PartialOrd, Ord)]
#[repr(transparent)]
pub struct NonZero<T: ?Sized>(pub(crate) T);

impl<T> NonZero<T> {
    /// Create a new non-zero integer.
    pub fn new(n: T) -> CtOption<Self>
    where
        T: Zero,
    {
        let is_zero = n.is_zero();
        CtOption::new(Self(n), !is_zero)
    }

    /// Returns the inner value.
    pub fn get(self) -> T {
        self.0
    }
}

impl<T: ?Sized> NonZero<T> {
    /// Provides access to the contents of `NonZero` in a `const` context.
    pub const fn as_ref(&self) -> &T {
        &self.0
    }
}

impl<T> NonZero<T>
where
    T: Bounded + ?Sized,
{
    /// Total size of the represented integer in bits.
    pub const BITS: u32 = T::BITS;

    /// Total size of the represented integer in bytes.
    pub const BYTES: usize = T::BYTES;
}

impl<T> NonZero<T>
where
    T: Constants,
{
    /// The value `1`.
    pub const ONE: Self = Self(T::ONE);

    /// Maximum value this integer can express.
    pub const MAX: Self = Self(T::MAX);
}

impl<T> NonZero<T>
where
    T: Encoding + Zero,
{
    /// Decode from big endian bytes.
    pub fn from_be_bytes(bytes: T::Repr) -> CtOption<Self> {
        Self::new(T::from_be_bytes(bytes))
    }

    /// Decode from little endian bytes.
    pub fn from_le_bytes(bytes: T::Repr) -> CtOption<Self> {
        Self::new(T::from_le_bytes(bytes))
    }
}

impl<T> ConstOne for NonZero<T>
where
    T: ConstOne + One,
{
    const ONE: Self = Self(T::ONE);
}

impl<T> One for NonZero<T>
where
    T: One,
{
    #[inline]
    fn one() -> Self {
        Self(T::one())
    }
}

impl<T> num_traits::One for NonZero<T>
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

/// Any non-zero integer multiplied by another non-zero integer is definitionally non-zero.
impl<T> Mul<Self> for NonZero<T>
where
    T: Mul<T, Output = T>,
{
    type Output = Self;

    fn mul(self, rhs: Self) -> Self {
        Self(self.0 * rhs.0)
    }
}

impl NonZero<Limb> {
    /// Creates a new non-zero limb in a const context.
    /// Panics if the value is zero.
    ///
    /// In future versions of Rust it should be possible to replace this with
    /// `NonZero::new(…).unwrap()`
    // TODO: Remove when `Self::new` and `CtOption::unwrap` support `const fn`
    pub const fn new_unwrap(n: Limb) -> Self {
        if n.is_nonzero().is_true_vartime() {
            Self(n)
        } else {
            panic!("Invalid value: zero")
        }
    }

    /// Create a [`NonZero<Limb>`] from a [`NonZeroU8`] (const-friendly)
    // TODO(tarcieri): replace with `const impl From<NonZeroU8>` when stable
    pub const fn from_u8(n: NonZeroU8) -> Self {
        Self(Limb::from_u8(n.get()))
    }

    /// Create a [`NonZero<Limb>`] from a [`NonZeroU16`] (const-friendly)
    // TODO(tarcieri): replace with `const impl From<NonZeroU16>` when stable
    pub const fn from_u16(n: NonZeroU16) -> Self {
        Self(Limb::from_u16(n.get()))
    }

    /// Create a [`NonZero<Limb>`] from a [`NonZeroU32`] (const-friendly)
    // TODO(tarcieri): replace with `const impl From<NonZeroU32>` when stable
    pub const fn from_u32(n: NonZeroU32) -> Self {
        Self(Limb::from_u32(n.get()))
    }

    /// Create a [`NonZero<Limb>`] from a [`NonZeroU64`] (const-friendly)
    // TODO(tarcieri): replace with `const impl From<NonZeroU64>` when stable
    #[cfg(target_pointer_width = "64")]
    pub const fn from_u64(n: NonZeroU64) -> Self {
        Self(Limb::from_u64(n.get()))
    }
}

impl<const LIMBS: usize> NonZeroUint<LIMBS> {
    /// Creates a new non-zero integer in a const context.
    ///
    /// In future versions of Rust it should be possible to replace this with
    /// `NonZero::new(…).unwrap()`
    ///
    /// # Panics
    /// - if the value is zero.
    // TODO: Remove when `Self::new` and `CtOption::unwrap` support `const fn`
    pub const fn new_unwrap(n: Uint<LIMBS>) -> Self {
        if n.is_nonzero().is_true_vartime() {
            Self(n)
        } else {
            panic!("Invalid value: zero")
        }
    }

    /// Create a new [`NonZero<Uint>`] from the provided big endian hex string.
    ///
    /// # Panics
    /// - if the hex is zero, malformed, or not zero-padded accordingly for the size.
    pub const fn from_be_hex(hex: &str) -> Self {
        Self::new_unwrap(Uint::from_be_hex(hex))
    }

    /// Create a new [`NonZero<Uint>`] from the provided little endian hex string.
    ///
    /// # Panics
    /// - if the hex is zero, malformed, or not zero-padded accordingly for the size.
    pub const fn from_le_hex(hex: &str) -> Self {
        Self::new_unwrap(Uint::from_le_hex(hex))
    }

    /// Create a [`NonZeroUint`] from a [`NonZeroU8`] (const-friendly)
    // TODO(tarcieri): replace with `const impl From<NonZeroU8>` when stable
    pub const fn from_u8(n: NonZeroU8) -> Self {
        Self(Uint::from_u8(n.get()))
    }

    /// Create a [`NonZeroUint`] from a [`NonZeroU16`] (const-friendly)
    // TODO(tarcieri): replace with `const impl From<NonZeroU16>` when stable
    pub const fn from_u16(n: NonZeroU16) -> Self {
        Self(Uint::from_u16(n.get()))
    }

    /// Create a [`NonZeroUint`] from a [`NonZeroU32`] (const-friendly)
    // TODO(tarcieri): replace with `const impl From<NonZeroU32>` when stable
    pub const fn from_u32(n: NonZeroU32) -> Self {
        Self(Uint::from_u32(n.get()))
    }

    /// Create a [`NonZeroUint`] from a [`NonZeroU64`] (const-friendly)
    // TODO(tarcieri): replace with `const impl From<NonZeroU64>` when stable
    pub const fn from_u64(n: NonZeroU64) -> Self {
        Self(Uint::from_u64(n.get()))
    }

    /// Create a [`NonZeroUint`] from a [`NonZeroU128`] (const-friendly)
    // TODO(tarcieri): replace with `const impl From<NonZeroU128>` when stable
    pub const fn from_u128(n: NonZeroU128) -> Self {
        Self(Uint::from_u128(n.get()))
    }
}

impl<const LIMBS: usize> NonZeroInt<LIMBS> {
    /// Creates a new non-zero integer in a const context.
    /// Panics if the value is zero.
    ///
    /// In future versions of Rust it should be possible to replace this with
    /// `NonZero::new(…).unwrap()`
    // TODO: Remove when `Self::new` and `CtOption::unwrap` support `const fn`
    pub const fn new_unwrap(n: Int<LIMBS>) -> Self {
        ConstCtOption::new(Self(n), n.is_nonzero()).expect("Invalid value: zero")
    }

    /// The sign and magnitude of this [`NonZeroInt`].
    pub const fn abs_sign(&self) -> (NonZero<Uint<LIMBS>>, ConstChoice) {
        let (abs, sign) = self.0.abs_sign();
        // Absolute value of a non-zero value is non-zero
        (NonZero(abs), sign)
    }

    /// The magnitude of this [`NonZeroInt`].
    pub const fn abs(&self) -> NonZero<Uint<LIMBS>> {
        self.abs_sign().0
    }
}

#[cfg(feature = "hybrid-array")]
impl<T> NonZero<T>
where
    T: ArrayEncoding + Zero,
{
    /// Decode a non-zero integer from big endian bytes.
    pub fn from_be_byte_array(bytes: ByteArray<T>) -> CtOption<Self> {
        Self::new(T::from_be_byte_array(bytes))
    }

    /// Decode a non-zero integer from big endian bytes.
    pub fn from_le_byte_array(bytes: ByteArray<T>) -> CtOption<Self> {
        Self::new(T::from_be_byte_array(bytes))
    }
}

impl<T: ?Sized> AsRef<T> for NonZero<T> {
    fn as_ref(&self) -> &T {
        &self.0
    }
}

impl<T> ConditionallySelectable for NonZero<T>
where
    T: ConditionallySelectable,
{
    fn conditional_select(a: &Self, b: &Self, choice: Choice) -> Self {
        Self(T::conditional_select(&a.0, &b.0, choice))
    }
}

impl<T> ConstantTimeEq for NonZero<T>
where
    T: ConstantTimeEq + ?Sized,
{
    fn ct_eq(&self, other: &Self) -> Choice {
        self.0.ct_eq(&other.0)
    }
}

impl<T> Default for NonZero<T>
where
    T: Constants,
{
    fn default() -> Self {
        Self(T::ONE)
    }
}

impl<T: ?Sized> Deref for NonZero<T> {
    type Target = T;

    fn deref(&self) -> &T {
        &self.0
    }
}

#[cfg(feature = "rand_core")]
impl<T> Random for NonZero<T>
where
    T: Random + Zero,
{
    /// This uses rejection sampling to avoid zero.
    ///
    /// As a result, it runs in variable time. If the generator `rng` is
    /// cryptographically secure (for example, it implements `CryptoRng`),
    /// then this is guaranteed not to leak anything about the output value.
    fn try_random<R: TryRngCore + ?Sized>(rng: &mut R) -> Result<Self, R::Error> {
        loop {
            if let Some(result) = Self::new(T::try_random(rng)?).into() {
                break Ok(result);
            }
        }
    }
}

impl From<NonZeroU8> for NonZero<Limb> {
    fn from(integer: NonZeroU8) -> Self {
        Self::from_u8(integer)
    }
}

impl From<NonZeroU16> for NonZero<Limb> {
    fn from(integer: NonZeroU16) -> Self {
        Self::from_u16(integer)
    }
}

impl From<NonZeroU32> for NonZero<Limb> {
    fn from(integer: NonZeroU32) -> Self {
        Self::from_u32(integer)
    }
}

#[cfg(target_pointer_width = "64")]
impl From<NonZeroU64> for NonZero<Limb> {
    fn from(integer: NonZeroU64) -> Self {
        Self::from_u64(integer)
    }
}

impl<const LIMBS: usize> From<NonZeroU8> for NonZero<Uint<LIMBS>> {
    fn from(integer: NonZeroU8) -> Self {
        Self::from_u8(integer)
    }
}

impl<const LIMBS: usize> From<NonZeroU16> for NonZero<Uint<LIMBS>> {
    fn from(integer: NonZeroU16) -> Self {
        Self::from_u16(integer)
    }
}

impl<const LIMBS: usize> From<NonZeroU32> for NonZero<Uint<LIMBS>> {
    fn from(integer: NonZeroU32) -> Self {
        Self::from_u32(integer)
    }
}

impl<const LIMBS: usize> From<NonZeroU64> for NonZero<Uint<LIMBS>> {
    fn from(integer: NonZeroU64) -> Self {
        Self::from_u64(integer)
    }
}

impl<const LIMBS: usize> From<NonZeroU128> for NonZero<Uint<LIMBS>> {
    fn from(integer: NonZeroU128) -> Self {
        Self::from_u128(integer)
    }
}

impl<T> From<Odd<T>> for NonZero<T> {
    fn from(odd: Odd<T>) -> NonZero<T> {
        NonZero(odd.get())
    }
}

impl<T> fmt::Display for NonZero<T>
where
    T: fmt::Display + ?Sized,
{
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        fmt::Display::fmt(&self.0, f)
    }
}

impl<T> fmt::Binary for NonZero<T>
where
    T: fmt::Binary + ?Sized,
{
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        fmt::Binary::fmt(&self.0, f)
    }
}

impl<T> fmt::Octal for NonZero<T>
where
    T: fmt::Octal + ?Sized,
{
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        fmt::Octal::fmt(&self.0, f)
    }
}

impl<T> fmt::LowerHex for NonZero<T>
where
    T: fmt::LowerHex + ?Sized,
{
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        fmt::LowerHex::fmt(&self.0, f)
    }
}

impl<T> fmt::UpperHex for NonZero<T>
where
    T: fmt::UpperHex + ?Sized,
{
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        fmt::UpperHex::fmt(&self.0, f)
    }
}

#[cfg(feature = "serde")]
impl<'de, T: Deserialize<'de> + Zero> Deserialize<'de> for NonZero<T> {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: Deserializer<'de>,
    {
        let value: T = T::deserialize(deserializer)?;

        if bool::from(value.is_zero()) {
            Err(D::Error::invalid_value(
                Unexpected::Other("zero"),
                &"a non-zero value",
            ))
        } else {
            Ok(Self(value))
        }
    }
}

#[cfg(feature = "serde")]
impl<T: Serialize + Zero> Serialize for NonZero<T> {
    fn serialize<S>(&self, serializer: S) -> Result<S::Ok, S::Error>
    where
        S: Serializer,
    {
        self.0.serialize(serializer)
    }
}

#[cfg(feature = "zeroize")]
impl<T: zeroize::Zeroize + Zero> zeroize::Zeroize for NonZero<T> {
    fn zeroize(&mut self) {
        self.0.zeroize();
    }
}

#[cfg(test)]
mod tests {
    use crate::{ConstChoice, I128, U128};

    #[test]
    fn int_abs_sign() {
        let x = I128::from(-55).to_nz().unwrap();
        let (abs, sgn) = x.abs_sign();
        assert_eq!(abs, U128::from(55u32).to_nz().unwrap());
        assert_eq!(sgn, ConstChoice::TRUE);
    }
}

#[cfg(all(test, feature = "serde"))]
#[allow(clippy::unwrap_used)]
mod tests_serde {
    use crate::{NonZero, U64};

    #[test]
    fn serde() {
        let test =
            Option::<NonZero<U64>>::from(NonZero::new(U64::from_u64(0x0011223344556677))).unwrap();

        let serialized = bincode::serde::encode_to_vec(test, bincode::config::standard()).unwrap();
        let deserialized: NonZero<U64> =
            bincode::serde::decode_from_slice(&serialized, bincode::config::standard())
                .unwrap()
                .0;

        assert_eq!(test, deserialized);

        let serialized =
            bincode::serde::encode_to_vec(U64::ZERO, bincode::config::standard()).unwrap();
        assert!(
            bincode::serde::decode_from_slice::<NonZero<U64>, _>(
                &serialized,
                bincode::config::standard()
            )
            .is_err()
        );
    }
}
