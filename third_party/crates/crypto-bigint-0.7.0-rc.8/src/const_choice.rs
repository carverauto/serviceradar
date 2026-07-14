use subtle::{Choice, CtOption};

use crate::{
    Int, Limb, NonZero, NonZeroInt, Odd, OddInt, Uint, WideWord, Word,
    modular::{ConstMontyForm, ConstMontyParams, SafeGcdInverter},
};

/// A boolean value returned by constant-time `const fn`s.
// TODO: should be replaced by `subtle::Choice` or `CtOption`
// when `subtle` starts supporting const fns.
#[derive(Debug, Copy, Clone)]
pub struct ConstChoice(Word);

impl ConstChoice {
    /// The falsy value.
    pub const FALSE: Self = Self(0);

    /// The truthy value.
    pub const TRUE: Self = Self(Word::MAX);

    #[inline]
    #[allow(trivial_numeric_casts)]
    pub(crate) const fn as_u32_mask(&self) -> u32 {
        self.0 as u32
    }

    #[inline]
    #[cfg(target_pointer_width = "32")]
    pub(crate) const fn as_u64_mask(&self) -> u64 {
        ((self.0 as u64) << 32) | (self.0 as u64)
    }

    #[inline]
    #[cfg(target_pointer_width = "64")]
    pub(crate) const fn as_u64_mask(&self) -> u64 {
        self.0
    }

    #[inline]
    pub(crate) const fn as_word_mask(&self) -> Word {
        self.0
    }

    /// Returns the truthy value if `value == Word::MAX`, and the falsy value if `value == 0`.
    /// Panics for other values.
    #[inline]
    pub(crate) const fn from_word_mask(value: Word) -> Self {
        debug_assert!(value == Self::FALSE.0 || value == Self::TRUE.0);
        Self(value)
    }

    /// Returns the truthy value if `value == 1`, and the falsy value if `value == 0`.
    /// Panics for other values.
    #[inline]
    pub(crate) const fn from_word_lsb(value: Word) -> Self {
        debug_assert!(value == 0 || value == 1);
        Self(value.wrapping_neg())
    }

    /// Returns the truthy value if the most significant bit of `value` is `1`,
    /// and the falsy value if it equals `0`.
    #[inline]
    pub(crate) const fn from_word_msb(value: Word) -> Self {
        Self::from_word_lsb(value >> (Word::BITS - 1))
    }

    /// Returns the truthy value if `value == 1`, and the falsy value if `value == 0`.
    /// Panics for other values.
    #[inline]
    pub(crate) const fn from_wide_word_lsb(value: WideWord) -> Self {
        debug_assert!(value == 0 || value == 1);
        Self(value.wrapping_neg() as Word)
    }

    #[inline]
    pub(crate) const fn from_u32_lsb(value: u32) -> Self {
        debug_assert!(value == 0 || value == 1);
        #[allow(trivial_numeric_casts)]
        Self((value as Word).wrapping_neg())
    }

    #[inline]
    pub(crate) const fn from_u64_lsb(value: u64) -> Self {
        debug_assert!(value == 0 || value == 1);
        #[allow(trivial_numeric_casts)]
        Self((value as Word).wrapping_neg())
    }

    /// Returns the truthy value if `value != 0`, and the falsy value otherwise.
    #[inline]
    pub(crate) const fn from_u32_nonzero(value: u32) -> Self {
        Self::from_u32_lsb((value | value.wrapping_neg()) >> (u32::BITS - 1))
    }

    /// Returns the truthy value if `value != 0`, and the falsy value otherwise.
    #[inline]
    pub(crate) const fn from_u64_nonzero(value: u64) -> Self {
        Self::from_u64_lsb((value | value.wrapping_neg()) >> (u64::BITS - 1))
    }

    /// Returns the truthy value if `value != 0`, and the falsy value otherwise.
    #[inline]
    pub(crate) const fn from_word_nonzero(value: Word) -> Self {
        Self::from_word_lsb((value | value.wrapping_neg()) >> (Word::BITS - 1))
    }

    /// Returns the truthy value if `x == y`, and the falsy value otherwise.
    #[inline]
    pub(crate) const fn from_u32_eq(x: u32, y: u32) -> Self {
        Self::from_u32_nonzero(x ^ y).not()
    }

    /// Returns the truthy value if `x == y`, and the falsy value otherwise.
    #[inline]
    pub(crate) const fn from_word_eq(x: Word, y: Word) -> Self {
        Self::from_word_nonzero(x ^ y).not()
    }

    /// Returns the truthy value if `x < y`, and the falsy value otherwise.
    #[inline]
    pub(crate) const fn from_word_lt(x: Word, y: Word) -> Self {
        // See "Hacker's Delight" 2nd ed, section 2-12 (Comparison predicates)
        let bit = (((!x) & y) | (((!x) | y) & (x.wrapping_sub(y)))) >> (Word::BITS - 1);
        Self::from_word_lsb(bit)
    }

    /// Returns the truthy value if `x > y`, and the falsy value otherwise.
    #[inline]
    pub(crate) const fn from_word_gt(x: Word, y: Word) -> Self {
        Self::from_word_lt(y, x)
    }

    /// Returns the truthy value if `x < y`, and the falsy value otherwise.
    #[inline]
    pub(crate) const fn from_u32_lt(x: u32, y: u32) -> Self {
        // See "Hacker's Delight" 2nd ed, section 2-12 (Comparison predicates)
        let bit = (((!x) & y) | (((!x) | y) & (x.wrapping_sub(y)))) >> (u32::BITS - 1);
        Self::from_u32_lsb(bit)
    }

    /// Returns the truthy value if `x <= y` and the falsy value otherwise.
    #[inline]
    pub(crate) const fn from_word_le(x: Word, y: Word) -> Self {
        // See "Hacker's Delight" 2nd ed, section 2-12 (Comparison predicates)
        let bit = (((!x) | y) & ((x ^ y) | !(y.wrapping_sub(x)))) >> (Word::BITS - 1);
        Self::from_word_lsb(bit)
    }

    /// Returns the truthy value if `x <= y` and the falsy value otherwise.
    #[inline]
    pub(crate) const fn from_wide_word_le(x: WideWord, y: WideWord) -> Self {
        // See "Hacker's Delight" 2nd ed, section 2-12 (Comparison predicates)
        let bit = (((!x) | y) & ((x ^ y) | !(y.wrapping_sub(x)))) >> (WideWord::BITS - 1);
        Self::from_wide_word_lsb(bit)
    }

    /// Returns the truthy value if `x <= y` and the falsy value otherwise.
    #[inline]
    pub(crate) const fn from_u32_le(x: u32, y: u32) -> Self {
        // See "Hacker's Delight" 2nd ed, section 2-12 (Comparison predicates)
        let bit = (((!x) | y) & ((x ^ y) | !(y.wrapping_sub(x)))) >> (u32::BITS - 1);
        Self::from_u32_lsb(bit)
    }

    /// Returns the truthy value if `x == y`, and the falsy value otherwise.
    #[inline]
    pub(crate) const fn from_i64_eq(x: i64, y: i64) -> Self {
        Self::from_word_nonzero(x as Word ^ y as Word).not()
    }

    #[inline]
    pub(crate) const fn not(&self) -> Self {
        Self(!self.0)
    }

    #[inline]
    pub(crate) const fn or(&self, other: Self) -> Self {
        Self(self.0 | other.0)
    }

    #[inline]
    pub(crate) const fn and(&self, other: Self) -> Self {
        Self(self.0 & other.0)
    }

    #[inline]
    pub(crate) const fn xor(&self, other: Self) -> Self {
        Self(self.0 ^ other.0)
    }

    #[inline]
    pub(crate) const fn ne(&self, other: Self) -> Self {
        Self::xor(self, other)
    }

    #[inline]
    pub(crate) const fn eq(&self, other: Self) -> Self {
        Self::ne(self, other).not()
    }

    /// Return `b` if `self` is truthy, otherwise return `a`.
    #[inline]
    pub(crate) const fn select_word(&self, a: Word, b: Word) -> Word {
        a ^ (self.0 & (a ^ b))
    }

    /// Return `b` if `self` is truthy, otherwise return `a`.
    #[inline]
    pub(crate) const fn select_wide_word(&self, a: WideWord, b: WideWord) -> WideWord {
        let mask = ((self.0 as WideWord) << Word::BITS) | (self.0 as WideWord);
        a ^ (mask & (a ^ b))
    }

    /// Return `b` if `self` is truthy, otherwise return `a`.
    #[inline]
    pub(crate) const fn select_u32(&self, a: u32, b: u32) -> u32 {
        a ^ (self.as_u32_mask() & (a ^ b))
    }

    /// Return `b` if `self` is truthy, otherwise return `a`.
    #[inline]
    pub(crate) const fn select_i64(&self, a: i64, b: i64) -> i64 {
        self.select_u64(a as u64, b as u64) as i64
    }

    /// Return `b` if `self` is truthy, otherwise return `a`.
    #[inline]
    pub(crate) const fn select_u64(&self, a: u64, b: u64) -> u64 {
        a ^ (self.as_u64_mask() & (a ^ b))
    }

    /// Return `x` if `self` is truthy, otherwise return 0.
    #[inline]
    pub(crate) const fn if_true_word(&self, x: Word) -> Word {
        x & self.0
    }

    /// Return `x` if `self` is truthy, otherwise return 0.
    #[inline]
    pub(crate) const fn if_true_u32(&self, x: u32) -> u32 {
        x & self.as_u32_mask()
    }

    #[inline]
    pub(crate) const fn is_true_vartime(&self) -> bool {
        self.0 == ConstChoice::TRUE.0
    }

    #[inline]
    pub(crate) const fn to_u8(self) -> u8 {
        (self.0 as u8) & 1
    }

    /// WARNING: this method should only be used in contexts that aren't constant-time critical!
    #[inline]
    pub(crate) const fn to_bool_vartime(self) -> bool {
        self.to_u8() != 0
    }
}

/// `const` equivalent of `u32::max(a, b)`.
pub const fn u32_max(a: u32, b: u32) -> u32 {
    ConstChoice::from_u32_lt(a, b).select_u32(a, b)
}

/// `const` equivalent of `u32::min(a, b)`.
pub const fn u32_min(a: u32, b: u32) -> u32 {
    ConstChoice::from_u32_lt(a, b).select_u32(b, a)
}

impl From<ConstChoice> for Choice {
    #[inline]
    fn from(choice: ConstChoice) -> Self {
        Choice::from(choice.to_u8())
    }
}

impl From<Choice> for ConstChoice {
    #[inline]
    fn from(choice: Choice) -> Self {
        ConstChoice::from_word_lsb(choice.unwrap_u8() as Word)
    }
}

impl From<ConstChoice> for bool {
    fn from(choice: ConstChoice) -> Self {
        choice.is_true_vartime()
    }
}

impl PartialEq for ConstChoice {
    fn eq(&self, other: &Self) -> bool {
        self.0 == other.0
    }
}

/// An equivalent of `subtle::CtOption` usable in a `const fn` context.
#[derive(Debug, Clone)]
pub struct ConstCtOption<T> {
    value: T,
    is_some: ConstChoice,
}

impl<T> ConstCtOption<T> {
    #[inline]
    pub(crate) const fn new(value: T, is_some: ConstChoice) -> Self {
        Self { value, is_some }
    }

    #[inline]
    pub(crate) const fn some(value: T) -> Self {
        Self {
            value,
            is_some: ConstChoice::TRUE,
        }
    }

    #[inline]
    pub(crate) const fn none(dummy_value: T) -> Self {
        Self {
            value: dummy_value,
            is_some: ConstChoice::FALSE,
        }
    }

    /// Returns a reference to the contents of this structure.
    ///
    /// **Note:** if the second element is `None`, the first value may take any value.
    #[inline]
    pub(crate) const fn components_ref(&self) -> (&T, ConstChoice) {
        // Since Rust is not smart enough to tell that we would be moving the value,
        // and hence no destructors will be called, we have to return a reference instead.
        // See https://github.com/rust-lang/rust/issues/66753
        (&self.value, self.is_some)
    }

    /// Returns a true [`ConstChoice`] if this value is `Some`.
    #[inline]
    pub const fn is_some(&self) -> ConstChoice {
        self.is_some
    }

    /// Returns a true [`ConstChoice`] if this value is `None`.
    #[inline]
    pub const fn is_none(&self) -> ConstChoice {
        self.is_some.not()
    }

    /// This returns the underlying value but panics if it is not `Some`.
    #[inline]
    #[track_caller]
    pub fn unwrap(self) -> T {
        assert!(
            self.is_some.is_true_vartime(),
            "called `ConstCtOption::unwrap()` on a `None` value"
        );
        self.value
    }

    /// Apply an additional [`ConstChoice`] requirement to `is_some`.
    #[inline]
    pub(crate) const fn and_choice(mut self, is_some: ConstChoice) -> Self {
        self.is_some = self.is_some.and(is_some);
        self
    }
}

impl<T> From<ConstCtOption<T>> for CtOption<T> {
    #[inline]
    fn from(value: ConstCtOption<T>) -> Self {
        CtOption::new(value.value, value.is_some.into())
    }
}

impl<T> From<ConstCtOption<T>> for Option<T> {
    #[inline]
    fn from(value: ConstCtOption<T>) -> Self {
        if value.is_some.into() {
            Some(value.value)
        } else {
            None
        }
    }
}

// Need specific implementations to work around the
// "destructors cannot be evaluated at compile-time" error
// See https://github.com/rust-lang/rust/issues/66753

impl<const LIMBS: usize> ConstCtOption<Uint<LIMBS>> {
    /// This returns the underlying value if it is `Some` or the provided value otherwise.
    #[inline]
    pub const fn unwrap_or(self, def: Uint<LIMBS>) -> Uint<LIMBS> {
        Uint::select(&def, &self.value, self.is_some)
    }

    /// Returns the contained value, consuming the `self` value.
    ///
    /// # Panics
    ///
    /// Panics if the value is none with a custom panic message provided by
    /// `msg`.
    #[inline]
    #[track_caller]
    pub const fn expect(self, msg: &str) -> Uint<LIMBS> {
        assert!(self.is_some.is_true_vartime(), "{}", msg);
        self.value
    }

    /// Returns the contained value, interpreting the underlying [`Uint`] value as an [`Int`].
    #[inline]
    pub const fn as_int(&self) -> ConstCtOption<Int<LIMBS>> {
        ConstCtOption::new(*self.value.as_int(), self.is_some)
    }
}

impl<const LIMBS: usize> ConstCtOption<(Uint<LIMBS>, Uint<LIMBS>)> {
    /// Returns the contained value, consuming the `self` value.
    ///
    /// # Panics
    ///
    /// Panics if the value is none with a custom panic message provided by
    /// `msg`.
    #[inline]
    #[track_caller]
    pub const fn expect(self, msg: &str) -> (Uint<LIMBS>, Uint<LIMBS>) {
        assert!(self.is_some.is_true_vartime(), "{}", msg);
        self.value
    }
}

impl<const LIMBS: usize> ConstCtOption<NonZero<Uint<LIMBS>>> {
    /// Returns the contained value, consuming the `self` value.
    ///
    /// # Panics
    ///
    /// Panics if the value is none with a custom panic message provided by
    /// `msg`.
    #[inline]
    #[track_caller]
    pub const fn expect(self, msg: &str) -> NonZero<Uint<LIMBS>> {
        assert!(self.is_some.is_true_vartime(), "{}", msg);
        self.value
    }
}

impl<const LIMBS: usize> ConstCtOption<Odd<Uint<LIMBS>>> {
    /// Returns the contained value, consuming the `self` value.
    ///
    /// # Panics
    ///
    /// Panics if the value is none with a custom panic message provided by
    /// `msg`.
    #[inline]
    #[track_caller]
    pub const fn expect(self, msg: &str) -> Odd<Uint<LIMBS>> {
        assert!(self.is_some.is_true_vartime(), "{}", msg);
        self.value
    }
}

impl<const LIMBS: usize> ConstCtOption<Int<LIMBS>> {
    /// This returns the underlying value if it is `Some` or the provided value otherwise.
    #[inline]
    pub const fn unwrap_or(self, def: Int<LIMBS>) -> Int<LIMBS> {
        Int::select(&def, &self.value, self.is_some)
    }

    /// Returns the contained value, consuming the `self` value.
    ///
    /// # Panics
    ///
    /// Panics if the value is none with a custom panic message provided by
    /// `msg`.
    #[inline]
    #[track_caller]
    pub const fn expect(self, msg: &str) -> Int<LIMBS> {
        assert!(self.is_some.is_true_vartime(), "{}", msg);
        self.value
    }
}

impl<const LIMBS: usize> ConstCtOption<NonZeroInt<LIMBS>> {
    /// Returns the contained value, consuming the `self` value.
    ///
    /// # Panics
    ///
    /// Panics if the value is none with a custom panic message provided by
    /// `msg`.
    #[inline]
    #[track_caller]
    pub const fn expect(self, msg: &str) -> NonZeroInt<LIMBS> {
        assert!(self.is_some.is_true_vartime(), "{}", msg);
        self.value
    }
}

impl<const LIMBS: usize> ConstCtOption<OddInt<LIMBS>> {
    /// Returns the contained value, consuming the `self` value.
    ///
    /// # Panics
    ///
    /// Panics if the value is none with a custom panic message provided by
    /// `msg`.
    #[inline]
    #[track_caller]
    pub const fn expect(self, msg: &str) -> OddInt<LIMBS> {
        assert!(self.is_some.is_true_vartime(), "{}", msg);
        self.value
    }
}

impl ConstCtOption<NonZero<Limb>> {
    /// Returns the contained value, consuming the `self` value.
    ///
    /// # Panics
    ///
    /// Panics if the value is none with a custom panic message provided by
    /// `msg`.
    #[inline]
    #[track_caller]
    pub const fn expect(self, msg: &str) -> NonZero<Limb> {
        assert!(self.is_some.is_true_vartime(), "{}", msg);
        self.value
    }
}

impl<const LIMBS: usize> ConstCtOption<SafeGcdInverter<LIMBS>> {
    /// Returns the contained value, consuming the `self` value.
    ///
    /// # Panics
    ///
    /// Panics if the value is none with a custom panic message provided by
    /// `msg`.
    #[inline]
    #[track_caller]
    pub const fn expect(self, msg: &str) -> SafeGcdInverter<LIMBS> {
        assert!(self.is_some.is_true_vartime(), "{}", msg);
        self.value
    }
}

impl<MOD: ConstMontyParams<LIMBS>, const LIMBS: usize> ConstCtOption<ConstMontyForm<MOD, LIMBS>> {
    /// This returns the underlying value if it is `Some` or the provided value otherwise.
    #[inline]
    pub const fn unwrap_or(self, def: ConstMontyForm<MOD, LIMBS>) -> ConstMontyForm<MOD, LIMBS> {
        ConstMontyForm::<MOD, LIMBS>::select(&def, &self.value, self.is_some)
    }

    /// Returns the contained value, consuming the `self` value.
    ///
    /// # Panics
    ///
    /// Panics if the value is none with a custom panic message provided by `msg`.
    #[inline]
    #[track_caller]
    pub const fn expect(self, msg: &str) -> ConstMontyForm<MOD, LIMBS> {
        assert!(self.is_some.is_true_vartime(), "{}", msg);
        self.value
    }
}

#[cfg(test)]
mod tests {
    use super::{ConstChoice, u32_max, u32_min};
    use crate::{WideWord, Word};

    #[test]
    fn from_u64_lsb() {
        assert_eq!(ConstChoice::from_u64_lsb(0), ConstChoice::FALSE);
        assert_eq!(ConstChoice::from_u64_lsb(1), ConstChoice::TRUE);
    }

    #[test]
    fn from_word_lt() {
        assert_eq!(ConstChoice::from_word_lt(4, 5), ConstChoice::TRUE);
        assert_eq!(ConstChoice::from_word_lt(5, 5), ConstChoice::FALSE);
        assert_eq!(ConstChoice::from_word_lt(6, 5), ConstChoice::FALSE);
    }

    #[test]
    fn from_word_gt() {
        assert_eq!(ConstChoice::from_word_gt(4, 5), ConstChoice::FALSE);
        assert_eq!(ConstChoice::from_word_gt(5, 5), ConstChoice::FALSE);
        assert_eq!(ConstChoice::from_word_gt(6, 5), ConstChoice::TRUE);
    }

    #[test]
    fn from_wide_word_le() {
        assert_eq!(ConstChoice::from_wide_word_le(4, 5), ConstChoice::TRUE);
        assert_eq!(ConstChoice::from_wide_word_le(5, 5), ConstChoice::TRUE);
        assert_eq!(ConstChoice::from_wide_word_le(6, 5), ConstChoice::FALSE);
    }

    #[test]
    fn select_u32() {
        let a: u32 = 1;
        let b: u32 = 2;
        assert_eq!(ConstChoice::TRUE.select_u32(a, b), b);
        assert_eq!(ConstChoice::FALSE.select_u32(a, b), a);
    }

    #[test]
    fn select_u64() {
        let a: u64 = 1;
        let b: u64 = 2;
        assert_eq!(ConstChoice::TRUE.select_u64(a, b), b);
        assert_eq!(ConstChoice::FALSE.select_u64(a, b), a);
    }

    #[test]
    fn select_word() {
        let a: Word = 1;
        let b: Word = 2;
        assert_eq!(ConstChoice::TRUE.select_word(a, b), b);
        assert_eq!(ConstChoice::FALSE.select_word(a, b), a);
    }

    #[test]
    fn select_wide_word() {
        let a: WideWord = (1 << Word::BITS) + 1;
        let b: WideWord = (3 << Word::BITS) + 4;
        assert_eq!(ConstChoice::TRUE.select_wide_word(a, b), b);
        assert_eq!(ConstChoice::FALSE.select_wide_word(a, b), a);
    }

    #[test]
    fn test_u32_const_min() {
        assert_eq!(u32_min(0, 5), 0);
        assert_eq!(u32_min(7, 0), 0);
        assert_eq!(u32_min(7, 5), 5);
        assert_eq!(u32_min(7, 7), 7);
    }

    #[test]
    fn test_u32_const_max() {
        assert_eq!(u32_max(0, 5), 5);
        assert_eq!(u32_max(7, 0), 7);
        assert_eq!(u32_max(7, 5), 7);
        assert_eq!(u32_max(7, 7), 7);
    }
}
