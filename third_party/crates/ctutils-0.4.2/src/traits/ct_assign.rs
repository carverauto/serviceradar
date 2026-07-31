use crate::Choice;
use cmov::Cmov;
use core::{
    cmp,
    num::{
        NonZeroI8, NonZeroI16, NonZeroI32, NonZeroI64, NonZeroI128, NonZeroIsize, NonZeroU8,
        NonZeroU16, NonZeroU32, NonZeroU64, NonZeroU128, NonZeroUsize,
    },
};

#[cfg(feature = "subtle")]
use crate::CtSelect;

#[cfg(doc)]
use core::num::NonZero;

/// Constant-time conditional assignment: assign a given value to another based on a [`Choice`].
///
/// This crate provides built-in implementations for the following types:
/// - [`i8`], [`i16`], [`i32`], [`i64`], [`i128`], [`isize`]
/// - [`u8`], [`u16`], [`u32`], [`u64`], [`u128`], [`usize`]
/// - [`NonZeroI8`], [`NonZeroI16`], [`NonZeroI32`], [`NonZeroI64`], [`NonZeroI128`], [`NonZeroI128`]
/// - [`NonZeroU8`], [`NonZeroU16`], [`NonZeroU32`], [`NonZeroU64`], [`NonZeroU128`],, [`NonZeroUsize`]
/// - [`cmp::Ordering`]
/// - [`Choice`]
/// - `[T]` and `[T; N]` where `T` impls [`CtAssignSlice`], which the previously mentioned
///   types all do.
pub trait CtAssign<Rhs: ?Sized = Self> {
    /// Conditionally assign `src` to `self` if `choice` is [`Choice::TRUE`].
    fn ct_assign(&mut self, src: &Rhs, choice: Choice);
}

/// Implementing this trait enables use of the [`CtAssign`] trait for `[T]` where `T` is the
/// `Self` type implementing the trait, via a blanket impl.
///
/// It needs to be a separate trait from [`CtAssign`] because we need to be able to impl
/// [`CtAssign`] for `[T]` which is `?Sized`.
pub trait CtAssignSlice: CtAssign + Sized {
    /// Conditionally assign `src` to `dst` if `choice` is [`Choice::TRUE`], or leave it unchanged
    /// for [`Choice::FALSE`].
    fn ct_assign_slice(dst: &mut [Self], src: &[Self], choice: Choice) {
        assert_eq!(
            dst.len(),
            src.len(),
            "source slice length ({}) does not match destination slice length ({})",
            src.len(),
            dst.len()
        );

        for (a, b) in dst.iter_mut().zip(src) {
            a.ct_assign(b, choice);
        }
    }
}

impl<T: CtAssignSlice> CtAssign for [T] {
    fn ct_assign(&mut self, src: &[T], choice: Choice) {
        T::ct_assign_slice(self, src, choice);
    }
}

/// Impl `CtAssign` using the `cmov::Cmov` trait
macro_rules! impl_ct_assign_with_cmov {
    ( $($ty:ty),+ ) => {
        $(
            impl CtAssign for $ty {
                #[inline]
                fn ct_assign(&mut self, rhs: &Self, choice: Choice) {
                    self.cmovnz(rhs, choice.into());
                }
            }
        )+
    };
}

/// Impl `CtAssign` and `CtAssignSlice` using the `cmov::Cmov` trait
macro_rules! impl_ct_assign_slice_with_cmov {
    ( $($ty:ty),+ ) => {
        $(
            impl_ct_assign_with_cmov!($ty);

            impl CtAssignSlice for $ty {
                #[inline]
                fn ct_assign_slice(dst: &mut [Self], src: &[Self], choice: Choice) {
                    dst.cmovnz(src, choice.into());
                }
            }
        )+
    };
}

// NOTE: impls `CtAssign` and `CtAssignSlice`
impl_ct_assign_slice_with_cmov!(
    i8,
    i16,
    i32,
    i64,
    i128,
    u8,
    u16,
    u32,
    u64,
    u128,
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

impl_ct_assign_with_cmov!(isize, usize);
impl CtAssignSlice for isize {}
impl CtAssignSlice for usize {}

impl<T, const N: usize> CtAssign for [T; N]
where
    T: CtAssignSlice,
{
    #[inline]
    fn ct_assign(&mut self, rhs: &Self, choice: Choice) {
        self.as_mut_slice().ct_assign(rhs, choice);
    }
}

impl<T, const N: usize> CtAssignSlice for [T; N] where T: CtAssignSlice {}

#[cfg(feature = "subtle")]
impl CtAssign for subtle::Choice {
    #[inline]
    fn ct_assign(&mut self, rhs: &Self, choice: Choice) {
        *self = Self::ct_select(self, rhs, choice);
    }
}

#[cfg(feature = "subtle")]
impl<T> CtAssign for subtle::CtOption<T>
where
    T: Default + subtle::ConditionallySelectable,
{
    #[inline]
    fn ct_assign(&mut self, rhs: &Self, choice: Choice) {
        use subtle::ConditionallySelectable as _;
        self.conditional_assign(rhs, choice.into());
    }
}
#[cfg(feature = "alloc")]
mod alloc {
    use super::{Choice, CtAssign, CtAssignSlice};
    use ::alloc::{boxed::Box, vec::Vec};

    impl<T> CtAssign for Box<T>
    where
        T: CtAssign,
    {
        #[inline]
        #[track_caller]
        fn ct_assign(&mut self, rhs: &Self, choice: Choice) {
            (**self).ct_assign(rhs, choice);
        }
    }

    impl<T> CtAssign for Box<[T]>
    where
        T: CtAssignSlice,
    {
        #[inline]
        #[track_caller]
        fn ct_assign(&mut self, rhs: &Self, choice: Choice) {
            self.ct_assign(&**rhs, choice);
        }
    }

    impl<T> CtAssign<[T]> for Box<[T]>
    where
        T: CtAssignSlice,
    {
        #[inline]
        #[track_caller]
        fn ct_assign(&mut self, rhs: &[T], choice: Choice) {
            (**self).ct_assign(rhs, choice);
        }
    }

    impl<T> CtAssign for Vec<T>
    where
        T: CtAssignSlice,
    {
        #[inline]
        #[track_caller]
        fn ct_assign(&mut self, rhs: &Self, choice: Choice) {
            self.ct_assign(rhs.as_slice(), choice);
        }
    }

    impl<T> CtAssign<[T]> for Vec<T>
    where
        T: CtAssignSlice,
    {
        #[inline]
        #[track_caller]
        fn ct_assign(&mut self, rhs: &[T], choice: Choice) {
            self.as_mut_slice().ct_assign(rhs, choice);
        }
    }
}
