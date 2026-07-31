use crate::Choice;
use core::{
    cmp,
    num::{NonZeroU8, NonZeroU16, NonZeroU32, NonZeroU64, NonZeroU128, NonZeroUsize},
};

/// Constant time greater than.
pub trait CtGt {
    /// Compute whether `self > other` in constant time.
    #[must_use]
    fn ct_gt(&self, other: &Self) -> Choice;
}

// Impl `CtGt` using overflowing subtraction
macro_rules! impl_unsigned_ct_gt {
    ( $($uint:ty),+ ) => {
        $(
            impl CtGt for $uint {
                #[inline]
                fn ct_gt(&self, other: &Self) -> Choice {
                    let (_, overflow) = other.overflowing_sub(*self);
                    Choice(overflow.into())
                }
            }
        )+
    };
}

impl_unsigned_ct_gt!(u8, u16, u32, u64, u128, usize);

/// Impl `CtGt` for `NonZero<T>` by calling `NonZero::get`.
macro_rules! impl_ct_gt_for_nonzero_integer {
    ( $($ty:ty),+ ) => {
        $(
            impl CtGt for $ty {
                #[inline]
                fn ct_gt(&self, other: &Self) -> Choice {
                    self.get().ct_gt(&other.get())
                }
            }
        )+
    };
}

impl_ct_gt_for_nonzero_integer!(
    NonZeroU8,
    NonZeroU16,
    NonZeroU32,
    NonZeroU64,
    NonZeroU128,
    NonZeroUsize
);

impl CtGt for cmp::Ordering {
    #[inline]
    #[allow(clippy::arithmetic_side_effects, clippy::cast_sign_loss)]
    fn ct_gt(&self, other: &Self) -> Choice {
        // No impl of `CtGt` for `i8`, so use `u8`
        // TODO(tarcieri): use `cast_signed` when MSRV is 1.87
        let a = (*self as i8) + 1;
        let b = (*other as i8) + 1;

        // TODO(tarcieri): use `cast_unsigned` when MSRV is 1.87
        (a as u8).ct_gt(&(b as u8))
    }
}

#[cfg(test)]
mod tests {
    use super::CtGt;
    use core::cmp::Ordering;

    /// Test `CtGt`
    macro_rules! ct_gt_tests {
         ( $($int:ident),+ ) => {
             $(
                mod $int {
                    use super::CtGt;

                    #[test]
                    fn ct_gt() {
                        let a = <$int>::MIN;
                        let b = <$int>::MAX;
                        assert!(!a.ct_gt(&a).to_bool());
                        assert!(!a.ct_gt(&b).to_bool());
                        assert!(b.ct_gt(&a).to_bool());
                    }

                }
             )+
        };
    }

    ct_gt_tests!(u8, u16, u32, u64, u128, usize);

    #[test]
    fn ordering() {
        assert!(!Ordering::Equal.ct_gt(&Ordering::Equal).to_bool());
        assert!(!Ordering::Less.ct_gt(&Ordering::Greater).to_bool());
        assert!(Ordering::Greater.ct_gt(&Ordering::Less).to_bool());
    }
}
