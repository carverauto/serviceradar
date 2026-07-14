//! Interop support for `hybrid-array`

use crate::{Encoding, Integer};
use core::ops::Add;
use hybrid_array::{Array, ArraySize, typenum::Unsigned};

/// Alias for a byte array whose size is defined by [`ArrayEncoding::ByteSize`].
pub type ByteArray<T> = Array<u8, <T as ArrayEncoding>::ByteSize>;

/// Support for encoding a big integer as a `Array`.
pub trait ArrayEncoding: Encoding {
    /// Size of a byte array which encodes a big integer.
    type ByteSize: ArraySize + Add + Eq + Ord + Unsigned;

    /// Deserialize from a big-endian byte array.
    fn from_be_byte_array(bytes: ByteArray<Self>) -> Self;

    /// Deserialize from a little-endian byte array.
    fn from_le_byte_array(bytes: ByteArray<Self>) -> Self;

    /// Serialize to a big-endian byte array.
    fn to_be_byte_array(&self) -> ByteArray<Self>;

    /// Serialize to a little-endian byte array.
    fn to_le_byte_array(&self) -> ByteArray<Self>;
}

/// Support for decoding a `Array` as a big integer.
pub trait ArrayDecoding {
    /// Big integer which decodes a `Array`.
    type Output: ArrayEncoding + Integer;

    /// Deserialize from a big-endian `Array`.
    fn into_uint_be(self) -> Self::Output;

    /// Deserialize from a little-endian `Array`.
    fn into_uint_le(self) -> Self::Output;
}
