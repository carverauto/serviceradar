use base16ct::HexDisplay;
use core::fmt;
use core::marker::PhantomData;
use serde::{
    Serializer,
    de::{Error, Unexpected, Visitor},
};

#[cfg(feature = "alloc")]
use alloc::vec::Vec;

pub(crate) fn serialize_hex<S, T, const UPPERCASE: bool>(
    value: &T,
    serializer: S,
) -> Result<S::Ok, S::Error>
where
    S: Serializer,
    T: AsRef<[u8]>,
{
    let hex = HexDisplay(value.as_ref());

    if UPPERCASE {
        serializer.collect_str(&format_args!("{:X}", hex))
    } else {
        serializer.collect_str(&format_args!("{:x}", hex))
    }
}

pub(crate) fn serialize_hex_lower_or_bin<S, T>(value: &T, serializer: S) -> Result<S::Ok, S::Error>
where
    S: Serializer,
    T: AsRef<[u8]>,
{
    if serializer.is_human_readable() {
        serialize_hex::<_, _, false>(value, serializer)
    } else {
        serializer.serialize_bytes(value.as_ref())
    }
}

/// Serialize the given type as upper case hex when using human-readable
/// formats or binary if the format is binary.
pub(crate) fn serialize_hex_upper_or_bin<S, T>(value: &T, serializer: S) -> Result<S::Ok, S::Error>
where
    S: Serializer,
    T: AsRef<[u8]>,
{
    if serializer.is_human_readable() {
        serialize_hex::<_, _, true>(value, serializer)
    } else {
        serializer.serialize_bytes(value.as_ref())
    }
}

pub(crate) trait LengthCheck {
    fn length_check(buffer_length: usize, data_length: usize) -> bool;
    fn expecting(
        formatter: &mut fmt::Formatter<'_>,
        data_type: &str,
        data_length: usize,
    ) -> fmt::Result;
}

pub(crate) struct StrIntoBufVisitor<'b, T: LengthCheck>(pub &'b mut [u8], pub PhantomData<T>);

impl<'b, T: LengthCheck> Visitor<'_> for StrIntoBufVisitor<'b, T> {
    type Value = &'b [u8];

    fn expecting(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        T::expecting(formatter, "a string", self.0.len() * 2)
    }

    fn visit_str<E>(self, v: &str) -> Result<Self::Value, E>
    where
        E: Error,
    {
        base16ct::mixed::decode(v, self.0).map_err(|err| match err {
            base16ct::Error::InvalidLength => {
                Error::invalid_length(v.len(), &"an even number of hex digits")
            }
            base16ct::Error::InvalidEncoding => Error::invalid_value(
                Unexpected::Other("<potentially secret hex string>"),
                &"a sequence of hex digits (0-9,a-f,A-F)",
            ),
        })
    }
}

#[cfg(feature = "alloc")]
pub(crate) struct StrIntoVecVisitor;

#[cfg(feature = "alloc")]
impl Visitor<'_> for StrIntoVecVisitor {
    type Value = Vec<u8>;

    fn expecting(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(formatter, "a string")
    }

    fn visit_str<E>(self, v: &str) -> Result<Self::Value, E>
    where
        E: Error,
    {
        base16ct::mixed::decode_vec(v).map_err(E::custom)
    }
}

pub(crate) struct SliceVisitor<'b, T: LengthCheck>(pub &'b mut [u8], pub PhantomData<T>);

impl<'b, T: LengthCheck> Visitor<'_> for SliceVisitor<'b, T> {
    type Value = &'b [u8];

    fn expecting(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        T::expecting(formatter, "an array", self.0.len())
    }

    fn visit_bytes<E>(self, v: &[u8]) -> Result<Self::Value, E>
    where
        E: Error,
    {
        // Workaround for
        // https://github.com/rust-lang/rfcs/blob/b1de05846d9bc5591d753f611ab8ee84a01fa500/text/2094-nll.md#problem-case-3-conditional-control-flow-across-functions
        if T::length_check(self.0.len(), v.len()) {
            let buffer = &mut self.0[..v.len()];
            buffer.copy_from_slice(v);
            return Ok(buffer);
        }

        Err(E::invalid_length(v.len(), &self))
    }

    #[cfg(feature = "alloc")]
    fn visit_byte_buf<E>(self, mut v: Vec<u8>) -> Result<Self::Value, E>
    where
        E: Error,
    {
        // Workaround for
        // https://github.com/rust-lang/rfcs/blob/b1de05846d9bc5591d753f611ab8ee84a01fa500/text/2094-nll.md#problem-case-3-conditional-control-flow-across-functions
        if T::length_check(self.0.len(), v.len()) {
            let buffer = &mut self.0[..v.len()];
            buffer.swap_with_slice(&mut v);
            return Ok(buffer);
        }

        Err(E::invalid_length(v.len(), &self))
    }
}

#[cfg(feature = "alloc")]
pub(crate) struct VecVisitor;

#[cfg(feature = "alloc")]
impl Visitor<'_> for VecVisitor {
    type Value = Vec<u8>;

    fn expecting(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(formatter, "a bytestring")
    }

    fn visit_bytes<E>(self, v: &[u8]) -> Result<Self::Value, E>
    where
        E: Error,
    {
        Ok(v.into())
    }

    fn visit_byte_buf<E>(self, v: Vec<u8>) -> Result<Self::Value, E>
    where
        E: Error,
    {
        Ok(v)
    }
}
