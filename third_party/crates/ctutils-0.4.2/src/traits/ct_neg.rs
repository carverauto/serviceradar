use crate::{Choice, CtAssign, CtSelect};
use core::num::{
    NonZeroI8, NonZeroI16, NonZeroI32, NonZeroI64, NonZeroI128, NonZeroIsize, NonZeroU8,
    NonZeroU16, NonZeroU32, NonZeroU64, NonZeroU128, NonZeroUsize,
};

/// Constant-time conditional negation: negates a value when `choice` is [`Choice::TRUE`].
pub trait CtNeg: Sized {
    /// Conditionally negate `self`, returning `-self` if `choice` is [`Choice::TRUE`], or `self`
    /// otherwise.
    #[must_use]
    fn ct_neg(&self, choice: Choice) -> Self;

    /// Conditionally negate `self` in-place, replacing it with `-self` if `choice` is
    /// [`Choice::TRUE`].
    fn ct_neg_assign(&mut self, choice: Choice) {
        *self = self.ct_neg(choice);
    }
}

// Impl `CtNeg` for a signed integer (`i*`) type which impls `CtSelect`
macro_rules! impl_signed_ct_neg {
    ( $($int:ty),+ ) => {
        $(
            impl CtNeg for $int {
                #[inline]
                #[allow(clippy::arithmetic_side_effects)]
                fn ct_neg(&self, choice: Choice) -> Self {
                    self.ct_select(&-*self, choice)
                }

                #[inline]
                #[allow(clippy::arithmetic_side_effects)]
                fn ct_neg_assign(&mut self, choice: Choice) {
                    self.ct_assign(&-*self, choice)
                }
            }
        )+
    };
}

// Impl `CtNeg` for an unsigned integer (`u*`) type which impls `CtSelect`
macro_rules! impl_unsigned_ct_neg {
    ( $($uint:ty),+ ) => {
        $(
            impl CtNeg for $uint {
                #[inline]
                fn ct_neg(&self, choice: Choice) -> Self {
                    self.ct_select(&self.wrapping_neg(), choice)
                }

                #[inline]
                fn ct_neg_assign(&mut self, choice: Choice) {
                    self.ct_assign(&self.wrapping_neg(), choice)
                }
            }
        )+
    };
}

impl_signed_ct_neg!(
    i8,
    i16,
    i32,
    i64,
    i128,
    isize,
    NonZeroI8,
    NonZeroI16,
    NonZeroI32,
    NonZeroI64,
    NonZeroI128,
    NonZeroIsize
);
impl_unsigned_ct_neg!(u8, u16, u32, u64, u128, usize);

/// Unfortunately `NonZeroU*` doesn't support `wrapping_neg` for some reason (but `NonZeroI*` does),
/// even though the wrapping negation of any non-zero integer should also be non-zero.
///
/// So we need a special case just for `NonZeroU*`, at least for now.
macro_rules! impl_ct_neg_for_unsigned_nonzero {
    ( $($nzuint:ident),+ ) => {
        $(
            impl CtNeg for $nzuint {
                #[inline]
                fn ct_neg(&self, choice: Choice) -> Self {
                    // TODO(tarcieri): use `NonZero::wrapping_neg` if it becomes available
                    let n = self.get().ct_select(&self.get().wrapping_neg(), choice);
                    $nzuint::new(n).expect("should be non-zero")
                }
            }
        )+
    };
}

impl_ct_neg_for_unsigned_nonzero!(
    NonZeroU8,
    NonZeroU16,
    NonZeroU32,
    NonZeroU64,
    NonZeroU128,
    NonZeroUsize
);

#[cfg(test)]
mod tests {
    /// Test `CtNeg` impl on `i*`
    macro_rules! signed_ct_neg_tests {
         ( $($int:ident),+ ) => {
             $(
                mod $int {
                    use crate::{Choice, CtNeg};

                    #[test]
                    fn ct_neg() {
                        let n: $int = 42;
                        assert_eq!(n, n.ct_neg(Choice::FALSE));
                        assert_eq!(-n, n.ct_neg(Choice::TRUE));
                    }

                    #[test]
                    fn ct_neg_assign() {
                        let n: $int = 42;
                        let mut x = n;
                        x.ct_neg_assign(Choice::FALSE);
                        assert_eq!(n, x);

                        x.ct_neg_assign(Choice::TRUE);
                        assert_eq!(-n, x);
                    }
                }
             )+
        };
    }

    /// Test `CtNeg` impl on `u*`
    macro_rules! unsigned_ct_neg_tests {
         ( $($uint:ident),+ ) => {
             $(
                mod $uint {
                    use crate::{Choice, CtNeg};

                    #[test]
                    fn ct_neg() {
                        let n: $uint = 42;
                        assert_eq!(n, n.ct_neg(Choice::FALSE));
                        assert_eq!(<$uint>::MAX - n + 1, n.ct_neg(Choice::TRUE));
                    }

                    #[test]
                    fn ct_neg_assign() {
                        let n: $uint = 42;
                        let mut x = n;
                        x.ct_neg_assign(Choice::FALSE);
                        assert_eq!(n, x);

                        x.ct_neg_assign(Choice::TRUE);
                        assert_eq!(<$uint>::MAX - n + 1, x);
                    }
                }
             )+
        };
    }

    signed_ct_neg_tests!(i8, i16, i32, i64, i128, isize);
    unsigned_ct_neg_tests!(u8, u16, u32, u64, u128, usize);
}
