//! Wrapper object for encoding reference types.
// TODO(tarcieri): replace with blanket impls of `Encode(Value)` for reference types?

use crate::{Encode, EncodeValue, Length, Result, Tag, Tagged, ValueOrd, Writer};
use core::cmp::Ordering;

/// Reference encoder: wrapper type which impls `Encode` for any reference to a
/// type which impls the same.
pub struct EncodeRef<'a, T>(pub &'a T);

impl<T> AsRef<T> for EncodeRef<'_, T> {
    fn as_ref(&self) -> &T {
        self.0
    }
}

impl<T> Encode for EncodeRef<'_, T>
where
    T: Encode,
{
    fn encoded_len(&self) -> Result<Length> {
        self.0.encoded_len()
    }

    fn encode(&self, writer: &mut impl Writer) -> Result<()> {
        self.0.encode(writer)
    }
}

/// Reference value encoder: wrapper type which impls `EncodeValue` and `Tagged`
/// for any reference type which impls the same.
///
/// By virtue of the blanket impl, this type also impls `Encode`.
pub struct EncodeValueRef<'a, T>(pub &'a T);

impl<T> AsRef<T> for EncodeValueRef<'_, T> {
    fn as_ref(&self) -> &T {
        self.0
    }
}

impl<T> EncodeValue for EncodeValueRef<'_, T>
where
    T: EncodeValue,
{
    fn value_len(&self) -> Result<Length> {
        self.0.value_len()
    }

    fn encode_value(&self, writer: &mut impl Writer) -> Result<()> {
        self.0.encode_value(writer)
    }
}

impl<T> Tagged for EncodeValueRef<'_, T>
where
    T: Tagged,
{
    fn tag(&self) -> Tag {
        self.0.tag()
    }
}

impl<T> ValueOrd for EncodeValueRef<'_, T>
where
    T: ValueOrd,
{
    fn value_cmp(&self, other: &Self) -> Result<Ordering> {
        self.0.value_cmp(other.0)
    }
}
