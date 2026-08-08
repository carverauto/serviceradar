#![no_std]
#![cfg_attr(docsrs, feature(doc_cfg))]
#![doc = include_str!("../README.md")]
#![doc(
    html_logo_url = "https://raw.githubusercontent.com/RustCrypto/meta/master/logo.svg",
    html_favicon_url = "https://raw.githubusercontent.com/RustCrypto/meta/master/logo.svg"
)]
#![allow(clippy::undocumented_unsafe_blocks)] // TODO(tarcieri): document all unsafe blocks
#![warn(
    clippy::arithmetic_side_effects,
    clippy::integer_division_remainder_used,
    clippy::panic
)]

#[macro_use]
mod macros;

mod array;
mod backends;
mod slice;

use core::{
    cmp,
    num::{
        NonZeroI8, NonZeroI16, NonZeroI32, NonZeroI64, NonZeroI128, NonZeroIsize, NonZeroU8,
        NonZeroU16, NonZeroU32, NonZeroU64, NonZeroU128, NonZeroUsize,
    },
};

/// Condition: the argument given to [`Cmov`] and [`CmovEq`] representing an effective boolean
/// condition by virtue of being zero or non-zero.
///
/// Using a `u8` for this type helps prevent rustc optimizers from speculating about it as if it
/// were a boolean value.
pub type Condition = u8;

/// Conditional move
pub trait Cmov {
    /// Move if non-zero.
    ///
    /// Moves `value` to `self` in constant-time if `condition` is non-zero.
    fn cmovnz(&mut self, value: &Self, condition: Condition);

    /// Move if zero.
    ///
    /// Moves `value` to `self` in constant-time if `condition` is equal to zero.
    fn cmovz(&mut self, value: &Self, condition: Condition) {
        let nz = masknz!(condition: Condition);
        self.cmovnz(value, !nz);
    }
}

/// Conditional move with equality comparison
pub trait CmovEq {
    /// Move if both inputs are not equal.
    ///
    /// Moves `input` to `output` in constant-time if `self` and `rhs` are NOT equal.
    fn cmovne(&self, rhs: &Self, input: Condition, output: &mut Condition) {
        let mut tmp = 1u8;
        self.cmoveq(rhs, 0u8, &mut tmp);
        tmp.cmoveq(&1u8, input, output);
    }

    /// Move if both inputs are equal.
    ///
    /// Moves `input` to `output` in constant-time if `self` and `rhs` are equal.
    fn cmoveq(&self, rhs: &Self, input: Condition, output: &mut Condition) {
        let mut tmp = 1u8;
        self.cmovne(rhs, 0u8, &mut tmp);
        tmp.cmoveq(&1, input, output);
    }
}

impl Cmov for u8 {
    #[inline]
    fn cmovnz(&mut self, value: &Self, condition: Condition) {
        let mut tmp = u16::from(*self);
        tmp.cmovnz(&u16::from(*value), condition);
        debug_assert!(u8::try_from(tmp).is_ok());
        *self = (tmp & 0xFF) as u8;
    }

    #[inline]
    fn cmovz(&mut self, value: &Self, condition: Condition) {
        let mut tmp = u16::from(*self);
        tmp.cmovz(&u16::from(*value), condition);
        debug_assert!(u8::try_from(tmp).is_ok());
        *self = (tmp & 0xFF) as u8;
    }
}

impl Cmov for u128 {
    #[inline]
    fn cmovnz(&mut self, value: &Self, condition: Condition) {
        let mut lo = (*self & 0xFFFF_FFFF_FFFF_FFFF) as u64;
        let mut hi = (*self >> 64) as u64;

        lo.cmovnz(&((*value & 0xFFFF_FFFF_FFFF_FFFF) as u64), condition);
        hi.cmovnz(&((*value >> 64) as u64), condition);

        *self = u128::from(lo) | (u128::from(hi) << 64);
    }

    #[inline]
    fn cmovz(&mut self, value: &Self, condition: Condition) {
        let mut lo = (*self & 0xFFFF_FFFF_FFFF_FFFF) as u64;
        let mut hi = (*self >> 64) as u64;

        lo.cmovz(&((*value & 0xFFFF_FFFF_FFFF_FFFF) as u64), condition);
        hi.cmovz(&((*value >> 64) as u64), condition);

        *self = u128::from(lo) | (u128::from(hi) << 64);
    }
}

impl CmovEq for u8 {
    #[inline]
    fn cmoveq(&self, rhs: &Self, input: Condition, output: &mut Condition) {
        u16::from(*self).cmoveq(&u16::from(*rhs), input, output);
    }

    #[inline]
    fn cmovne(&self, rhs: &Self, input: Condition, output: &mut Condition) {
        u16::from(*self).cmovne(&u16::from(*rhs), input, output);
    }
}

impl CmovEq for u128 {
    #[inline]
    fn cmovne(&self, rhs: &Self, input: Condition, output: &mut Condition) {
        let lo = (*self & 0xFFFF_FFFF_FFFF_FFFF) as u64;
        let hi = (*self >> 64) as u64;

        let mut tmp = 1u8;
        lo.cmovne(&((*rhs & 0xFFFF_FFFF_FFFF_FFFF) as u64), 0, &mut tmp);
        hi.cmovne(&((*rhs >> 64) as u64), 0, &mut tmp);
        tmp.cmoveq(&0, input, output);
    }

    #[inline]
    fn cmoveq(&self, rhs: &Self, input: Condition, output: &mut Condition) {
        let lo = (*self & 0xFFFF_FFFF_FFFF_FFFF) as u64;
        let hi = (*self >> 64) as u64;

        let mut tmp = 1u8;
        lo.cmovne(&((*rhs & 0xFFFF_FFFF_FFFF_FFFF) as u64), 0, &mut tmp);
        hi.cmovne(&((*rhs >> 64) as u64), 0, &mut tmp);
        tmp.cmoveq(&1, input, output);
    }
}

/// Impl `Cmov*` by first casting to unsigned then using the unsigned `Cmov` impls
// TODO(tarcieri): use `cast_unsigned`/`cast_signed` to get rid of the `=> u*`
macro_rules! impl_cmov_traits_for_signed_ints {
    ( $($int:ty => $uint:ty),+ ) => {
        $(
            impl Cmov for $int {
                #[inline]
                #[allow(clippy::cast_possible_wrap, clippy::cast_sign_loss)]
                fn cmovnz(&mut self, value: &Self, condition: Condition) {
                    let mut tmp = *self as $uint;
                    tmp.cmovnz(&(*value as $uint), condition);
                    *self = tmp as $int;
                }

                #[inline]
                #[allow(clippy::cast_possible_wrap, clippy::cast_sign_loss)]
                fn cmovz(&mut self, value: &Self, condition: Condition) {
                    let mut tmp = *self as $uint;
                    tmp.cmovz(&(*value as $uint), condition);
                    *self = tmp as $int;
                }
            }

            impl CmovEq for $int {
                #[inline]
                #[allow(clippy::cast_possible_wrap, clippy::cast_sign_loss)]
                fn cmoveq(&self, rhs: &Self, input: Condition, output: &mut Condition) {
                    (*self as $uint).cmoveq(&(*rhs as $uint), input, output);
                }

                #[inline]
                #[allow(clippy::cast_possible_wrap, clippy::cast_sign_loss)]
                fn cmovne(&self, rhs: &Self, input: Condition, output: &mut Condition) {
                    (*self as $uint).cmovne(&(*rhs as $uint), input, output);
                }
            }
        )+
    };
}

impl_cmov_traits_for_signed_ints!(
    i8 => u8,
    i16 => u16,
    i32 => u32,
    i64 => u64,
    i128 => u128
);

macro_rules! impl_cmov_traits_for_size_int {
    ($size:ty, $int16:ty, $int32:ty, $int64:ty) => {
        #[cfg(any(
            target_pointer_width = "16",
            target_pointer_width = "32",
            target_pointer_width = "64"
        ))]
        #[cfg_attr(docsrs, doc(cfg(true)))]
        #[allow(clippy::cast_possible_truncation)]
        impl Cmov for $size {
            #[cfg(target_pointer_width = "16")]
            #[inline]
            fn cmovnz(&mut self, other: &Self, condition: Condition) {
                let mut tmp = *self as $int16;
                tmp.cmovnz(&(*other as $int16), condition);
                *self = tmp as $size;
            }

            #[cfg(target_pointer_width = "32")]
            #[inline]
            fn cmovnz(&mut self, other: &Self, condition: Condition) {
                let mut tmp = *self as $int32;
                tmp.cmovnz(&(*other as $int32), condition);
                *self = tmp as $size;
            }

            #[cfg(target_pointer_width = "64")]
            #[inline]
            fn cmovnz(&mut self, other: &Self, condition: Condition) {
                let mut tmp = *self as $int64;
                tmp.cmovnz(&(*other as $int64), condition);
                *self = tmp as $size;
            }
        }

        #[cfg(any(
            target_pointer_width = "16",
            target_pointer_width = "32",
            target_pointer_width = "64"
        ))]
        #[cfg_attr(docsrs, doc(cfg(true)))]
        #[allow(clippy::cast_possible_truncation)]
        impl CmovEq for $size {
            #[cfg(target_pointer_width = "16")]
            #[inline]
            fn cmovne(&self, rhs: &Self, input: Condition, output: &mut Condition) {
                (*self as $int16).cmovne(&(*rhs as $int16), input, output);
            }

            #[cfg(target_pointer_width = "32")]
            #[inline]
            fn cmovne(&self, rhs: &Self, input: Condition, output: &mut Condition) {
                (*self as $int32).cmovne(&(*rhs as $int32), input, output);
            }

            #[cfg(target_pointer_width = "64")]
            #[inline]
            fn cmovne(&self, rhs: &Self, input: Condition, output: &mut Condition) {
                (*self as $int64).cmovne(&(*rhs as $int64), input, output);
            }
        }
    };
}

impl_cmov_traits_for_size_int!(isize, i16, i32, i64);
impl_cmov_traits_for_size_int!(usize, u16, u32, u64);

/// Impl `Cmov` for `NonZero<T>` by calling the `Cmov` impl for `T`.
macro_rules! impl_cmov_traits_for_nonzero_integers {
    ( $($nzint:ident),+ ) => {
        $(
             impl Cmov for $nzint {
                #[inline]
                fn cmovnz(&mut self, src: &Self, condition: Condition) {
                    let mut n = self.get();
                    n.cmovnz(&src.get(), condition);

                    // SAFETY: we are constructing `NonZero` from a value we obtained from
                    // `NonZero::get`, which ensures it's non-zero.
                    #[allow(unsafe_code)]
                    unsafe { *self = $nzint::new_unchecked(n) }
                }
            }

            impl CmovEq for $nzint {
                #[inline]
                fn cmoveq(&self, rhs: &Self, input: Condition, output: &mut Condition) {
                    self.get().cmoveq(&rhs.get(), input, output);
                }
            }
        )+
    };
}

impl_cmov_traits_for_nonzero_integers!(
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
    NonZeroUsize
);

impl Cmov for cmp::Ordering {
    #[inline]
    fn cmovnz(&mut self, src: &Self, condition: Condition) {
        // `Ordering` is `#[repr(i8)]` where:
        //
        // - `Less` => -1
        // - `Equal` => 0
        // - `Greater` => 1
        //
        // Given this, it's possible to operate on orderings as if they're `i8`, which allows us to
        // use the `CtSelect` impl on `i8` to select between them.
        let mut n = *self as i8;
        n.cmovnz(&(*src as i8), condition);

        // SAFETY: `Ordering` is `#[repr(i8)]` and `ret` has been assigned to
        // a value which was originally a valid `Ordering` then cast to `i8`
        #[allow(trivial_casts, unsafe_code)]
        unsafe {
            *self = *(&raw const n).cast::<Self>();
        }
    }
}

impl CmovEq for cmp::Ordering {
    #[inline]
    fn cmoveq(&self, rhs: &Self, input: Condition, output: &mut Condition) {
        (*self as i8).cmoveq(&(*rhs as i8), input, output);
    }
}
