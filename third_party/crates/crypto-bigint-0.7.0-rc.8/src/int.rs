//! Stack-allocated big signed integers.

use crate::{
    Bounded, ConstChoice, ConstCtOption, Constants, FixedInteger, Integer, Limb, NonZero, Odd, One,
    Signed, Uint, Word, Zero,
};
use core::fmt;
use num_traits::{ConstOne, ConstZero};
use subtle::{Choice, ConditionallySelectable, ConstantTimeEq};

#[cfg(feature = "serde")]
use crate::Encoding;
#[cfg(feature = "serde")]
use serdect::serde::{Deserialize, Deserializer, Serialize, Serializer};

mod add;
mod bit_and;
mod bit_not;
mod bit_or;
mod bit_xor;
mod cmp;
mod div;
mod div_uint;
mod encoding;
mod from;
mod gcd;
mod invert_mod;
mod mod_symbol;
mod mul;
mod mul_uint;
mod neg;
mod resize;
mod shl;
mod shr;
mod sign;
mod sub;
pub(crate) mod types;

#[cfg(feature = "rand_core")]
mod rand;

/// Stack-allocated big _signed_ integer.
/// See [`Uint`] for _unsigned_ integers.
///
/// Created as a [`Uint`] newtype.
#[allow(clippy::derived_hash_with_manual_eq)]
#[derive(Copy, Clone, Hash)]
#[repr(transparent)]
pub struct Int<const LIMBS: usize>(Uint<LIMBS>);

impl<const LIMBS: usize> Int<LIMBS> {
    /// The value `0`.
    pub const ZERO: Self = Self(Uint::ZERO); // Bit sequence (be): 0000....0000

    /// The value `1`.
    pub const ONE: Self = Self(Uint::ONE); // Bit sequence (be): 0000....0001

    /// The value `-1`
    pub const MINUS_ONE: Self = Self::FULL_MASK; // Bit sequence (be): 1111....1111

    /// Smallest value this [`Int`] can express.
    pub const MIN: Self = Self(Uint::MAX.bitxor(&Uint::MAX.shr(1u32))); // Bit sequence (be): 1000....0000

    /// Maximum value this [`Int`] can express.
    pub const MAX: Self = Self(Uint::MAX.shr(1u32)); // Bit sequence (be): 0111....1111

    /// Bit mask for the sign bit of this [`Int`].
    pub const SIGN_MASK: Self = Self::MIN; // Bit sequence (be): 1000....0000

    /// All-one bit mask.
    pub const FULL_MASK: Self = Self(Uint::MAX); // Bit sequence (be): 1111...1111

    /// Total size of the represented integer in bits.
    pub const BITS: u32 = Uint::<LIMBS>::BITS;

    /// Total size of the represented integer in bytes.
    pub const BYTES: usize = Uint::<LIMBS>::BYTES;

    /// The number of limbs used on this platform.
    pub const LIMBS: usize = LIMBS;

    /// Const-friendly [`Int`] constructor.
    pub const fn new(limbs: [Limb; LIMBS]) -> Self {
        Self(Uint::new(limbs))
    }

    /// Const-friendly [`Int`] constructor.
    ///
    /// Reinterprets the bits of a value of type [`Uint`] as an [`Int`].
    /// For a proper conversion, see [`Int::new_from_abs_sign`];
    /// the public interface of this function is available at [`Uint::as_int`].
    pub(crate) const fn from_bits(value: Uint<LIMBS>) -> Self {
        Self(value)
    }

    /// Create an [`Int`] from an array of [`Word`]s (i.e. word-sized unsigned
    /// integers).
    #[inline]
    pub const fn from_words(arr: [Word; LIMBS]) -> Self {
        Self(Uint::from_words(arr))
    }

    /// Create an array of [`Word`]s (i.e. word-sized unsigned integers) from
    /// an [`Int`].
    #[inline]
    pub const fn to_words(self) -> [Word; LIMBS] {
        self.0.to_words()
    }

    /// Borrow the inner limbs as an array of [`Word`]s.
    pub const fn as_words(&self) -> &[Word; LIMBS] {
        self.0.as_words()
    }

    /// Borrow the inner limbs as a mutable array of [`Word`]s.
    pub fn as_mut_words(&mut self) -> &mut [Word; LIMBS] {
        self.0.as_mut_words()
    }

    /// Borrow the inner limbs as a mutable slice of [`Word`]s.
    #[deprecated(since = "0.7.0", note = "please use `as_mut_words` instead")]
    pub fn as_words_mut(&mut self) -> &mut [Word] {
        self.as_mut_words()
    }

    /// Borrow the limbs of this [`Int`].
    pub const fn as_limbs(&self) -> &[Limb; LIMBS] {
        self.0.as_limbs()
    }

    /// Borrow the limbs of this [`Int`] mutably.
    pub const fn as_mut_limbs(&mut self) -> &mut [Limb; LIMBS] {
        self.0.as_mut_limbs()
    }

    /// Borrow the limbs of this [`Int`] mutably.
    #[deprecated(since = "0.7.0", note = "please use `as_mut_limbs` instead")]
    pub const fn as_limbs_mut(&mut self) -> &mut [Limb] {
        self.as_mut_limbs()
    }

    /// Convert this [`Int`] into its inner limbs.
    pub const fn to_limbs(self) -> [Limb; LIMBS] {
        self.0.to_limbs()
    }

    /// Convert to a [`NonZero<Int<LIMBS>>`].
    ///
    /// Returns some if the original value is non-zero, and false otherwise.
    pub const fn to_nz(self) -> ConstCtOption<NonZero<Self>> {
        ConstCtOption::new(NonZero(self), self.0.is_nonzero())
    }

    /// Convert to a [`Odd<Int<LIMBS>>`].
    ///
    /// Returns some if the original value is odd, and false otherwise.
    pub const fn to_odd(self) -> ConstCtOption<Odd<Self>> {
        ConstCtOption::new(Odd(self), self.0.is_odd())
    }

    /// Interpret the data in this object as a [`Uint`] instead.
    ///
    /// Note: this is a casting operation. See
    /// - [`Self::try_into_uint`] for the checked equivalent, and
    /// - [`Self::abs`] to obtain the absolute value of `self`.
    pub const fn as_uint(&self) -> &Uint<LIMBS> {
        &self.0
    }

    /// Get a [`Uint`] equivalent of this value; returns `None` if `self` is negative.
    ///
    /// Note: this is a checked conversion operation. See
    /// - [`Self::as_uint`] for the unchecked equivalent, and
    /// - [`Self::abs`] to obtain the absolute value of `self`.
    pub const fn try_into_uint(self) -> ConstCtOption<Uint<LIMBS>> {
        ConstCtOption::new(self.0, self.is_negative().not())
    }

    /// Whether this [`Int`] is equal to `Self::MIN`.
    pub const fn is_min(&self) -> ConstChoice {
        Self::eq(self, &Self::MIN)
    }

    /// Whether this [`Int`] is equal to `Self::MAX`.
    pub fn is_max(&self) -> ConstChoice {
        Self::eq(self, &Self::MAX)
    }

    /// Invert the most significant bit (msb) of this [`Int`]
    const fn invert_msb(&self) -> Self {
        Self(self.0.bitxor(&Self::SIGN_MASK.0))
    }
}

impl<const LIMBS: usize> AsRef<[Word; LIMBS]> for Int<LIMBS> {
    fn as_ref(&self) -> &[Word; LIMBS] {
        self.as_words()
    }
}

impl<const LIMBS: usize> AsMut<[Word; LIMBS]> for Int<LIMBS> {
    fn as_mut(&mut self) -> &mut [Word; LIMBS] {
        self.as_mut_words()
    }
}

impl<const LIMBS: usize> AsRef<[Limb]> for Int<LIMBS> {
    fn as_ref(&self) -> &[Limb] {
        self.as_limbs()
    }
}

impl<const LIMBS: usize> AsMut<[Limb]> for Int<LIMBS> {
    fn as_mut(&mut self) -> &mut [Limb] {
        self.as_mut_limbs()
    }
}

impl<const LIMBS: usize> ConditionallySelectable for Int<LIMBS> {
    fn conditional_select(a: &Self, b: &Self, choice: Choice) -> Self {
        Self(Uint::conditional_select(&a.0, &b.0, choice))
    }
}

impl<const LIMBS: usize> Bounded for Int<LIMBS> {
    const BITS: u32 = Self::BITS;
    const BYTES: usize = Self::BYTES;
}

impl<const LIMBS: usize> Constants for Int<LIMBS> {
    const MAX: Self = Self::MAX;
}

impl<const LIMBS: usize> Default for Int<LIMBS> {
    fn default() -> Self {
        Self::ZERO
    }
}

impl<const LIMBS: usize> FixedInteger for Int<LIMBS> {
    const LIMBS: usize = LIMBS;
}

impl<const LIMBS: usize> Integer for Int<LIMBS> {
    fn nlimbs(&self) -> usize {
        self.0.nlimbs()
    }
}

impl<const LIMBS: usize> Signed for Int<LIMBS> {
    type Unsigned = Uint<LIMBS>;

    fn abs_sign(&self) -> (Uint<LIMBS>, Choice) {
        let (abs, sign) = self.abs_sign();
        (abs, sign.into())
    }

    fn is_negative(&self) -> Choice {
        self.is_negative().into()
    }

    fn is_positive(&self) -> Choice {
        self.is_positive().into()
    }
}

impl<const LIMBS: usize> ConstZero for Int<LIMBS> {
    const ZERO: Self = Self::ZERO;
}

impl<const LIMBS: usize> ConstOne for Int<LIMBS> {
    const ONE: Self = Self::ONE;
}

impl<const LIMBS: usize> Zero for Int<LIMBS> {
    #[inline(always)]
    fn zero() -> Self {
        Self::ZERO
    }
}

impl<const LIMBS: usize> One for Int<LIMBS> {
    #[inline(always)]
    fn one() -> Self {
        Self::ONE
    }
}

impl<const LIMBS: usize> num_traits::Zero for Int<LIMBS> {
    #[inline(always)]
    fn zero() -> Self {
        Self::ZERO
    }

    fn is_zero(&self) -> bool {
        self.0.ct_eq(&Self::ZERO.0).into()
    }
}

impl<const LIMBS: usize> num_traits::One for Int<LIMBS> {
    #[inline(always)]
    fn one() -> Self {
        Self::ONE
    }

    fn is_one(&self) -> bool {
        self.0.ct_eq(&Self::ONE.0).into()
    }
}

impl<const LIMBS: usize> fmt::Debug for Int<LIMBS> {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "Int(0x{self:X})")
    }
}

impl<const LIMBS: usize> fmt::Binary for Int<LIMBS> {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        fmt::Binary::fmt(&self.0, f)
    }
}

impl<const LIMBS: usize> fmt::Display for Int<LIMBS> {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        fmt::UpperHex::fmt(self, f)
    }
}

impl<const LIMBS: usize> fmt::LowerHex for Int<LIMBS> {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        fmt::LowerHex::fmt(&self.0, f)
    }
}

impl<const LIMBS: usize> fmt::UpperHex for Int<LIMBS> {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        fmt::UpperHex::fmt(&self.0, f)
    }
}

#[cfg(feature = "serde")]
impl<'de, const LIMBS: usize> Deserialize<'de> for Int<LIMBS>
where
    Int<LIMBS>: Encoding,
{
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: Deserializer<'de>,
    {
        let mut buffer = Self::ZERO.to_le_bytes();
        serdect::array::deserialize_hex_or_bin(buffer.as_mut(), deserializer)?;
        Ok(Self::from_le_bytes(buffer))
    }
}

#[cfg(feature = "serde")]
impl<const LIMBS: usize> Serialize for Int<LIMBS>
where
    Int<LIMBS>: Encoding,
{
    fn serialize<S>(&self, serializer: S) -> Result<S::Ok, S::Error>
    where
        S: Serializer,
    {
        serdect::array::serialize_hex_lower_or_bin(&Encoding::to_le_bytes(self), serializer)
    }
}

#[cfg(test)]
#[allow(clippy::unwrap_used)]
mod tests {
    use subtle::ConditionallySelectable;

    use crate::{ConstChoice, I128, U128};

    #[cfg(target_pointer_width = "64")]
    #[test]
    fn as_words() {
        let n = I128::from_be_hex("AAAAAAAABBBBBBBBCCCCCCCCDDDDDDDD");
        assert_eq!(n.as_words(), &[0xCCCCCCCCDDDDDDDD, 0xAAAAAAAABBBBBBBB]);
    }

    #[cfg(target_pointer_width = "64")]
    #[test]
    fn as_words_mut() {
        let mut n = I128::from_be_hex("AAAAAAAABBBBBBBBCCCCCCCCDDDDDDDD");
        assert_eq!(n.as_mut_words(), &[0xCCCCCCCCDDDDDDDD, 0xAAAAAAAABBBBBBBB]);
    }

    #[cfg(feature = "alloc")]
    #[test]
    fn debug() {
        let n = I128::from_be_hex("AAAAAAAABBBBBBBBCCCCCCCCDDDDDDDD");

        assert_eq!(format!("{n:?}"), "Int(0xAAAAAAAABBBBBBBBCCCCCCCCDDDDDDDD)");
    }

    #[cfg(feature = "alloc")]
    #[test]
    fn display() {
        let hex = "AAAAAAAABBBBBBBBCCCCCCCCDDDDDDDD";
        let n = I128::from_be_hex(hex);

        use alloc::string::ToString;
        assert_eq!(hex, n.to_string());

        let hex = "AAAAAAAABBBBBBBB0000000000000000";
        let n = I128::from_be_hex(hex);
        assert_eq!(hex, n.to_string());

        let hex = "AAAAAAAABBBBBBBB00000000DDDDDDDD";
        let n = I128::from_be_hex(hex);
        assert_eq!(hex, n.to_string());

        let hex = "AAAAAAAABBBBBBBB0CCCCCCCDDDDDDDD";
        let n = I128::from_be_hex(hex);
        assert_eq!(hex, n.to_string());
    }

    #[cfg(feature = "alloc")]
    #[test]
    fn fmt_lower_hex() {
        let n = I128::from_be_hex("AAAAAAAABBBBBBBBCCCCCCCCDDDDDDDD");
        assert_eq!(format!("{n:x}"), "aaaaaaaabbbbbbbbccccccccdddddddd");
        assert_eq!(format!("{n:#x}"), "0xaaaaaaaabbbbbbbbccccccccdddddddd");
    }

    #[cfg(feature = "alloc")]
    #[test]
    fn fmt_upper_hex() {
        let n = I128::from_be_hex("aaaaaaaabbbbbbbbccccccccdddddddd");
        assert_eq!(format!("{n:X}"), "AAAAAAAABBBBBBBBCCCCCCCCDDDDDDDD");
        assert_eq!(format!("{n:#X}"), "0xAAAAAAAABBBBBBBBCCCCCCCCDDDDDDDD");
    }

    #[cfg(feature = "alloc")]
    #[test]
    fn fmt_binary() {
        let n = I128::from_be_hex("AAAAAAAABBBBBBBBCCCCCCCCDDDDDDDD");
        assert_eq!(
            format!("{n:b}"),
            "10101010101010101010101010101010101110111011101110111011101110111100110011001100110011001100110011011101110111011101110111011101"
        );
        assert_eq!(
            format!("{n:#b}"),
            "0b10101010101010101010101010101010101110111011101110111011101110111100110011001100110011001100110011011101110111011101110111011101"
        );
    }

    #[test]
    fn conditional_select() {
        let a = I128::from_be_hex("00002222444466668888AAAACCCCEEEE");
        let b = I128::from_be_hex("11113333555577779999BBBBDDDDFFFF");

        let select_0 = I128::conditional_select(&a, &b, 0.into());
        assert_eq!(a, select_0);

        let select_1 = I128::conditional_select(&a, &b, 1.into());
        assert_eq!(b, select_1);
    }

    #[test]
    fn is_minimal() {
        let min = I128::from_be_hex("80000000000000000000000000000000");
        assert_eq!(min.is_min(), ConstChoice::TRUE);

        let random = I128::from_be_hex("11113333555577779999BBBBDDDDFFFF");
        assert_eq!(random.is_min(), ConstChoice::FALSE);
    }

    #[test]
    fn is_maximal() {
        let max = I128::from_be_hex("7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF");
        assert_eq!(max.is_max(), ConstChoice::TRUE);

        let random = I128::from_be_hex("11113333555577779999BBBBDDDDFFFF");
        assert_eq!(random.is_max(), ConstChoice::FALSE);
    }

    #[test]
    fn as_uint() {
        assert_eq!(*I128::MIN.as_uint(), U128::ONE << 127);
        assert_eq!(*I128::MINUS_ONE.as_uint(), U128::MAX);
        assert_eq!(*I128::ZERO.as_uint(), U128::ZERO);
        assert_eq!(*I128::ONE.as_uint(), U128::ONE);
        assert_eq!(*I128::MAX.as_uint(), U128::MAX >> 1);
    }

    #[test]
    fn to_uint() {
        assert!(bool::from(I128::MIN.try_into_uint().is_none()));
        assert!(bool::from(I128::MINUS_ONE.try_into_uint().is_none()));
        assert_eq!(I128::ZERO.try_into_uint().unwrap(), U128::ZERO);
        assert_eq!(I128::ONE.try_into_uint().unwrap(), U128::ONE);
        assert_eq!(I128::MAX.try_into_uint().unwrap(), U128::MAX >> 1);
    }
}
