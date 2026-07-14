//! Support for constructing arrays using a provided iterator function and other iterator-related
//! functionality.

use crate::{Array, ArraySize};
use core::{
    fmt,
    slice::{Iter, IterMut},
};

/// Couldn't construct an array from an iterator because the number of items in the iterator
/// didn't match the array size.
#[derive(Clone, Copy, Debug)]
pub struct TryFromIteratorError;

impl fmt::Display for TryFromIteratorError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("iterator did not contain the correct number of items for the array size")
    }
}

impl core::error::Error for TryFromIteratorError {}

impl<T, U> Array<T, U>
where
    U: ArraySize,
{
    /// Construct an array from the given iterator, returning [`TryFromIteratorError`] in the event
    /// that the number of items in the iterator does not match the array size.
    ///
    /// # Errors
    ///
    /// Returns [`TryFromIteratorError`] in the event the iterator does not return a number of
    /// items which is exactly equal to the array size.
    pub fn try_from_iter<I: IntoIterator<Item = T>>(iter: I) -> Result<Self, TryFromIteratorError> {
        let mut iter = iter.into_iter();
        let ret = Self::try_from_fn(|_| iter.next().ok_or(TryFromIteratorError))?;

        match iter.next() {
            None => Ok(ret),
            Some(_) => Err(TryFromIteratorError),
        }
    }
}

impl<T, U> FromIterator<T> for Array<T, U>
where
    U: ArraySize,
{
    fn from_iter<I: IntoIterator<Item = T>>(iter: I) -> Self {
        let mut iter = iter.into_iter();
        let ret = Self::from_fn(|_| {
            iter.next()
                .expect("iterator should have enough items to fill array")
        });

        assert!(
            iter.next().is_none(),
            "too many items in iterator to fit in array"
        );

        ret
    }
}

impl<T, U> IntoIterator for Array<T, U>
where
    U: ArraySize,
{
    type Item = T;
    type IntoIter = <U::ArrayType<T> as IntoIterator>::IntoIter;

    /// Creates a consuming iterator, that is, one that moves each value out of the array (from
    /// start to end).
    ///
    /// The array cannot be used after calling this unless `T` implements `Copy`, so the whole
    /// array is copied.
    #[inline]
    fn into_iter(self) -> Self::IntoIter {
        self.0.into_iter()
    }
}

impl<'a, T, U> IntoIterator for &'a Array<T, U>
where
    U: ArraySize,
{
    type Item = &'a T;
    type IntoIter = Iter<'a, T>;

    #[inline]
    fn into_iter(self) -> Iter<'a, T> {
        self.iter()
    }
}

impl<'a, T, U> IntoIterator for &'a mut Array<T, U>
where
    U: ArraySize,
{
    type Item = &'a mut T;
    type IntoIter = IterMut<'a, T>;

    #[inline]
    fn into_iter(self) -> IterMut<'a, T> {
        self.iter_mut()
    }
}

#[cfg(test)]
mod tests {
    use crate::{Array, sizes::U3};

    #[test]
    fn mut_array_ref_into_iterator() {
        let array_ref: &mut Array<u8, U3> = &mut Array([1, 2, 3]);
        let mut iter = array_ref.into_iter();

        for i in 1..=3 {
            assert_eq!(iter.next().copied(), Some(i));
        }

        assert_eq!(iter.next(), None);
    }

    #[cfg(feature = "alloc")]
    #[test]
    fn display_try_from_iterator_error() {
        use super::TryFromIteratorError;
        use alloc::string::ToString;
        let _ = TryFromIteratorError.to_string();
    }
}
