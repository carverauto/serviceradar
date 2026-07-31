use crate::{Choice, CtAssign, CtAssignSlice, CtEq, CtEqSlice, CtSelect};
use core::ops::{Deref, DerefMut};

/// Helper macro for providing behavior like the [`CtOption::map`] combinator that works in
/// `const fn` contexts.
///
/// Requires a provided `$mapper` function to convert from one type to another, e.g.
///
/// ```ignore
/// const fn mapper(value: T) -> U
/// ```
#[macro_export]
macro_rules! map {
    ($opt:expr, $mapper:path) => {{ $crate::CtOption::new($mapper($opt.to_inner_unchecked()), $opt.is_some()) }};
}

/// Helper macro for providing behavior like the [`CtOption::unwrap_or`] combinator that works in
/// `const fn` contexts.
///
/// Requires a provided selector function `$select` to perform constant-time selection which takes
/// two `T` values by reference along with a [`Choice`], returning the first `T` for
/// [`Choice::FALSE`], and the second for [`Choice::TRUE`], e.g.:
///
/// ```ignore
/// const fn ct_select(a: &T, b: &T, condition: Choice) -> T
/// ```
#[macro_export]
macro_rules! unwrap_or {
    ($opt:expr, $default:expr, $select:path) => {
        $select(&$default, $opt.as_inner_unchecked(), $opt.is_some())
    };
}

/// Equivalent of [`Option`] but predicated on a [`Choice`] with combinators that allow for
/// constant-time operations which always perform the same sequence of instructions regardless of
/// the value of `is_some`.
///
/// Unlike [`Option`], [`CtOption`] always contains a value, and will use the contained value when
/// e.g. evaluating the callbacks of combinator methods, which unlike `core` it does unconditionally
/// in order to ensure constant-time operation. This approach stands in contrast to the lazy
/// evaluation similar methods on [`Option`] provide.
#[derive(Clone, Copy, Debug)]
pub struct CtOption<T> {
    value: T,
    is_some: Choice,
}

impl<T> CtOption<T> {
    /// Construct a new [`CtOption`], with a [`Choice`] parameter `is_some` as a stand-in for
    /// `Some` or `None` enum variants of a typical [`Option`] type.
    #[inline]
    #[must_use]
    pub const fn new(value: T, is_some: Choice) -> CtOption<T> {
        Self { value, is_some }
    }

    /// Construct a new [`CtOption`] where `self.is_some()` is [`Choice::TRUE`].
    #[inline]
    #[must_use]
    pub const fn some(value: T) -> CtOption<T> {
        Self::new(value, Choice::TRUE)
    }

    /// Construct a new [`CtOption`] with the [`Default`] value, and where `self.is_some()` is
    /// [`Choice::FALSE`].
    #[inline]
    #[must_use]
    pub fn none() -> CtOption<T>
    where
        T: Default,
    {
        Self::new(Default::default(), Choice::FALSE)
    }

    /// Convert from a `&mut CtOption<T>` to `CtOption<&mut T>`.
    #[inline]
    #[must_use]
    pub const fn as_mut(&mut self) -> CtOption<&mut T> {
        CtOption {
            value: &mut self.value,
            is_some: self.is_some,
        }
    }

    /// Convert from a `&CtOption<T>` to `CtOption<&T>`.
    #[inline]
    #[must_use]
    pub const fn as_ref(&self) -> CtOption<&T> {
        CtOption {
            value: &self.value,
            is_some: self.is_some,
        }
    }

    /// Convert from `CtOption<T>` (or `&CtOption<T>`) to `CtOption<&T::Target>`, for types which
    /// impl the [`Deref`] trait.
    #[inline]
    #[must_use]
    pub fn as_deref(&self) -> CtOption<&T::Target>
    where
        T: Deref,
    {
        self.as_ref().map(Deref::deref)
    }

    /// Convert from `CtOption<T>` (or `&mut CtOption<T>`) to `CtOption<&mut T::Target>`, for types
    /// which impl the [`DerefMut`] trait.
    #[inline]
    #[must_use]
    pub fn as_deref_mut(&mut self) -> CtOption<&mut T::Target>
    where
        T: DerefMut,
    {
        self.as_mut().map(DerefMut::deref_mut)
    }

    /// Return the contained value, consuming the `self` value.
    ///
    /// # Panics
    /// In the event `self.is_some()` is [`Choice::FALSE`], panics with a custom panic message
    /// provided as the `msg` argument.
    #[inline]
    #[must_use]
    #[track_caller]
    pub fn expect(self, msg: &str) -> T {
        assert!(self.is_some().to_bool(), "{}", msg);
        self.value
    }

    /// Return the contained value, consuming the `self` value, with `const fn` support.
    ///
    /// Relies on a `Copy` bound which implies `!Drop` which is needed to be able to move out of
    /// `self` in a `const fn` without `feature(const_precise_live_drops)`.
    ///
    /// # Panics
    /// In the event `self.is_some()` is [`Choice::FALSE`], panics with a custom panic message
    /// provided as the `msg` argument.
    // TODO(tarcieri): get rid of this when we can make `expect` a `const fn`
    // (needs `const_precise_live_drops`)
    #[inline]
    #[must_use]
    #[track_caller]
    pub const fn expect_copied(self, msg: &str) -> T
    where
        T: Copy,
    {
        *self.expect_ref(msg)
    }

    /// Borrow the contained value.
    ///
    /// # Panics
    /// In the event `self.is_some()` is [`Choice::FALSE`], panics with a custom panic message
    /// provided as the `msg` argument.
    // TODO(tarcieri): get rid of this when we can make `expect` a `const fn`
    // (needs `const_precise_live_drops`)
    #[inline]
    #[must_use]
    #[track_caller]
    pub const fn expect_ref(&self, msg: &str) -> &T {
        // TODO(tarcieri): use `self.is_some().to_bool()` when MSRV is 1.86
        assert!(self.is_some.to_bool_vartime(), "{}", msg);
        self.as_inner_unchecked()
    }

    /// Inserts `value` into the [`CtOption`], then returns a mutable reference to it.
    ///
    /// If the option already contains a value, the old value is dropped.
    pub fn insert(&mut self, value: T) -> &mut T {
        self.value = value;
        self.is_some = Choice::TRUE;
        &mut self.value
    }

    /// Conditionally inserts `value` into the [`CtOption`] if the given condition holds.
    pub fn insert_if(&mut self, value: &T, condition: Choice)
    where
        T: CtAssign,
    {
        self.value.ct_assign(value, condition);
        self.is_some.ct_assign(&Choice::TRUE, condition);
    }

    /// Convert the [`CtOption`] wrapper into an [`Option`], depending on whether
    /// [`CtOption::is_some`] is a truthy or falsy [`Choice`].
    ///
    /// This function exists to avoid ending up with ugly, verbose and/or bad handled conversions
    /// from the [`CtOption`] wraps to an [`Option`] or [`Result`].
    ///
    /// It's equivalent to the corresponding [`From`] impl, however this version is friendlier for
    /// type inference.
    ///
    /// <div class="warning">
    /// <b>Warning: variable-time!</b>
    ///
    /// This implementation doesn't intend to be constant-time nor try to protect the leakage of the
    /// `T` value since the [`Option`] will do it anyway.
    /// </div>
    #[inline]
    pub fn into_option(self) -> Option<T> {
        if self.is_some.to_bool() {
            Some(self.value)
        } else {
            None
        }
    }

    /// Convert the [`CtOption`] wrapper into an [`Option`] in a `const fn`-friendly manner.
    ///
    /// This is the equivalent of [`CtOption::into_option`] but is `const fn`-friendly by only
    /// allowing `Copy` types which are implicitly `!Drop` and don't run into problems with
    /// `const fn` and destructors.
    ///
    /// <div class="warning">
    /// <b>Warning: variable-time!</b>
    ///
    /// This implementation doesn't intend to be constant-time nor try to protect the leakage of the
    /// `T` value since the [`Option`] will do it anyway.
    /// </div>
    #[inline]
    pub const fn into_option_copied(self) -> Option<T>
    where
        T: Copy,
    {
        // TODO(tarcieri): use `self.is_some().to_bool()` when MSRV is 1.86
        if self.is_some.to_bool_vartime() {
            Some(self.value)
        } else {
            None
        }
    }

    /// Returns [`Choice::TRUE`] if the option is the equivalent of a `Some`.
    #[inline]
    #[must_use]
    pub const fn is_some(&self) -> Choice {
        self.is_some
    }

    /// Returns [`Choice::TRUE`] if the option is the equivalent of a `None`.
    #[inline]
    #[must_use]
    pub const fn is_none(&self) -> Choice {
        self.is_some.not()
    }

    /// Returns `optb` if `self.is_some()` is [`Choice::TRUE`], otherwise returns a [`CtOption`]
    /// where `self.is_some()` is [`Choice::FALSE`].
    #[inline]
    #[must_use]
    pub fn and<U>(self, mut optb: CtOption<U>) -> CtOption<U> {
        optb.is_some &= self.is_some;
        optb
    }

    /// Calls the provided callback with the wrapped inner value, returning the resulting
    /// [`CtOption`] value in the event that `self.is_some()` is [`Choice::TRUE`], or if not
    /// returns a [`CtOption`] with `self.is_none()`.
    ///
    /// Unlike [`Option`], the provided callback `f` is unconditionally evaluated to ensure
    /// constant-time operation. This requires evaluating the function with "dummy" value of `T`
    /// (e.g. if the [`CtOption`] was constructed with a supplied placeholder value and
    /// [`Choice::FALSE`], the placeholder value will be provided).
    #[inline]
    #[must_use]
    pub fn and_then<U, F>(self, f: F) -> CtOption<U>
    where
        F: FnOnce(T) -> CtOption<U>,
    {
        let mut ret = f(self.value);
        ret.is_some &= self.is_some;
        ret
    }

    /// Obtain a reference to the inner value without first checking that `self.is_some()` is
    /// [`Choice::TRUE`].
    ///
    /// This method is primarily intended for use in `const fn` scenarios where it's not yet
    /// possible to use the safe combinator methods, and returns a reference to avoid issues with
    /// `const fn` destructors.
    ///
    /// <div class="warning">
    /// <b>Use with care!</b>
    ///
    /// This method does not ensure the `value` is actually valid. Callers of this method should
    /// take great care to ensure that `self.is_some()` is checked elsewhere.
    /// </div>
    #[inline]
    #[must_use]
    pub const fn as_inner_unchecked(&self) -> &T {
        &self.value
    }

    /// Calls the provided callback with the wrapped inner value, which computes a [`Choice`],
    /// and updates `self.is_some()`.
    ///
    /// It updates it to be [`Choice::FALSE`] in the event the returned choice is also false.
    /// If it was [`Choice::FALSE`] to begin with, it will unconditionally remain that way.
    #[inline]
    #[must_use]
    pub fn filter<P>(mut self, predicate: P) -> Self
    where
        P: FnOnce(&T) -> Choice,
    {
        self.is_some &= predicate(&self.value);
        self
    }

    /// Apply an additional [`Choice`] requirement to `is_some`.
    #[inline]
    #[must_use]
    pub const fn filter_by(mut self, is_some: Choice) -> Self {
        self.is_some = self.is_some.and(is_some);
        self
    }

    /// Maps a `CtOption<T>` to a `CtOption<U>` by unconditionally applying a function to the
    /// contained `value`, but returning a new option value which inherits `self.is_some()`.
    #[inline]
    #[must_use]
    pub fn map<U, F>(self, f: F) -> CtOption<U>
    where
        F: FnOnce(T) -> U,
    {
        CtOption::new(f(self.value), self.is_some)
    }

    /// Maps a `CtOption<T>` to a `U` value, eagerly evaluating the provided function, and returning
    /// the supplied `default` in the event `self.is_some()` is [`Choice::FALSE`].
    #[inline]
    #[must_use = "if you don't need the returned value, use `if let` instead"]
    pub fn map_or<U, F>(self, default: U, f: F) -> U
    where
        U: CtSelect,
        F: FnOnce(T) -> U,
    {
        self.map(f).unwrap_or(default)
    }

    /// Maps a `CtOption<T>` to a `U` value, eagerly evaluating the provided function, precomputing
    /// `U::default()` using the [`Default`] trait, and returning it in the event `self.is_some()`
    /// is [`Choice::FALSE`].
    #[inline]
    #[must_use]
    pub fn map_or_default<U, F>(self, f: F) -> U
    where
        U: CtSelect + Default,
        F: FnOnce(T) -> U,
    {
        self.map_or(U::default(), f)
    }

    /// Transforms a `CtOption<T>` into a `Result<T, E>`, mapping to `Ok(T)` if `self.is_some()` is
    /// [`Choice::TRUE`], or mapping to the provided `err` in the event `self.is_some()` is
    /// [`Choice::FALSE`].
    ///
    /// <div class="warning">
    /// <b>Warning: variable-time!</b>
    ///
    /// This implementation doesn't intend to be constant-time nor try to protect the leakage of the
    /// `T` value since the [`Result`] will do it anyway.
    /// </div>
    ///
    /// # Errors
    /// - Returns `err` in the event `self.is_some()` is [`Choice::FALSE`].
    #[inline]
    pub fn ok_or<E>(self, err: E) -> Result<T, E> {
        self.into_option().ok_or(err)
    }

    /// Transforms a `CtOption<T>` into a `Result<T, E>` by unconditionally calling the provided
    /// callback value and using its result in the event `self.is_some()` is [`Choice::FALSE`].
    ///
    /// <div class="warning">
    /// <b>Warning: variable-time!</b>
    ///
    /// This implementation doesn't intend to be constant-time nor try to protect the leakage of the
    /// `T` value since the [`Result`] will do it anyway.
    /// </div>
    ///
    /// # Errors
    /// - Returns `err` in the event `self.is_some()` is [`Choice::FALSE`].
    #[inline]
    #[allow(clippy::missing_errors_doc)]
    pub fn ok_or_else<E, F>(self, err: F) -> Result<T, E>
    where
        F: FnOnce() -> E,
    {
        self.ok_or(err())
    }

    /// Returns `self` if `self.is_some()` is [`Choice::TRUE`], otherwise returns `optb`.
    #[inline]
    #[must_use]
    pub fn or(self, optb: CtOption<T>) -> CtOption<T>
    where
        T: CtSelect,
    {
        CtOption {
            value: self.value.ct_select(&optb.value, self.is_none()),
            is_some: self.is_some | optb.is_some,
        }
    }

    /// Obtain a copy of the inner value without first checking that `self.is_some()` is
    /// [`Choice::TRUE`].
    ///
    /// This method is primarily intended for use in `const fn` scenarios where it's not yet
    /// possible to use the safe combinator methods, and uses a `Copy` bound to avoid issues with
    /// `const fn` destructors.
    ///
    /// <div class="warning">
    /// <b>Use with care!</b>
    ///
    /// This method does not ensure the `value` is actually valid. Callers of this method should
    /// take great care to ensure that `self.is_some()` is checked elsewhere.
    /// </div>
    #[inline]
    #[must_use]
    pub const fn to_inner_unchecked(self) -> T
    where
        T: Copy,
    {
        self.value
    }

    /// Return the contained value, consuming the `self` value.
    ///
    /// Use of this function is discouraged due to panic potential. Instead, prefer non-panicking
    /// alternatives such as `unwrap_or` or `unwrap_or_default` which operate in constant-time.
    ///
    /// As the final step of a sequence of constant-time operations, or in the event you are dealing
    /// with a [`CtOption`] in a non-secret context where constant-time does not matter, you can
    /// also convert to [`Option`] using `into_option` or the [`From`] impl on [`Option`]. Note
    /// this introduces a branch and with it a small amount of timing variability. If possible try
    /// to avoid this branch when writing constant-time code (e.g. use implicit rejection instead
    /// of `Option`/`Result` to handle errors)
    ///
    /// # Panics
    /// In the event `self.is_some()` is [`Choice::FALSE`].
    #[inline]
    #[must_use]
    #[track_caller]
    pub fn unwrap(self) -> T {
        assert!(
            self.is_some.to_bool(),
            "called `CtOption::unwrap()` on a value with `is_some` set to `Choice::FALSE`"
        );
        self.value
    }

    /// Return the contained value in the event `self.is_some()` is [`Choice::TRUE`], or if not,
    /// uses a provided default.
    #[inline]
    #[must_use]
    pub fn unwrap_or(self, default: T) -> T
    where
        T: CtSelect,
    {
        default.ct_select(&self.value, self.is_some)
    }

    /// Unconditionally computes `T::default()` using the [`Default`] trait, then returns either
    /// the contained value if `self.is_some()` is [`Choice::TRUE`], or if it's [`Choice::FALSE`]
    /// returns the previously computed default.
    #[inline]
    #[must_use]
    pub fn unwrap_or_default(self) -> T
    where
        T: CtSelect + Default,
    {
        self.unwrap_or(T::default())
    }

    /// Returns an "is some" [`CtOption`] with the contained value from either `self` or `optb` in
    /// the event exactly one of them has `self.is_some()` set to [`Choice::TRUE`], or else returns
    /// a [`CtOption`] with `self.is_some()` set to [`Choice::FALSE`].
    #[inline]
    #[must_use]
    pub fn xor(self, optb: CtOption<T>) -> CtOption<T>
    where
        T: CtSelect,
    {
        CtOption {
            value: self.value.ct_select(&optb.value, self.is_none()),
            is_some: self.is_some ^ optb.is_some,
        }
    }

    /// Zips `self` with another [`CtOption`].
    ///
    /// If `self.is_some() && other.is_some()`, this method returns a new [`CtOption`] for a 2-tuple
    /// of their contents where `is_some()` is [`Choice::TRUE`].
    ///
    /// Otherwise, a [`CtOption`] where `is_some()` is [`Choice::FALSE`] is returned.
    pub fn zip<U>(self, other: CtOption<U>) -> CtOption<(T, U)> {
        CtOption {
            value: (self.value, other.value),
            is_some: self.is_some & other.is_some,
        }
    }

    /// Zips `self` and another `CtOption` with function `f`.
    ///
    /// If `self.is_some() && other.is_some()`, this method returns a new [`CtOption`] for
    /// the result of `f` applied to their inner values where `is_some()` is [`Choice::TRUE`].
    ///
    /// Otherwise, a [`CtOption`] where `is_some()` is [`Choice::FALSE`] is returned.
    pub fn zip_with<U, F, R>(self, other: CtOption<U>, f: F) -> CtOption<R>
    where
        F: FnOnce(T, U) -> R,
    {
        self.zip(other).map(|(a, b)| f(a, b))
    }
}

impl<T> CtOption<&T> {
    /// Maps a `CtOption<&T>` to `CtOption<T>` by copying the contents of the option.
    #[must_use = "`self` will be dropped if the result is not used"]
    pub const fn copied(self) -> CtOption<T>
    where
        T: Copy,
    {
        CtOption {
            value: *self.value,
            is_some: self.is_some,
        }
    }

    /// Maps a `CtOption<&T>` to `CtOption<T>` by cloning the contents of the option.
    #[must_use = "`self` will be dropped if the result is not used"]
    pub fn cloned(self) -> CtOption<T>
    where
        T: Clone,
    {
        CtOption {
            value: self.value.clone(),
            is_some: self.is_some,
        }
    }
}

impl<T> CtOption<&mut T> {
    /// Maps a `CtOption<&mut T>` to `CtOption<T>` by copying the contents of the option.
    #[must_use = "`self` will be dropped if the result is not used"]
    pub const fn copied(self) -> CtOption<T>
    where
        T: Copy,
    {
        CtOption {
            value: *self.value,
            is_some: self.is_some,
        }
    }

    /// Maps a `CtOption<&mut T>` to `CtOption<T>` by cloning the contents of the option.
    #[must_use = "`self` will be dropped if the result is not used"]
    pub fn cloned(self) -> CtOption<T>
    where
        T: Clone,
    {
        CtOption {
            value: self.value.clone(),
            is_some: self.is_some,
        }
    }
}

impl<T: CtAssign> CtAssign for CtOption<T> {
    fn ct_assign(&mut self, other: &Self, choice: Choice) {
        self.value.ct_assign(&other.value, choice);
        self.is_some.ct_assign(&other.is_some, choice);
    }
}
impl<T: CtAssign> CtAssignSlice for CtOption<T> {}

impl<T: CtEq> CtEq for CtOption<T> {
    #[inline]
    fn ct_eq(&self, other: &CtOption<T>) -> Choice {
        (self.is_some & other.is_some & self.value.ct_eq(&other.value))
            | (self.is_none() & other.is_none())
    }
}

impl<T: CtEq> CtEqSlice for CtOption<T> {}

impl<T: CtSelect> CtSelect for CtOption<T> {
    fn ct_select(&self, other: &Self, choice: Choice) -> Self {
        Self {
            value: self.value.ct_select(&other.value, choice),
            is_some: self.is_some.ct_select(&other.is_some, choice),
        }
    }
}

impl<T: Default> Default for CtOption<T> {
    fn default() -> Self {
        Self::none()
    }
}

/// Convert the [`CtOption`] wrapper into an [`Option`], depending on whether
/// [`CtOption::is_some`] is a truthy or falsy [`Choice`].
///
/// <div class="warning">
/// <b>Warning: variable-time!</b>
///
/// This implementation doesn't intend to be constant-time nor try to protect the leakage of the
/// `T` value since the `Option` will do it anyway.
/// </div>
impl<T> From<CtOption<T>> for Option<T> {
    fn from(src: CtOption<T>) -> Option<T> {
        src.into_option()
    }
}

/// NOTE: in order to be able to unwrap the `subtle::CtOption` we rely on a `Default` bound in
/// order to have a placeholder value, and `ConditionallySelectable` to be able to use `unwrap_or`.
#[cfg(feature = "subtle")]
impl<T> From<subtle::CtOption<T>> for CtOption<T>
where
    T: subtle::ConditionallySelectable + Default,
{
    #[inline]
    fn from(src: subtle::CtOption<T>) -> CtOption<T> {
        let is_some = src.is_some();
        CtOption {
            value: src.unwrap_or(Default::default()),
            is_some: is_some.into(),
        }
    }
}

#[cfg(feature = "subtle")]
impl<T> From<CtOption<T>> for subtle::CtOption<T> {
    #[inline]
    fn from(src: CtOption<T>) -> subtle::CtOption<T> {
        subtle::CtOption::new(src.value, src.is_some.into())
    }
}

#[cfg(feature = "subtle")]
impl<T> subtle::ConditionallySelectable for CtOption<T>
where
    T: Copy, // `ConditionallySelectable` supertrait bound
    Self: CtSelect,
{
    #[inline]
    fn conditional_select(a: &Self, b: &Self, choice: subtle::Choice) -> Self {
        CtSelect::ct_select(a, b, choice.into())
    }
}

#[cfg(feature = "subtle")]
impl<T> subtle::ConstantTimeEq for CtOption<T>
where
    Self: CtEq,
{
    #[inline]
    fn ct_eq(&self, other: &Self) -> subtle::Choice {
        CtEq::ct_eq(self, other).into()
    }
}

#[cfg(test)]
mod tests {
    use crate::{Choice, CtEq, CtOption, CtSelect};

    /// Example wrapped value for testing
    const VALUE: u8 = 42;

    /// Example option which is like `Option::Some`
    const SOME: CtOption<u8> = CtOption::new(VALUE, Choice::TRUE);

    /// Example option which is like `Option::None`
    const NONE: CtOption<u8> = CtOption::new(VALUE, Choice::FALSE);

    /// Another option containing a different value
    const OTHER: CtOption<u8> = CtOption::new(VALUE + 1, Choice::TRUE);

    /// Dummy error type
    #[derive(Debug, Eq, PartialEq)]
    struct Error;

    #[test]
    fn map_macro() {
        assert!(map!(NONE, u16::from).is_none().to_bool());
        assert_eq!(map!(SOME, u16::from).unwrap(), u16::from(VALUE));
    }

    #[test]
    fn unwrap_or_macro() {
        // Don't actually use this! It's just a test function implemented in variable-time
        #[allow(clippy::trivially_copy_pass_by_ref)]
        const fn select_vartime(a: &u8, b: &u8, choice: Choice) -> u8 {
            if choice.to_bool_vartime() { *b } else { *a }
        }

        assert_eq!(
            unwrap_or!(NONE, OTHER.unwrap(), select_vartime),
            OTHER.unwrap()
        );
        assert_eq!(unwrap_or!(SOME, OTHER.unwrap(), select_vartime), VALUE);
    }

    #[test]
    fn ct_eq() {
        assert!(NONE.ct_eq(&NONE).to_bool());
        assert!(NONE.ct_ne(&SOME).to_bool());
        assert!(SOME.ct_ne(&NONE).to_bool());
        assert!(SOME.ct_eq(&SOME).to_bool());
        assert!(SOME.ct_ne(&OTHER).to_bool());
    }

    #[test]
    fn ct_select() {
        assert!(NONE.ct_select(&SOME, Choice::FALSE).is_none().to_bool());
        assert!(NONE.ct_select(&SOME, Choice::TRUE).ct_eq(&SOME).to_bool());
        assert!(SOME.ct_select(&NONE, Choice::FALSE).ct_eq(&SOME).to_bool());
        assert!(SOME.ct_select(&NONE, Choice::TRUE).is_none().to_bool());
    }

    #[test]
    fn default() {
        assert!(NONE.ct_eq(&CtOption::default()).to_bool());
    }

    #[test]
    fn expect_some() {
        assert_eq!(SOME.expect("should succeed"), VALUE);
    }

    #[test]
    #[should_panic]
    fn expect_none() {
        let _ = NONE.expect("should panic");
    }

    #[test]
    fn into_option() {
        assert_eq!(SOME.into_option(), Some(VALUE));
        assert_eq!(NONE.into_option(), None);
    }

    #[test]
    fn into_option_copied() {
        assert_eq!(SOME.into_option_copied(), Some(VALUE));
        assert_eq!(NONE.into_option_copied(), None);
    }

    #[test]
    fn is_some() {
        assert!(SOME.is_some().to_bool());
        assert!(!NONE.is_some().to_bool());
    }

    #[test]
    fn is_none() {
        assert!(!SOME.is_none().to_bool());
        assert!(NONE.is_none().to_bool());
    }

    #[test]
    fn and() {
        assert!(SOME.and(NONE).is_none().to_bool());
        assert_eq!(SOME.and(OTHER).unwrap(), OTHER.unwrap());
    }

    #[test]
    fn and_then() {
        assert!(NONE.and_then(|_| NONE).is_none().to_bool());
        assert!(NONE.and_then(|_| SOME).is_none().to_bool());

        let ret = SOME.and_then(|value| {
            assert_eq!(VALUE, value);
            OTHER
        });
        assert!(ret.ct_eq(&OTHER).to_bool());
    }

    #[test]
    fn filter() {
        assert!(NONE.filter(|_| Choice::TRUE).ct_eq(&NONE).to_bool());
        assert!(NONE.filter(|_| Choice::FALSE).ct_eq(&NONE).to_bool());
        assert!(SOME.filter(|_| Choice::FALSE).ct_eq(&NONE).to_bool());

        let ret = SOME.filter(|&value| {
            assert_eq!(VALUE, value);
            Choice::TRUE
        });
        assert_eq!(ret.unwrap(), VALUE);
    }

    #[test]
    fn filter_by() {
        assert!(NONE.filter_by(Choice::FALSE).is_none().to_bool());
        assert!(NONE.filter_by(Choice::TRUE).is_none().to_bool());
        assert!(SOME.filter_by(Choice::FALSE).ct_eq(&NONE).to_bool());
        assert_eq!(SOME.filter_by(Choice::TRUE).unwrap(), VALUE);
    }

    #[test]
    fn insert() {
        let mut example = NONE;
        assert!(example.is_none().to_bool());

        let ret = example.insert(42);
        assert_eq!(ret, &42);
        assert!(example.is_some().to_bool());
    }

    #[test]
    fn insert_if() {
        let mut example = NONE;
        assert!(example.is_none().to_bool());

        example.insert_if(&42, Choice::FALSE);
        assert!(example.is_none().to_bool());

        example.insert_if(&42, Choice::TRUE);
        assert_eq!(example.unwrap(), 42);
    }

    #[test]
    fn map() {
        assert!(NONE.map(|value| value + 1).ct_eq(&NONE).to_bool());
        assert!(SOME.map(|value| value + 1).ct_eq(&OTHER).to_bool());
    }

    #[test]
    fn map_or() {
        let example = 52;
        assert_eq!(NONE.map_or(example, |value| value + 1), example);
        assert_eq!(SOME.map_or(example, |value| value + 1), VALUE + 1);
    }

    #[test]
    fn map_or_default() {
        assert_eq!(NONE.map_or_default(|value| value + 1), Default::default());
        assert_eq!(SOME.map_or_default(|value| value + 1), VALUE + 1);
    }

    #[test]
    fn ok_or() {
        assert_eq!(NONE.ok_or(Error), Err(Error));
        assert_eq!(SOME.ok_or(Error), Ok(VALUE));
    }

    #[test]
    fn ok_or_else() {
        assert_eq!(NONE.ok_or_else(|| Error), Err(Error));
        assert_eq!(SOME.ok_or_else(|| Error), Ok(VALUE));
    }

    #[test]
    fn or() {
        assert!(NONE.or(NONE).is_none().to_bool());
        assert!(SOME.or(NONE).ct_eq(&SOME).to_bool());
        assert!(NONE.or(SOME).ct_eq(&SOME).to_bool());
        assert!(SOME.or(OTHER).ct_eq(&SOME).to_bool());
    }

    #[test]
    fn some() {
        assert!(CtOption::some(VALUE).ct_eq(&SOME).to_bool());
    }

    #[test]
    fn unwrap_some() {
        assert_eq!(SOME.unwrap(), VALUE);
    }

    #[test]
    #[should_panic]
    fn unwrap_none() {
        let _ = NONE.unwrap();
    }

    #[test]
    fn unwrap_or() {
        let example = 52;
        assert_eq!(NONE.unwrap_or(example), example);
        assert_eq!(SOME.unwrap_or(example), VALUE);
    }

    #[test]
    fn unwrap_or_default() {
        assert_eq!(NONE.unwrap_or_default(), Default::default());
        assert_eq!(SOME.unwrap_or_default(), VALUE);
    }

    #[test]
    fn xor() {
        assert!(NONE.xor(NONE).is_none().to_bool());
        assert!(SOME.xor(NONE).ct_eq(&SOME).to_bool());
        assert!(NONE.xor(SOME).ct_eq(&SOME).to_bool());
        assert!(SOME.xor(OTHER).is_none().to_bool());
    }

    #[test]
    fn zip() {
        assert!(NONE.zip(NONE).is_none().to_bool());
        assert!(NONE.zip(SOME).is_none().to_bool());
        assert!(SOME.zip(NONE).is_none().to_bool());
        assert_eq!(SOME.zip(OTHER).unwrap(), (SOME.unwrap(), OTHER.unwrap()));
    }

    #[test]
    fn zip_with() {
        assert!(NONE.zip_with(NONE, |a, b| a + b).is_none().to_bool());
        assert!(NONE.zip_with(SOME, |a, b| a + b).is_none().to_bool());
        assert!(SOME.zip_with(NONE, |a, b| a + b).is_none().to_bool());
        assert_eq!(
            SOME.zip_with(OTHER, |a, b| a + b).unwrap(),
            SOME.unwrap() + OTHER.unwrap()
        );
    }
}
