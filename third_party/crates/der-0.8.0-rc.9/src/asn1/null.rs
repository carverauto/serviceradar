//! ASN.1 `NULL` support.

use crate::{
    BytesRef, DecodeValue, EncodeValue, Error, ErrorKind, FixedTag, Header, Length, Reader, Result,
    Tag, Writer, asn1::AnyRef, ord::OrdIsValueOrd,
};

/// ASN.1 `NULL` type.
#[derive(Copy, Clone, Debug, Eq, PartialEq, PartialOrd, Ord)]
pub struct Null;

impl_any_conversions!(Null);

impl<'a> DecodeValue<'a> for Null {
    type Error = Error;

    fn decode_value<R: Reader<'a>>(reader: &mut R, header: Header) -> Result<Self> {
        if header.length().is_zero() {
            Ok(Null)
        } else {
            Err(reader.error(ErrorKind::Length { tag: Self::TAG }))
        }
    }
}

impl EncodeValue for Null {
    fn value_len(&self) -> Result<Length> {
        Ok(Length::ZERO)
    }

    fn encode_value(&self, _writer: &mut impl Writer) -> Result<()> {
        Ok(())
    }
}

impl FixedTag for Null {
    const TAG: Tag = Tag::Null;
}

impl OrdIsValueOrd for Null {}

impl<'a> From<Null> for AnyRef<'a> {
    fn from(_: Null) -> AnyRef<'a> {
        AnyRef::from_tag_and_value(Tag::Null, BytesRef::EMPTY)
    }
}

impl TryFrom<AnyRef<'_>> for () {
    type Error = Error;

    fn try_from(any: AnyRef<'_>) -> Result<()> {
        Null::try_from(any).map(|_| ())
    }
}

impl<'a> From<()> for AnyRef<'a> {
    fn from(_: ()) -> AnyRef<'a> {
        Null.into()
    }
}

impl<'a> DecodeValue<'a> for () {
    type Error = Error;

    fn decode_value<R: Reader<'a>>(reader: &mut R, header: Header) -> Result<Self> {
        Null::decode_value(reader, header)?;
        Ok(())
    }
}

impl EncodeValue for () {
    fn value_len(&self) -> Result<Length> {
        Ok(Length::ZERO)
    }

    fn encode_value(&self, _writer: &mut impl Writer) -> Result<()> {
        Ok(())
    }
}

impl FixedTag for () {
    const TAG: Tag = Tag::Null;
}

#[cfg(test)]
#[allow(clippy::unwrap_used)]
mod tests {
    use super::Null;
    use crate::{Decode, Encode};

    #[test]
    fn decode() {
        Null::from_der(&[0x05, 0x00]).unwrap();
    }

    #[test]
    fn encode() {
        let mut buffer = [0u8; 2];
        assert_eq!(&[0x05, 0x00], Null.encode_to_slice(&mut buffer).unwrap());
        assert_eq!(&[0x05, 0x00], ().encode_to_slice(&mut buffer).unwrap());
    }

    #[test]
    fn reject_non_canonical() {
        assert!(Null::from_der(&[0x05, 0x81, 0x00]).is_err());
        assert!(Null::from_der(&[0x05, 0x01, 0xAA]).is_err());
    }
}
