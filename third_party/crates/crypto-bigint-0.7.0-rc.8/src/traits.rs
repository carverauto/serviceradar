//! Traits provided by this crate

pub use num_traits::{
    ConstOne, ConstZero, WrappingAdd, WrappingMul, WrappingNeg, WrappingShl, WrappingShr,
    WrappingSub,
};

use crate::{Limb, NonZero, Odd, Reciprocal, modular::Retrieve};
use core::{
    fmt::{self, Debug},
    ops::{
        Add, AddAssign, BitAnd, BitAndAssign, BitOr, BitOrAssign, BitXor, BitXorAssign, Div,
        DivAssign, Mul, MulAssign, Neg, Not, Rem, RemAssign, Shl, ShlAssign, Shr, ShrAssign, Sub,
        SubAssign,
    },
};
use subtle::{
    Choice, ConditionallySelectable, ConstantTimeEq, ConstantTimeGreater, ConstantTimeLess,
    CtOption,
};

#[cfg(feature = "rand_core")]
use rand_core::{RngCore, TryRngCore};

/// Integers whose representation takes a bounded amount of space.
pub trait Bounded {
    /// Size of this integer in bits.
    const BITS: u32;

    /// Size of this integer in bytes.
    const BYTES: usize;
}

/// Trait for types which are conditionally selectable in constant time.
///
/// Similar to (and blanket impl'd for) `subtle`'s [`ConditionallySelectable`] trait, but without
/// the `Copy` bound which allows it to be impl'd for heap allocated types such as `BoxedUint`.
///
/// It also provides generic implementations of conditional assignment and conditional swaps.
pub trait ConstantTimeSelect: Clone {
    /// Select `a` or `b` according to `choice`.
    ///
    /// # Returns
    /// - `a` if `choice == Choice(0)`;
    /// - `b` if `choice == Choice(1)`.
    fn ct_select(a: &Self, b: &Self, choice: Choice) -> Self;

    /// Conditionally assign `other` to `self`, according to `choice`.
    #[inline]
    fn ct_assign(&mut self, other: &Self, choice: Choice) {
        *self = Self::ct_select(self, other, choice);
    }

    /// Conditionally swap `self` and `other` if `choice == 1`; otherwise, reassign both unto themselves.
    #[inline]
    fn ct_swap(a: &mut Self, b: &mut Self, choice: Choice) {
        let t: Self = a.clone();
        a.ct_assign(b, choice);
        b.ct_assign(&t, choice);
    }
}

impl<T: ConditionallySelectable> ConstantTimeSelect for T {
    #[inline(always)]
    fn ct_select(a: &Self, b: &Self, choice: Choice) -> Self {
        T::conditional_select(a, b, choice)
    }

    #[inline(always)]
    fn ct_assign(&mut self, other: &Self, choice: Choice) {
        self.conditional_assign(other, choice)
    }

    #[inline(always)]
    fn ct_swap(a: &mut Self, b: &mut Self, choice: Choice) {
        T::conditional_swap(a, b, choice)
    }
}

/// Integer trait: represents common functionality of integer types provided by this crate.
pub trait Integer:
    'static
    + Add<Output = Self>
    + for<'a> Add<&'a Self, Output = Self>
    + AddAssign<Self>
    + for<'a> AddAssign<&'a Self>
    + AsRef<[Limb]>
    + BitAnd<Output = Self>
    + for<'a> BitAnd<&'a Self, Output = Self>
    + BitAndAssign
    + for<'a> BitAndAssign<&'a Self>
    + BitOr<Output = Self>
    + for<'a> BitOr<&'a Self, Output = Self>
    + BitOrAssign
    + for<'a> BitOrAssign<&'a Self>
    + BitXor<Output = Self>
    + for<'a> BitXor<&'a Self, Output = Self>
    + BitXorAssign
    + for<'a> BitXorAssign<&'a Self>
    + CheckedAdd
    + CheckedSub
    + CheckedMul
    + CheckedDiv
    + Clone
    + ConstantTimeEq
    + ConstantTimeGreater
    + ConstantTimeLess
    + ConstantTimeSelect
    + Debug
    + Default
    + DivAssign<NonZero<Self>>
    + for<'a> DivAssign<&'a NonZero<Self>>
    + Eq
    + fmt::LowerHex
    + fmt::UpperHex
    + fmt::Binary
    + Mul<Output = Self>
    + for<'a> Mul<&'a Self, Output = Self>
    + MulAssign<Self>
    + for<'a> MulAssign<&'a Self>
    + Not<Output = Self>
    + One
    + Ord
    + Rem<NonZero<Self>, Output = Self>
    + for<'a> Rem<&'a NonZero<Self>, Output = Self>
    + RemAssign<NonZero<Self>>
    + for<'a> RemAssign<&'a NonZero<Self>>
    + Send
    + Sized
    + Shl<u32, Output = Self>
    + ShlAssign<u32>
    + ShlVartime
    + Shr<u32, Output = Self>
    + ShrAssign<u32>
    + ShrVartime
    + Sub<Output = Self>
    + for<'a> Sub<&'a Self, Output = Self>
    + SubAssign<Self>
    + for<'a> SubAssign<&'a Self>
    + Sync
    + WrappingAdd
    + WrappingSub
    + WrappingMul
    + WrappingNeg
    + WrappingShl
    + WrappingShr
    + Zero
{
    /// Number of limbs in this integer.
    fn nlimbs(&self) -> usize;

    /// Is this integer value an odd number?
    ///
    /// # Returns
    ///
    /// If odd, returns `Choice(1)`. Otherwise, returns `Choice(0)`.
    fn is_odd(&self) -> Choice {
        self.as_ref()
            .first()
            .map(|limb| limb.is_odd())
            .unwrap_or_else(|| Choice::from(0))
    }

    /// Is this integer value an even number?
    ///
    /// # Returns
    ///
    /// If even, returns `Choice(1)`. Otherwise, returns `Choice(0)`.
    fn is_even(&self) -> Choice {
        !self.is_odd()
    }
}

/// Signed [`Integer`]s.
pub trait Signed:
    Div<NonZero<Self>, Output = CtOption<Self>>
    + for<'a> Div<&'a NonZero<Self>, Output = CtOption<Self>>
    + From<i8>
    + From<i16>
    + From<i32>
    + From<i64>
    + Integer
{
    /// Corresponding unsigned integer type.
    type Unsigned: Unsigned;

    /// The sign and magnitude of this [`Signed`].
    fn abs_sign(&self) -> (Self::Unsigned, Choice);

    /// The magnitude of this [`Signed`].
    fn abs(&self) -> Self::Unsigned {
        self.abs_sign().0
    }

    /// Whether this [`Signed`] is negative (and non-zero), as a [`Choice`].
    fn is_negative(&self) -> Choice;

    /// Whether this [`Signed`] is positive (and non-zero), as a [`Choice`].
    fn is_positive(&self) -> Choice;
}

/// Unsigned [`Integer`]s.
pub trait Unsigned:
    AddMod<Output = Self>
    + BitOps
    + Div<NonZero<Self>, Output = Self>
    + for<'a> Div<&'a NonZero<Self>, Output = Self>
    + DivRemLimb
    + From<u8>
    + From<u16>
    + From<u32>
    + From<u64>
    + From<Limb>
    + Integer
    + MulMod<Output = Self>
    + NegMod<Output = Self>
    + RemLimb
    + SquareRoot
    + SquareMod<Output = Self>
    + SubMod<Output = Self>
{
    /// The corresponding Montgomery representation,
    /// optimized for the performance of modular operations at the price of a conversion overhead.
    type Monty: Monty<Integer = Self>;

    /// Returns an integer with the first limb set to `limb`, and the same precision as `other`.
    fn from_limb_like(limb: Limb, other: &Self) -> Self;
}

/// Zero values: additive identity element for `Self`.
pub trait Zero: ConstantTimeEq + Sized {
    /// Returns the additive identity element of `Self`, `0`.
    fn zero() -> Self;

    /// Determine if this value is equal to `0`.
    ///
    /// # Returns
    ///
    /// If zero, returns `Choice(1)`. Otherwise, returns `Choice(0)`.
    #[inline]
    fn is_zero(&self) -> Choice {
        self.ct_eq(&Self::zero())
    }

    /// Set `self` to its additive identity, i.e. `Self::zero`.
    #[inline]
    fn set_zero(&mut self) {
        *self = Zero::zero();
    }

    /// Return the value `0` with the same precision as `other`.
    fn zero_like(other: &Self) -> Self
    where
        Self: Clone,
    {
        let mut ret = other.clone();
        ret.set_zero();
        ret
    }
}

/// One values: multiplicative identity element for `Self`.
pub trait One: ConstantTimeEq + Sized {
    /// Returns the multiplicative identity element of `Self`, `1`.
    fn one() -> Self;

    /// Determine if this value is equal to `1`.
    ///
    /// # Returns
    ///
    /// If one, returns `Choice(1)`. Otherwise, returns `Choice(0)`.
    #[inline]
    fn is_one(&self) -> Choice {
        self.ct_eq(&Self::one())
    }

    /// Set `self` to its multiplicative identity, i.e. `Self::one`.
    #[inline]
    fn set_one(&mut self) {
        *self = One::one();
    }

    /// Return the value `0` with the same precision as `other`.
    fn one_like(other: &Self) -> Self
    where
        Self: Clone,
    {
        let mut ret = other.clone();
        ret.set_one();
        ret
    }
}

/// Trait for associating constant values with a type.
pub trait Constants: ConstZero + ConstOne {
    /// Maximum value this integer can express.
    const MAX: Self;
}

/// Fixed-width [`Integer`]s.
pub trait FixedInteger: Bounded + ConditionallySelectable + Constants + Copy + Integer {
    /// The number of limbs used on this platform.
    const LIMBS: usize;
}

/// Compute the greatest common divisor of two integers.
pub trait Gcd<Rhs = Self>: Sized {
    /// Output type.
    type Output;

    /// Compute the greatest common divisor of `self` and `rhs`.
    fn gcd(&self, rhs: &Rhs) -> Self::Output;

    /// Compute the greatest common divisor of `self` and `rhs` in variable time.
    fn gcd_vartime(&self, rhs: &Rhs) -> Self::Output;
}

/// Compute the extended greatest common divisor of two integers.
pub trait Xgcd<Rhs = Self>: Sized {
    /// Output type.
    type Output;

    /// Compute the extended greatest common divisor of `self` and `rhs`.
    fn xgcd(&self, rhs: &Rhs) -> Self::Output;

    /// Compute the extended greatest common divisor of `self` and `rhs` in variable time.
    fn xgcd_vartime(&self, rhs: &Rhs) -> Self::Output;
}

/// Random number generation support.
#[cfg(feature = "rand_core")]
pub trait Random: Sized {
    /// Generate a random value.
    ///
    /// If `rng` is a CSRNG, the generation is cryptographically secure as well.
    fn random<R: RngCore + ?Sized>(rng: &mut R) -> Self {
        let Ok(out) = Self::try_random(rng);
        out
    }

    /// Generate a random value.
    ///
    /// If `rng` is a CSRNG, the generation is cryptographically secure as well.
    fn try_random<R: TryRngCore + ?Sized>(rng: &mut R) -> Result<Self, R::Error>;
}

/// Possible errors of the methods in [`RandomBits`] trait.
#[cfg(feature = "rand_core")]
#[derive(Debug)]
pub enum RandomBitsError<T> {
    /// An error of the internal RNG library.
    RandCore(T),
    /// The requested `bits_precision` does not match the size of the integer
    /// corresponding to the type (in the cases where this is set in compile time).
    BitsPrecisionMismatch {
        /// The requested precision.
        bits_precision: u32,
        /// The compile-time size of the integer.
        integer_bits: u32,
    },
    /// The requested `bit_length` is larger than `bits_precision`.
    BitLengthTooLarge {
        /// The requested bit length of the random number.
        bit_length: u32,
        /// The requested precision.
        bits_precision: u32,
    },
}

#[cfg(feature = "rand_core")]
impl<T> fmt::Display for RandomBitsError<T>
where
    T: fmt::Display,
{
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::RandCore(err) => write!(f, "{err}"),
            Self::BitsPrecisionMismatch {
                bits_precision,
                integer_bits,
            } => write!(
                f,
                concat![
                    "The requested `bits_precision` ({}) does not match ",
                    "the size of the integer corresponding to the type ({})"
                ],
                bits_precision, integer_bits
            ),
            Self::BitLengthTooLarge {
                bit_length,
                bits_precision,
            } => write!(
                f,
                "The requested `bit_length` ({bit_length}) is larger than `bits_precision` ({bits_precision}).",
            ),
        }
    }
}

#[cfg(feature = "rand_core")]
impl<T> core::error::Error for RandomBitsError<T> where T: Debug + fmt::Display {}

/// Random bits generation support.
#[cfg(feature = "rand_core")]
pub trait RandomBits: Sized {
    /// Generate a random value in range `[0, 2^bit_length)`.
    ///
    /// A wrapper for [`RandomBits::try_random_bits`] that panics on error.
    fn random_bits<R: TryRngCore + ?Sized>(rng: &mut R, bit_length: u32) -> Self {
        Self::try_random_bits(rng, bit_length).expect("try_random_bits() failed")
    }

    /// Generate a random value in range `[0, 2^bit_length)`.
    ///
    /// This method is variable time wrt `bit_length`.
    ///
    /// If `rng` is a CSRNG, the generation is cryptographically secure as well.
    fn try_random_bits<R: TryRngCore + ?Sized>(
        rng: &mut R,
        bit_length: u32,
    ) -> Result<Self, RandomBitsError<R::Error>>;

    /// Generate a random value in range `[0, 2^bit_length)`,
    /// returning an integer with the closest available size to `bits_precision`
    /// (if the implementing type supports runtime sizing).
    ///
    /// A wrapper for [`RandomBits::try_random_bits_with_precision`] that panics on error.
    fn random_bits_with_precision<R: TryRngCore + ?Sized>(
        rng: &mut R,
        bit_length: u32,
        bits_precision: u32,
    ) -> Self {
        Self::try_random_bits_with_precision(rng, bit_length, bits_precision)
            .expect("try_random_bits_with_precision() failed")
    }

    /// Generate a random value in range `[0, 2^bit_length)`,
    /// returning an integer with the closest available size to `bits_precision`
    /// (if the implementing type supports runtime sizing).
    ///
    /// This method is variable time wrt `bit_length`.
    ///
    /// If `rng` is a CSRNG, the generation is cryptographically secure as well.
    fn try_random_bits_with_precision<R: TryRngCore + ?Sized>(
        rng: &mut R,
        bit_length: u32,
        bits_precision: u32,
    ) -> Result<Self, RandomBitsError<R::Error>>;
}

/// Modular random number generation support.
#[cfg(feature = "rand_core")]
pub trait RandomMod: Sized + Zero {
    /// Generate a random number which is less than a given `modulus`.
    ///
    /// This uses rejection sampling.
    ///
    /// As a result, it runs in variable time that depends in part on
    /// `modulus`. If the generator `rng` is cryptographically secure (for
    /// example, it implements `CryptoRng`), then this is guaranteed not to
    /// leak anything about the output value aside from it being less than
    /// `modulus`.
    fn random_mod<R: RngCore + ?Sized>(rng: &mut R, modulus: &NonZero<Self>) -> Self {
        let Ok(out) = Self::try_random_mod(rng, modulus);
        out
    }

    /// Generate a random number which is less than a given `modulus`.
    ///
    /// This uses rejection sampling.
    ///
    /// As a result, it runs in variable time that depends in part on
    /// `modulus`. If the generator `rng` is cryptographically secure (for
    /// example, it implements `CryptoRng`), then this is guaranteed not to
    /// leak anything about the output value aside from it being less than
    /// `modulus`.
    fn try_random_mod<R: TryRngCore + ?Sized>(
        rng: &mut R,
        modulus: &NonZero<Self>,
    ) -> Result<Self, R::Error>;
}

/// Compute `self + rhs mod p`.
pub trait AddMod<Rhs = Self, Mod = NonZero<Self>> {
    /// Output type.
    type Output;

    /// Compute `self + rhs mod p`.
    ///
    /// Assumes `self` and `rhs` are `< p`.
    fn add_mod(&self, rhs: &Rhs, p: &Mod) -> Self::Output;
}

/// Compute `self - rhs mod p`.
pub trait SubMod<Rhs = Self, Mod = NonZero<Self>> {
    /// Output type.
    type Output;

    /// Compute `self - rhs mod p`.
    ///
    /// Assumes `self` and `rhs` are `< p`.
    fn sub_mod(&self, rhs: &Rhs, p: &Mod) -> Self::Output;
}

/// Compute `-self mod p`.
pub trait NegMod<Mod = NonZero<Self>> {
    /// Output type.
    type Output;

    /// Compute `-self mod p`.
    #[must_use]
    fn neg_mod(&self, p: &Mod) -> Self::Output;
}

/// Compute `self * rhs mod p`.
pub trait MulMod<Rhs = Self, Mod = NonZero<Self>> {
    /// Output type.
    type Output;

    /// Compute `self * rhs mod p`.
    fn mul_mod(&self, rhs: &Rhs, p: &Mod) -> Self::Output;
}

/// Compute `self * self mod p`.
pub trait SquareMod<Mod = NonZero<Self>> {
    /// Output type.
    type Output;

    /// Compute `self * self mod p`.
    fn square_mod(&self, p: &Mod) -> Self::Output;
}

/// Compute `1 / self mod p`.
#[deprecated(since = "0.7.0", note = "please use `InvertMod` instead")]
pub trait InvMod<Rhs = Self>: Sized {
    /// Output type.
    type Output;

    /// Compute `1 / self mod p`.
    fn inv_mod(&self, p: &Rhs) -> CtOption<Self::Output>;
}

#[allow(deprecated)]
impl<T, Rhs> InvMod<Rhs> for T
where
    T: InvertMod<Rhs>,
{
    type Output = <T as InvertMod<Rhs>>::Output;

    fn inv_mod(&self, p: &Rhs) -> CtOption<Self::Output> {
        self.invert_mod(p)
    }
}

/// Compute `1 / self mod p`.
pub trait InvertMod<Mod = NonZero<Self>>: Sized {
    /// Output type.
    type Output;

    /// Compute `1 / self mod p`.
    fn invert_mod(&self, p: &Mod) -> CtOption<Self::Output>;
}

/// Checked addition.
pub trait CheckedAdd<Rhs = Self>: Sized {
    /// Perform checked addition, returning a [`CtOption`] which `is_some` only if the operation
    /// did not overflow.
    fn checked_add(&self, rhs: &Rhs) -> CtOption<Self>;
}

/// Checked division.
pub trait CheckedDiv<Rhs = Self>: Sized {
    /// Perform checked division, returning a [`CtOption`] which `is_some` only if the divisor is
    /// non-zero.
    fn checked_div(&self, rhs: &Rhs) -> CtOption<Self>;
}

/// Checked multiplication.
pub trait CheckedMul<Rhs = Self>: Sized {
    /// Perform checked multiplication, returning a [`CtOption`] which `is_some`
    /// only if the operation did not overflow.
    fn checked_mul(&self, rhs: &Rhs) -> CtOption<Self>;
}

/// Checked subtraction.
pub trait CheckedSub<Rhs = Self>: Sized {
    /// Perform checked subtraction, returning a [`CtOption`] which `is_some`
    /// only if the operation did not underflow.
    fn checked_sub(&self, rhs: &Rhs) -> CtOption<Self>;
}

/// Concatenate two numbers into a "wide" double-width value, using the `hi` value as the most
/// significant portion of the resulting value.
pub trait Concat: ConcatMixed<Self, MixedOutput = Self::Output> {
    /// Concatenated output: twice the width of `Self`.
    type Output: Integer;

    /// Concatenate the two halves, with `self` as least significant and `hi` as the most significant.
    fn concat(&self, hi: &Self) -> Self::Output {
        self.concat_mixed(hi)
    }
}

/// Concatenate two numbers into a "wide" combined-width value, using the `hi` value as the most
/// significant value.
pub trait ConcatMixed<Hi: ?Sized = Self> {
    /// Concatenated output: combination of `Self` and `Hi`.
    type MixedOutput: Integer;

    /// Concatenate the two values, with `self` as least significant and `hi` as the most
    /// significant.
    fn concat_mixed(&self, hi: &Hi) -> Self::MixedOutput;
}

/// Split a number in half, returning the least significant half followed by the most significant.
pub trait Split: SplitMixed<Self::Output, Self::Output> {
    /// Split output: low/high components of the value.
    type Output;

    /// Split this number in half, returning its low and high components respectively.
    fn split(&self) -> (Self::Output, Self::Output) {
        self.split_mixed()
    }
}

/// Split a number into parts, returning the least significant part followed by the most
/// significant.
pub trait SplitMixed<Lo, Hi> {
    /// Split this number into parts, returning its low and high components respectively.
    fn split_mixed(&self) -> (Lo, Hi);
}

/// Encoding support.
pub trait Encoding: Sized {
    /// Byte array representation.
    type Repr: AsRef<[u8]>
        + AsMut<[u8]>
        + Copy
        + Clone
        + Sized
        + for<'a> TryFrom<&'a [u8], Error = core::array::TryFromSliceError>;

    /// Decode from big endian bytes.
    fn from_be_bytes(bytes: Self::Repr) -> Self;

    /// Decode from little endian bytes.
    fn from_le_bytes(bytes: Self::Repr) -> Self;

    /// Encode to big endian bytes.
    fn to_be_bytes(&self) -> Self::Repr;

    /// Encode to little endian bytes.
    fn to_le_bytes(&self) -> Self::Repr;
}

/// Possible errors in variable-time integer decoding methods.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum DecodeError {
    /// The input value was empty.
    Empty,

    /// The input was not consistent with the format restrictions.
    InvalidDigit,

    /// Input size is too small to fit in the given precision.
    InputSize,

    /// The deserialized number is larger than the given precision.
    Precision,
}

impl fmt::Display for DecodeError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Empty => write!(f, "empty value provided"),
            Self::InvalidDigit => {
                write!(f, "invalid digit character")
            }
            Self::InputSize => write!(f, "input size is too small to fit in the given precision"),
            Self::Precision => write!(
                f,
                "the deserialized number is larger than the given precision"
            ),
        }
    }
}

impl core::error::Error for DecodeError {}

/// Support for optimized squaring
pub trait Square {
    /// Computes the same as `self * self`, but may be more efficient.
    fn square(&self) -> Self;
}

/// Support for optimized squaring in-place
pub trait SquareAssign {
    /// Computes the same as `self * self`, but may be more efficient.
    /// Writes the result in `self`.
    fn square_assign(&mut self);
}

/// Support for calucaling square roots.
pub trait SquareRoot {
    /// Computes `floor(sqrt(self))`.
    fn sqrt(&self) -> Self;

    /// Computes `floor(sqrt(self))`, variable time in `self`.
    fn sqrt_vartime(&self) -> Self;
}

/// Support for optimized division by a single limb.
pub trait DivRemLimb: Sized {
    /// Computes `self / rhs` using a pre-made reciprocal,
    /// returns the quotient (q) and remainder (r).
    fn div_rem_limb(&self, rhs: NonZero<Limb>) -> (Self, Limb) {
        self.div_rem_limb_with_reciprocal(&Reciprocal::new(rhs))
    }

    /// Computes `self / rhs`, returns the quotient (q) and remainder (r).
    fn div_rem_limb_with_reciprocal(&self, reciprocal: &Reciprocal) -> (Self, Limb);
}

/// Support for calculating the remainder of two differently sized integers.
pub trait RemMixed<Reductor>: Sized {
    /// Calculate the remainder of `self` by the `reductor`.
    fn rem_mixed(&self, reductor: &NonZero<Reductor>) -> Reductor;
}

/// Modular reduction from a larger value `T`.
///
/// This can be seen as fixed modular reduction, where the modulus is fixed at compile time
/// by `Self`.
///
/// For modular reduction with a variable modulus, use [`Rem`].
pub trait Reduce<T>: Sized {
    /// Reduces `self` modulo `Modulus`.
    fn reduce(value: &T) -> Self;
}

/// Division in variable time.
pub trait DivVartime: Sized {
    /// Computes `self / rhs` in variable time.
    fn div_vartime(&self, rhs: &NonZero<Self>) -> Self;
}

/// Support for optimized division by a single limb.
pub trait RemLimb: Sized {
    /// Computes `self % rhs` using a pre-made reciprocal.
    fn rem_limb(&self, rhs: NonZero<Limb>) -> Limb {
        self.rem_limb_with_reciprocal(&Reciprocal::new(rhs))
    }

    /// Computes `self % rhs`.
    fn rem_limb_with_reciprocal(&self, reciprocal: &Reciprocal) -> Limb;
}

/// Bit counting and bit operations.
pub trait BitOps {
    /// Precision of this integer in bits.
    fn bits_precision(&self) -> u32;

    /// `floor(log2(self.bits_precision()))`.
    fn log2_bits(&self) -> u32 {
        u32::BITS - self.bits_precision().leading_zeros() - 1
    }

    /// Precision of this integer in bytes.
    fn bytes_precision(&self) -> usize;

    /// Get the value of the bit at position `index`, as a truthy or falsy `Choice`.
    /// Returns the falsy value for indices out of range.
    fn bit(&self, index: u32) -> Choice;

    /// Sets the bit at `index` to 0 or 1 depending on the value of `bit_value`.
    fn set_bit(&mut self, index: u32, bit_value: Choice);

    /// Calculate the number of bits required to represent a given number.
    fn bits(&self) -> u32 {
        self.bits_precision() - self.leading_zeros()
    }

    /// Calculate the number of trailing zeros in the binary representation of this number.
    fn trailing_zeros(&self) -> u32;

    /// Calculate the number of trailing ones in the binary representation of this number.
    fn trailing_ones(&self) -> u32;

    /// Calculate the number of leading zeros in the binary representation of this number.
    fn leading_zeros(&self) -> u32;

    /// Returns `true` if the bit at position `index` is set, `false` otherwise.
    ///
    /// # Remarks
    /// This operation is variable time with respect to `index` only.
    fn bit_vartime(&self, index: u32) -> bool;

    /// Calculate the number of bits required to represent a given number in variable-time with
    /// respect to `self`.
    fn bits_vartime(&self) -> u32;

    /// Sets the bit at `index` to 0 or 1 depending on the value of `bit_value`,
    /// variable time in `self`.
    fn set_bit_vartime(&mut self, index: u32, bit_value: bool);

    /// Calculate the number of leading zeros in the binary representation of this number.
    fn leading_zeros_vartime(&self) -> u32 {
        self.bits_precision() - self.bits_vartime()
    }

    /// Calculate the number of trailing zeros in the binary representation of this number in
    /// variable-time with respect to `self`.
    fn trailing_zeros_vartime(&self) -> u32;

    /// Calculate the number of trailing ones in the binary representation of this number,
    /// variable time in `self`.
    fn trailing_ones_vartime(&self) -> u32;
}

/// Constant-time exponentiation.
pub trait Pow<Exponent> {
    /// Raises to the `exponent` power.
    fn pow(&self, exponent: &Exponent) -> Self;
}

impl<T: PowBoundedExp<Exponent>, Exponent: Bounded> Pow<Exponent> for T {
    fn pow(&self, exponent: &Exponent) -> Self {
        self.pow_bounded_exp(exponent, Exponent::BITS)
    }
}

/// Constant-time exponentiation with exponent of a bounded bit size.
pub trait PowBoundedExp<Exponent> {
    /// Raises to the `exponent` power,
    /// with `exponent_bits` representing the number of (least significant) bits
    /// to take into account for the exponent.
    ///
    /// NOTE: `exponent_bits` may be leaked in the time pattern.
    fn pow_bounded_exp(&self, exponent: &Exponent, exponent_bits: u32) -> Self;
}

/// Performs modular multi-exponentiation using Montgomery's ladder.
///
/// See: Straus, E. G. Problems and solutions: Addition chains of vectors. American Mathematical Monthly 71 (1964), 806–808.
pub trait MultiExponentiate<Exponent, BasesAndExponents>: Pow<Exponent> + Sized
where
    BasesAndExponents: AsRef<[(Self, Exponent)]> + ?Sized,
{
    /// Calculates `x1 ^ k1 * ... * xn ^ kn`.
    fn multi_exponentiate(bases_and_exponents: &BasesAndExponents) -> Self;
}

impl<T, Exponent, BasesAndExponents> MultiExponentiate<Exponent, BasesAndExponents> for T
where
    T: MultiExponentiateBoundedExp<Exponent, BasesAndExponents>,
    Exponent: Bounded,
    BasesAndExponents: AsRef<[(Self, Exponent)]> + ?Sized,
{
    fn multi_exponentiate(bases_and_exponents: &BasesAndExponents) -> Self {
        Self::multi_exponentiate_bounded_exp(bases_and_exponents, Exponent::BITS)
    }
}

/// Performs modular multi-exponentiation using Montgomery's ladder.
/// `exponent_bits` represents the number of bits to take into account for the exponent.
///
/// See: Straus, E. G. Problems and solutions: Addition chains of vectors. American Mathematical Monthly 71 (1964), 806–808.
///
/// NOTE: this value is leaked in the time pattern.
pub trait MultiExponentiateBoundedExp<Exponent, BasesAndExponents>: Pow<Exponent> + Sized
where
    BasesAndExponents: AsRef<[(Self, Exponent)]> + ?Sized,
{
    /// Calculates `x1 ^ k1 * ... * xn ^ kn`.
    fn multi_exponentiate_bounded_exp(
        bases_and_exponents: &BasesAndExponents,
        exponent_bits: u32,
    ) -> Self;
}

/// Constant-time inversion.
pub trait Invert {
    /// Output of the inversion.
    type Output;

    /// Computes the inverse.
    fn invert(&self) -> Self::Output;

    /// Computes the inverse in variable-time.
    fn invert_vartime(&self) -> Self::Output {
        self.invert()
    }
}

/// Widening multiply: returns a value with a number of limbs equal to the sum of the inputs.
#[deprecated(since = "0.7.0", note = "please use `ConcatenatingMul` instead")]
pub trait WideningMul<Rhs = Self>: Sized {
    /// Output of the widening multiplication.
    type Output: Integer;

    /// Perform widening multiplication.
    fn widening_mul(&self, rhs: Rhs) -> Self::Output;
}

#[allow(deprecated)]
impl<T, Rhs> WideningMul<Rhs> for T
where
    T: ConcatenatingMul<Rhs>,
{
    type Output = <T as ConcatenatingMul<Rhs>>::Output;

    fn widening_mul(&self, rhs: Rhs) -> Self::Output {
        self.concatenating_mul(rhs)
    }
}

/// Widening multiply: returns a value with a number of limbs equal to the sum of the inputs.
pub trait ConcatenatingMul<Rhs = Self>: Sized {
    /// Output of the widening multiplication.
    type Output: Integer;

    /// Perform widening multiplication.
    fn concatenating_mul(&self, rhs: Rhs) -> Self::Output;
}

/// Left shifts, variable time in `shift`.
pub trait ShlVartime: Sized {
    /// Computes `self << shift`.
    ///
    /// Returns `None` if `shift >= self.bits_precision()`.
    fn overflowing_shl_vartime(&self, shift: u32) -> CtOption<Self>;

    /// Computes `self << shift` in a panic-free manner, masking off bits of `shift`
    /// which would cause the shift to exceed the type's width.
    fn wrapping_shl_vartime(&self, shift: u32) -> Self;
}

/// Right shifts, variable time in `shift`.
pub trait ShrVartime: Sized {
    /// Computes `self >> shift`.
    ///
    /// Returns `None` if `shift >= self.bits_precision()`.
    fn overflowing_shr_vartime(&self, shift: u32) -> CtOption<Self>;

    /// Computes `self >> shift` in a panic-free manner, masking off bits of `shift`
    /// which would cause the shift to exceed the type's width.
    fn wrapping_shr_vartime(&self, shift: u32) -> Self;
}

/// Methods for resizing the allocated storage.
pub trait Resize: Sized {
    /// The result of the resizing.
    type Output;

    /// Resizes to the minimum storage that fits `at_least_bits_precision`
    /// without checking if the bit size of `self` is larger than `at_least_bits_precision`.
    ///
    /// Variable-time w.r.t. `at_least_bits_precision`.
    fn resize_unchecked(self, at_least_bits_precision: u32) -> Self::Output;

    /// Resizes to the minimum storage that fits `at_least_bits_precision`
    /// returning `None` if the bit size of `self` is larger than `at_least_bits_precision`.
    ///
    /// Variable-time w.r.t. `at_least_bits_precision`.
    fn try_resize(self, at_least_bits_precision: u32) -> Option<Self::Output>;

    /// Resizes to the minimum storage that fits `at_least_bits_precision`
    /// panicking if the bit size of `self` is larger than `at_least_bits_precision`.
    ///
    /// Variable-time w.r.t. `at_least_bits_precision`.
    fn resize(self, at_least_bits_precision: u32) -> Self::Output {
        self.try_resize(at_least_bits_precision).unwrap_or_else(|| {
            panic!("The bit size of `self` is larger than `at_least_bits_precision`")
        })
    }
}

/// A representation of an integer optimized for the performance of modular operations.
pub trait Monty:
    'static
    + Clone
    + Debug
    + Eq
    + Sized
    + Send
    + Sync
    + Add<Output = Self>
    + for<'a> Add<&'a Self, Output = Self>
    + AddAssign
    + for<'a> AddAssign<&'a Self>
    + Sub<Output = Self>
    + for<'a> Sub<&'a Self, Output = Self>
    + SubAssign
    + for<'a> SubAssign<&'a Self>
    + Mul<Output = Self>
    + for<'a> Mul<&'a Self, Output = Self>
    + MulAssign
    + for<'a> MulAssign<&'a Self>
    + Neg<Output = Self>
    + PowBoundedExp<Self::Integer>
    + Retrieve<Output = Self::Integer>
    + Square
    + SquareAssign
{
    /// The original integer type.
    type Integer: Unsigned<Monty = Self>;

    /// Prepared Montgomery multiplier for tight loops.
    type Multiplier<'a>: Debug + Clone + MontyMultiplier<'a, Monty = Self>;

    /// The precomputed data needed for this representation.
    type Params: 'static + Clone + Debug + Eq + Sized + Send + Sync;

    /// Create the precomputed data for Montgomery representation of integers modulo `modulus`,
    /// variable time in `modulus`.
    fn new_params_vartime(modulus: Odd<Self::Integer>) -> Self::Params;

    /// Convert the value into the representation using precomputed data.
    fn new(value: Self::Integer, params: Self::Params) -> Self;

    /// Returns zero in this representation.
    fn zero(params: Self::Params) -> Self;

    /// Returns one in this representation.
    fn one(params: Self::Params) -> Self;

    /// Returns the parameter struct used to initialize this object.
    fn params(&self) -> &Self::Params;

    /// Access the value in Montgomery form.
    fn as_montgomery(&self) -> &Self::Integer;

    /// Copy the Montgomery representation from `other` into `self`.
    /// NOTE: the parameters remain unchanged.
    fn copy_montgomery_from(&mut self, other: &Self);

    /// Performs doubling, returning `self + self`.
    fn double(&self) -> Self;

    /// Performs division by 2, that is returns `x` such that `x + x = self`.
    fn div_by_2(&self) -> Self;

    /// Performs division by 2 inplace, that is finds `x` such that `x + x = self`
    /// and writes it into `self`.
    fn div_by_2_assign(&mut self) {
        *self = self.div_by_2()
    }

    /// Calculate the sum of products of pairs `(a, b)` in `products`.
    ///
    /// This method is variable time only with the value of the modulus.
    /// For a modulus with leading zeros, this method is more efficient than a naive sum of products.
    ///
    /// This method will panic if `products` is empty. All terms must be associated with equivalent
    /// Montgomery parameters.
    fn lincomb_vartime(products: &[(&Self, &Self)]) -> Self;
}

/// Prepared Montgomery multiplier for tight loops.
///
/// Allows one to perform inplace multiplication without allocations
/// (important for the `BoxedUint` case).
///
/// NOTE: You will be operating with Montgomery representations directly,
/// make sure they all correspond to the same set of parameters.
pub trait MontyMultiplier<'a>: From<&'a <Self::Monty as Monty>::Params> {
    /// The associated Montgomery-representation integer.
    type Monty: Monty;

    /// Performs a Montgomery multiplication, assigning a fully reduced result to `lhs`.
    fn mul_assign(&mut self, lhs: &mut Self::Monty, rhs: &Self::Monty);

    /// Performs a Montgomery squaring, assigning a fully reduced result to `lhs`.
    fn square_assign(&mut self, lhs: &mut Self::Monty);
}
