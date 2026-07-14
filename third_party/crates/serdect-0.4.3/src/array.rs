//! Serialization primitives for arrays.

// Unfortunately, we currently cannot tell `serde` in a uniform fashion that we are serializing
// a fixed-size byte array.
// See https://github.com/serde-rs/serde/issues/2120 for the discussion.
// Therefore we have to fall back to the slice methods,
// which will add the size information in the binary formats.
// The only difference is that for the arrays we require the size of the data
// to be exactly equal to the size of the buffer during deserialization,
// while for slices the buffer can be larger than the deserialized data.

use core::fmt;
use core::marker::PhantomData;

use serde::{Deserialize, Deserializer, Serialize, Serializer};

use crate::common::{self, LengthCheck, SliceVisitor, StrIntoBufVisitor};

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

struct ExactLength;

impl LengthCheck for ExactLength {
    fn length_check(buffer_length: usize, data_length: usize) -> bool {
        buffer_length == data_length
    }
    fn expecting(
        formatter: &mut fmt::Formatter<'_>,
        data_type: &str,
        data_length: usize,
    ) -> fmt::Result {
        write!(formatter, "{data_type} of length {data_length}")
    }
}

/// Deserialize from hex when using human-readable formats or binary if the
/// format is binary. Fails if the `buffer` isn't the exact same size as the
/// resulting array.
pub fn deserialize_hex_or_bin<'de, D>(buffer: &mut [u8], deserializer: D) -> Result<&[u8], D::Error>
where
    D: Deserializer<'de>,
{
    if deserializer.is_human_readable() {
        deserializer.deserialize_str(StrIntoBufVisitor::<ExactLength>(buffer, PhantomData))
    } else {
        deserializer.deserialize_byte_buf(SliceVisitor::<ExactLength>(buffer, PhantomData))
    }
}

/// [`HexOrBin`] serializer which uses lower case.
pub type HexLowerOrBin<const N: usize> = HexOrBin<N, false>;

/// [`HexOrBin`] serializer which uses upper case.
pub type HexUpperOrBin<const N: usize> = HexOrBin<N, true>;

/// Serializer/deserializer newtype which encodes bytes as either binary or hex.
///
/// Use hexadecimal with human-readable formats, or raw binary with binary formats.
#[derive(Clone, Copy, Debug, Eq, Hash, Ord, PartialEq, PartialOrd)]
pub struct HexOrBin<const N: usize, const UPPERCASE: bool>(pub [u8; N]);

impl<const N: usize, const UPPERCASE: bool> Default for HexOrBin<N, UPPERCASE> {
    fn default() -> Self {
        Self([0; N])
    }
}

impl<const N: usize, const UPPERCASE: bool> AsRef<[u8]> for HexOrBin<N, UPPERCASE> {
    fn as_ref(&self) -> &[u8] {
        self.0.as_ref()
    }
}

impl<const N: usize, const UPPERCASE: bool> From<&[u8; N]> for HexOrBin<N, UPPERCASE> {
    fn from(bytes: &[u8; N]) -> Self {
        Self(*bytes)
    }
}

impl<const N: usize, const UPPERCASE: bool> From<[u8; N]> for HexOrBin<N, UPPERCASE> {
    fn from(bytes: [u8; N]) -> Self {
        Self(bytes)
    }
}

impl<const N: usize, const UPPERCASE: bool> From<HexOrBin<N, UPPERCASE>> for [u8; N] {
    fn from(hex_or_bin: HexOrBin<N, UPPERCASE>) -> Self {
        hex_or_bin.0
    }
}

impl<const N: usize, const UPPERCASE: bool> Serialize for HexOrBin<N, UPPERCASE> {
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

impl<'de, const N: usize, const UPPERCASE: bool> Deserialize<'de> for HexOrBin<N, UPPERCASE> {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: Deserializer<'de>,
    {
        let mut buffer = [0; N];
        deserialize_hex_or_bin(&mut buffer, deserializer)?;

        Ok(Self(buffer))
    }
}

#[cfg(feature = "zeroize")]
impl<const N: usize, const UPPERCASE: bool> Zeroize for HexOrBin<N, UPPERCASE> {
    fn zeroize(&mut self) {
        self.0.as_mut_slice().zeroize();
    }
}
