//! ASN.1 `SEQUENCE OF` support.

use crate::{
    ArrayVec, Decode, DecodeValue, DerOrd, Encode, EncodeValue, Error, FixedTag, Header, Length,
    Reader, Tag, ValueOrd, Writer, arrayvec, ord::iter_cmp,
};
use core::cmp::Ordering;

#[cfg(feature = "alloc")]
use alloc::vec::Vec;

/// ASN.1 `SEQUENCE OF` backed by an array.
///
/// This type implements an append-only `SEQUENCE OF` type which is stack-based
/// and does not depend on `alloc` support.
// TODO(tarcieri): use `ArrayVec` when/if it's merged into `core`
// See: https://github.com/rust-lang/rfcs/pull/2990
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct SequenceOf<T, const N: usize> {
    inner: ArrayVec<T, N>,
}

impl<T, const N: usize> SequenceOf<T, N> {
    /// Create a new [`SequenceOf`].
    pub fn new() -> Self {
        Self {
            inner: ArrayVec::new(),
        }
    }

    /// Add an element to this [`SequenceOf`].
    pub fn add(&mut self, element: T) -> Result<(), Error> {
        self.inner.push(element)
    }

    /// Get an element of this [`SequenceOf`].
    pub fn get(&self, index: usize) -> Option<&T> {
        self.inner.get(index)
    }

    /// Iterate over the elements in this [`SequenceOf`].
    pub fn iter(&self) -> SequenceOfIter<'_, T> {
        SequenceOfIter {
            inner: self.inner.iter(),
        }
    }

    /// Is this [`SequenceOf`] empty?
    pub fn is_empty(&self) -> bool {
        self.inner.is_empty()
    }

    /// Number of elements in this [`SequenceOf`].
    pub fn len(&self) -> usize {
        self.inner.len()
    }
}

impl<T, const N: usize> Default for SequenceOf<T, N> {
    fn default() -> Self {
        Self::new()
    }
}

impl<'a, T, const N: usize> DecodeValue<'a> for SequenceOf<T, N>
where
    T: Decode<'a>,
{
    type Error = T::Error;

    fn decode_value<R: Reader<'a>>(reader: &mut R, _header: Header) -> Result<Self, Self::Error> {
        let mut sequence_of = Self::new();

        while !reader.is_finished() {
            sequence_of.add(T::decode(reader)?)?;
        }

        Ok(sequence_of)
    }
}

impl<T, const N: usize> EncodeValue for SequenceOf<T, N>
where
    T: Encode,
{
    fn value_len(&self) -> Result<Length, Error> {
        self.iter()
            .try_fold(Length::ZERO, |len, elem| len + elem.encoded_len()?)
    }

    fn encode_value(&self, writer: &mut impl Writer) -> Result<(), Error> {
        for elem in self.iter() {
            elem.encode(writer)?;
        }

        Ok(())
    }
}

impl<T, const N: usize> FixedTag for SequenceOf<T, N> {
    const TAG: Tag = Tag::Sequence;
}

impl<T, const N: usize> ValueOrd for SequenceOf<T, N>
where
    T: DerOrd,
{
    fn value_cmp(&self, other: &Self) -> Result<Ordering, Error> {
        iter_cmp(self.iter(), other.iter())
    }
}

/// Iterator over the elements of an [`SequenceOf`].
#[derive(Clone, Debug)]
pub struct SequenceOfIter<'a, T> {
    /// Inner iterator.
    inner: arrayvec::Iter<'a, T>,
}

impl<'a, T> Iterator for SequenceOfIter<'a, T> {
    type Item = &'a T;

    fn next(&mut self) -> Option<&'a T> {
        self.inner.next()
    }

    fn size_hint(&self) -> (usize, Option<usize>) {
        self.inner.size_hint()
    }
}

impl<T> ExactSizeIterator for SequenceOfIter<'_, T> {}

impl<T: Encode> EncodeValue for [T] {
    fn value_len(&self) -> Result<Length, Error> {
        self.iter()
            .try_fold(Length::ZERO, |len, elem| len + elem.encoded_len()?)
    }

    fn encode_value(&self, writer: &mut impl Writer) -> Result<(), Error> {
        for elem in self {
            elem.encode(writer)?;
        }

        Ok(())
    }
}

impl<'a, T, const N: usize> DecodeValue<'a> for [T; N]
where
    T: Decode<'a>,
{
    type Error = T::Error;

    fn decode_value<R: Reader<'a>>(reader: &mut R, header: Header) -> Result<Self, Self::Error> {
        let sequence_of = SequenceOf::<T, N>::decode_value(reader, header)?;

        // TODO(tarcieri): use `[T; N]::try_map` instead of `expect` when stable
        if sequence_of.inner.len() == N {
            Ok(sequence_of
                .inner
                .into_array()
                .map(|elem| elem.expect("arrayvec length mismatch")))
        } else {
            Err(reader.error(Self::TAG.length_error()).into())
        }
    }
}

impl<T, const N: usize> EncodeValue for [T; N]
where
    T: Encode,
{
    fn value_len(&self) -> Result<Length, Error> {
        self.iter()
            .try_fold(Length::ZERO, |len, elem| len + elem.encoded_len()?)
    }

    fn encode_value(&self, writer: &mut impl Writer) -> Result<(), Error> {
        self.as_slice().encode_value(writer)
    }
}

impl<T, const N: usize> FixedTag for [T; N] {
    const TAG: Tag = Tag::Sequence;
}

impl<T, const N: usize> ValueOrd for [T; N]
where
    T: DerOrd,
{
    fn value_cmp(&self, other: &Self) -> Result<Ordering, Error> {
        iter_cmp(self.iter(), other.iter())
    }
}

#[cfg(feature = "alloc")]
impl<'a, T> DecodeValue<'a> for Vec<T>
where
    T: Decode<'a>,
{
    type Error = T::Error;

    fn decode_value<R: Reader<'a>>(reader: &mut R, _header: Header) -> Result<Self, Self::Error> {
        let mut sequence_of = Vec::<T>::new();

        while !reader.is_finished() {
            sequence_of.push(T::decode(reader)?);
        }

        Ok(sequence_of)
    }
}

#[cfg(feature = "alloc")]
impl<T> EncodeValue for Vec<T>
where
    T: Encode,
{
    fn value_len(&self) -> Result<Length, Error> {
        self.iter()
            .try_fold(Length::ZERO, |len, elem| len + elem.encoded_len()?)
    }

    fn encode_value(&self, writer: &mut impl Writer) -> Result<(), Error> {
        self.as_slice().encode_value(writer)
    }
}

#[cfg(feature = "alloc")]
impl<T> FixedTag for Vec<T> {
    const TAG: Tag = Tag::Sequence;
}

#[cfg(feature = "alloc")]
impl<T> ValueOrd for Vec<T>
where
    T: DerOrd,
{
    fn value_cmp(&self, other: &Self) -> Result<Ordering, Error> {
        iter_cmp(self.iter(), other.iter())
    }
}

#[cfg(test)]
mod tests {
    use crate::asn1::SequenceOf;
    use crate::ord::DerOrd;

    #[test]
    fn sequenceof_valueord_value_cmp() {
        use core::cmp::Ordering;

        let arr1 = {
            let mut arr: SequenceOf<u16, 2> = SequenceOf::new();
            arr.add(0u16).expect("element to be added");
            arr.add(2u16).expect("element to be added");
            arr
        };
        let arr2 = {
            let mut arr: SequenceOf<u16, 2> = SequenceOf::new();
            arr.add(0u16).expect("element to be added");
            arr.add(1u16).expect("element to be added");
            arr
        };
        assert_eq!(arr1.der_cmp(&arr2), Ok(Ordering::Greater));
    }
}
