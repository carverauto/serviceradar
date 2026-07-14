//! ASN.1 `OBJECT IDENTIFIER`

use crate::{
    DecodeValue, EncodeValue, Error, FixedTag, Header, Length, Reader, Result, Tag, Tagged, Writer,
    asn1::AnyRef, ord::OrdIsValueOrd,
};
use const_oid::{ObjectIdentifier, ObjectIdentifierRef};

#[cfg(feature = "alloc")]
use super::Any;

impl<'a, const MAX_SIZE: usize> DecodeValue<'a> for ObjectIdentifier<MAX_SIZE> {
    type Error = Error;

    fn decode_value<R: Reader<'a>>(reader: &mut R, header: Header) -> Result<Self> {
        let mut buf = [0u8; MAX_SIZE];
        let slice = buf
            .get_mut(..header.length().try_into()?)
            .ok_or_else(|| Self::TAG.length_error())?;

        let actual_len = reader.read_into(slice)?.len();
        debug_assert_eq!(actual_len, header.length().try_into()?);
        Ok(ObjectIdentifierRef::from_bytes(slice)?.try_into()?)
    }
}

impl<const MAX_SIZE: usize> EncodeValue for ObjectIdentifier<MAX_SIZE> {
    fn value_len(&self) -> Result<Length> {
        Length::try_from(self.as_bytes().len())
    }

    fn encode_value(&self, writer: &mut impl Writer) -> Result<()> {
        writer.write(self.as_bytes())
    }
}

impl<const MAX_SIZE: usize> FixedTag for ObjectIdentifier<MAX_SIZE> {
    const TAG: Tag = Tag::ObjectIdentifier;
}

impl<const MAX_SIZE: usize> OrdIsValueOrd for ObjectIdentifier<MAX_SIZE> {}

impl<'a, const MAX_SIZE: usize> From<&'a ObjectIdentifier<MAX_SIZE>> for AnyRef<'a> {
    fn from(oid: &'a ObjectIdentifier<MAX_SIZE>) -> AnyRef<'a> {
        // Note: ensuring an infallible conversion is possible relies on the
        // invariant that `const_oid::MAX_LEN <= Length::max()`.
        //
        // The `length()` test below ensures this is the case.
        let value = oid
            .as_bytes()
            .try_into()
            .expect("OID length invariant violated");

        AnyRef::from_tag_and_value(Tag::ObjectIdentifier, value)
    }
}

#[cfg(feature = "alloc")]
impl<const MAX_SIZE: usize> From<ObjectIdentifier<MAX_SIZE>> for Any {
    fn from(oid: ObjectIdentifier<MAX_SIZE>) -> Any {
        AnyRef::from(&oid).into()
    }
}

impl<const MAX_SIZE: usize> TryFrom<AnyRef<'_>> for ObjectIdentifier<MAX_SIZE> {
    type Error = Error;

    fn try_from(any: AnyRef<'_>) -> Result<ObjectIdentifier<MAX_SIZE>> {
        any.tag().assert_eq(Tag::ObjectIdentifier)?;
        Ok(ObjectIdentifierRef::from_bytes(any.value())?.try_into()?)
    }
}

#[cfg(test)]
#[allow(clippy::unwrap_used)]
mod tests {
    use super::ObjectIdentifier;
    use crate::{Decode, Encode, Length};

    const EXAMPLE_OID: ObjectIdentifier = ObjectIdentifier::new_unwrap("1.2.840.113549");
    const EXAMPLE_OID_BYTES: &[u8; 8] = &[0x06, 0x06, 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d];

    #[test]
    fn decode() {
        let oid = ObjectIdentifier::from_der(EXAMPLE_OID_BYTES).unwrap();
        assert_eq!(EXAMPLE_OID, oid);
    }

    #[test]
    fn encode() {
        let mut buffer = [0u8; 8];
        assert_eq!(
            EXAMPLE_OID_BYTES,
            EXAMPLE_OID.encode_to_slice(&mut buffer).unwrap()
        );
    }

    #[test]
    fn length() {
        // Ensure an infallible `From` conversion to `Any` will never panic
        assert!(ObjectIdentifier::MAX_SIZE <= Length::MAX.try_into().unwrap());
    }
}
