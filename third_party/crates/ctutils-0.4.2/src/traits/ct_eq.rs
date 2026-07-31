use crate::Choice;
use cmov::CmovEq;
use core::{
    cmp,
    num::{
        NonZeroI8, NonZeroI16, NonZeroI32, NonZeroI64, NonZeroI128, NonZeroU8, NonZeroU16,
        NonZeroU32, NonZeroU64, NonZeroU128,
    },
};

#[cfg(feature = "subtle")]
use crate::CtOption;

/// Constant-time equality: like `(Partial)Eq` with [`Choice`] instead of [`bool`].
///
/// Impl'd for: [`u8`], [`u16`], [`u32`], [`u64`], [`u128`], [`usize`], [`cmp::Ordering`],
/// [`Choice`], and arrays/slices of any type which also impls [`CtEq`].
///
/// This crate provides built-in implementations for the following types:
/// - [`i8`], [`i16`], [`i32`], [`i64`], [`i128`], [`isize`]
/// - [`u8`], [`u16`], [`u32`], [`u64`], [`u128`], [`usize`]
/// - [`NonZeroI8`], [`NonZeroI16`], [`NonZeroI32`], [`NonZeroI64`], [`NonZeroI128`]
/// - [`NonZeroU8`], [`NonZeroU16`], [`NonZeroU32`], [`NonZeroU64`], [`NonZeroU128`]
/// - [`cmp::Ordering`]
/// - [`Choice`]
/// - `[T]` and `[T; N]` where `T` impls [`CtEqSlice`], which the previously mentioned types all do.
pub trait CtEq<Rhs = Self>
where
    Rhs: ?Sized,
{
    /// Determine if `self` is equal to `other` in constant-time.
    #[must_use]
    fn ct_eq(&self, other: &Rhs) -> Choice;

    /// Determine if `self` is NOT equal to `other` in constant-time.
    #[must_use]
    fn ct_ne(&self, other: &Rhs) -> Choice {
        !self.ct_eq(other)
    }
}

/// Implementing this trait enables use of the [`CtEq`] trait for `[T]` where `T` is the
/// `Self` type implementing the trait, via a blanket impl.
///
/// It needs to be a separate trait from [`CtEq`] because we need to be able to impl
/// [`CtEq`] for `[T]` which is `?Sized`.
pub trait CtEqSlice: CtEq + Sized {
    /// Determine if `a` is equal to `b` in constant-time.
    #[must_use]
    fn ct_eq_slice(a: &[Self], b: &[Self]) -> Choice {
        let mut ret = a.len().ct_eq(&b.len());
        for (a, b) in a.iter().zip(b.iter()) {
            ret &= a.ct_eq(b);
        }
        ret
    }

    /// Determine if `a` is NOT equal to `b` in constant-time.
    #[must_use]
    fn ct_ne_slice(a: &[Self], b: &[Self]) -> Choice {
        !Self::ct_eq_slice(a, b)
    }
}

impl<T: CtEqSlice> CtEq for [T] {
    fn ct_eq(&self, other: &Self) -> Choice {
        T::ct_eq_slice(self, other)
    }

    fn ct_ne(&self, other: &Self) -> Choice {
        T::ct_ne_slice(self, other)
    }
}

/// Impl `CtEq` using the `cmov::CmovEq` trait
macro_rules! impl_ct_eq_with_cmov_eq {
    ( $($ty:ty),+ ) => {
        $(
            impl CtEq for $ty {
                #[inline]
                fn ct_eq(&self, other: &Self) -> Choice {
                    let mut ret = Choice::FALSE;
                    self.cmoveq(other, 1, &mut ret.0);
                    ret
                }
            }
        )+
    };
}

/// Impl `CtEq` and `CtEqSlice` using the `cmov::CmovEq` trait
macro_rules! impl_ct_eq_slice_with_cmov_eq {
    ( $($ty:ty),+ ) => {
        $(
            impl_ct_eq_with_cmov_eq!($ty);

            impl CtEqSlice for $ty {
                #[inline]
                fn ct_eq_slice(a: &[Self], b: &[Self]) -> Choice {
                    let mut ret = Choice::FALSE;
                    a.cmoveq(b, 1, &mut ret.0);
                    ret
                }
            }
        )+
    };
}

impl_ct_eq_slice_with_cmov_eq!(i8, i16, i32, i64, i128, u8, u16, u32, u64, u128);
impl_ct_eq_with_cmov_eq!(isize, usize);
impl CtEqSlice for isize {}
impl CtEqSlice for usize {}

/// Impl `CtEq` for `NonZero<T>` by calling `NonZero::get`.
macro_rules! impl_ct_eq_for_nonzero_integer {
    ( $($ty:ty),+ ) => {
        $(
            impl CtEq for $ty {
                #[inline]
                fn ct_eq(&self, other: &Self) -> Choice {
                    self.get().ct_eq(&other.get())
                }
            }

            impl CtEqSlice for $ty {}
        )+
    };
}

impl_ct_eq_for_nonzero_integer!(
    NonZeroI8,
    NonZeroI16,
    NonZeroI32,
    NonZeroI64,
    NonZeroI128,
    NonZeroU8,
    NonZeroU16,
    NonZeroU32,
    NonZeroU64,
    NonZeroU128
);

impl CtEq for cmp::Ordering {
    #[inline]
    fn ct_eq(&self, other: &Self) -> Choice {
        // `Ordering` is `repr(i8)`, which has a `CtEq` impl
        (*self as i8).ct_eq(&(*other as i8))
    }
}

impl CtEqSlice for cmp::Ordering {}

impl<T, const N: usize> CtEq for [T; N]
where
    T: CtEqSlice,
{
    #[inline]
    fn ct_eq(&self, other: &[T; N]) -> Choice {
        self.as_slice().ct_eq(other.as_slice())
    }
}

impl<T, const N: usize> CtEqSlice for [T; N] where T: CtEqSlice {}

#[cfg(feature = "subtle")]
impl CtEq for subtle::Choice {
    #[inline]
    fn ct_eq(&self, other: &Self) -> Choice {
        self.unwrap_u8().ct_eq(&other.unwrap_u8())
    }
}

#[cfg(feature = "subtle")]
impl<T> CtEq for subtle::CtOption<T>
where
    T: CtEq + Default + subtle::ConditionallySelectable,
{
    #[inline]
    fn ct_eq(&self, other: &Self) -> Choice {
        CtOption::from(*self).ct_eq(&CtOption::from(*other))
    }
}

#[cfg(feature = "alloc")]
mod alloc {
    use super::{Choice, CtEq, CtEqSlice};
    use ::alloc::{boxed::Box, vec::Vec};

    impl<T> CtEq for Box<T>
    where
        T: CtEq,
    {
        #[inline]
        #[track_caller]
        fn ct_eq(&self, rhs: &Self) -> Choice {
            (**self).ct_eq(rhs)
        }
    }

    impl<T> CtEq for Box<[T]>
    where
        T: CtEqSlice,
    {
        #[inline]
        #[track_caller]
        fn ct_eq(&self, rhs: &Self) -> Choice {
            self.ct_eq(&**rhs)
        }
    }

    impl<T> CtEq<[T]> for Box<[T]>
    where
        T: CtEqSlice,
    {
        #[inline]
        #[track_caller]
        fn ct_eq(&self, rhs: &[T]) -> Choice {
            (**self).ct_eq(rhs)
        }
    }

    impl<T> CtEq for Vec<T>
    where
        T: CtEqSlice,
    {
        #[inline]
        #[track_caller]
        fn ct_eq(&self, rhs: &Self) -> Choice {
            self.ct_eq(rhs.as_slice())
        }
    }

    impl<T> CtEq<[T]> for Vec<T>
    where
        T: CtEqSlice,
    {
        #[inline]
        #[track_caller]
        fn ct_eq(&self, rhs: &[T]) -> Choice {
            self.as_slice().ct_eq(rhs)
        }
    }
}

#[cfg(test)]
mod tests {
    use super::CtEq;
    use core::cmp::Ordering;

    macro_rules! truth_table {
        ($a:expr, $b:expr, $c:expr) => {
            assert!($a.ct_eq(&$b).to_bool());
            assert!(!$a.ct_eq(&$c).to_bool());
            assert!(!$b.ct_eq(&$c).to_bool());

            assert!(!$a.ct_ne(&$b).to_bool());
            assert!($a.ct_ne(&$c).to_bool());
            assert!($b.ct_ne(&$c).to_bool());
        };
    }

    macro_rules! ct_eq_test_unsigned {
        ($ty:ty, $name:ident) => {
            #[test]
            fn $name() {
                let a = <$ty>::MAX;
                let b = <$ty>::MAX;
                let c = <$ty>::MIN;
                truth_table!(a, b, c);
            }
        };
    }

    macro_rules! ct_eq_test_signed {
        ($ty:ty, $name:ident) => {
            #[test]
            fn $name() {
                let a = <$ty>::MAX;
                let b = <$ty>::MAX;
                let c = <$ty>::MIN;
                truth_table!(a, b, c);
            }
        };
    }

    ct_eq_test_unsigned!(u8, u8_ct_eq);
    ct_eq_test_unsigned!(u16, u16_ct_eq);
    ct_eq_test_unsigned!(u32, u32_ct_eq);
    ct_eq_test_unsigned!(u64, u64_ct_eq);
    ct_eq_test_unsigned!(u128, u128_ct_eq);
    ct_eq_test_unsigned!(usize, usize_ct_eq);

    ct_eq_test_signed!(i8, i8_ct_eq);
    ct_eq_test_signed!(i16, i16_ct_eq);
    ct_eq_test_signed!(i32, i32_ct_eq);
    ct_eq_test_signed!(i64, i64_ct_eq);
    ct_eq_test_signed!(i128, i128_ct_eq);
    ct_eq_test_signed!(isize, isize_ct_eq);

    #[test]
    fn array_ct_eq() {
        let a = [1u64, 2, 3];
        let b = [1u64, 2, 3];
        let c = [1u64, 2, 4];
        truth_table!(a, b, c);
    }

    #[test]
    fn ordering_ct_eq() {
        let a = Ordering::Greater;
        let b = Ordering::Greater;
        let c = Ordering::Less;
        truth_table!(a, b, c);
    }

    #[test]
    fn slice_ct_eq() {
        let a: &[u64] = &[1, 2, 3];
        let b: &[u64] = &[1, 2, 3];
        let c: &[u64] = &[1, 2, 4];
        truth_table!(a, b, c);

        // Length mismatches
        assert!(a.ct_ne(&[]).to_bool());
        assert!(a.ct_ne(&[1, 2]).to_bool());
    }
}
