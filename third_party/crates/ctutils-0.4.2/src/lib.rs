#![no_std]
#![doc = include_str!("../README.md")]
#![doc(
    html_logo_url = "https://raw.githubusercontent.com/RustCrypto/meta/master/logo.svg",
    html_favicon_url = "https://raw.githubusercontent.com/RustCrypto/meta/master/logo.svg"
)]
#![forbid(unsafe_code)] // `unsafe` should go in `cmov`
#![warn(
    clippy::arithmetic_side_effects,
    clippy::integer_division_remainder_used,
    clippy::panic
)]

//! # API Design
//!
//! ## [`Choice`]: constant-time analogue for [`bool`]
//! Values of this type are one of either [`Choice::FALSE`] or [`Choice::TRUE`].
//!
//! To achieve constant-time operation, `Choice` is ultimately used in combination with special
//! CPU-specific constant-time predication instructions implemented by the [`cmov`] crate
//! (with a portable "best effort" fallback that cannot provide guarantees).
//!
//! It additionally uses various methods to hint to the compiler that it should avoid inserting
//! branches based on its value where it otherwise would if `bool` were used instead, but cannot
//! provide guarantees in this regard.
//!
//! ## [`CtOption`]: constant-time analogue for [`Option`]
//! The core `Option` type is typically great for representing the conditional absence or presence
//! of a value, and provides a number of handy combinators for operating on them.
//!
//! However, it has a rather fundamental flaw when constant-time is desirable: its combinators are
//! lazily evaluated. To ensure constant-time operation, all combinators must be eagerly evaluated
//! so they aren't conditionally executed based on the value's presence.
//!
//! `CtOption` instead carries a `Choice` along with a value, which makes it possible to do
//! something it isn't with `Option`: evaluate combinators eagerly instead of lazily, running the
//! same functions regardless of the value's effective presence or absence.
//!
//! ## [`CtAssign`]: constant-time additional assignment using [predication]
//! Support for conditionally assigning to a type or slices thereof (for types which impl the
//! [`CtAssignSlice`] trait) based on a provided condition value.
//!
//! Uses predication instructions or a portable simulation thereof to perform constant-time
//! conditional assignment based ona  [`Choice`].
//!
//! *NOTE: for `subtle` users, this trait provides the equivalent of the
//! `ConditionallySelectable::conditional_assign` method, but as its own trait without a `Sized`
//! bound so it can also be impl'd for slices*
//!
//! ## [`CtEq`]: constant-time analogue for [`PartialEq`]/[`Eq`]
//! Equality testing often short circuits for performance reasons, but when comparing values in
//! constant-time such short-circuiting is forbidden.
//!
//! The `CtEq` trait is a replacement for these scenarios. It's impl'd for several core types
//! including unsigned and signed integers as well as slices and arrays. It returns a `Choice`
//! as opposed to a `bool`], following the standard practice in this crate.
//!
//! *NOTE: for `subtle` users, this is the equivalent of the `ConstantTimeEq` trait*
//!
//! ## [`CtSelect`]: constant-time [predication]
//! Predication in computer architecture describes methods for conditionally modifying state
//! using non-branch instructions which perform conditional modifications based on a *predicate*
//! or boolean value, in the design of this library a `Choice`.
//!
//! The `CtSelect` trait provides methods for performing conditional selection between two
//! different inputs and returning a new one.
//!
//! *NOTE: for `subtle` users, this is the equivalent of the `ConditionallySelectable` trait*
//!
//! [predication]: https://en.wikipedia.org/wiki/Predication_(computer_architecture)
//!
//! # [`subtle`] interop
//!
//! When the `subtle` feature of this crate is enabled, bidirectional [`From`] impls are available
//! for the following types:
//!
//! - [`Choice`] <=> [`subtle::Choice`]
//! - [`CtOption`] <=> [`subtle::CtOption`]
//!
//! This makes it possible to use `ctutils` in a codebase where other dependencies are using
//! `subtle`.
//!
//! # [`subtle`] migration guide
//!
//! This library presents an API which is largely the same shape as `subtle` and amenable to mostly
//! mechanical find-and-replace updates. Using the above `subtle` interop, you can also migrate
//! incrementally by converting `ctutils::Choice` <=> `subtle::Choice` and `ctutils::CtOption`
//! <=> `subtle::CtOption`.
//!
//! The following substitutions can be used to perform the migration:
//!
//! 1. `subtle` => `ctutils`
//! 2. `ConstantTimeEq` => `CtEq`, `ConstantTimeGreater` => `CtGt`, `ConstantTimeLess` => `CtLt`.
//!    - These all use the same `ct_eq`/`ct_gt`/`ct_lt` method names as `subtle` with the same type
//!      signatures, so only the trait names need to be changed.
//! 3. `ConditionallySelectable` => `CtSelect`, `conditional_select` => `ct_select`.
//!    - Note that `ct_select` has a slightly different type signature in that it accepts `&self`
//!      as the LHS argument. This needs to be changed in the `impl` blocks, but call sites are
//!      compatible if you update the method name alone because it's valid "fully qualified syntax".
//!      Changing them from `T::conditional_select(&a, &b, choice)` => `a.ct_select(&b, choice)`
//!      may still be nice for brevity.
//!    - `conditional_assign` => `CtAssign::ct_assign`: this one will require some manual work as
//!      this method has been split out of `ConditionallySelectable` into its own `CtAssign` trait,
//!      which makes it possible to impl on DSTs like slices which can't be returned from a select
//!      operation because they're `!Sized`.
//! 4. `ConditionallyNegatable` => `CtNeg`, `conditional_negate` => `ct_neg`
//!
//! ## `CtOption` notes
//!
//! A notable semantic change from `subtle` is combinators like `CtOption::map` no longer have a
//! `Default` bound and will call the provided function with the contained value unconditionally.
//!
//! This means whatever value was provided at the time the `CtOption` was constructed now needs to
//! uphold whatever invariants the provided function is expecting.
//!
//! Code which previously constructed a `CtOption` with an invalid inner value that worked with
//! `subtle` because the `Default` value upheld these invariants might break when the provided
//! function is now called with the invalid inner value.
//!
//! See also: [dalek-cryptography/subtle#63](https://github.com/dalek-cryptography/subtle/issues/63)

#[cfg(feature = "alloc")]
extern crate alloc;

mod choice;
mod ct_option;
mod traits;

pub use choice::Choice;
pub use ct_option::CtOption;
pub use traits::{
    ct_assign::{CtAssign, CtAssignSlice},
    ct_eq::{CtEq, CtEqSlice},
    ct_find::CtFind,
    ct_gt::CtGt,
    ct_lookup::CtLookup,
    ct_lt::CtLt,
    ct_neg::CtNeg,
    ct_select::{CtSelect, CtSelectArray, CtSelectUsingCtAssign},
};
