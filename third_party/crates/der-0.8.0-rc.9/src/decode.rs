//! Trait definition for [`Decode`].

use crate::{Error, FixedTag, Header, Reader, SliceReader, reader::read_value};

use core::marker::PhantomData;

#[cfg(feature = "pem")]
use crate::{PemReader, pem::PemLabel};

#[cfg(doc)]
use crate::{ErrorKind, Length, Tag};

#[cfg(feature = "alloc")]
use alloc::boxed::Box;

#[cfg(feature = "ber")]
use crate::EncodingRules;

/// Decoding trait.
///
/// This trait provides the core abstraction upon which all decoding operations
/// are based.
#[diagnostic::on_unimplemented(
    note = "Consider adding impls of `DecodeValue` and `FixedTag` to `{Self}`"
)]
pub trait Decode<'a>: Sized + 'a {
    /// Type returned in the event of a decoding error.
    type Error: From<Error> + 'static;

    /// Attempt to decode this message using the provided decoder.
    fn decode<R: Reader<'a>>(decoder: &mut R) -> Result<Self, Self::Error>;

    /// Parse `Self` from the provided BER-encoded byte slice.
    ///
    /// Note that most usages should probably use [`Decode::from_der`]. This method allows some
    /// BER productions which are not allowed under DER.
    #[cfg(feature = "ber")]
    fn from_ber(bytes: &'a [u8]) -> Result<Self, Self::Error> {
        let mut reader = SliceReader::new_with_encoding_rules(bytes, EncodingRules::Ber)?;
        let result = Self::decode(&mut reader)?;
        reader.finish()?;
        Ok(result)
    }

    /// Parse `Self` from the provided DER-encoded byte slice.
    ///
    /// Returns [`ErrorKind::TrailingData`] if message is incomplete.
    fn from_der(bytes: &'a [u8]) -> Result<Self, Self::Error> {
        let mut reader = SliceReader::new(bytes)?;
        let result = Self::decode(&mut reader)?;
        reader.finish()?;
        Ok(result)
    }

    /// Parse `Self` from the provided DER-encoded byte slice.
    ///
    /// Returns remaining byte slice, without checking for incomplete message.
    fn from_der_partial(bytes: &'a [u8]) -> Result<(Self, &'a [u8]), Self::Error> {
        let mut reader = SliceReader::new(bytes)?;
        let result = Self::decode(&mut reader)?;

        let remaining = reader.remaining()?;
        Ok((result, remaining))
    }
}

impl<'a, T> Decode<'a> for T
where
    T: DecodeValue<'a> + FixedTag + 'a,
{
    type Error = <T as DecodeValue<'a>>::Error;

    fn decode<R: Reader<'a>>(reader: &mut R) -> Result<T, <T as DecodeValue<'a>>::Error> {
        let header = Header::decode(reader)?;
        header.tag().assert_eq(T::TAG)?;
        read_value(reader, header, T::decode_value)
    }
}

/// Dummy implementation for [`PhantomData`] which allows deriving
/// implementations on structs with phantom fields.
impl<'a, T> Decode<'a> for PhantomData<T>
where
    T: ?Sized + 'a,
{
    type Error = Error;

    fn decode<R: Reader<'a>>(_reader: &mut R) -> Result<PhantomData<T>, Error> {
        Ok(PhantomData)
    }
}

/// Marker trait for data structures that can be decoded from DER without
/// borrowing any data from the decoder.
///
/// This is primarily useful for trait bounds on functions which require that
/// no data is borrowed from the decoder, for example a PEM decoder which needs
/// to first decode data from Base64.
///
/// This trait is inspired by the [`DeserializeOwned` trait from `serde`](https://docs.rs/serde/latest/serde/de/trait.DeserializeOwned.html).
#[diagnostic::on_unimplemented(
    note = "`DecodeOwned` is auto-impl'd for all lifetime-free types which impl `Decode`"
)]
pub trait DecodeOwned: for<'a> Decode<'a> {}

impl<T> DecodeOwned for T where T: for<'a> Decode<'a> {}

/// PEM decoding trait.
///
/// This trait is automatically impl'd for any type which impls both
/// [`DecodeOwned`] and [`PemLabel`].
#[cfg(feature = "pem")]
#[diagnostic::on_unimplemented(
    note = "`DecodePem` is auto-impl'd for all lifetime-free types which impl both `Decode` and `PemLabel`"
)]
pub trait DecodePem: DecodeOwned + PemLabel {
    /// Try to decode this type from PEM.
    fn from_pem(pem: impl AsRef<[u8]>) -> Result<Self, <Self as Decode<'static>>::Error>;
}

#[cfg(feature = "pem")]
impl<T: DecodeOwned<Error = Error> + PemLabel> DecodePem for T {
    fn from_pem(pem: impl AsRef<[u8]>) -> Result<T, Error> {
        let mut reader = PemReader::new(pem.as_ref())?;
        Self::validate_pem_label(reader.type_label()).map_err(Error::from)?;
        T::decode(&mut reader)
    }
}

/// Decode the value part of a Tag-Length-Value encoded field, sans the [`Tag`]
/// and [`Length`].
pub trait DecodeValue<'a>: Sized {
    /// Type returned in the event of a decoding error.
    type Error: From<Error> + 'static;

    /// Attempt to decode this message using the provided [`Reader`].
    fn decode_value<R: Reader<'a>>(reader: &mut R, header: Header) -> Result<Self, Self::Error>;
}

#[cfg(feature = "alloc")]
impl<'a, T> DecodeValue<'a> for Box<T>
where
    T: DecodeValue<'a>,
{
    type Error = T::Error;

    fn decode_value<R: Reader<'a>>(reader: &mut R, header: Header) -> Result<Self, Self::Error> {
        Ok(Box::new(T::decode_value(reader, header)?))
    }
}
