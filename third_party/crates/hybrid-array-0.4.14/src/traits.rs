//! Trait definitions.

use crate::Array;
use core::{
    borrow::{Borrow, BorrowMut},
    fmt::Debug,
    ops::{Index, IndexMut, Range},
};
use typenum::Unsigned;

/// Trait which associates a [`usize`] size and `ArrayType` with a
/// `typenum`-provided [`Unsigned`] integer.
///
/// # Safety
///
/// `ArrayType` MUST be an array with a number of elements exactly equal to
/// [`Unsigned::USIZE`]. Breaking this requirement will cause undefined behavior.
///
/// NOTE: This trait is effectively sealed and can not be implemented by third-party crates.
/// It is implemented only for a number of types defined in [`typenum::consts`].
#[diagnostic::on_unimplemented(note = "size may not be supported (see RustCrypto/hybrid-array#66)")]
pub unsafe trait ArraySize: Unsigned + Debug {
    /// Array type which corresponds to this size.
    ///
    /// This is always defined to be `[T; N]` where `N` is the same as
    /// [`ArraySize::USIZE`][`typenum::Unsigned::USIZE`].
    type ArrayType<T>: AssocArraySize<Size = Self>
        + AsRef<[T]>
        + AsMut<[T]>
        + Borrow<[T]>
        + BorrowMut<[T]>
        + From<Array<T, Self>>
        + Index<usize>
        + Index<Range<usize>>
        + IndexMut<usize>
        + IndexMut<Range<usize>>
        + Into<Array<T, Self>>
        + IntoIterator<Item = T>;
}

/// Associates an [`ArraySize`] with a given type. Can be used to accept `[T; N]` const generic
/// arguments and convert to [`Array`] internally.
///
/// This trait is also the magic glue that makes the [`ArrayN`][`crate::ArrayN`] type alias work.
///
/// # Example
///
/// ```
/// use hybrid_array::{ArrayN, AssocArraySize};
///
/// pub fn example<const N: usize>(bytes: &[u8; N])
/// where
///     [u8; N]: AssocArraySize + AsRef<ArrayN<u8, N>>
/// {
///     // _arrayn is ArrayN<u8, N>
///     let _arrayn = bytes.as_ref();
/// }
/// ```
pub trait AssocArraySize: Sized {
    /// Size of an array type, expressed as a [`typenum`]-based [`ArraySize`].
    type Size: ArraySize;
}

impl<T, U> AssocArraySize for Array<T, U>
where
    U: ArraySize,
{
    type Size = U;
}

/// Obtain an `&Array` reference for a given type.
///
/// This provides functionality equivalent to `AsRef<Array>` or `Borrow<Array>`, but is deliberately
/// implemented as its own trait both so it can leverage [`AssocArraySize`] to determine the
/// array size, and also to avoid inference problems that occur when third party impls of traits
/// like [`AsRef`] and [`Borrow`] are added to `[T; N]`.
///
/// # Usage with `[T; N]`
///
/// ```
/// use hybrid_array::{Array, ArraySize, AsArrayRef};
///
/// pub fn getn_hybrid<T, U: ArraySize>(arr: &Array<T, U>, n: usize) -> &T {
///     &arr[2]
/// }
///
/// pub fn getn_generic<T, const N: usize>(arr: &[T; N], n: usize) -> &T
/// where
///     [T; N]: AsArrayRef<T>
/// {
///     getn_hybrid(arr.as_array_ref(), n)
/// }
///
/// let array = [0u8, 1, 2, 3];
/// let x = getn_generic(&array, 2);
/// assert_eq!(x, &2);
/// ```
pub trait AsArrayRef<T>: AssocArraySize {
    /// Converts this type into an immutable [`Array`] reference.
    fn as_array_ref(&self) -> &Array<T, Self::Size>;
}

/// Obtain a `&mut Array` reference for a given type.
///
/// Companion trait to [`AsArrayRef`] for mutable references, equivalent to [`AsMut`] or
/// [`BorrowMut`].
pub trait AsArrayMut<T>: AsArrayRef<T> {
    /// Converts this type into a mutable [`Array`] reference.
    fn as_array_mut(&mut self) -> &mut Array<T, Self::Size>;
}

impl<T, U> AsArrayRef<T> for Array<T, U>
where
    U: ArraySize,
{
    fn as_array_ref(&self) -> &Self {
        self
    }
}

impl<T, U> AsArrayMut<T> for Array<T, U>
where
    U: ArraySize,
{
    fn as_array_mut(&mut self) -> &mut Self {
        self
    }
}

impl<T, U, const N: usize> AsArrayRef<T> for [T; N]
where
    Self: AssocArraySize<Size = U>,
    U: ArraySize<ArrayType<T> = Self>,
{
    fn as_array_ref(&self) -> &Array<T, U> {
        self.into()
    }
}

impl<T, U, const N: usize> AsArrayMut<T> for [T; N]
where
    Self: AssocArraySize<Size = U>,
    U: ArraySize<ArrayType<T> = Self>,
{
    fn as_array_mut(&mut self) -> &mut Array<T, U> {
        self.into()
    }
}

/// Extension trait for `[T]` providing methods for working with [`Array`].
pub trait SliceExt<T>: sealed::Sealed {
    /// Get a reference to an array from a slice, if the slice is exactly the size of the array.
    ///
    /// Returns `None` if the slice's length is not exactly equal to the array size.
    fn as_hybrid_array<U: ArraySize>(&self) -> Option<&Array<T, U>>;

    /// Get a mutable reference to an array from a slice, if the slice is exactly the size of the
    /// array.
    ///
    /// Returns `None` if the slice's length is not exactly equal to the array size.
    fn as_mut_hybrid_array<U: ArraySize>(&mut self) -> Option<&mut Array<T, U>>;

    /// Splits the shared slice into a slice of `U`-element arrays, starting at the beginning
    /// of the slice, and a remainder slice with length strictly less than `U`.
    ///
    /// # Panics
    /// If `U` is 0.
    fn as_hybrid_chunks<U: ArraySize>(&self) -> (&[Array<T, U>], &[T]);

    /// Splits the exclusive slice into a slice of `U`-element arrays, starting at the beginning
    /// of the slice, and a remainder slice with length strictly less than `U`.
    ///
    /// # Panics
    /// If `U` is 0.
    fn as_hybrid_chunks_mut<U: ArraySize>(&mut self) -> (&mut [Array<T, U>], &mut [T]);
}

impl<T> SliceExt<T> for [T] {
    fn as_hybrid_array<U: ArraySize>(&self) -> Option<&Array<T, U>> {
        Array::slice_as_array(self)
    }

    fn as_mut_hybrid_array<U: ArraySize>(&mut self) -> Option<&mut Array<T, U>> {
        Array::slice_as_mut_array(self)
    }

    fn as_hybrid_chunks<U: ArraySize>(&self) -> (&[Array<T, U>], &[T]) {
        Array::slice_as_chunks(self)
    }

    fn as_hybrid_chunks_mut<U: ArraySize>(&mut self) -> (&mut [Array<T, U>], &mut [T]) {
        Array::slice_as_chunks_mut(self)
    }
}

impl<T> sealed::Sealed for [T] {}

mod sealed {
    pub trait Sealed {}
}

#[cfg(test)]
mod tests {
    use super::{AsArrayMut, AsArrayRef, SliceExt};
    use crate::{
        Array,
        sizes::{U2, U3},
    };

    type A = Array<u8, U2>;

    #[test]
    fn core_as_array_ref() {
        assert_eq!([1, 2, 3].as_array_ref(), &Array([1, 2, 3]));
    }

    #[test]
    fn core_as_array_mut() {
        assert_eq!([1, 2, 3].as_array_mut(), &Array([1, 2, 3]));
    }

    #[test]
    fn hybrid_as_array_ref() {
        assert_eq!(A::from([1, 2]).as_array_ref(), &Array([1, 2]));
    }

    #[test]
    fn hybrid_as_array_mut() {
        assert_eq!(A::from([1, 2]).as_array_mut(), &Array([1, 2]));
    }

    #[test]
    fn slice_as_hybrid_array() {
        assert_eq!([1, 2].as_hybrid_array::<U3>(), None);
        assert_eq!([1, 2, 3].as_hybrid_array::<U3>(), Some(&Array([1, 2, 3])));
        assert_eq!([1, 2, 3, 4].as_hybrid_array::<U3>(), None);
    }

    #[test]
    fn slice_as_mut_hybrid_array() {
        assert_eq!([1, 2].as_mut_hybrid_array::<U3>(), None);
        assert_eq!(
            [1, 2, 3].as_mut_hybrid_array::<U3>(),
            Some(&mut Array([1, 2, 3]))
        );
        assert_eq!([1, 2, 3, 4].as_mut_hybrid_array::<U3>(), None);
    }

    #[test]
    fn slice_as_hybrid_chunks() {
        let (slice_empty, rem_empty): (&[A], &[u8]) = [].as_hybrid_chunks::<U2>();
        assert!(slice_empty.is_empty());
        assert!(rem_empty.is_empty());

        let (slice_one, rem_one) = [1].as_hybrid_chunks::<U2>();
        assert!(slice_one.is_empty());
        assert_eq!(rem_one, &[1]);

        let (slice_aligned, rem_aligned) = [1u8, 2].as_hybrid_chunks::<U2>();
        assert_eq!(slice_aligned, &[Array([1u8, 2])]);
        assert_eq!(rem_aligned, b"");

        let (slice_unaligned, rem_unaligned) = [1u8, 2, 3].as_hybrid_chunks::<U2>();
        assert_eq!(slice_unaligned, &[Array([1u8, 2])]);
        assert_eq!(rem_unaligned, &[3]);
    }

    #[test]
    fn slice_as_hybrid_chunks_mut() {
        let (slice_empty, rem_empty): (&mut [A], &mut [u8]) = [].as_hybrid_chunks_mut::<U2>();
        assert!(slice_empty.is_empty());
        assert!(rem_empty.is_empty());

        let mut arr1 = [1];
        let (slice_one, rem_one) = arr1.as_hybrid_chunks_mut::<U2>();
        assert!(slice_one.is_empty());
        assert_eq!(rem_one, &[1]);

        let mut arr2 = [1u8, 2];
        let (slice_aligned, rem_aligned) = arr2.as_hybrid_chunks_mut::<U2>();
        assert_eq!(slice_aligned, &mut [Array([1u8, 2])]);
        assert_eq!(rem_aligned, b"");

        let mut arr3 = [1u8, 2, 3];
        let (slice_unaligned, rem_unaligned) = arr3.as_hybrid_chunks_mut::<U2>();
        assert_eq!(slice_unaligned, &mut [Array([1u8, 2])]);
        assert_eq!(rem_unaligned, &mut [3]);
    }
}
