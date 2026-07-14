//! Reader trait.

#[cfg(feature = "pem")]
pub(crate) mod pem;
pub(crate) mod slice;

#[cfg(feature = "pem")]
mod position;

use crate::{
    Decode, DecodeValue, Encode, EncodingRules, Error, ErrorKind, FixedTag, Header, Length, Tag,
    TagMode, TagNumber, asn1::ContextSpecific,
};

#[cfg(feature = "alloc")]
use alloc::vec::Vec;

#[cfg(feature = "ber")]
use crate::length::indefinite::read_eoc;

/// Reader trait which reads DER-encoded input.
pub trait Reader<'r>: Clone {
    /// Get the [`EncodingRules`] which should be applied when decoding the input.
    fn encoding_rules(&self) -> EncodingRules;

    /// Get the length of the input.
    fn input_len(&self) -> Length;

    /// Get the position within the buffer.
    fn position(&self) -> Length;

    /// Read nested data of the given length.
    fn read_nested<T, F, E>(&mut self, len: Length, f: F) -> Result<T, E>
    where
        E: From<Error>,
        F: FnOnce(&mut Self) -> Result<T, E>;

    /// Attempt to read data borrowed directly from the input as a slice,
    /// updating the internal cursor position.
    ///
    /// # Returns
    /// - `Ok(slice)` on success
    /// - `Err(ErrorKind::Incomplete)` if there is not enough data
    /// - `Err(ErrorKind::Reader)` if the reader can't borrow from the input
    fn read_slice(&mut self, len: Length) -> Result<&'r [u8], Error>;

    /// Attempt to decode an ASN.1 `CONTEXT-SPECIFIC` field with the
    /// provided [`TagNumber`].
    fn context_specific<T>(
        &mut self,
        tag_number: TagNumber,
        tag_mode: TagMode,
    ) -> Result<Option<T>, T::Error>
    where
        T: DecodeValue<'r> + FixedTag + 'r,
    {
        Ok(match tag_mode {
            TagMode::Explicit => ContextSpecific::<T>::decode_explicit(self, tag_number)?,
            TagMode::Implicit => ContextSpecific::<T>::decode_implicit(self, tag_number)?,
        }
        .map(|field| field.value))
    }

    /// Decode a value which impls the [`Decode`] trait.
    fn decode<T: Decode<'r>>(&mut self) -> Result<T, T::Error> {
        T::decode(self)
    }

    /// Drain the given amount of data from the reader, discarding it.
    fn drain(&mut self, mut amount: Length) -> Result<(), Error> {
        const BUFFER_SIZE: usize = 16;
        let mut buffer = [0u8; BUFFER_SIZE];

        while amount > Length::ZERO {
            let amount_usize = usize::try_from(amount)?;

            let nbytes_drained = if amount_usize >= BUFFER_SIZE {
                self.read_into(&mut buffer)?;
                Length::try_from(BUFFER_SIZE)?
            } else {
                self.read_into(&mut buffer[..amount_usize])?;
                amount
            };

            amount = (amount - nbytes_drained)?;
        }

        Ok(())
    }

    /// Return an error with the given [`ErrorKind`], annotating it with
    /// context about where the error occurred.
    fn error(&mut self, kind: ErrorKind) -> Error {
        kind.at(self.position())
    }

    /// Finish decoding, returning `Ok(())` if there is no
    /// remaining data, or an error otherwise
    fn finish(self) -> Result<(), Error> {
        if !self.is_finished() {
            Err(ErrorKind::TrailingData {
                decoded: self.position(),
                remaining: self.remaining_len(),
            }
            .at(self.position()))
        } else {
            Ok(())
        }
    }

    /// Have we read all input data?
    fn is_finished(&self) -> bool {
        self.remaining_len().is_zero()
    }

    /// Offset within the original input stream.
    ///
    /// This is used for error reporting, and doesn't need to be overridden
    /// by any reader implementations (except for the built-in `NestedReader`,
    /// which consumes nested input messages)
    fn offset(&self) -> Length {
        self.position()
    }

    /// Peek at the next byte of input without modifying the cursor.
    fn peek_byte(&self) -> Option<u8> {
        let mut byte = [0];
        self.peek_into(&mut byte).ok().map(|_| byte[0])
    }

    /// Peek at the decoded data without updating the internal state, writing into the provided
    /// output buffer.
    ///
    /// Attempts to fill the entire buffer, returning an error if there is not enough data.
    fn peek_into(&self, buf: &mut [u8]) -> Result<(), Error> {
        let mut reader = self.clone();
        reader.read_into(buf)?;
        Ok(())
    }

    /// Peek forward in the input data, attempting to decode a [`Header`] from
    /// the data at the current position in the decoder.
    ///
    /// Does not modify the decoder's state.
    #[deprecated(since = "0.8.0-rc.1", note = "use `Header::peek` instead")]
    fn peek_header(&self) -> Result<Header, Error> {
        Header::peek(self)
    }

    /// Peek at the next tag in the reader.
    #[deprecated(since = "0.8.0-rc.1", note = "use `Tag::peek` instead")]
    fn peek_tag(&self) -> Result<Tag, Error> {
        Tag::peek(self)
    }

    /// Read a single byte.
    fn read_byte(&mut self) -> Result<u8, Error> {
        let mut buf = [0];
        self.read_into(&mut buf)?;
        Ok(buf[0])
    }

    /// Attempt to read input data, writing it into the provided buffer, and
    /// returning a slice on success.
    ///
    /// # Returns
    /// - `Ok(slice)` if there is sufficient data
    /// - `Err(ErrorKind::Incomplete)` if there is not enough data
    fn read_into<'o>(&mut self, buf: &'o mut [u8]) -> Result<&'o [u8], Error> {
        let input = self.read_slice(buf.len().try_into()?)?;
        buf.copy_from_slice(input);
        Ok(buf)
    }

    /// Read a byte vector of the given length.
    #[cfg(feature = "alloc")]
    fn read_vec(&mut self, len: Length) -> Result<Vec<u8>, Error> {
        let mut bytes = vec![0u8; usize::try_from(len)?];
        self.read_into(&mut bytes)?;
        Ok(bytes)
    }

    /// Get the number of bytes still remaining in the buffer.
    fn remaining_len(&self) -> Length {
        debug_assert!(self.position() <= self.input_len());
        self.input_len().saturating_sub(self.position())
    }

    /// Read an ASN.1 `SEQUENCE`, creating a nested [`Reader`] for the body and
    /// calling the provided closure with it.
    fn sequence<F, T, E>(&mut self, f: F) -> Result<T, E>
    where
        F: FnOnce(&mut Self) -> Result<T, E>,
        E: From<Error>,
    {
        let header = Header::decode(self)?;
        header.tag().assert_eq(Tag::Sequence)?;
        read_value(self, header, |r, _| f(r))
    }

    /// Obtain a slice of bytes containing a complete TLV production suitable for parsing later.
    fn tlv_bytes(&mut self) -> Result<&'r [u8], Error> {
        let header = Header::peek(self)?;
        let header_len = header.encoded_len()?;
        self.read_slice((header_len + header.length())?)
    }
}

/// Read a value (i.e. the "V" part of a "TLV" field) using the provided header.
///
/// This calls the provided function `f` with a nested reader created using
/// [`Reader::read_nested`].
pub(crate) fn read_value<'r, R, T, F, E>(reader: &mut R, header: Header, f: F) -> Result<T, E>
where
    R: Reader<'r>,
    E: From<Error>,
    F: FnOnce(&mut R, Header) -> Result<T, E>,
{
    #[cfg(feature = "ber")]
    let header = header.with_length(header.length().sans_eoc());

    let ret = reader.read_nested(header.length(), |r| f(r, header))?;

    // Consume EOC marker if the length is indefinite.
    #[cfg(feature = "ber")]
    if header.length().is_indefinite() {
        read_eoc(reader)?;
    }

    Ok(ret)
}
