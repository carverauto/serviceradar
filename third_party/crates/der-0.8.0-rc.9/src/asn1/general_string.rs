use crate::{BytesRef, DecodeValue, EncodeValue, FixedTag, Header, Length, Reader, Tag, Writer};

/// This is currently `&[u8]` internally, as `GeneralString` is not fully implemented yet
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct GeneralStringRef<'a> {
    /// Raw contents, unchecked
    inner: &'a BytesRef,
}
impl<'a> GeneralStringRef<'a> {
    /// This is currently `&[u8]` internally, as `GeneralString` is not fully implemented yet
    pub fn as_bytes(&self) -> &'a [u8] {
        self.inner.as_slice()
    }
}

impl FixedTag for GeneralStringRef<'_> {
    const TAG: Tag = Tag::GeneralString;
}
impl<'a> DecodeValue<'a> for GeneralStringRef<'a> {
    type Error = crate::Error;

    fn decode_value<R: Reader<'a>>(reader: &mut R, header: Header) -> Result<Self, Self::Error> {
        Ok(Self {
            inner: <&'a BytesRef>::decode_value(reader, header)?,
        })
    }
}
impl EncodeValue for GeneralStringRef<'_> {
    fn value_len(&self) -> crate::Result<Length> {
        self.inner.value_len()
    }

    fn encode_value(&self, encoder: &mut impl Writer) -> crate::Result<()> {
        self.inner.encode_value(encoder)
    }
}
