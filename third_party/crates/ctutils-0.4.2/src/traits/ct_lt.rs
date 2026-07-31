use crate::Choice;
use core::{
    cmp,
    num::{NonZeroU8, NonZeroU16, NonZeroU32, NonZeroU64, NonZeroU128, NonZeroUsize},
};

/// Constant time less than.
pub trait CtLt {
    /// Compute whether `self < other` in constant time.
    #[must_use]
    fn ct_lt(&self, other: &Self) -> Choice;
}

// Impl `CtLt` using overflowing subtraction
macro_rules! impl_unsigned_ct_lt {
    ( $($uint:ty),+ ) => {
        $(
            impl CtLt for $uint {
                #[inline]
                fn ct_lt(&self, other: &Self) -> Choice {
                    let (_, overflow) = self.overflowing_sub(*other);
                    Choice(overflow.into())
                }
            }
        )+
    };
}

impl_unsigned_ct_lt!(u8, u16, u32, u64, u128, usize);

/// Impl `CtLt` for `NonZero<T>` by calling `NonZero::get`.
macro_rules! impl_ct_lt_for_nonzero_integer {
    ( $($ty:ty),+ ) => {
        $(
            impl CtLt for $ty {
                #[inline]
                fn ct_lt(&self, other: &Self) -> Choice {
                    self.get().ct_lt(&other.get())
                }
            }
        )+
    };
}

impl_ct_lt_for_nonzero_integer!(
    NonZeroU8,
    NonZeroU16,
    NonZeroU32,
    NonZeroU64,
    NonZeroU128,
    NonZeroUsize
);

impl CtLt for cmp::Ordering {
    #[inline]
    #[allow(clippy::arithmetic_side_effects, clippy::cast_sign_loss)]
    fn ct_lt(&self, other: &Self) -> Choice {
        // No impl of `CtLt` for `i8`, so use `u8`
        // TODO(tarcieri): use `cast_signed` when MSRV is 1.87
        let a = (*self as i8) + 1;
        let b = (*other as i8) + 1;

        // TODO(tarcieri): use `cast_unsigned` when MSRV is 1.87
        (a as u8).ct_lt(&(b as u8))
    }
}

#[cfg(test)]
mod tests {
    use super::CtLt;
    use core::cmp::Ordering;

    #[test]
    fn ct_lt() {
        let a = 42u64;
        let b = 43u64;
        assert!(!a.ct_lt(&a).to_bool());
        assert!(a.ct_lt(&b).to_bool());
        assert!(!b.ct_lt(&a).to_bool());
    }

    /// Test `CtLt`
    macro_rules! ct_lt_tests {
         ( $($int:ident),+ ) => {
             $(
                mod $int {
                    use super::CtLt;

                    #[test]
                    fn ct_gt() {
                        let a = <$int>::MIN;
                        let b = <$int>::MAX;
                        assert!(!a.ct_lt(&a).to_bool());
                        assert!(a.ct_lt(&b).to_bool());
                        assert!(!b.ct_lt(&a).to_bool());
                    }

                }
             )+
        };
    }

    ct_lt_tests!(u8, u16, u32, u64, u128, usize);

    #[test]
    fn ordering() {
        assert!(!Ordering::Equal.ct_lt(&Ordering::Equal).to_bool());
        assert!(Ordering::Less.ct_lt(&Ordering::Greater).to_bool());
        assert!(!Ordering::Greater.ct_lt(&Ordering::Less).to_bool());
    }
}
