use crate::{Choice, CtAssign, CtAssignSlice};
use core::{
    cmp,
    num::{
        NonZeroI8, NonZeroI16, NonZeroI32, NonZeroI64, NonZeroI128, NonZeroIsize, NonZeroU8,
        NonZeroU16, NonZeroU32, NonZeroU64, NonZeroU128, NonZeroUsize,
    },
};

#[cfg(feature = "subtle")]
use crate::CtOption;

/// Constant-time selection: choose between two values based on a given [`Choice`].
///
/// This crate provides built-in implementations for the following types:
/// - [`i8`], [`i16`], [`i32`], [`i64`], [`i128`], [`isize`]
/// - [`u8`], [`u16`], [`u32`], [`u64`], [`u128`], [`usize`]
/// - [`NonZeroI8`], [`NonZeroI16`], [`NonZeroI32`], [`NonZeroI64`], [`NonZeroI128`], [`NonZeroI128`]
/// - [`NonZeroU8`], [`NonZeroU16`], [`NonZeroU32`], [`NonZeroU64`], [`NonZeroU128`],, [`NonZeroUsize`]
/// - [`cmp::Ordering`]
/// - [`Choice`]
/// - `[T; N]` where `T` impls [`CtSelectArray`], which the previously mentioned types all do,
///   as well as any type which impls [`Clone`] + [`CtAssignSlice`] + [`CtSelect`].
pub trait CtSelect: Sized {
    /// Select between `self` and `other` based on `choice`, returning a copy of the value.
    ///
    /// # Returns
    /// - `self` if `choice` is [`Choice::FALSE`].
    /// - `other` if `choice` is [`Choice::TRUE`].
    #[must_use]
    fn ct_select(&self, other: &Self, choice: Choice) -> Self;

    /// Conditionally swap `self` and `other` if `choice` is [`Choice::TRUE`].
    fn ct_swap(&mut self, other: &mut Self, choice: Choice) {
        let tmp = self.ct_select(other, choice);
        *other = Self::ct_select(other, self, choice);
        *self = tmp;
    }
}

/// Implementing this trait enables use of the [`CtSelect`] trait to construct `[T; N]` where `T`
/// is the `Self` type implementing the trait, via a blanket impl.
///
/// All types which impl [`Clone`] + [`CtAssignSlice`] + [`CtSelect`] will receive a blanket impl
/// of this trait and thus also be usable with the [`CtSelect`] impl for `[T; N]`.
pub trait CtSelectArray<const N: usize>: CtSelect + Sized {
    /// Select between `a` and `b` in constant-time based on `choice`.
    #[must_use]
    fn ct_select_array(a: &[Self; N], b: &[Self; N], choice: Choice) -> [Self; N] {
        core::array::from_fn(|i| Self::ct_select(&a[i], &b[i], choice))
    }
}

impl<T, const N: usize> CtSelect for [T; N]
where
    T: CtSelectArray<N>,
{
    #[inline]
    fn ct_select(&self, other: &Self, choice: Choice) -> Self {
        T::ct_select_array(self, other, choice)
    }
}

impl<T, const N: usize> CtSelectArray<N> for T
where
    T: Clone + CtAssignSlice + CtSelect,
{
    #[inline]
    fn ct_select_array(a: &[Self; N], b: &[Self; N], choice: Choice) -> [Self; N] {
        let mut ret = a.clone();
        ret.ct_assign(b, choice);
        ret
    }
}

/// Marker trait which enables a blanket impl of [`CtSelect`] for types which also impl
/// [`Clone`] + [`CtAssign`].
pub trait CtSelectUsingCtAssign: Clone + CtAssign {}

impl<T: CtSelectUsingCtAssign> CtSelect for T {
    #[inline]
    fn ct_select(&self, other: &Self, choice: Choice) -> Self {
        let mut ret = self.clone();
        ret.ct_assign(other, choice);
        ret
    }
}

/// Macro to write impls of `CtSelectUsingCtAssign`.
macro_rules! impl_ct_select_with_ct_assign {
    ( $($ty:ty),+ ) => { $(impl CtSelectUsingCtAssign for $ty {})+ };
}

impl_ct_select_with_ct_assign!(
    i8,
    i16,
    i32,
    i64,
    i128,
    isize,
    u8,
    u16,
    u32,
    u64,
    u128,
    usize,
    NonZeroI8,
    NonZeroI16,
    NonZeroI32,
    NonZeroI64,
    NonZeroI128,
    NonZeroIsize,
    NonZeroU8,
    NonZeroU16,
    NonZeroU32,
    NonZeroU64,
    NonZeroU128,
    NonZeroUsize,
    cmp::Ordering
);

#[cfg(feature = "subtle")]
impl CtSelect for subtle::Choice {
    #[inline]
    fn ct_select(&self, other: &Self, choice: Choice) -> Self {
        Choice::from(*self)
            .ct_select(&Choice::from(*other), choice)
            .into()
    }
}

#[cfg(feature = "subtle")]
impl<T> CtSelect for subtle::CtOption<T>
where
    T: CtSelect + Default + subtle::ConditionallySelectable,
{
    #[inline]
    fn ct_select(&self, other: &Self, choice: Choice) -> Self {
        CtOption::from(*self)
            .ct_select(&CtOption::from(*other), choice)
            .into()
    }
}

#[cfg(feature = "alloc")]
mod alloc {
    use super::CtSelectUsingCtAssign;
    use crate::{CtAssign, CtAssignSlice};
    use ::alloc::{boxed::Box, vec::Vec};

    impl<T: Clone + CtAssign> CtSelectUsingCtAssign for Box<T> {}

    #[cfg(feature = "alloc")]
    impl<T> CtSelectUsingCtAssign for Box<[T]> where T: Clone + CtAssignSlice {}

    #[cfg(feature = "alloc")]
    impl<T: Clone + CtAssignSlice> CtSelectUsingCtAssign for Vec<T> {}
}

#[cfg(test)]
mod tests {
    use super::{Choice, CtSelect, cmp};

    macro_rules! ct_select_test_unsigned {
        ($ty:ty, $name:ident) => {
            #[test]
            fn $name() {
                let a: $ty = 1;
                let b: $ty = 2;
                assert_eq!(a.ct_select(&b, Choice::FALSE), a);
                assert_eq!(a.ct_select(&b, Choice::TRUE), b);
            }
        };
    }

    macro_rules! ct_select_test_signed {
        ($ty:ty, $name:ident) => {
            #[test]
            fn $name() {
                let a: $ty = 1;
                let b: $ty = -2;
                assert_eq!(a.ct_select(&b, Choice::FALSE), a);
                assert_eq!(a.ct_select(&b, Choice::TRUE), b);
            }
        };
    }

    ct_select_test_unsigned!(u8, u8_ct_select);
    ct_select_test_unsigned!(u16, u16_ct_select);
    ct_select_test_unsigned!(u32, u32_ct_select);
    ct_select_test_unsigned!(u64, u64_ct_select);
    ct_select_test_unsigned!(u128, u128_ct_select);
    ct_select_test_unsigned!(usize, usize_ct_select);

    ct_select_test_signed!(i8, i8_ct_select);
    ct_select_test_signed!(i16, i16_ct_select);
    ct_select_test_signed!(i32, i32_ct_select);
    ct_select_test_signed!(i64, i64_ct_select);
    ct_select_test_signed!(i128, i128_ct_select);
    ct_select_test_signed!(isize, isize_ct_select);

    #[test]
    fn ordering_ct_select() {
        let a = cmp::Ordering::Less;
        let b = cmp::Ordering::Greater;
        assert_eq!(a.ct_select(&b, Choice::FALSE), a);
        assert_eq!(a.ct_select(&b, Choice::TRUE), b);
    }
}
