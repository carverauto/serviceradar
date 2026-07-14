//! ASN.1 `OPTIONAL` as mapped to Rust's `Option` type

use crate::{Choice, Decode, DerOrd, Encode, Error, Length, Reader, Tag, Writer};
use core::cmp::Ordering;

impl<'a, T> Decode<'a> for Option<T>
where
    T: Choice<'a>, // NOTE: all `Decode + Tagged` types receive a blanket `Choice` impl
{
    type Error = T::Error;

    fn decode<R: Reader<'a>>(reader: &mut R) -> Result<Option<T>, Self::Error> {
        if reader.is_finished() {
            return Ok(None);
        }

        if T::can_decode(Tag::peek(reader)?) {
            return T::decode(reader).map(Some);
        }

        Ok(None)
    }
}

impl<T> DerOrd for Option<T>
where
    T: DerOrd,
{
    fn der_cmp(&self, other: &Self) -> Result<Ordering, Error> {
        match self {
            Some(a) => match other {
                Some(b) => a.der_cmp(b),
                None => Ok(Ordering::Greater),
            },
            None => Ok(Ordering::Less),
        }
    }
}

impl<T> Encode for Option<T>
where
    T: Encode,
{
    fn encoded_len(&self) -> Result<Length, Error> {
        (&self).encoded_len()
    }

    fn encode(&self, writer: &mut impl Writer) -> Result<(), Error> {
        (&self).encode(writer)
    }
}

impl<T> Encode for &Option<T>
where
    T: Encode,
{
    fn encoded_len(&self) -> Result<Length, Error> {
        match self {
            Some(encodable) => encodable.encoded_len(),
            None => Ok(0u8.into()),
        }
    }

    fn encode(&self, encoder: &mut impl Writer) -> Result<(), Error> {
        match self {
            Some(encodable) => encodable.encode(encoder),
            None => Ok(()),
        }
    }
}
