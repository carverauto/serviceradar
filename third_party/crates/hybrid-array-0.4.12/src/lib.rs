#![no_std]
#![cfg_attr(docsrs, feature(doc_cfg))]
#![doc = include_str!("../README.md")]
#![doc(
    html_logo_url = "https://raw.githubusercontent.com/RustCrypto/meta/master/logo.svg",
    html_favicon_url = "https://raw.githubusercontent.com/RustCrypto/meta/master/logo.svg"
)]

//! ## Features
//!
//! This crate exposes the following feature flags. The default is NO features.
//!
//! - `bytemuck`: impls the `Pod` and `Zeroable` traits
//! - `serde`: impls the `Deserialize` and `Serialize` traits for `Array`
//! - `zeroize`: impls [`Zeroize`](https://docs.rs/zeroize/latest/zeroize/trait.Zeroize.html) for `Array<T: Zeroize, U>`
//!
//! ## Usage
//!
//! The two core types in this crate are as follows:
//!
//! - [`Array<T, U>`]: wrapper for `[T; N]` where `U` is an [`ArraySize`] provided by [`typenum`]
//!   whose associated [`ArraySize::ArrayType<T>`] determines the inner array size.
//! - [`ArrayN<T, N>`]: type alias for [`Array`] which is const generic around `const N: usize`.
//!   This provides a linkage between const generics and [`typenum`].
//!
//! The [`Array`] type has an inner `pub [T; N]` field, which means writing a literal can be
//! expressed as follows:
//!
//! ```
//! use hybrid_array::{Array, sizes::U4};
//!
//! let arr: Array<u8, U4> = Array([1, 2, 3, 4]);
//! ```
//!
//! ### About [`typenum`]
//!
//! The [`typenum`] crate provides a type-level implementation of numbers and arithmetic operations.
//!
//! While [`typenum`] can be used to express arbitrary integers using the type system, the
//! `hybrid-array` crate is limited to the array sizes in the [`sizes`] module, which have
//! names like [`U0`][`sizes::U0`], [`U1`][`sizes::U1`], [`U2`][`sizes::U2`], [`U3`][`sizes::U3`],
//! etc. All supported sizes will have an impl of [`ArraySize`], which is the trait providing
//! linkage between [`typenum`]-based types and core arrays / const generics.
//!
//! [`ArraySize`] bounds on the [`typenum::Unsigned`] trait, which can be used to obtain integer
//! sizes of arrays via associated constants. For example, to obtain the size of an `ArraySize` as
//! a `usize`, use the associated [`typenum::Unsigned::USIZE`] constant.
//!
//! ### [`AsArrayRef`] and [`AsArrayMut`] traits
//!
//! These traits simplify obtaining references to [`Array`] and are impl'd for both [`Array`]
//! and `[T; N]`. They're analogous to traits like [`AsRef`] and [`AsMut`].
//!
//! They make it possible to write code which uses `[T; N]` or `&[T; N]` in the external facing
//! API which can obtain references to `&Array` and call other functions which accept such
//! references, without the caller having to use `Array` in their code and while still supporting
//! generic sizes.
//!
//! For more information and a code example, see [`AsArrayRef`].
//!
//! ## Relationship with `generic-array`
//!
//! `hybrid-array` is directly inspired by the [`generic-array`] crate.
//!
//! However, where `generic-array` predates const generics and uses a core which is built
//! on `unsafe` code, `hybrid-array`'s core implementation is built on safe code and const
//! generic implementations. This allows the inner `[T; N]` field of an `Array` to be `pub` as
//! noted above, and in general for the implementation to be significantly simpler, easier-to-audit,
//! and with significantly less use of `unsafe`.
//!
//! The only places `hybrid-array` uses unsafe are where it is absolutely necessary, primarily
//! for reference conversions between `Array<T, U>` and `[T; N]`, and also to provide features
//! which are not yet stable in `core`/`std`, such as [`Array::try_from_fn`].
//!
//! [`generic-array`]: https://docs.rs/generic-array
//!
//! ## Migrating from `generic-array`
//!
//! *NOTE: this guide assumes a migration from `generic-array` v0.14*
//!
//! `hybrid-array` has been designed to largely be a drop-in replacement for
//! `generic-array`, albeit with a public inner array type and significantly less
//! `unsafe` code.
//!
//! The bulk of the migration work can be accomplished by making the following find/replace-style
//! substitutions in your `.rs` files:
//!
//! - Replace `generic_array` with `hybrid_array`
//! - Replace `GenericArray<T, U>` with `Array<T, U>`
//! - Replace `ArrayLength<T>` with `ArraySize`
//! - Replace usages of the `Concat` and `Split` traits with [`Array::concat`] and [`Array::split`]
//! - Replace `<U as ArrayLength<T>>::ArrayType` with `<U as ArraySize>::ArrayType<T>`
//! - Replace usages of the `arr![N; A, B, C]` macro with `Array([A, B, C])`
//!
//! If you have any questions, please
//! [start a discussion](https://github.com/RustCrypto/hybrid-array/discussions).

#[cfg(feature = "alloc")]
extern crate alloc;

pub mod sizes;

mod flatten;
mod from_fn;
mod iter;
mod traits;

#[cfg(feature = "serde")]
mod serde;

pub use crate::{
    flatten::{Flatten, Unflatten},
    iter::TryFromIteratorError,
    traits::*,
};
pub use typenum;

use core::{
    array::TryFromSliceError,
    borrow::{Borrow, BorrowMut},
    cmp::Ordering,
    fmt::{self, Debug},
    hash::{Hash, Hasher},
    mem::{self, ManuallyDrop, MaybeUninit},
    ops::{Add, Deref, DerefMut, Index, IndexMut, Sub},
    ptr,
    slice::{self, Iter, IterMut},
};
use typenum::{Diff, Sum, U1};

#[cfg(feature = "arbitrary")]
use arbitrary::Arbitrary;

#[cfg(feature = "bytemuck")]
use bytemuck::{Pod, Zeroable};

#[cfg(feature = "zeroize")]
use zeroize::{Zeroize, ZeroizeOnDrop};

#[cfg(feature = "zerocopy")]
use zerocopy::{FromBytes, Immutable, IntoBytes, KnownLayout, Unaligned};

/// Type alias for [`Array`] which is const generic around a size `N`, ala `[T; N]`.
pub type ArrayN<T, const N: usize> = Array<T, <[T; N] as AssocArraySize>::Size>;

/// [`Array`] is a newtype for an inner `[T; N]` array where `N` is determined by a generic
/// [`ArraySize`] parameter, which is a marker trait for a numeric value determined by ZSTs that
/// impl the [`typenum::Unsigned`] trait.
///
/// The inner `[T; N]` field is `pub` which means it's possible to write [`Array`] literals like:
///
/// [`Array`] is defined as `repr(transparent)`, meaning it can be used anywhere an appropriately
/// sized `[T; N]` type is used in unsafe code / FFI.
///
/// ```
/// use hybrid_array::{Array, sizes::U3};
///
/// let arr: Array<u8, U3> = Array([1, 2, 3]);
/// ```
#[cfg_attr(
    feature = "zerocopy",
    derive(IntoBytes, FromBytes, Immutable, Unaligned, KnownLayout)
)]
#[repr(transparent)]
pub struct Array<T, U: ArraySize>(pub U::ArrayType<T>);

type SplitResult<T, U, N> = (Array<T, N>, Array<T, Diff<U, N>>);
type SplitRefResult<'a, T, U, N> = (&'a Array<T, N>, &'a Array<T, Diff<U, N>>);
type SplitRefMutResult<'a, T, U, N> = (&'a mut Array<T, N>, &'a mut Array<T, Diff<U, N>>);

impl<T, U> Array<T, U>
where
    U: ArraySize,
{
    /// Returns a slice containing the entire array. Equivalent to `&s[..]`.
    #[inline]
    pub const fn as_slice(&self) -> &[T] {
        // SAFETY: `[T]` is layout-identical to `Array<T, U>`, which is a `repr(transparent)`
        // newtype for `[T; N]`.
        unsafe { slice::from_raw_parts(self.as_ptr(), U::USIZE) }
    }

    /// Returns a mutable slice containing the entire array. Equivalent to `&mut s[..]`.
    #[inline]
    pub const fn as_mut_slice(&mut self) -> &mut [T] {
        // SAFETY: `[T]` is layout-identical to `Array<T, U>`, which is a `repr(transparent)`
        // newtype for `[T; N]`.
        unsafe { slice::from_raw_parts_mut(self.as_mut_ptr(), U::USIZE) }
    }

    /// Returns a pointer to the start of the array.
    pub const fn as_ptr(&self) -> *const T {
        ptr::from_ref::<Self>(self).cast::<T>()
    }

    /// Returns a mutable pointer to the start of the array.
    pub const fn as_mut_ptr(&mut self) -> *mut T {
        ptr::from_mut::<Self>(self).cast::<T>()
    }

    /// Returns an iterator over the array.
    #[inline]
    pub fn iter(&self) -> Iter<'_, T> {
        self.as_slice().iter()
    }

    /// Returns an iterator that allows modifying each value.
    #[inline]
    pub fn iter_mut(&mut self) -> IterMut<'_, T> {
        self.0.as_mut().iter_mut()
    }

    /// Returns an array of the same size as `self`, with function `f` applied to each element in
    /// order.
    pub fn map<F, O>(self, f: F) -> Array<O, U>
    where
        F: FnMut(T) -> O,
    {
        self.into_iter().map(f).collect()
    }

    /// Concatenates `self` with `other`.
    #[inline]
    pub fn concat<N>(self, other: Array<T, N>) -> Array<T, Sum<U, N>>
    where
        N: ArraySize,
        U: Add<N>,
        Sum<U, N>: ArraySize,
    {
        let mut c = Array::uninit();
        let (left, right) = c.split_at_mut(self.len());
        for (val, dst) in self.into_iter().zip(left) {
            dst.write(val);
        }
        for (val, dst) in other.into_iter().zip(right) {
            dst.write(val);
        }
        // SAFETY: We wrote to every element of `c`.
        unsafe { c.assume_init() }
    }

    /// Splits `self` at index `N` in two arrays.
    ///
    /// New arrays hold the original memory from `self`.
    #[inline]
    pub fn split<N>(self) -> SplitResult<T, U, N>
    where
        U: Sub<N>,
        N: ArraySize,
        Diff<U, N>: ArraySize,
    {
        unsafe {
            let array = ManuallyDrop::new(self);
            let head = ptr::read(array.as_ptr().cast());
            let tail = ptr::read(array.as_ptr().add(N::USIZE).cast());
            (head, tail)
        }
    }

    /// Splits `&self` at index `N` in two array references.
    #[inline]
    pub fn split_ref<N>(&self) -> SplitRefResult<'_, T, U, N>
    where
        U: Sub<N>,
        N: ArraySize,
        Diff<U, N>: ArraySize,
    {
        unsafe {
            let array_ptr = self.as_ptr();
            let head = &*array_ptr.cast();
            let tail = &*array_ptr.add(N::USIZE).cast();
            (head, tail)
        }
    }

    /// Splits `&mut self` at index `N` in two mutable array references.
    #[inline]
    pub fn split_ref_mut<N>(&mut self) -> SplitRefMutResult<'_, T, U, N>
    where
        U: Sub<N>,
        N: ArraySize,
        Diff<U, N>: ArraySize,
    {
        unsafe {
            let array_ptr = self.as_mut_ptr();
            let head = &mut *array_ptr.cast();
            let tail = &mut *array_ptr.add(N::USIZE).cast();
            (head, tail)
        }
    }

    /// Get a reference to an array from a slice, if the slice is exactly the size of the array.
    ///
    /// Returns `None` if the slice's length is not exactly equal to the array size.
    #[inline]
    #[must_use]
    pub const fn slice_as_array(slice: &[T]) -> Option<&Self> {
        if slice.len() == U::USIZE {
            // SAFETY: `Self` is ensured to be layout-identical to `[T; U::USIZE]`, and immediately
            // above we validated that `slice` is also layout-identical to `[T; U::USIZE]`,
            // therefore the cast is valid.
            unsafe { Some(&*slice.as_ptr().cast()) }
        } else {
            None
        }
    }

    /// Get a mutable reference to an array from a slice, if the slice is exactly the size of the
    /// array.
    ///
    /// Returns `None` if the slice's length is not exactly equal to the array size.
    #[inline]
    #[must_use]
    pub const fn slice_as_mut_array(slice: &mut [T]) -> Option<&mut Self> {
        if slice.len() == U::USIZE {
            // SAFETY: `Self` is ensured to be layout-identical to `[T; U::USIZE]`, and immediately
            // above we validated that `slice` is also layout-identical to `[T; U::USIZE]`,
            // therefore the cast is valid.
            unsafe { Some(&mut *slice.as_mut_ptr().cast()) }
        } else {
            None
        }
    }

    /// Splits the shared slice into a slice of `U`-element arrays, starting at the beginning
    /// of the slice, and a remainder slice with length strictly less than `U`.
    ///
    /// # Panics
    /// Panics if `U` is 0.
    #[allow(clippy::arithmetic_side_effects)]
    #[inline]
    pub const fn slice_as_chunks(buf: &[T]) -> (&[Self], &[T]) {
        assert!(U::USIZE != 0, "chunk size must be non-zero");
        // Arithmetic safety: we have checked that `N::USIZE` is not zero, thus
        // division always returns correct result. `tail_pos` can not be bigger than `buf.len()`,
        // thus overflow on multiplication and underflow on substraction are impossible.
        let chunks_len = buf.len() / U::USIZE;
        let tail_pos = U::USIZE * chunks_len;
        let tail_len = buf.len() - tail_pos;
        unsafe {
            let ptr = buf.as_ptr();
            let chunks = slice::from_raw_parts(ptr.cast(), chunks_len);
            let tail = slice::from_raw_parts(ptr.add(tail_pos), tail_len);
            (chunks, tail)
        }
    }

    /// Splits the exclusive slice into a slice of `U`-element arrays, starting at the beginning
    /// of the slice, and a remainder slice with length strictly less than `U`.
    ///
    /// # Panics
    /// Panics if `U` is 0.
    #[allow(clippy::arithmetic_side_effects)]
    #[inline]
    pub const fn slice_as_chunks_mut(buf: &mut [T]) -> (&mut [Self], &mut [T]) {
        assert!(U::USIZE != 0, "chunk size must be non-zero");
        // Arithmetic safety: we have checked that `N::USIZE` is not zero, thus
        // division always returns correct result. `tail_pos` can not be bigger than `buf.len()`,
        // thus overflow on multiplication and underflow on substraction are impossible.
        let chunks_len = buf.len() / U::USIZE;
        let tail_pos = U::USIZE * chunks_len;
        let tail_len = buf.len() - tail_pos;
        unsafe {
            let ptr = buf.as_mut_ptr();
            let chunks = slice::from_raw_parts_mut(ptr.cast(), chunks_len);
            let tail = slice::from_raw_parts_mut(ptr.add(tail_pos), tail_len);
            (chunks, tail)
        }
    }

    /// Obtain a flattened slice from a slice of array chunks.
    ///
    /// # Panics
    /// - if the length calculation for the flattened slice overflows
    #[inline]
    pub const fn slice_as_flattened(slice: &[Self]) -> &[T] {
        let len = slice
            .len()
            .checked_mul(U::USIZE)
            .expect("slice len overflow");

        // SAFETY: `[T]` is layout-identical to `Array<T, U>`, which is a `repr(transparent)`
        // newtype for `[T; N]`.
        unsafe { slice::from_raw_parts(slice.as_ptr().cast(), len) }
    }

    /// Obtain a mutable flattened slice from a mutable slice of array chunks.
    ///
    /// # Panics
    /// - if the length calculation for the flattened slice overflows
    #[inline]
    pub const fn slice_as_flattened_mut(slice: &mut [Self]) -> &mut [T] {
        let len = slice
            .len()
            .checked_mul(U::USIZE)
            .expect("slice len overflow");

        // SAFETY: `[T]` is layout-identical to `Array<T, U>`, which is a `repr(transparent)`
        // newtype for `[T; N]`.
        unsafe { slice::from_raw_parts_mut(slice.as_mut_ptr().cast(), len) }
    }
}

impl<T> Array<T, U1> {
    /// Convert a reference to `T` into a reference to an [`Array`] of length [`U1`].
    pub const fn from_ref(r: &T) -> &Self {
        Self::cast_from_core(core::array::from_ref(r))
    }

    /// Converts a mutable reference to `T` into a mutable reference to an [`Array`] of
    /// length [`U1`].
    pub const fn from_mut(r: &mut T) -> &mut Self {
        Self::cast_from_core_mut(core::array::from_mut(r))
    }
}

impl<T, U, V> Array<Array<T, U>, V>
where
    U: ArraySize,
    V: ArraySize,
{
    /// Takes a `&Array<Array<T, N>, >>`, and flattens it to a `&[T]`.
    ///
    /// # Panics
    ///
    /// This panics if the length of the resulting slice would overflow a `usize`.
    ///
    /// This is only possible when flattening a slice of arrays of zero-sized
    /// types, and thus tends to be irrelevant in practice. If
    /// `size_of::<T>() > 0`, this will never panic.
    ///
    /// # Examples
    ///
    /// ```
    /// use hybrid_array::{Array, typenum::{U0, U2, U3, U5, U10}};
    ///
    /// let a: Array<Array<usize, U3>, U2> = Array([Array([1, 2, 3]), Array([4, 5, 6])]);
    /// assert_eq!(a.as_flattened(), &[1, 2, 3, 4, 5, 6]);
    ///
    /// let b: Array<Array<usize, U2>, U3> = Array([Array([1, 2]), Array([3, 4]), Array([5, 6])]);
    /// assert_eq!(a.as_flattened(), b.as_flattened());
    ///
    /// let c: Array<[usize; 2], U3> = Array([[1, 2], [3, 4], [5, 6]]);
    /// assert_eq!(a.as_flattened(), c.as_flattened());
    ///
    /// let slice_of_empty_arrays: &Array<Array<i32, U5>, U0> = &Array::from_fn(|_| Array([1, 2, 3, 4, 5]));
    /// assert!(slice_of_empty_arrays.as_flattened().is_empty());
    ///
    /// let empty_slice_of_arrays: &Array<Array<u32, U10>, U0>  = &Array([]);
    /// assert!(empty_slice_of_arrays.as_flattened().is_empty());
    /// ```
    pub const fn as_flattened(&self) -> &[T] {
        Array::slice_as_flattened(self.as_slice())
    }

    /// Takes a `&mut Array<Array<T, N>,M>`, and flattens it to a `&mut [T]`.
    ///
    /// # Panics
    ///
    /// This panics if the length of the resulting slice would overflow a `usize`.
    ///
    /// This is only possible when flattening a slice of arrays of zero-sized
    /// types, and thus tends to be irrelevant in practice. If
    /// `size_of::<T>() > 0`, this will never panic.
    ///
    /// # Examples
    ///
    /// ```
    /// use hybrid_array::{Array, typenum::U3};
    ///
    /// fn add_5_to_all(slice: &mut [i32]) {
    ///     for i in slice {
    ///         *i += 5;
    ///     }
    /// }
    ///
    /// let mut array: Array<Array<i32, U3>, U3> = Array([Array([1_i32, 2, 3]), Array([4, 5, 6]), Array([7, 8, 9])]);
    /// add_5_to_all(array.as_flattened_mut());
    /// assert_eq!(array, Array([Array([6, 7, 8]), Array([9, 10, 11]), Array([12, 13, 14])]));
    /// ```
    pub const fn as_flattened_mut(&mut self) -> &mut [T] {
        Array::slice_as_flattened_mut(self.as_mut_slice())
    }
}

// Impls which depend on the inner array type being `[T; N]`.
impl<T, U, const N: usize> Array<T, U>
where
    U: ArraySize<ArrayType<T> = [T; N]>,
{
    /// Cast a reference to a core array to an [`Array`] reference.
    #[inline]
    pub const fn cast_from_core(array_ref: &[T; N]) -> &Self {
        // SAFETY: `Self` is a `repr(transparent)` newtype for `[T; N]`
        unsafe { &*array_ref.as_ptr().cast() }
    }

    /// Cast a mutable reference to a core array to an [`Array`] reference.
    #[inline]
    pub const fn cast_from_core_mut(array_ref: &mut [T; N]) -> &mut Self {
        // SAFETY: `Self` is a `repr(transparent)` newtype for `[T; 1]`
        unsafe { &mut *array_ref.as_mut_ptr().cast() }
    }

    /// Transform slice to slice of core array type.
    #[inline]
    pub const fn cast_slice_from_core(slice: &[[T; N]]) -> &[Self] {
        // SAFETY: `Self` is a `repr(transparent)` newtype for `[T; N]`
        unsafe { slice::from_raw_parts(slice.as_ptr().cast(), slice.len()) }
    }

    /// Transform mutable slice to mutable slice of core array type.
    #[inline]
    pub const fn cast_slice_from_core_mut(slice: &mut [[T; N]]) -> &mut [Self] {
        // SAFETY: `Self` is a `repr(transparent)` newtype for `[T; N]`
        unsafe { slice::from_raw_parts_mut(slice.as_mut_ptr().cast(), slice.len()) }
    }

    /// Transform slice to slice of core array type.
    #[inline]
    pub const fn cast_slice_to_core(slice: &[Self]) -> &[[T; N]] {
        // SAFETY: `Self` is a `repr(transparent)` newtype for `[T; N]`
        unsafe { slice::from_raw_parts(slice.as_ptr().cast(), slice.len()) }
    }

    /// Transform mutable slice to mutable slice of core array type.
    #[inline]
    pub const fn cast_slice_to_core_mut(slice: &mut [Self]) -> &mut [[T; N]] {
        // SAFETY: `Self` is a `repr(transparent)` newtype for `[T; N]`
        unsafe { slice::from_raw_parts_mut(slice.as_mut_ptr().cast(), slice.len()) }
    }
}

impl<T, U> Array<MaybeUninit<T>, U>
where
    U: ArraySize,
{
    /// Create an uninitialized array of [`MaybeUninit`]s for the given type.
    #[must_use]
    pub const fn uninit() -> Array<MaybeUninit<T>, U> {
        // SAFETY: `Array` is a `repr(transparent)` newtype for `[MaybeUninit<T>, N]`, i.e. an
        // array of uninitialized memory mediated via the `MaybeUninit` interface, where the inner
        // type is constrained by `ArraySize` impls which can only be added by this crate.
        //
        // Calling `uninit().assume_init()` triggers the `clippy::uninit_assumed_init` lint, but
        // as just mentioned the inner type we're "assuming init" for is `[MaybeUninit<T>, N]`,
        // i.e. an array of uninitialized memory, which is always valid because definitionally no
        // initialization is required of uninitialized memory.
        #[allow(clippy::uninit_assumed_init)]
        Self(unsafe { MaybeUninit::uninit().assume_init() })
    }

    /// Extract the values from an array of `MaybeUninit` containers.
    ///
    /// # Safety
    ///
    /// It is up to the caller to guarantee that all elements of the array are in an initialized
    /// state.
    #[inline]
    pub unsafe fn assume_init(self) -> Array<T, U> {
        unsafe {
            // `Array` is a `repr(transparent)` newtype for a generic inner type which is constrained to
            // be `[T; N]` by the `ArraySize` impls in this crate.
            //
            // Since we're working with a type-erased inner type and ultimately trying to convert
            // `[MaybeUninit<T>; N]` to `[T; N]`, we can't use simpler approaches like a pointer cast
            // or `transmute`, since the compiler can't prove to itself that the size will be the same.
            //
            // We've taken unique ownership of `self`, which is a `MaybeUninit` array, and as such we
            // don't need to worry about `Drop` impls because `MaybeUninit` does not impl `Drop`.
            // Since we have unique ownership of `self`, it's okay to make a copy because we're throwing
            // the original away (and this should all get optimized to a noop by the compiler, anyway).
            mem::transmute_copy(&self)
        }
    }
}

impl<T, U> AsRef<Array<T, U>> for Array<T, U>
where
    U: ArraySize,
{
    #[inline]
    fn as_ref(&self) -> &Self {
        self
    }
}

impl<T, U> AsRef<[T]> for Array<T, U>
where
    U: ArraySize,
{
    #[inline]
    fn as_ref(&self) -> &[T] {
        self.0.as_ref()
    }
}

impl<T, U, const N: usize> AsRef<[T; N]> for Array<T, U>
where
    U: ArraySize<ArrayType<T> = [T; N]>,
{
    #[inline]
    fn as_ref(&self) -> &[T; N] {
        &self.0
    }
}

impl<T, U> AsMut<Array<T, U>> for Array<T, U>
where
    U: ArraySize,
{
    #[inline]
    fn as_mut(&mut self) -> &mut Self {
        self
    }
}

impl<T, U> AsMut<[T]> for Array<T, U>
where
    U: ArraySize,
{
    #[inline]
    fn as_mut(&mut self) -> &mut [T] {
        self.0.as_mut()
    }
}

impl<T, U, const N: usize> AsMut<[T; N]> for Array<T, U>
where
    U: ArraySize<ArrayType<T> = [T; N]>,
{
    #[inline]
    fn as_mut(&mut self) -> &mut [T; N] {
        &mut self.0
    }
}

impl<T, U> Borrow<[T]> for Array<T, U>
where
    U: ArraySize,
{
    #[inline]
    fn borrow(&self) -> &[T] {
        self.0.as_ref()
    }
}

impl<T, U, const N: usize> Borrow<[T; N]> for Array<T, U>
where
    U: ArraySize<ArrayType<T> = [T; N]>,
{
    #[inline]
    fn borrow(&self) -> &[T; N] {
        &self.0
    }
}

impl<T, U> BorrowMut<[T]> for Array<T, U>
where
    U: ArraySize,
{
    #[inline]
    fn borrow_mut(&mut self) -> &mut [T] {
        self.0.as_mut()
    }
}

impl<T, U, const N: usize> BorrowMut<[T; N]> for Array<T, U>
where
    U: ArraySize<ArrayType<T> = [T; N]>,
{
    #[inline]
    fn borrow_mut(&mut self) -> &mut [T; N] {
        &mut self.0
    }
}

impl<T, U> Clone for Array<T, U>
where
    T: Clone,
    U: ArraySize,
{
    #[inline]
    fn clone(&self) -> Self {
        Self::from_fn(|n| self.0.as_ref()[n].clone())
    }
}

impl<T, U> Copy for Array<T, U>
where
    T: Copy,
    U: ArraySize,
    U::ArrayType<T>: Copy,
{
}

impl<T, U> Debug for Array<T, U>
where
    T: Debug,
    U: ArraySize,
{
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_tuple("Array").field(&self.0.as_ref()).finish()
    }
}

impl<T, U> Default for Array<T, U>
where
    T: Default,
    U: ArraySize,
{
    #[inline]
    fn default() -> Self {
        Self::from_fn(|_| Default::default())
    }
}

impl<T, U> Deref for Array<T, U>
where
    U: ArraySize,
{
    type Target = [T];

    #[inline]
    fn deref(&self) -> &[T] {
        self.0.as_ref()
    }
}

impl<T, U> DerefMut for Array<T, U>
where
    U: ArraySize,
{
    #[inline]
    fn deref_mut(&mut self) -> &mut [T] {
        self.0.as_mut()
    }
}

impl<T, U> Eq for Array<T, U>
where
    T: Eq,
    U: ArraySize,
{
}

impl<T, U, const N: usize> From<[T; N]> for Array<T, U>
where
    U: ArraySize<ArrayType<T> = [T; N]>,
{
    #[inline]
    fn from(arr: [T; N]) -> Array<T, U> {
        Array(arr)
    }
}

impl<T, U, const N: usize> From<Array<T, U>> for [T; N]
where
    U: ArraySize<ArrayType<T> = [T; N]>,
{
    #[inline]
    fn from(arr: Array<T, U>) -> [T; N] {
        arr.0
    }
}

impl<'a, T, U, const N: usize> From<&'a [T; N]> for &'a Array<T, U>
where
    U: ArraySize<ArrayType<T> = [T; N]>,
{
    #[inline]
    fn from(array_ref: &'a [T; N]) -> &'a Array<T, U> {
        Array::cast_from_core(array_ref)
    }
}

impl<'a, T, U, const N: usize> From<&'a Array<T, U>> for &'a [T; N]
where
    U: ArraySize<ArrayType<T> = [T; N]>,
{
    #[inline]
    fn from(array_ref: &'a Array<T, U>) -> &'a [T; N] {
        array_ref.as_ref()
    }
}

impl<'a, T, U, const N: usize> From<&'a mut [T; N]> for &'a mut Array<T, U>
where
    U: ArraySize<ArrayType<T> = [T; N]>,
{
    #[inline]
    fn from(array_ref: &'a mut [T; N]) -> &'a mut Array<T, U> {
        Array::cast_from_core_mut(array_ref)
    }
}

impl<'a, T, U, const N: usize> From<&'a mut Array<T, U>> for &'a mut [T; N]
where
    U: ArraySize<ArrayType<T> = [T; N]>,
{
    #[inline]
    fn from(array_ref: &'a mut Array<T, U>) -> &'a mut [T; N] {
        array_ref.as_mut()
    }
}

#[cfg(feature = "alloc")]
impl<T, U> From<Array<T, U>> for alloc::boxed::Box<[T]>
where
    U: ArraySize,
{
    #[inline]
    fn from(array: Array<T, U>) -> alloc::boxed::Box<[T]> {
        array.into_iter().collect()
    }
}

#[cfg(feature = "alloc")]
impl<T, U> From<&Array<T, U>> for alloc::boxed::Box<[T]>
where
    T: Clone,
    U: ArraySize,
{
    #[inline]
    fn from(array: &Array<T, U>) -> alloc::boxed::Box<[T]> {
        array.as_slice().into()
    }
}

#[cfg(feature = "alloc")]
impl<T, U> From<Array<T, U>> for alloc::vec::Vec<T>
where
    U: ArraySize,
{
    #[inline]
    fn from(array: Array<T, U>) -> alloc::vec::Vec<T> {
        array.into_iter().collect()
    }
}

#[cfg(feature = "alloc")]
impl<T, U> From<&Array<T, U>> for alloc::vec::Vec<T>
where
    T: Clone,
    U: ArraySize,
{
    #[inline]
    fn from(array: &Array<T, U>) -> alloc::vec::Vec<T> {
        array.as_slice().into()
    }
}

impl<T, U> Hash for Array<T, U>
where
    T: Hash,
    U: ArraySize,
{
    #[inline]
    fn hash<H: Hasher>(&self, state: &mut H) {
        self.0.as_ref().hash(state);
    }
}

impl<T, I, U> Index<I> for Array<T, U>
where
    [T]: Index<I>,
    U: ArraySize,
{
    type Output = <[T] as Index<I>>::Output;

    #[inline]
    fn index(&self, index: I) -> &Self::Output {
        Index::index(self.as_slice(), index)
    }
}

impl<T, I, U> IndexMut<I> for Array<T, U>
where
    [T]: IndexMut<I>,
    U: ArraySize,
{
    #[inline]
    fn index_mut(&mut self, index: I) -> &mut Self::Output {
        IndexMut::index_mut(self.as_mut_slice(), index)
    }
}

impl<T, U> PartialEq for Array<T, U>
where
    T: PartialEq,
    U: ArraySize,
{
    #[inline]
    fn eq(&self, other: &Self) -> bool {
        self.0.as_ref().eq(other.0.as_ref())
    }
}

impl<T, U, const N: usize> PartialEq<[T; N]> for Array<T, U>
where
    T: PartialEq,
    U: ArraySize<ArrayType<T> = [T; N]>,
{
    #[inline]
    fn eq(&self, other: &[T; N]) -> bool {
        self.0.eq(other)
    }
}

impl<T, U, const N: usize> PartialEq<Array<T, U>> for [T; N]
where
    T: PartialEq,
    U: ArraySize<ArrayType<T> = [T; N]>,
{
    #[inline]
    fn eq(&self, other: &Array<T, U>) -> bool {
        self.eq(&other.0)
    }
}

impl<T, U> PartialOrd for Array<T, U>
where
    T: PartialOrd,
    U: ArraySize,
{
    #[inline]
    fn partial_cmp(&self, other: &Self) -> Option<Ordering> {
        self.0.as_ref().partial_cmp(other.0.as_ref())
    }
}

impl<T, U> Ord for Array<T, U>
where
    T: Ord,
    U: ArraySize,
{
    #[inline]
    fn cmp(&self, other: &Self) -> Ordering {
        self.0.as_ref().cmp(other.0.as_ref())
    }
}

/// SAFETY: `Array` is a `repr(transparent)` newtype for `[T; N]`, so as long as `T: Send` it should
/// also be `Send`.
unsafe impl<T, U: ArraySize> Send for Array<T, U> where T: Send {}

/// SAFETY: `Array` is a `repr(transparent)` newtype for `[T; N]`, so as long as `T: Sync` it should
/// also be `Sync`.
unsafe impl<T, U: ArraySize> Sync for Array<T, U> where T: Sync {}

impl<'a, T, U> TryFrom<&'a [T]> for &'a Array<T, U>
where
    U: ArraySize,
{
    type Error = TryFromSliceError;

    #[inline]
    fn try_from(slice: &'a [T]) -> Result<Self, TryFromSliceError> {
        check_slice_length::<T, U>(slice)?;

        // SAFETY: `Array<T, U>` is a `repr(transparent)` newtype for a core
        // array with length checked above.
        Ok(unsafe { &*slice.as_ptr().cast() })
    }
}

impl<'a, T, U> TryFrom<&'a mut [T]> for &'a mut Array<T, U>
where
    U: ArraySize,
{
    type Error = TryFromSliceError;

    #[inline]
    fn try_from(slice: &'a mut [T]) -> Result<Self, TryFromSliceError> {
        check_slice_length::<T, U>(slice)?;

        // SAFETY: `Array<T, U>` is a `repr(transparent)` newtype for a core
        // array with length checked above.
        Ok(unsafe { &mut *slice.as_mut_ptr().cast() })
    }
}

impl<'a, T, U> TryFrom<&'a [T]> for Array<T, U>
where
    Self: Clone,
    U: ArraySize,
{
    type Error = TryFromSliceError;

    #[inline]
    fn try_from(slice: &'a [T]) -> Result<Array<T, U>, TryFromSliceError> {
        <&'a Self>::try_from(slice).cloned()
    }
}

#[cfg(feature = "alloc")]
impl<T, U> TryFrom<alloc::boxed::Box<[T]>> for Array<T, U>
where
    U: ArraySize,
{
    type Error = TryFromSliceError;

    #[inline]
    fn try_from(b: alloc::boxed::Box<[T]>) -> Result<Self, TryFromSliceError> {
        check_slice_length::<T, U>(b.as_ref())?;
        Ok(Array::from_iter(b))
    }
}

#[cfg(feature = "alloc")]
impl<'a, T, U> TryFrom<&'a alloc::boxed::Box<[T]>> for Array<T, U>
where
    Self: Clone,
    U: ArraySize,
{
    type Error = TryFromSliceError;

    #[inline]
    fn try_from(b: &'a alloc::boxed::Box<[T]>) -> Result<Self, TryFromSliceError> {
        Self::try_from(&**b)
    }
}

#[cfg(feature = "alloc")]
impl<T, U> TryFrom<alloc::vec::Vec<T>> for Array<T, U>
where
    U: ArraySize,
{
    type Error = TryFromSliceError;

    #[inline]
    fn try_from(v: alloc::vec::Vec<T>) -> Result<Self, TryFromSliceError> {
        check_slice_length::<T, U>(v.as_ref())?;
        Ok(Array::from_iter(v))
    }
}

#[cfg(feature = "alloc")]
impl<'a, T, U> TryFrom<&'a alloc::vec::Vec<T>> for Array<T, U>
where
    Self: Clone,
    U: ArraySize,
{
    type Error = TryFromSliceError;

    #[inline]
    fn try_from(v: &'a alloc::vec::Vec<T>) -> Result<Self, TryFromSliceError> {
        Self::try_from(v.as_slice())
    }
}

// Deprecated legacy methods to ease migrations from `generic-array`
impl<T, U> Array<T, U>
where
    U: ArraySize,
{
    /// Convert the given slice into a reference to a hybrid array.
    ///
    /// # Panics
    ///
    /// Panics if the slice's length doesn't match the array type.
    #[deprecated(since = "0.2.0", note = "use `TryFrom` instead")]
    #[inline]
    pub fn from_slice(slice: &[T]) -> &Self {
        slice.try_into().expect("slice length mismatch")
    }

    /// Convert the given mutable slice to a mutable reference to a hybrid array.
    ///
    /// # Panics
    ///
    /// Panics if the slice's length doesn't match the array type.
    #[deprecated(since = "0.2.0", note = "use `TryFrom` instead")]
    #[inline]
    pub fn from_mut_slice(slice: &mut [T]) -> &mut Self {
        slice.try_into().expect("slice length mismatch")
    }

    /// Clone the contents of the slice as a new hybrid array.
    ///
    /// # Panics
    ///
    /// Panics if the slice's length doesn't match the array type.
    #[deprecated(since = "0.2.0", note = "use `TryFrom` instead")]
    #[inline]
    pub fn clone_from_slice(slice: &[T]) -> Self
    where
        Self: Clone,
    {
        slice.try_into().expect("slice length mismatch")
    }
}

#[cfg(feature = "arbitrary")]
impl<'a, T, U> Arbitrary<'a> for Array<T, U>
where
    T: Arbitrary<'a>,
    U: ArraySize,
{
    fn arbitrary(u: &mut arbitrary::Unstructured<'a>) -> arbitrary::Result<Self> {
        Self::try_from_fn(|_n| Arbitrary::arbitrary(u))
    }
}

#[cfg(feature = "bytemuck")]
unsafe impl<T, U> Pod for Array<T, U>
where
    T: Pod,
    U: ArraySize,
    U::ArrayType<T>: Copy,
{
}

#[cfg(feature = "bytemuck")]
unsafe impl<T, U> Zeroable for Array<T, U>
where
    T: Zeroable,
    U: ArraySize,
{
}

#[cfg(feature = "ctutils")]
impl<T, U> ctutils::CtAssign for Array<T, U>
where
    [T]: ctutils::CtAssign,
    U: ArraySize,
{
    #[inline]
    fn ct_assign(&mut self, other: &Self, choice: ctutils::Choice) {
        self.as_mut_slice().ct_assign(other.as_slice(), choice);
    }
}

#[cfg(feature = "ctutils")]
impl<T, U> ctutils::CtSelect for Array<T, U>
where
    U: ArraySize,
    U::ArrayType<T>: ctutils::CtSelect,
{
    #[inline]
    fn ct_select(&self, other: &Self, choice: ctutils::Choice) -> Self {
        Self(self.0.ct_select(&other.0, choice))
    }
}

#[cfg(feature = "ctutils")]
impl<T, U> ctutils::CtEq for Array<T, U>
where
    U: ArraySize,
    U::ArrayType<T>: ctutils::CtEq,
{
    #[inline]
    fn ct_eq(&self, other: &Self) -> ctutils::Choice {
        self.0.ct_eq(&other.0)
    }
}

#[cfg(feature = "subtle")]
impl<T, U> subtle::ConditionallySelectable for Array<T, U>
where
    Self: Copy,
    T: subtle::ConditionallySelectable,
    U: ArraySize,
{
    #[inline]
    fn conditional_select(a: &Self, b: &Self, choice: subtle::Choice) -> Self {
        let mut output = *a;
        output.conditional_assign(b, choice);
        output
    }

    fn conditional_assign(&mut self, other: &Self, choice: subtle::Choice) {
        for (a_i, b_i) in self.iter_mut().zip(other) {
            a_i.conditional_assign(b_i, choice);
        }
    }
}

#[cfg(feature = "subtle")]
impl<T, U> subtle::ConstantTimeEq for Array<T, U>
where
    T: subtle::ConstantTimeEq,
    U: ArraySize,
{
    #[inline]
    fn ct_eq(&self, other: &Self) -> subtle::Choice {
        self.iter()
            .zip(other.iter())
            .fold(subtle::Choice::from(1), |acc, (a, b)| acc & a.ct_eq(b))
    }
}

#[cfg(feature = "zeroize")]
impl<T, U> Zeroize for Array<T, U>
where
    T: Zeroize,
    U: ArraySize,
{
    #[inline]
    fn zeroize(&mut self) {
        self.0.as_mut().iter_mut().zeroize();
    }
}

#[cfg(feature = "zeroize")]
impl<T, U> ZeroizeOnDrop for Array<T, U>
where
    T: ZeroizeOnDrop,
    U: ArraySize,
{
}

/// Generate a [`TryFromSliceError`] if the slice doesn't match the given length.
fn check_slice_length<T, U: ArraySize>(slice: &[T]) -> Result<(), TryFromSliceError> {
    debug_assert_eq!(Array::<(), U>::default().len(), U::USIZE);

    if slice.len() == U::USIZE {
        Ok(())
    } else {
        // Hack: `TryFromSliceError` lacks a public constructor, so this fakes one
        <&[T; 1]>::try_from([].as_slice()).map(|_| ())
    }
}
