//! Serialization primitives for slices.

use core::fmt;
use core::marker::PhantomData;

use serde::{Deserializer, Serializer};

use crate::common::{self, LengthCheck, SliceVisitor, StrIntoBufVisitor};

#[cfg(feature = "alloc")]
use ::{
    alloc::vec::Vec,
    serde::{Deserialize, Serialize},
};

#[cfg(feature = "alloc")]
use crate::common::{StrIntoVecVisitor, VecVisitor};

#[cfg(feature = "zeroize")]
use zeroize::Zeroize;

/// Serialize the given type as lower case hex when using human-readable
/// formats or binary if the format is binary.
pub fn serialize_hex_lower_or_bin<S, T>(value: &T, serializer: S) -> Result<S::Ok, S::Error>
where
    S: Serializer,
    T: AsRef<[u8]>,
{
    common::serialize_hex_lower_or_bin(value, serializer)
}

/// Serialize the given type as upper case hex when using human-readable
/// formats or binary if the format is binary.
pub fn serialize_hex_upper_or_bin<S, T>(value: &T, serializer: S) -> Result<S::Ok, S::Error>
where
    S: Serializer,
    T: AsRef<[u8]>,
{
    common::serialize_hex_upper_or_bin(value, serializer)
}

struct UpperBound;

impl LengthCheck for UpperBound {
    fn length_check(buffer_length: usize, data_length: usize) -> bool {
        buffer_length >= data_length
    }
    fn expecting(
        formatter: &mut fmt::Formatter<'_>,
        data_type: &str,
        data_length: usize,
    ) -> fmt::Result {
        write!(
            formatter,
            "{data_type} with a maximum length of {data_length}"
        )
    }
}

/// Deserialize from hex when using human-readable formats or binary if the
/// format is binary. Fails if the `buffer` is smaller then the resulting
/// slice.
pub fn deserialize_hex_or_bin<'de, D>(buffer: &mut [u8], deserializer: D) -> Result<&[u8], D::Error>
where
    D: Deserializer<'de>,
{
    if deserializer.is_human_readable() {
        deserializer.deserialize_str(StrIntoBufVisitor::<UpperBound>(buffer, PhantomData))
    } else {
        deserializer.deserialize_byte_buf(SliceVisitor::<UpperBound>(buffer, PhantomData))
    }
}

/// Deserialize from hex when using human-readable formats or binary if the
/// format is binary.
#[cfg(feature = "alloc")]
pub fn deserialize_hex_or_bin_vec<'de, D>(deserializer: D) -> Result<Vec<u8>, D::Error>
where
    D: Deserializer<'de>,
{
    if deserializer.is_human_readable() {
        deserializer.deserialize_str(StrIntoVecVisitor)
    } else {
        deserializer.deserialize_byte_buf(VecVisitor)
    }
}

/// [`HexOrBin`] serializer which uses lower case.
#[cfg(feature = "alloc")]
pub type HexLowerOrBin = HexOrBin<false>;

/// [`HexOrBin`] serializer which uses upper case.
#[cfg(feature = "alloc")]
pub type HexUpperOrBin = HexOrBin<true>;

/// Serializer/deserializer newtype which encodes bytes as either binary or hex.
///
/// Use hexadecimal with human-readable formats, or raw binary with binary formats.
#[cfg(feature = "alloc")]
#[derive(Clone, Debug, Default, Eq, Hash, Ord, PartialEq, PartialOrd)]
pub struct HexOrBin<const UPPERCASE: bool>(pub Vec<u8>);

#[cfg(feature = "alloc")]
impl<const UPPERCASE: bool> AsRef<[u8]> for HexOrBin<UPPERCASE> {
    fn as_ref(&self) -> &[u8] {
        self.0.as_ref()
    }
}

#[cfg(feature = "alloc")]
impl<const UPPERCASE: bool> From<&[u8]> for HexOrBin<UPPERCASE> {
    fn from(bytes: &[u8]) -> HexOrBin<UPPERCASE> {
        Self(bytes.into())
    }
}

#[cfg(feature = "alloc")]
impl<const UPPERCASE: bool> From<Vec<u8>> for HexOrBin<UPPERCASE> {
    fn from(vec: Vec<u8>) -> HexOrBin<UPPERCASE> {
        Self(vec)
    }
}

#[cfg(feature = "alloc")]
impl<const UPPERCASE: bool> From<HexOrBin<UPPERCASE>> for Vec<u8> {
    fn from(vec: HexOrBin<UPPERCASE>) -> Vec<u8> {
        vec.0
    }
}

#[cfg(feature = "alloc")]
impl<const UPPERCASE: bool> Serialize for HexOrBin<UPPERCASE> {
    fn serialize<S>(&self, serializer: S) -> Result<S::Ok, S::Error>
    where
        S: Serializer,
    {
        if UPPERCASE {
            serialize_hex_upper_or_bin(self, serializer)
        } else {
            serialize_hex_lower_or_bin(self, serializer)
        }
    }
}

#[cfg(feature = "alloc")]
impl<'de, const UPPERCASE: bool> Deserialize<'de> for HexOrBin<UPPERCASE> {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: Deserializer<'de>,
    {
        deserialize_hex_or_bin_vec(deserializer).map(Self)
    }
}

#[cfg(all(feature = "alloc", feature = "zeroize"))]
impl<const UPPERCASE: bool> Zeroize for HexOrBin<UPPERCASE> {
    fn zeroize(&mut self) {
        self.0.as_mut_slice().zeroize();
    }
}
