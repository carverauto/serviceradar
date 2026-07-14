//! Context-specific field.

use crate::{
    Choice, Class, Decode, DecodeValue, DerOrd, Encode, EncodeValue, EncodeValueRef, Error, Header,
    Length, Reader, Tag, TagMode, TagNumber, Tagged, ValueOrd, Writer, asn1::AnyRef,
    tag::IsConstructed,
};
use core::cmp::Ordering;

#[cfg(doc)]
use crate::ErrorKind;

impl_custom_class!(
    ContextSpecific,
    ContextSpecific,
    "CONTEXT-SPECIFIC",
    "0b10000000"
);
impl_custom_class_ref!(
    ContextSpecificRef,
    ContextSpecific,
    "CONTEXT-SPECIFIC",
    "0b10000000"
);

#[cfg(test)]
#[allow(clippy::unwrap_used)]
mod tests {
    use super::ContextSpecific;
    use crate::{
        Decode, Encode, SliceReader, TagMode, TagNumber,
        asn1::{BitStringRef, ContextSpecificRef, SetOf, Utf8StringRef},
    };
    use hex_literal::hex;

    // Public key data from `pkcs8` crate's `ed25519-pkcs8-v2.der`
    const EXAMPLE_BYTES: &[u8] =
        &hex!("A123032100A3A7EAE3A8373830BC47E1167BC50E1DB551999651E0E2DC587623438EAC3F31");

    #[test]
    fn round_trip() {
        let field = ContextSpecific::<BitStringRef<'_>>::from_der(EXAMPLE_BYTES).unwrap();
        assert_eq!(field.tag_number.value(), 1);
        assert_eq!(
            field.value,
            BitStringRef::from_bytes(&EXAMPLE_BYTES[5..]).unwrap()
        );

        let mut buf = [0u8; 128];
        let encoded = field.encode_to_slice(&mut buf).unwrap();
        assert_eq!(encoded, EXAMPLE_BYTES);
    }

    #[test]
    fn context_specific_with_explicit_field() {
        let tag_number = TagNumber(0);

        // Empty message
        let mut reader = SliceReader::new(&[]).unwrap();
        assert_eq!(
            ContextSpecific::<u8>::decode_explicit(&mut reader, tag_number).unwrap(),
            None
        );

        // Message containing a non-context-specific type
        let mut reader = SliceReader::new(&hex!("020100")).unwrap();
        assert_eq!(
            ContextSpecific::<u8>::decode_explicit(&mut reader, tag_number).unwrap(),
            None
        );

        // Message containing an EXPLICIT context-specific field
        let mut reader = SliceReader::new(&hex!("A003020100")).unwrap();
        let field = ContextSpecific::<u8>::decode_explicit(&mut reader, tag_number)
            .unwrap()
            .unwrap();

        assert_eq!(field.tag_number, tag_number);
        assert_eq!(field.tag_mode, TagMode::Explicit);
        assert_eq!(field.value, 0);
    }

    #[test]
    fn context_specific_with_implicit_field() {
        // From RFC8410 Section 10.3:
        // <https://datatracker.ietf.org/doc/html/rfc8410#section-10.3>
        //
        //    81  33:   [1] 00 19 BF 44 09 69 84 CD FE 85 41 BA C1 67 DC 3B
        //                  96 C8 50 86 AA 30 B6 B6 CB 0C 5C 38 AD 70 31 66
        //                  E1
        let context_specific_implicit_bytes =
            hex!("81210019BF44096984CDFE8541BAC167DC3B96C85086AA30B6B6CB0C5C38AD703166E1");

        let tag_number = TagNumber(1);

        let mut reader = SliceReader::new(&context_specific_implicit_bytes).unwrap();
        let field = ContextSpecific::<BitStringRef<'_>>::decode_implicit(&mut reader, tag_number)
            .unwrap()
            .unwrap();

        assert_eq!(field.tag_number, tag_number);
        assert_eq!(field.tag_mode, TagMode::Implicit);
        assert_eq!(
            field.value.as_bytes().unwrap(),
            &context_specific_implicit_bytes[3..]
        );
    }

    #[test]
    fn context_specific_not_skipping_unknown_field() {
        let tag = TagNumber(1);
        let mut reader = SliceReader::new(&hex!("A003020100A103020101")).unwrap();
        let field = ContextSpecific::<u8>::decode_explicit(&mut reader, tag).unwrap();
        assert_eq!(field, None);
    }

    #[test]
    fn context_specific_returns_none_on_greater_tag_number() {
        let tag = TagNumber(0);
        let mut reader = SliceReader::new(&hex!("A103020101")).unwrap();
        assert_eq!(
            ContextSpecific::<u8>::decode_explicit(&mut reader, tag).unwrap(),
            None
        );
    }

    #[test]
    fn context_specific_explicit_ref() {
        let mut set = SetOf::new();
        set.insert(8u16).unwrap();
        set.insert(7u16).unwrap();

        let field = ContextSpecificRef::<SetOf<u16, 2>> {
            value: &set,
            tag_number: TagNumber(2),
            tag_mode: TagMode::Explicit,
        };

        let mut buf = [0u8; 16];
        let encoded = field.encode_to_slice(&mut buf).unwrap();
        assert_eq!(
            encoded,
            &[
                /* CONTEXT-SPECIFIC [2] */ 0xA2, 0x08, /* SET 0x11 | 0x20 */ 0x31, 0x06,
                /* INTEGER */ 0x02, 0x01, 0x07, /* INTEGER */ 0x02, 0x01, 0x08
            ]
        );

        let mut reader = SliceReader::new(encoded).unwrap();
        let field = ContextSpecific::<SetOf<u16, 2>>::decode_explicit(&mut reader, TagNumber(2))
            .unwrap()
            .unwrap();

        assert_eq!(field.value.len(), 2);
        assert_eq!(field.value.get(0).cloned(), Some(7));
        assert_eq!(field.value.get(1).cloned(), Some(8));
    }

    #[test]
    fn context_specific_implicit_ref() {
        let hello = Utf8StringRef::new("Hello").unwrap();
        let world = Utf8StringRef::new("world").unwrap();

        let mut set = SetOf::new();
        set.insert(hello).unwrap();
        set.insert(world).unwrap();

        let field = ContextSpecificRef::<SetOf<Utf8StringRef<'_>, 2>> {
            value: &set,
            tag_number: TagNumber(2),
            tag_mode: TagMode::Implicit,
        };

        let mut buf = [0u8; 16];
        let encoded = field.encode_to_slice(&mut buf).unwrap();
        assert_eq!(
            encoded,
            &[
                0xA2, 0x0E, // CONTEXT-SPECIFIC [2]
                0x0C, 0x05, b'H', b'e', b'l', b'l', b'o', // UTF8String "Hello"
                0x0C, 0x05, b'w', b'o', b'r', b'l', b'd', // UTF8String "world"
            ]
        );

        let mut reader = SliceReader::new(encoded).unwrap();
        let field = ContextSpecific::<SetOf<Utf8StringRef<'_>, 2>>::decode_implicit(
            &mut reader,
            TagNumber(2),
        )
        .unwrap()
        .unwrap();

        assert_eq!(field.value.len(), 2);
        assert_eq!(field.value.get(0).cloned(), Some(hello));
        assert_eq!(field.value.get(1).cloned(), Some(world));
    }
}
