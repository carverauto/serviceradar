use crate::{CtAssign, CtAssignSlice, CtEq, CtEqSlice, CtSelectUsingCtAssign};
use core::ops::{BitAnd, BitAndAssign, BitOr, BitOrAssign, BitXor, BitXorAssign, Not};

#[cfg(feature = "subtle")]
use crate::CtSelect;

/// Bitwise less-than-or equal: returns `1` if `x <= y`, and otherwise returns `0`.
///
/// See "Hacker's Delight" 2nd edition, section 2-12 (Comparison predicates)
macro_rules! bitle {
    ($x:expr, $y:expr, $bits:expr) => {
        (((!$x) | $y) & (($x ^ $y) | !($y.wrapping_sub($x)))) >> ($bits - 1)
    };
}

/// Bitwise less-than: returns `1` if `x < y`, and otherwise returns `0`.
///
/// See "Hacker's Delight" 2nd edition, section 2-12 (Comparison predicates)
macro_rules! bitlt {
    ($x:expr, $y:expr, $bits:expr) => {
        (((!$x) & $y) | (((!$x) | $y) & $x.wrapping_sub($y))) >> ($bits - 1)
    };
}

/// Bitwise non-zero: returns `1` if `x != 0`, and otherwise returns `0`.
macro_rules! bitnz {
    ($value:expr, $bits:expr) => {
        ($value | $value.wrapping_neg()) >> ($bits - 1)
    };
}

/// Constant-time analogue of `bool` providing a "best effort" optimization barrier.
///
/// This type attempts to hint to the compiler and its codegen backends that optimizations should
/// not be applied which depend on specific values of this type.
///
/// This is used as a "belt-and-suspenders" defense in addition to mechanisms like
/// constant-time predication intrinsics provided by the [`cmov`] crate, and is never expected to be
/// the only line of defense.
// NOTE: we deliberately do NOT impl `Eq`, `Hash`, `PartialEq`, etc. See #1315
#[derive(Copy, Clone, Debug)]
pub struct Choice(pub(crate) u8);

impl Choice {
    /// Equivalent of [`false`].
    pub const FALSE: Self = Self(0);

    /// Equivalent of [`true`].
    pub const TRUE: Self = Self(1);

    //
    // `const fn` bitwise ops
    //

    /// Apply an `and` conditional to the given [`Choice`]s.
    #[inline]
    #[must_use]
    pub const fn and(self, rhs: Choice) -> Choice {
        Self(self.0 & rhs.0)
    }

    /// Apply an `or` conditional to the given [`Choice`]s.
    #[inline]
    #[must_use]
    pub const fn or(self, rhs: Choice) -> Choice {
        Self(self.0 | rhs.0)
    }

    /// Apply an `xor` conditional to the given [`Choice`]s.
    #[inline]
    #[must_use]
    pub const fn xor(self, rhs: Choice) -> Choice {
        Self(self.0 ^ rhs.0)
    }

    /// Compute the boolean inverse of `self`.
    #[inline]
    #[must_use]
    pub const fn not(self) -> Choice {
        // NOTE: assumes self.0 is `0` or `1` as checked in constructor
        Self(self.0 ^ 1)
    }

    //
    // `const fn` comparison ops
    //

    /// `const fn` equality operation.
    #[inline]
    #[must_use]
    pub const fn eq(self, other: Self) -> Self {
        Self::ne(self, other).not()
    }

    /// `const fn` not equal operation.
    #[inline]
    #[must_use]
    pub const fn ne(self, other: Self) -> Self {
        Self::xor(self, other)
    }

    //
    // `const fn` constructor methods
    //

    // i64

    /// Returns [`Choice::TRUE`] if `x == y`, and [`Choice::FALSE`] otherwise.
    #[inline]
    #[must_use]
    #[allow(clippy::cast_sign_loss)]
    pub const fn from_i64_eq(x: i64, y: i64) -> Self {
        // TODO(tarcieri): use `cast_unsigned` when MSRV is 1.87
        Self::from_u64_nz(x as u64 ^ y as u64).not()
    }

    // u8

    /// Returns [`Choice::TRUE`] if `x == y`, and [`Choice::FALSE`] otherwise.
    #[inline]
    #[must_use]
    pub const fn from_u8_eq(x: u8, y: u8) -> Self {
        Self::from_u8_nz(x ^ y).not()
    }

    /// Returns [`Choice::TRUE`] if `x <= y` and [`Choice::FALSE`] otherwise.
    #[inline]
    #[must_use]
    pub const fn from_u8_le(x: u8, y: u8) -> Self {
        Self::from_u8_lsb(bitle!(x, y, u8::BITS))
    }

    /// Initialize from the least significant bit of a `u8`.
    #[inline]
    #[must_use]
    pub const fn from_u8_lsb(value: u8) -> Self {
        Self(value & 0x1)
    }

    /// Returns [`Choice::TRUE`] if `x < y`, and [`Choice::FALSE`] otherwise.
    #[inline]
    #[must_use]
    pub const fn from_u8_lt(x: u8, y: u8) -> Self {
        Self::from_u8_lsb(bitlt!(x, y, u8::BITS))
    }

    /// Returns [`Choice::TRUE`] if `value != 0`, and [`Choice::FALSE`] otherwise.
    #[inline]
    #[must_use]
    pub const fn from_u8_nz(value: u8) -> Self {
        Self::from_u8_lsb(bitnz!(value, u8::BITS))
    }

    // u16

    /// Returns [`Choice::TRUE`] if `x == y`, and [`Choice::FALSE`] otherwise.
    #[inline]
    #[must_use]
    pub const fn from_u16_eq(x: u16, y: u16) -> Self {
        Self::from_u16_nz(x ^ y).not()
    }

    /// Returns [`Choice::TRUE`] if `x <= y` and [`Choice::FALSE`] otherwise.
    #[inline]
    #[must_use]
    pub const fn from_u16_le(x: u16, y: u16) -> Self {
        Self::from_u16_lsb(bitle!(x, y, u16::BITS))
    }

    /// Initialize from the least significant bit of a `u16`.
    #[inline]
    #[must_use]
    pub const fn from_u16_lsb(value: u16) -> Self {
        Self((value & 0x1) as u8)
    }

    /// Returns [`Choice::TRUE`] if `x < y`, and [`Choice::FALSE`] otherwise.
    #[inline]
    #[must_use]
    pub const fn from_u16_lt(x: u16, y: u16) -> Self {
        Self::from_u16_lsb(bitlt!(x, y, u16::BITS))
    }

    /// Returns [`Choice::TRUE`] if `value != 0`, and [`Choice::FALSE`] otherwise.
    #[inline]
    #[must_use]
    pub const fn from_u16_nz(value: u16) -> Self {
        Self::from_u16_lsb(bitnz!(value, u16::BITS))
    }

    // u32

    /// Returns [`Choice::TRUE`] if `x == y`, and [`Choice::FALSE`] otherwise.
    #[inline]
    #[must_use]
    pub const fn from_u32_eq(x: u32, y: u32) -> Self {
        Self::from_u32_nz(x ^ y).not()
    }

    /// Returns [`Choice::TRUE`] if `x <= y` and [`Choice::FALSE`] otherwise.
    #[inline]
    #[must_use]
    pub const fn from_u32_le(x: u32, y: u32) -> Self {
        Self::from_u32_lsb(bitle!(x, y, u32::BITS))
    }

    /// Initialize from the least significant bit of a `u32`.
    #[inline]
    #[must_use]
    pub const fn from_u32_lsb(value: u32) -> Self {
        Self((value & 0x1) as u8)
    }

    /// Returns [`Choice::TRUE`] if `x < y`, and [`Choice::FALSE`] otherwise.
    #[inline]
    #[must_use]
    pub const fn from_u32_lt(x: u32, y: u32) -> Self {
        Self::from_u32_lsb(bitlt!(x, y, u32::BITS))
    }

    /// Returns [`Choice::TRUE`] if `value != 0`, and [`Choice::FALSE`] otherwise.
    #[inline]
    #[must_use]
    pub const fn from_u32_nz(value: u32) -> Self {
        Self::from_u32_lsb(bitnz!(value, u32::BITS))
    }

    // u64

    /// Returns [`Choice::TRUE`] if `x == y`, and [`Choice::FALSE`] otherwise.
    #[inline]
    #[must_use]
    pub const fn from_u64_eq(x: u64, y: u64) -> Self {
        Self::from_u64_nz(x ^ y).not()
    }

    /// Returns [`Choice::TRUE`] if `x <= y` and [`Choice::FALSE`] otherwise.
    #[inline]
    #[must_use]
    pub const fn from_u64_le(x: u64, y: u64) -> Self {
        Self::from_u64_lsb(bitle!(x, y, u64::BITS))
    }

    /// Initialize from the least significant bit of a `u64`.
    #[inline]
    #[must_use]
    pub const fn from_u64_lsb(value: u64) -> Self {
        Self((value & 0x1) as u8)
    }

    /// Returns [`Choice::TRUE`] if `x < y`, and [`Choice::FALSE`] otherwise.
    #[inline]
    #[must_use]
    pub const fn from_u64_lt(x: u64, y: u64) -> Self {
        Self::from_u64_lsb(bitlt!(x, y, u64::BITS))
    }

    /// Returns [`Choice::TRUE`] if `value != 0`, and [`Choice::FALSE`] otherwise.
    #[inline]
    #[must_use]
    pub const fn from_u64_nz(value: u64) -> Self {
        Self::from_u64_lsb(bitnz!(value, u64::BITS))
    }

    // u128

    /// Returns [`Choice::TRUE`] if `x == y`, and [`Choice::FALSE`] otherwise.
    #[inline]
    #[must_use]
    pub const fn from_u128_eq(x: u128, y: u128) -> Self {
        Self::from_u128_nz(x ^ y).not()
    }

    /// Returns [`Choice::TRUE`] if `x <= y` and [`Choice::FALSE`] otherwise.
    #[inline]
    #[must_use]
    pub const fn from_u128_le(x: u128, y: u128) -> Self {
        Self::from_u128_lsb(bitle!(x, y, u128::BITS))
    }

    /// Initialize from the least significant bit of a `u128`.
    #[inline]
    #[must_use]
    pub const fn from_u128_lsb(value: u128) -> Self {
        Self((value & 1) as u8)
    }

    /// Returns [`Choice::TRUE`] if `x < y`, and [`Choice::FALSE`] otherwise.
    #[inline]
    #[must_use]
    pub const fn from_u128_lt(x: u128, y: u128) -> Self {
        Self::from_u128_lsb(bitlt!(x, y, u128::BITS))
    }

    /// Returns [`Choice::TRUE`] if `value != 0`, and [`Choice::FALSE`] otherwise.
    #[inline]
    #[must_use]
    pub const fn from_u128_nz(value: u128) -> Self {
        Self::from_u128_lsb(bitnz!(value, u128::BITS))
    }

    //
    // `const fn` predication methods
    //

    /// `const fn` helper: return `b` if `self` is [`Choice::TRUE`], otherwise return `a`.
    ///
    /// Only use this instead of the [`CtSelect`] trait in the event you're in a `const fn` context
    /// and can't use the trait. The former will provide better constant-time assurances.
    #[inline]
    #[must_use]
    #[allow(clippy::cast_possible_wrap, clippy::cast_sign_loss)]
    pub const fn select_i64(self, a: i64, b: i64) -> i64 {
        // TODO(tarcieri): use `cast_signed` when MSRV is 1.87
        self.select_u64(a as u64, b as u64) as i64
    }

    /// `const fn` helper: return `b` if `self` is [`Choice::TRUE`], otherwise return `a`.
    ///
    /// Only use this instead of the [`CtSelect`] trait in the event you're in a `const fn` context
    /// and can't use the trait. The former will provide better constant-time assurances.
    #[inline]
    #[must_use]
    pub const fn select_u8(self, a: u8, b: u8) -> u8 {
        a ^ (self.to_u8_mask() & (a ^ b))
    }

    /// `const fn` helper: return `b` if `self` is [`Choice::TRUE`], otherwise return `a`.
    ///
    /// Only use this instead of the [`CtSelect`] trait in the event you're in a `const fn` context
    /// and can't use the trait. The former will provide better constant-time assurances.
    #[inline]
    #[must_use]
    pub const fn select_u16(self, a: u16, b: u16) -> u16 {
        a ^ (self.to_u16_mask() & (a ^ b))
    }

    /// `const fn` helper: return `b` if `self` is [`Choice::TRUE`], otherwise return `a`.
    ///
    /// Only use this instead of the [`CtSelect`] trait in the event you're in a `const fn` context
    /// and can't use the trait. The former will provide better constant-time assurances.
    #[inline]
    #[must_use]
    pub const fn select_u32(self, a: u32, b: u32) -> u32 {
        a ^ (self.to_u32_mask() & (a ^ b))
    }

    /// `const fn` helper: return `b` if `self` is [`Choice::TRUE`], otherwise return `a`.
    ///
    /// Only use this instead of the [`CtSelect`] trait in the event you're in a `const fn` context
    /// and can't use the trait. The former will provide better constant-time assurances.
    #[inline]
    #[must_use]
    pub const fn select_u64(self, a: u64, b: u64) -> u64 {
        a ^ (self.to_u64_mask() & (a ^ b))
    }

    /// `const fn` helper: return `b` if `self` is [`Choice::TRUE`], otherwise return `a`.
    ///
    /// Only use this instead of the [`CtSelect`] trait in the event you're in a `const fn` context
    /// and can't use the trait. The former will provide better constant-time assurances.
    #[inline]
    #[must_use]
    pub const fn select_u128(self, a: u128, b: u128) -> u128 {
        a ^ (self.to_u128_mask() & (a ^ b))
    }

    //
    // Output conversion methods
    //

    /// Convert `Choice` into a `bool`.
    ///
    /// <div class = "warning">
    /// <b>Security Warning</b>
    ///
    /// Using this function will introduce timing variability, since computing this at all currently
    /// requires a branch.
    ///
    /// This is intended to be used as either the one and only branch at the end of a constant-time
    /// operation to e.g. differentiate between success and failure, or in contexts where
    /// constant-time doesn't matter, e.g. variable-time code that operates on "maybe secret" types
    /// which aren't secrets in a particular context.
    ///
    /// If you are trying to use this in the context of a constant-time operation, be warned that
    /// the small amount of timing variability it introduces can potentially be exploited. Whenever
    /// possible, prefer fully constant-time approaches instead.
    /// </div>
    // TODO(tarcieri): `const fn` when MSRV 1.86
    #[must_use]
    pub fn to_bool(self) -> bool {
        self.to_u8() != 0
    }

    /// Convert [`Choice`] to a `u8`, attempting to apply a "best effort" optimization barrier.
    // TODO(tarcieri): `const fn` when MSRV 1.86
    #[must_use]
    pub fn to_u8(self) -> u8 {
        // `black_box` is documented as working on a "best effort" basis. That's fine, this type is
        // likewise documented as only working on a "best effort" basis itself. The only way we
        // rely on `black_box` for correctness is it behaving as the identity function.
        core::hint::black_box(self.0)
    }

    /// HACK: workaround to allow `const fn` boolean support on Rust 1.85.
    ///
    /// This does not apply `black_box` to the output.
    ///
    /// <div class = "warning">
    /// <b>Security Warning</b>
    ///
    /// See the security warnings for [`Choice::to_bool`].
    /// </div>
    // TODO(tarcieri): deprecate/remove this in favor of `to_bool` when MSRV is Rust 1.86
    #[must_use]
    pub const fn to_bool_vartime(self) -> bool {
        self.0 != 0
    }

    /// HACK: workaround to allow `const fn` boolean support on Rust 1.85.
    ///
    /// This does not apply `black_box` to the output.
    // TODO(tarcieri): deprecate/remove this in favor of `to_u8` when MSRV is Rust 1.86
    #[must_use]
    pub const fn to_u8_vartime(self) -> u8 {
        self.0
    }

    /// Create a `u8` bitmask.
    ///
    /// # Returns
    /// - `0` for `Choice::FALSE`
    /// - `u8::MAX` for `Choice::TRUE`
    #[inline]
    #[must_use]
    pub const fn to_u8_mask(self) -> u8 {
        self.0.wrapping_neg()
    }

    /// Create a `u16` bitmask.
    ///
    /// # Returns
    /// - `0` for `Choice::FALSE`
    /// - `u16::MAX` for `Choice::TRUE`
    #[inline]
    #[must_use]
    pub const fn to_u16_mask(self) -> u16 {
        (self.0 as u16).wrapping_neg()
    }

    /// Create a `u32` bitmask.
    ///
    /// # Returns
    /// - `0` for `Choice::FALSE`
    /// - `u32::MAX` for `Choice::TRUE`
    #[inline]
    #[must_use]
    pub const fn to_u32_mask(self) -> u32 {
        (self.0 as u32).wrapping_neg()
    }

    /// Create a `u64` bitmask.
    ///
    /// # Returns
    /// - `0` for `Choice::FALSE`
    /// - `u64::MAX` for `Choice::TRUE`
    #[inline]
    #[must_use]
    pub const fn to_u64_mask(self) -> u64 {
        (self.0 as u64).wrapping_neg()
    }

    /// Create a `u128` bitmask.
    ///
    /// # Returns
    /// - `0` for `Choice::FALSE`
    /// - `u128::MAX` for `Choice::TRUE`
    #[inline]
    #[must_use]
    pub const fn to_u128_mask(self) -> u128 {
        (self.0 as u128).wrapping_neg()
    }
}

impl BitAnd for Choice {
    type Output = Choice;

    #[inline]
    fn bitand(self, rhs: Choice) -> Choice {
        self.and(rhs)
    }
}

impl BitAndAssign for Choice {
    #[inline]
    fn bitand_assign(&mut self, rhs: Choice) {
        *self = *self & rhs;
    }
}

impl BitOr for Choice {
    type Output = Choice;

    #[inline]
    fn bitor(self, rhs: Choice) -> Choice {
        self.or(rhs)
    }
}

impl BitOrAssign for Choice {
    #[inline]
    fn bitor_assign(&mut self, rhs: Choice) {
        *self = *self | rhs;
    }
}

impl BitXor for Choice {
    type Output = Choice;

    #[inline]
    fn bitxor(self, rhs: Choice) -> Choice {
        Choice(self.0 ^ rhs.0)
    }
}

impl BitXorAssign for Choice {
    #[inline]
    fn bitxor_assign(&mut self, rhs: Choice) {
        *self = *self ^ rhs;
    }
}

impl CtAssign for Choice {
    #[inline]
    fn ct_assign(&mut self, other: &Self, choice: Choice) {
        self.0.ct_assign(&other.0, choice);
    }
}
impl CtAssignSlice for Choice {}
impl CtSelectUsingCtAssign for Choice {}

impl CtEq for Choice {
    #[inline]
    fn ct_eq(&self, other: &Self) -> Self {
        self.0.ct_eq(&other.0)
    }
}
impl CtEqSlice for Choice {}

/// DEPRECATED: this exists to aid migrating code from `subtle`. Use `Choice::from_u8_lsb` instead.
///
/// <div class="warning">
/// <b>Note</b>
///
/// Rust doesn't actually let us deprecate an impl block, however this comment is here to
/// discourage future use and warn that this will be removed in a future release.
/// </div>
impl From<u8> for Choice {
    fn from(value: u8) -> Self {
        Choice::from_u8_lsb(value)
    }
}

impl From<Choice> for u8 {
    fn from(choice: Choice) -> u8 {
        choice.to_u8()
    }
}

/// Convert `Choice` into a `bool`.
///
/// <div class = "warning">
/// <b>Security Warning</b>
///
/// Using this function will introduce timing variability, since computing this at all currently
/// requires a branch.
///
/// See the security warnings for [`Choice::to_bool`].
/// </div>
impl From<Choice> for bool {
    fn from(choice: Choice) -> bool {
        choice.to_bool()
    }
}

impl Not for Choice {
    type Output = Choice;

    #[inline]
    fn not(self) -> Choice {
        self.not()
    }
}

#[cfg(feature = "subtle")]
impl From<subtle::Choice> for Choice {
    #[inline]
    fn from(choice: subtle::Choice) -> Choice {
        Choice(choice.unwrap_u8())
    }
}

#[cfg(feature = "subtle")]
impl From<Choice> for subtle::Choice {
    #[inline]
    fn from(choice: Choice) -> subtle::Choice {
        subtle::Choice::from(choice.0)
    }
}

#[cfg(feature = "subtle")]
impl subtle::ConditionallySelectable for Choice {
    #[inline]
    fn conditional_select(a: &Self, b: &Self, choice: subtle::Choice) -> Self {
        CtSelect::ct_select(a, b, choice.into())
    }
}

#[cfg(feature = "subtle")]
impl subtle::ConstantTimeEq for Choice {
    #[inline]
    fn ct_eq(&self, other: &Self) -> subtle::Choice {
        CtEq::ct_eq(self, other).into()
    }
}

#[cfg(test)]
mod tests {
    use super::Choice;
    use crate::{CtEq, CtSelect};

    #[test]
    fn ct_eq() {
        let a = Choice::TRUE;
        let b = Choice::TRUE;
        let c = Choice::FALSE;

        assert!(a.ct_eq(&b).to_bool());
        assert!(!a.ct_eq(&c).to_bool());
        assert!(!b.ct_eq(&c).to_bool());

        assert!(!a.ct_ne(&b).to_bool());
        assert!(a.ct_ne(&c).to_bool());
        assert!(b.ct_ne(&c).to_bool());
    }

    #[test]
    fn ct_select() {
        let a = Choice::FALSE;
        let b = Choice::TRUE;
        assert_eq!(a.ct_select(&b, Choice::FALSE).to_bool(), a.to_bool());
        assert_eq!(a.ct_select(&b, Choice::TRUE).to_bool(), b.to_bool());
    }

    #[test]
    fn and() {
        assert_eq!((Choice::FALSE & Choice::FALSE).to_u8(), 0);
        assert_eq!((Choice::TRUE & Choice::FALSE).to_u8(), 0);
        assert_eq!((Choice::FALSE & Choice::TRUE).to_u8(), 0);
        assert_eq!((Choice::TRUE & Choice::TRUE).to_u8(), 1);
    }

    #[test]
    fn or() {
        assert_eq!((Choice::FALSE | Choice::FALSE).to_u8(), 0);
        assert_eq!((Choice::TRUE | Choice::FALSE).to_u8(), 1);
        assert_eq!((Choice::FALSE | Choice::TRUE).to_u8(), 1);
        assert_eq!((Choice::TRUE | Choice::TRUE).to_u8(), 1);
    }

    #[test]
    fn xor() {
        assert_eq!((Choice::FALSE ^ Choice::FALSE).to_u8(), 0);
        assert_eq!((Choice::TRUE ^ Choice::FALSE).to_u8(), 1);
        assert_eq!((Choice::FALSE ^ Choice::TRUE).to_u8(), 1);
        assert_eq!((Choice::TRUE ^ Choice::TRUE).to_u8(), 0);
    }

    #[test]
    fn not() {
        assert_eq!(Choice::FALSE.not().to_u8(), 1);
        assert_eq!(Choice::TRUE.not().to_u8(), 0);
    }

    #[test]
    fn from_i64_eq() {
        assert!(Choice::from_i64_eq(0, 1).eq(Choice::FALSE).to_bool());
        assert!(Choice::from_i64_eq(1, 1).eq(Choice::TRUE).to_bool());
    }

    #[test]
    fn from_u8_eq() {
        assert!(Choice::from_u8_eq(0, 1).eq(Choice::FALSE).to_bool());
        assert!(Choice::from_u8_eq(1, 1).eq(Choice::TRUE).to_bool());
    }

    #[test]
    fn from_u8_le() {
        assert!(Choice::from_u8_le(0, 0).eq(Choice::TRUE).to_bool());
        assert!(Choice::from_u8_le(1, 0).eq(Choice::FALSE).to_bool());
        assert!(Choice::from_u8_le(1, 1).eq(Choice::TRUE).to_bool());
        assert!(Choice::from_u8_le(1, 2).eq(Choice::TRUE).to_bool());
    }

    #[test]
    fn from_u8_lsb() {
        assert!(Choice::from_u8_lsb(0).eq(Choice::FALSE).to_bool());
        assert!(Choice::from_u8_lsb(1).eq(Choice::TRUE).to_bool());
        assert!(Choice::from_u8_lsb(2).eq(Choice::FALSE).to_bool());
        assert!(Choice::from_u8_lsb(3).eq(Choice::TRUE).to_bool());
    }

    #[test]
    fn from_u8_lt() {
        assert!(Choice::from_u8_lt(0, 0).eq(Choice::FALSE).to_bool());
        assert!(Choice::from_u8_lt(1, 0).eq(Choice::FALSE).to_bool());
        assert!(Choice::from_u8_lt(1, 1).eq(Choice::FALSE).to_bool());
        assert!(Choice::from_u8_lt(1, 2).eq(Choice::TRUE).to_bool());
    }

    #[test]
    fn from_u8_nz() {
        assert!(Choice::from_u8_nz(0).eq(Choice::FALSE).to_bool());
        assert!(Choice::from_u8_nz(1).eq(Choice::TRUE).to_bool());
        assert!(Choice::from_u8_nz(2).eq(Choice::TRUE).to_bool());
    }

    #[test]
    fn from_u16_eq() {
        assert!(Choice::from_u16_eq(0, 1).eq(Choice::FALSE).to_bool());
        assert!(Choice::from_u16_eq(1, 1).eq(Choice::TRUE).to_bool());
    }

    #[test]
    fn from_u16_le() {
        assert!(Choice::from_u16_le(0, 0).eq(Choice::TRUE).to_bool());
        assert!(Choice::from_u16_le(1, 0).eq(Choice::FALSE).to_bool());
        assert!(Choice::from_u16_le(1, 1).eq(Choice::TRUE).to_bool());
        assert!(Choice::from_u16_le(1, 2).eq(Choice::TRUE).to_bool());
    }

    #[test]
    fn from_u16_lsb() {
        assert!(Choice::from_u16_lsb(0).eq(Choice::FALSE).to_bool());
        assert!(Choice::from_u16_lsb(1).eq(Choice::TRUE).to_bool());
        assert!(Choice::from_u16_lsb(2).eq(Choice::FALSE).to_bool());
        assert!(Choice::from_u16_lsb(3).eq(Choice::TRUE).to_bool());
    }

    #[test]
    fn from_u16_lt() {
        assert!(Choice::from_u16_lt(0, 0).eq(Choice::FALSE).to_bool());
        assert!(Choice::from_u16_lt(1, 0).eq(Choice::FALSE).to_bool());
        assert!(Choice::from_u16_lt(1, 1).eq(Choice::FALSE).to_bool());
        assert!(Choice::from_u16_lt(1, 2).eq(Choice::TRUE).to_bool());
    }

    #[test]
    fn from_u16_nz() {
        assert!(Choice::from_u16_nz(0).eq(Choice::FALSE).to_bool());
        assert!(Choice::from_u16_nz(1).eq(Choice::TRUE).to_bool());
        assert!(Choice::from_u16_nz(2).eq(Choice::TRUE).to_bool());
    }

    #[test]
    fn from_u32_eq() {
        assert!(Choice::from_u32_eq(0, 1).eq(Choice::FALSE).to_bool());
        assert!(Choice::from_u32_eq(1, 1).eq(Choice::TRUE).to_bool());
    }

    #[test]
    fn from_u32_le() {
        assert!(Choice::from_u32_le(0, 0).eq(Choice::TRUE).to_bool());
        assert!(Choice::from_u32_le(1, 0).eq(Choice::FALSE).to_bool());
        assert!(Choice::from_u32_le(1, 1).eq(Choice::TRUE).to_bool());
        assert!(Choice::from_u32_le(1, 2).eq(Choice::TRUE).to_bool());
    }

    #[test]
    fn from_u32_lsb() {
        assert!(Choice::from_u32_lsb(0).eq(Choice::FALSE).to_bool());
        assert!(Choice::from_u32_lsb(1).eq(Choice::TRUE).to_bool());
        assert!(Choice::from_u32_lsb(2).eq(Choice::FALSE).to_bool());
        assert!(Choice::from_u32_lsb(3).eq(Choice::TRUE).to_bool());
    }

    #[test]
    fn from_u32_lt() {
        assert!(Choice::from_u32_lt(0, 0).eq(Choice::FALSE).to_bool());
        assert!(Choice::from_u32_lt(1, 0).eq(Choice::FALSE).to_bool());
        assert!(Choice::from_u32_lt(1, 1).eq(Choice::FALSE).to_bool());
        assert!(Choice::from_u32_lt(1, 2).eq(Choice::TRUE).to_bool());
    }

    #[test]
    fn from_u32_nz() {
        assert!(Choice::from_u32_nz(0).eq(Choice::FALSE).to_bool());
        assert!(Choice::from_u32_nz(1).eq(Choice::TRUE).to_bool());
        assert!(Choice::from_u32_nz(2).eq(Choice::TRUE).to_bool());
    }

    #[test]
    fn from_u64_eq() {
        assert!(Choice::from_u64_eq(0, 1).eq(Choice::FALSE).to_bool());
        assert!(Choice::from_u64_eq(1, 1).eq(Choice::TRUE).to_bool());
    }

    #[test]
    fn from_u64_le() {
        assert!(Choice::from_u64_le(0, 0).eq(Choice::TRUE).to_bool());
        assert!(Choice::from_u64_le(1, 0).eq(Choice::FALSE).to_bool());
        assert!(Choice::from_u64_le(1, 1).eq(Choice::TRUE).to_bool());
        assert!(Choice::from_u64_le(1, 2).eq(Choice::TRUE).to_bool());
    }

    #[test]
    fn from_u64_lsb() {
        assert!(Choice::from_u64_lsb(0).eq(Choice::FALSE).to_bool());
        assert!(Choice::from_u64_lsb(1).eq(Choice::TRUE).to_bool());
    }

    #[test]
    fn from_u64_lt() {
        assert!(Choice::from_u64_lt(0, 0).eq(Choice::FALSE).to_bool());
        assert!(Choice::from_u64_lt(1, 0).eq(Choice::FALSE).to_bool());
        assert!(Choice::from_u64_lt(1, 1).eq(Choice::FALSE).to_bool());
        assert!(Choice::from_u64_lt(1, 2).eq(Choice::TRUE).to_bool());
    }

    #[test]
    fn from_u64_nz() {
        assert!(Choice::from_u64_nz(0).eq(Choice::FALSE).to_bool());
        assert!(Choice::from_u64_nz(1).eq(Choice::TRUE).to_bool());
        assert!(Choice::from_u64_nz(2).eq(Choice::TRUE).to_bool());
    }

    #[test]
    fn from_u128_eq() {
        assert!(Choice::from_u128_eq(0, 1).eq(Choice::FALSE).to_bool());
        assert!(Choice::from_u128_eq(1, 1).eq(Choice::TRUE).to_bool());
    }

    #[test]
    fn from_u128_le() {
        assert!(Choice::from_u128_le(0, 0).eq(Choice::TRUE).to_bool());
        assert!(Choice::from_u128_le(1, 0).eq(Choice::FALSE).to_bool());
        assert!(Choice::from_u128_le(1, 1).eq(Choice::TRUE).to_bool());
        assert!(Choice::from_u128_le(1, 2).eq(Choice::TRUE).to_bool());
    }

    #[test]
    fn from_u128_lsb() {
        assert!(Choice::from_u128_lsb(0).eq(Choice::FALSE).to_bool());
        assert!(Choice::from_u128_lsb(1).eq(Choice::TRUE).to_bool());
    }

    #[test]
    fn from_u128_lt() {
        assert!(Choice::from_u128_lt(0, 0).eq(Choice::FALSE).to_bool());
        assert!(Choice::from_u128_lt(1, 0).eq(Choice::FALSE).to_bool());
        assert!(Choice::from_u128_lt(1, 1).eq(Choice::FALSE).to_bool());
        assert!(Choice::from_u128_lt(1, 2).eq(Choice::TRUE).to_bool());
    }

    #[test]
    fn from_u128_nz() {
        assert!(Choice::from_u128_nz(0).eq(Choice::FALSE).to_bool());
        assert!(Choice::from_u128_nz(1).eq(Choice::TRUE).to_bool());
        assert!(Choice::from_u128_nz(2).eq(Choice::TRUE).to_bool());
    }

    #[test]
    fn select_i64() {
        let a: i64 = 1;
        let b: i64 = 2;
        assert_eq!(Choice::TRUE.select_i64(a, b), b);
        assert_eq!(Choice::FALSE.select_i64(a, b), a);
    }

    #[test]
    fn select_u8() {
        let a: u8 = 1;
        let b: u8 = 2;
        assert_eq!(Choice::TRUE.select_u8(a, b), b);
        assert_eq!(Choice::FALSE.select_u8(a, b), a);
    }

    #[test]
    fn select_u16() {
        let a: u16 = 1;
        let b: u16 = 2;
        assert_eq!(Choice::TRUE.select_u16(a, b), b);
        assert_eq!(Choice::FALSE.select_u16(a, b), a);
    }

    #[test]
    fn select_u32() {
        let a: u32 = 1;
        let b: u32 = 2;
        assert_eq!(Choice::TRUE.select_u32(a, b), b);
        assert_eq!(Choice::FALSE.select_u32(a, b), a);
    }

    #[test]
    fn select_u64() {
        let a: u64 = 1;
        let b: u64 = 2;
        assert_eq!(Choice::TRUE.select_u64(a, b), b);
        assert_eq!(Choice::FALSE.select_u64(a, b), a);
    }

    #[test]
    fn select_u128() {
        let a: u128 = 1;
        let b: u128 = 2;
        assert_eq!(Choice::TRUE.select_u128(a, b), b);
        assert_eq!(Choice::FALSE.select_u128(a, b), a);
    }

    #[test]
    fn to_bool() {
        assert!(!Choice::FALSE.to_bool());
        assert!(Choice::TRUE.to_bool());
    }

    #[test]
    fn to_u8() {
        assert_eq!(Choice::FALSE.to_u8(), 0);
        assert_eq!(Choice::TRUE.to_u8(), 1);
    }

    #[test]
    fn to_u8_mask() {
        assert_eq!(Choice::FALSE.to_u8_mask(), 0);
        assert_eq!(Choice::TRUE.to_u8_mask(), u8::MAX);
    }

    #[test]
    fn to_u16_mask() {
        assert_eq!(Choice::FALSE.to_u16_mask(), 0);
        assert_eq!(Choice::TRUE.to_u16_mask(), u16::MAX);
    }

    #[test]
    fn to_u32_mask() {
        assert_eq!(Choice::FALSE.to_u32_mask(), 0);
        assert_eq!(Choice::TRUE.to_u32_mask(), u32::MAX);
    }

    #[test]
    fn to_u64_mask() {
        assert_eq!(Choice::FALSE.to_u64_mask(), 0);
        assert_eq!(Choice::TRUE.to_u64_mask(), u64::MAX);
    }

    #[test]
    fn to_u128_mask() {
        assert_eq!(Choice::FALSE.to_u128_mask(), 0);
        assert_eq!(Choice::TRUE.to_u128_mask(), u128::MAX);
    }
}
