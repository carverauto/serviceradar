//! Stack-allocated big unsigned integers.

#![allow(clippy::needless_range_loop, clippy::many_single_char_names)]

use core::fmt;

#[cfg(feature = "serde")]
use serdect::serde::{Deserialize, Deserializer, Serialize, Serializer};
use subtle::{Choice, ConditionallySelectable, ConstantTimeEq};
#[cfg(feature = "zeroize")]
use zeroize::DefaultIsZeroes;

#[cfg(feature = "extra-sizes")]
pub use extra_sizes::*;

pub(crate) use ref_type::UintRef;

use crate::{
    Bounded, ConstChoice, ConstCtOption, ConstOne, ConstZero, Constants, Encoding, FixedInteger,
    Int, Integer, Limb, NonZero, Odd, One, Unsigned, Word, Zero, modular::MontyForm,
};

#[macro_use]
mod macros;

mod add;
mod add_mod;
mod bit_and;
mod bit_not;
mod bit_or;
mod bit_xor;
mod bits;
mod cmp;
mod concat;
mod div;
pub(crate) mod div_limb;
pub(crate) mod encoding;
mod from;
pub(crate) mod gcd;
mod invert_mod;
mod mod_symbol;
pub(crate) mod mul;
mod mul_mod;
mod neg;
mod neg_mod;
mod resize;
mod shl;
mod shr;
mod split;
mod sqrt;
mod sub;
mod sub_mod;

#[cfg(feature = "hybrid-array")]
mod array;
#[cfg(feature = "alloc")]
pub(crate) mod boxed;
#[cfg(feature = "rand_core")]
mod rand;

/// Stack-allocated big unsigned integer.
///
/// Generic over the given number of `LIMBS`
///
/// # Encoding support
/// This type supports many different types of encodings, either via the
/// [`Encoding`][`crate::Encoding`] trait or various `const fn` decoding and
/// encoding functions that can be used with [`Uint`] constants.
///
/// Optional crate features for encoding (off-by-default):
/// - `hybrid-array`: enables [`ArrayEncoding`][`crate::ArrayEncoding`] trait which can be used to
///   [`Uint`] as `Array<u8, N>` and a [`ArrayDecoding`][`crate::ArrayDecoding`] trait which
///   can be used to `Array<u8, N>` as [`Uint`].
/// - `rlp`: support for [Recursive Length Prefix (RLP)][RLP] encoding.
///
/// [RLP]: https://eth.wiki/fundamentals/rlp
// TODO(tarcieri): make generic around a specified number of bits.
// Our PartialEq impl only differs from the default one by being constant-time, so this is safe
#[allow(clippy::derived_hash_with_manual_eq)]
#[derive(Copy, Clone, Hash)]
pub struct Uint<const LIMBS: usize> {
    /// Inner limb array. Stored from least significant to most significant.
    pub(crate) limbs: [Limb; LIMBS],
}

impl<const LIMBS: usize> Uint<LIMBS> {
    /// The value `0`.
    pub const ZERO: Self = Self::from_u8(0);

    /// The value `1`.
    pub const ONE: Self = Self::from_u8(1);

    /// Maximum value this [`Uint`] can express.
    pub const MAX: Self = Self {
        limbs: [Limb::MAX; LIMBS],
    };

    /// Total size of the represented integer in bits.
    pub const BITS: u32 = LIMBS as u32 * Limb::BITS;

    /// `floor(log2(Self::BITS))`.
    // Note: assumes the type of `BITS` is `u32`. Any way to assert that?
    pub(crate) const LOG2_BITS: u32 = u32::BITS - Self::BITS.leading_zeros() - 1;

    /// Total size of the represented integer in bytes.
    pub const BYTES: usize = LIMBS * Limb::BYTES;

    /// The number of limbs used on this platform.
    pub const LIMBS: usize = LIMBS;

    /// Const-friendly [`Uint`] constructor.
    pub const fn new(limbs: [Limb; LIMBS]) -> Self {
        Self { limbs }
    }

    /// Create a [`Uint`] from an array of [`Word`]s (i.e. word-sized unsigned
    /// integers).
    #[inline]
    pub const fn from_words(arr: [Word; LIMBS]) -> Self {
        let mut limbs = [Limb::ZERO; LIMBS];
        let mut i = 0;

        while i < LIMBS {
            limbs[i] = Limb(arr[i]);
            i += 1;
        }

        Self { limbs }
    }

    /// Create an array of [`Word`]s (i.e. word-sized unsigned integers) from
    /// a [`Uint`].
    #[inline]
    pub const fn to_words(self) -> [Word; LIMBS] {
        let mut arr = [0; LIMBS];
        let mut i = 0;

        while i < LIMBS {
            arr[i] = self.limbs[i].0;
            i += 1;
        }

        arr
    }

    /// Borrow the inner limbs as an array of [`Word`]s.
    pub const fn as_words(&self) -> &[Word; LIMBS] {
        // SAFETY: `Limb` is a `repr(transparent)` newtype for `Word`
        #[allow(unsafe_code)]
        unsafe {
            &*self.limbs.as_ptr().cast()
        }
    }

    /// Borrow the inner limbs as a mutable array of [`Word`]s.
    pub const fn as_mut_words(&mut self) -> &mut [Word; LIMBS] {
        // SAFETY: `Limb` is a `repr(transparent)` newtype for `Word`
        #[allow(unsafe_code)]
        unsafe {
            &mut *self.limbs.as_mut_ptr().cast()
        }
    }

    /// Borrow the inner limbs as a mutable slice of [`Word`]s.
    #[deprecated(since = "0.7.0", note = "please use `as_mut_words` instead")]
    pub const fn as_words_mut(&mut self) -> &mut [Word] {
        self.as_mut_words()
    }

    /// Borrow the limbs of this [`Uint`].
    pub const fn as_limbs(&self) -> &[Limb; LIMBS] {
        &self.limbs
    }

    /// Borrow the limbs of this [`Uint`] mutably.
    pub const fn as_mut_limbs(&mut self) -> &mut [Limb; LIMBS] {
        &mut self.limbs
    }

    /// Borrow the limbs of this [`Uint`] mutably.
    #[deprecated(since = "0.7.0", note = "please use `as_mut_limbs` instead")]
    pub const fn as_limbs_mut(&mut self) -> &mut [Limb] {
        self.as_mut_limbs()
    }

    /// Convert this [`Uint`] into its inner limbs.
    pub const fn to_limbs(self) -> [Limb; LIMBS] {
        self.limbs
    }

    /// Borrow the limbs of this [`Uint`] as a [`UintRef`].
    #[inline(always)]
    pub(crate) const fn as_uint_ref(&self) -> &UintRef {
        UintRef::new(&self.limbs)
    }

    /// Mutably borrow the limbs of this [`Uint`] as a [`UintRef`].
    #[inline(always)]
    pub(crate) const fn as_mut_uint_ref(&mut self) -> &mut UintRef {
        UintRef::new_mut(&mut self.limbs)
    }

    /// Convert to a [`NonZero<Uint<LIMBS>>`].
    ///
    /// Returns some if the original value is non-zero, and false otherwise.
    pub const fn to_nz(self) -> ConstCtOption<NonZero<Self>> {
        ConstCtOption::new(NonZero(self), self.is_nonzero())
    }

    /// Convert to a [`Odd<Uint<LIMBS>>`].
    ///
    /// Returns some if the original value is odd, and false otherwise.
    pub const fn to_odd(self) -> ConstCtOption<Odd<Self>> {
        ConstCtOption::new(Odd(self), self.is_odd())
    }

    /// Interpret this object as an [`Int`] instead.
    ///
    /// Note: this is a casting operation. See [`Self::try_into_int`] for the checked equivalent.
    pub const fn as_int(&self) -> &Int<LIMBS> {
        #[allow(trivial_casts, unsafe_code)]
        unsafe {
            &*(self as *const Uint<LIMBS> as *const Int<LIMBS>)
        }
    }

    /// Convert this type into an [`Int`]; returns `None` if this value is greater than [`Int::MAX`].
    ///
    /// Note: this is the conversion operation. See [`Self::as_int`] for the unchecked equivalent.
    pub const fn try_into_int(self) -> ConstCtOption<Int<LIMBS>> {
        Int::new_from_abs_sign(self, ConstChoice::FALSE)
    }
}

impl<const LIMBS: usize> AsRef<[Word; LIMBS]> for Uint<LIMBS> {
    fn as_ref(&self) -> &[Word; LIMBS] {
        self.as_words()
    }
}

impl<const LIMBS: usize> AsMut<[Word; LIMBS]> for Uint<LIMBS> {
    fn as_mut(&mut self) -> &mut [Word; LIMBS] {
        self.as_mut_words()
    }
}

impl<const LIMBS: usize> AsRef<[Limb]> for Uint<LIMBS> {
    fn as_ref(&self) -> &[Limb] {
        self.as_limbs()
    }
}

impl<const LIMBS: usize> AsMut<[Limb]> for Uint<LIMBS> {
    fn as_mut(&mut self) -> &mut [Limb] {
        self.as_mut_limbs()
    }
}

impl<const LIMBS: usize> AsRef<UintRef> for Uint<LIMBS> {
    fn as_ref(&self) -> &UintRef {
        self.as_uint_ref()
    }
}

impl<const LIMBS: usize> AsMut<UintRef> for Uint<LIMBS> {
    fn as_mut(&mut self) -> &mut UintRef {
        self.as_mut_uint_ref()
    }
}

impl<const LIMBS: usize> ConditionallySelectable for Uint<LIMBS> {
    fn conditional_select(a: &Self, b: &Self, choice: Choice) -> Self {
        let mut limbs = [Limb::ZERO; LIMBS];

        for i in 0..LIMBS {
            limbs[i] = Limb::conditional_select(&a.limbs[i], &b.limbs[i], choice);
        }

        Self { limbs }
    }
}

impl<const LIMBS: usize> Bounded for Uint<LIMBS> {
    const BITS: u32 = Self::BITS;
    const BYTES: usize = Self::BYTES;
}

impl<const LIMBS: usize> Constants for Uint<LIMBS> {
    const MAX: Self = Self::MAX;
}

impl<const LIMBS: usize> Default for Uint<LIMBS> {
    fn default() -> Self {
        Self::ZERO
    }
}

impl<const LIMBS: usize> FixedInteger for Uint<LIMBS> {
    const LIMBS: usize = LIMBS;
}

impl<const LIMBS: usize> Integer for Uint<LIMBS> {
    fn nlimbs(&self) -> usize {
        Self::LIMBS
    }
}

impl<const LIMBS: usize> Unsigned for Uint<LIMBS> {
    type Monty = MontyForm<LIMBS>;

    fn from_limb_like(limb: Limb, _other: &Self) -> Self {
        Self::from(limb)
    }
}

impl<const LIMBS: usize> num_traits::Num for Uint<LIMBS> {
    type FromStrRadixErr = crate::DecodeError;

    /// ⚠️ WARNING: `from_str_radix` impl operates in variable-time with respect to the input.
    fn from_str_radix(str: &str, radix: u32) -> Result<Self, Self::FromStrRadixErr> {
        Self::from_str_radix_vartime(str, radix)
    }
}

impl<const LIMBS: usize> ConstZero for Uint<LIMBS> {
    const ZERO: Self = Self::ZERO;
}

impl<const LIMBS: usize> ConstOne for Uint<LIMBS> {
    const ONE: Self = Self::ONE;
}

impl<const LIMBS: usize> Zero for Uint<LIMBS> {
    #[inline(always)]
    fn zero() -> Self {
        Self::ZERO
    }
}

impl<const LIMBS: usize> One for Uint<LIMBS> {
    #[inline(always)]
    fn one() -> Self {
        Self::ONE
    }
}

impl<const LIMBS: usize> num_traits::Zero for Uint<LIMBS> {
    #[inline(always)]
    fn zero() -> Self {
        Self::ZERO
    }

    fn is_zero(&self) -> bool {
        self.ct_eq(&Self::ZERO).into()
    }
}

impl<const LIMBS: usize> num_traits::One for Uint<LIMBS> {
    #[inline(always)]
    fn one() -> Self {
        Self::ONE
    }

    fn is_one(&self) -> bool {
        self.ct_eq(&Self::ONE).into()
    }
}

impl<const LIMBS: usize> fmt::Debug for Uint<LIMBS> {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "Uint(0x{:X})", self.as_uint_ref())
    }
}

impl<const LIMBS: usize> fmt::Binary for Uint<LIMBS> {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        fmt::Binary::fmt(self.as_uint_ref(), f)
    }
}

impl<const LIMBS: usize> fmt::Display for Uint<LIMBS> {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        fmt::UpperHex::fmt(self, f)
    }
}

impl<const LIMBS: usize> fmt::LowerHex for Uint<LIMBS> {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        fmt::LowerHex::fmt(self.as_uint_ref(), f)
    }
}

impl<const LIMBS: usize> fmt::UpperHex for Uint<LIMBS> {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        fmt::UpperHex::fmt(self.as_uint_ref(), f)
    }
}

#[cfg(feature = "serde")]
impl<'de, const LIMBS: usize> Deserialize<'de> for Uint<LIMBS>
where
    Uint<LIMBS>: Encoding,
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
impl<const LIMBS: usize> Serialize for Uint<LIMBS>
where
    Uint<LIMBS>: Encoding,
{
    fn serialize<S>(&self, serializer: S) -> Result<S::Ok, S::Error>
    where
        S: Serializer,
    {
        serdect::array::serialize_hex_lower_or_bin(&Encoding::to_le_bytes(self), serializer)
    }
}

#[cfg(feature = "zeroize")]
impl<const LIMBS: usize> DefaultIsZeroes for Uint<LIMBS> {}

// TODO(tarcieri): use `generic_const_exprs` when stable to make generic around bits.
impl_uint_aliases! {
    (U64, 64, "64-bit"),
    (U128, 128, "128-bit"),
    (U192, 192, "192-bit"),
    (U256, 256, "256-bit"),
    (U320, 320, "320-bit"),
    (U384, 384, "384-bit"),
    (U448, 448, "448-bit"),
    (U512, 512, "512-bit"),
    (U576, 576, "576-bit"),
    (U640, 640, "640-bit"),
    (U704, 704, "704-bit"),
    (U768, 768, "768-bit"),
    (U832, 832, "832-bit"),
    (U896, 896, "896-bit"),
    (U960, 960, "960-bit"),
    (U1024, 1024, "1024-bit"),
    (U1280, 1280, "1280-bit"),
    (U1536, 1536, "1536-bit"),
    (U1792, 1792, "1792-bit"),
    (U2048, 2048, "2048-bit"),
    (U3072, 3072, "3072-bit"),
    (U3584, 3584, "3584-bit"),
    (U4096, 4096, "4096-bit"),
    (U4224, 4224, "4224-bit"),
    (U4352, 4352, "4352-bit"),
    (U6144, 6144, "6144-bit"),
    (U8192, 8192, "8192-bit"),
    (U16384, 16384, "16384-bit"),
    (U32768, 32768, "32768-bit")
}

#[cfg(target_pointer_width = "32")]
impl_uint_aliases! {
    (U224, 224, "224-bit"), // For NIST P-224
    (U544, 544, "544-bit")  // For NIST P-521
}

#[cfg(target_pointer_width = "32")]
impl_uint_concat_split_even! {
    U64,
}

// Implement concat and split for double-width Uint sizes: these should be
// multiples of 128 bits.
impl_uint_concat_split_even! {
    U128,
    U256,
    U384,
    U512,
    U640,
    U768,
    U896,
    U1024,
    U1280,
    U1536,
    U1792,
    U2048,
    U3072,
    U3584,
    U4096,
    U4224,
    U4352,
    U6144,
    U8192,
    U16384,
}

// Implement mixed concat, split and reduce for combinations not implemented by
// impl_uint_concat_split_even. The numbers represent the size of each
// component Uint in multiple of 64 bits. For example,
// (U256, [1, 3]) will allow splitting U256 into (U64, U192) as well as
// (U192, U64), while the (U128, U128) combination is already covered.
impl_uint_concat_split_mixed! {
    (U192, [1, 2]),
    (U256, [1, 3]),
    (U320, [1, 2, 3, 4]),
    (U384, [1, 2, 4, 5]),
    (U448, [1, 2, 3, 4, 5, 6]),
    (U512, [1, 2, 3, 5, 6, 7]),
    (U576, [1, 2, 3, 4, 5, 6, 7, 8]),
    (U640, [1, 2, 3, 4, 6, 7, 8, 9]),
    (U704, [1, 2, 3, 4, 5, 6, 7, 8, 9, 10]),
    (U768, [1, 2, 3, 4, 5, 7, 8, 9, 10, 11]),
    (U832, [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12]),
    (U896, [1, 2, 3, 4, 5, 6, 8, 9, 10, 11, 12, 13]),
    (U960, [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14]),
    (U1024, [1, 2, 3, 4, 5, 6, 7, 9, 10, 11, 12, 13, 14, 15]),
}

#[cfg(feature = "extra-sizes")]
mod extra_sizes;
mod mul_int;
mod ref_type;

#[cfg(test)]
#[allow(clippy::unwrap_used)]
mod tests {
    use crate::{Encoding, I128, Int, U128};
    use subtle::ConditionallySelectable;

    #[cfg(feature = "alloc")]
    use alloc::format;

    #[cfg(target_pointer_width = "64")]
    #[test]
    fn as_words() {
        let n = U128::from_be_hex("AAAAAAAABBBBBBBBCCCCCCCCDDDDDDDD");
        assert_eq!(n.as_words(), &[0xCCCCCCCCDDDDDDDD, 0xAAAAAAAABBBBBBBB]);
    }

    #[cfg(target_pointer_width = "64")]
    #[test]
    fn as_words_mut() {
        let mut n = U128::from_be_hex("AAAAAAAABBBBBBBBCCCCCCCCDDDDDDDD");
        assert_eq!(n.as_mut_words(), &[0xCCCCCCCCDDDDDDDD, 0xAAAAAAAABBBBBBBB]);
    }

    #[cfg(feature = "alloc")]
    #[test]
    fn debug() {
        let n = U128::from_be_hex("AAAAAAAABBBBBBBBCCCCCCCCDDDDDDDD");

        assert_eq!(format!("{n:?}"), "Uint(0xAAAAAAAABBBBBBBBCCCCCCCCDDDDDDDD)");
    }

    #[cfg(feature = "alloc")]
    #[test]
    fn display() {
        let hex = "AAAAAAAABBBBBBBBCCCCCCCCDDDDDDDD";
        let n = U128::from_be_hex(hex);

        use alloc::string::ToString;
        assert_eq!(hex, n.to_string());

        let hex = "AAAAAAAABBBBBBBB0000000000000000";
        let n = U128::from_be_hex(hex);
        assert_eq!(hex, n.to_string());

        let hex = "AAAAAAAABBBBBBBB00000000DDDDDDDD";
        let n = U128::from_be_hex(hex);
        assert_eq!(hex, n.to_string());

        let hex = "AAAAAAAABBBBBBBB0CCCCCCCDDDDDDDD";
        let n = U128::from_be_hex(hex);
        assert_eq!(hex, n.to_string());
    }

    #[cfg(feature = "alloc")]
    #[test]
    fn fmt_lower_hex() {
        let n = U128::from_be_hex("AAAAAAAABBBBBBBBCCCCCCCCDDDDDDDD");
        assert_eq!(format!("{n:x}"), "aaaaaaaabbbbbbbbccccccccdddddddd");
        assert_eq!(format!("{n:#x}"), "0xaaaaaaaabbbbbbbbccccccccdddddddd");
    }

    #[cfg(feature = "alloc")]
    #[test]
    fn fmt_lower_hex_from_trait() {
        fn format_int<T: crate::Integer>(n: T) -> alloc::string::String {
            format!("{n:x}")
        }
        let n = U128::from_be_hex("AAAAAAAABBBBBBBBCCCCCCCCDDDDDDDD");
        assert_eq!(format_int(n), "aaaaaaaabbbbbbbbccccccccdddddddd");
    }

    #[cfg(feature = "alloc")]
    #[test]
    fn fmt_upper_hex() {
        let n = U128::from_be_hex("aaaaaaaabbbbbbbbccccccccdddddddd");
        assert_eq!(format!("{n:X}"), "AAAAAAAABBBBBBBBCCCCCCCCDDDDDDDD");
        assert_eq!(format!("{n:#X}"), "0xAAAAAAAABBBBBBBBCCCCCCCCDDDDDDDD");
    }

    #[cfg(feature = "alloc")]
    #[test]
    fn fmt_upper_hex_from_trait() {
        fn format_int<T: crate::Integer>(n: T) -> alloc::string::String {
            format!("{n:X}")
        }
        let n = U128::from_be_hex("aaaaaaaabbbbbbbbccccccccdddddddd");
        assert_eq!(format_int(n), "AAAAAAAABBBBBBBBCCCCCCCCDDDDDDDD");
    }

    #[cfg(feature = "alloc")]
    #[test]
    fn fmt_binary() {
        let n = U128::from_be_hex("AAAAAAAABBBBBBBBCCCCCCCCDDDDDDDD");
        assert_eq!(
            format!("{n:b}"),
            "10101010101010101010101010101010101110111011101110111011101110111100110011001100110011001100110011011101110111011101110111011101"
        );
        assert_eq!(
            format!("{n:#b}"),
            "0b10101010101010101010101010101010101110111011101110111011101110111100110011001100110011001100110011011101110111011101110111011101"
        );
    }

    #[cfg(feature = "alloc")]
    #[test]
    fn fmt_binary_from_trait() {
        fn format_int<T: crate::Integer>(n: T) -> alloc::string::String {
            format!("{n:b}")
        }
        let n = U128::from_be_hex("aaaaaaaabbbbbbbbccccccccdddddddd");
        assert_eq!(
            format_int(n),
            "10101010101010101010101010101010101110111011101110111011101110111100110011001100110011001100110011011101110111011101110111011101"
        );
    }

    #[test]
    fn from_bytes() {
        let a = U128::from_be_hex("AAAAAAAABBBBBBBB0CCCCCCCDDDDDDDD");

        let be_bytes = a.to_be_bytes();
        let le_bytes = a.to_le_bytes();
        for i in 0..16 {
            assert_eq!(le_bytes[i], be_bytes[15 - i]);
        }

        let a_from_be = U128::from_be_bytes(be_bytes);
        let a_from_le = U128::from_le_bytes(le_bytes);
        assert_eq!(a_from_be, a_from_le);
        assert_eq!(a_from_be, a);
    }

    #[test]
    fn conditional_select() {
        let a = U128::from_be_hex("00002222444466668888AAAACCCCEEEE");
        let b = U128::from_be_hex("11113333555577779999BBBBDDDDFFFF");

        let select_0 = U128::conditional_select(&a, &b, 0.into());
        assert_eq!(a, select_0);

        let select_1 = U128::conditional_select(&a, &b, 1.into());
        assert_eq!(b, select_1);
    }

    #[test]
    fn as_int() {
        assert_eq!(*U128::ZERO.as_int(), Int::ZERO);
        assert_eq!(*U128::ONE.as_int(), Int::ONE);
        assert_eq!(*U128::MAX.as_int(), Int::MINUS_ONE);
    }

    #[test]
    fn to_int() {
        assert_eq!(U128::ZERO.try_into_int().unwrap(), Int::ZERO);
        assert_eq!(U128::ONE.try_into_int().unwrap(), Int::ONE);
        assert_eq!(I128::MAX.as_uint().try_into_int().unwrap(), Int::MAX);
        assert!(bool::from(U128::MAX.try_into_int().is_none()));
    }
}
