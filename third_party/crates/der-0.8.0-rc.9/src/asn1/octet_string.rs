//! ASN.1 `OCTET STRING` support.

use crate::{
    BytesRef, Decode, DecodeValue, EncodeValue, Error, ErrorKind, FixedTag, Header, Length, Reader,
    Tag, Writer, asn1::AnyRef, ord::OrdIsValueOrd,
};

/// Custom derive hack until `der_derive` is updated to support `&'a MyRef` reference types.
///
/// This is not considered a stable part of the public API and may be removed without warning.
// TODO(tarcieri): update `der_derive` to support `OctetStringRef` properly. See #2039
#[doc(hidden)]
pub type OctetStringRefDeriveHack<'a> = &'a OctetStringRef;

/// ASN.1 `OCTET STRING` type: borrowed form.
///
/// Octet strings represent contiguous sequences of octets, a.k.a. bytes.
///
/// This is a zero-copy reference type which borrows from the input data.
#[derive(Debug, Eq, Hash, PartialEq, PartialOrd, Ord)]
#[repr(transparent)]
pub struct OctetStringRef {
    /// Inner value
    inner: BytesRef,
}

impl OctetStringRef {
    /// Create a new ASN.1 `OCTET STRING` from a byte slice.
    pub fn new(slice: &[u8]) -> Result<&Self, Error> {
        BytesRef::new(slice)
            .map(Self::from_bytes_ref)
            .map_err(|_| ErrorKind::Length { tag: Self::TAG }.into())
    }

    /// Create an [`OctetStringRef`] from a [`BytesRef`].
    ///
    /// Implemented as an inherent method to keep [`BytesRef`] out of the public API.
    fn from_bytes_ref(bytes_ref: &BytesRef) -> &Self {
        // SAFETY: `Self` is a `repr(transparent)` newtype for `BytesRef`
        #[allow(unsafe_code)]
        unsafe {
            &*(bytes_ref.as_ptr() as *const Self)
        }
    }

    /// Borrow the inner byte slice.
    pub fn as_bytes(&self) -> &[u8] {
        self.inner.as_slice()
    }

    /// Get the length of the inner byte slice.
    pub fn len(&self) -> Length {
        self.inner.len()
    }

    /// Is the inner byte slice empty?
    pub fn is_empty(&self) -> bool {
        self.inner.is_empty()
    }

    /// Parse `T` from this `OCTET STRING`'s contents.
    pub fn decode_into<'a, T: Decode<'a>>(&'a self) -> Result<T, T::Error> {
        Decode::from_der(self.as_bytes())
    }
}

impl_any_conversions!(&'a OctetStringRef, 'a);

impl AsRef<[u8]> for OctetStringRef {
    fn as_ref(&self) -> &[u8] {
        self.as_bytes()
    }
}

impl<'a> DecodeValue<'a> for &'a OctetStringRef {
    type Error = Error;

    fn decode_value<R: Reader<'a>>(reader: &mut R, header: Header) -> Result<Self, Error> {
        <&'a BytesRef>::decode_value(reader, header).map(OctetStringRef::from_bytes_ref)
    }
}

impl EncodeValue for &OctetStringRef {
    fn value_len(&self) -> Result<Length, Error> {
        self.inner.value_len()
    }

    fn encode_value(&self, writer: &mut impl Writer) -> Result<(), Error> {
        self.inner.encode_value(writer)
    }
}

impl FixedTag for OctetStringRef {
    const TAG: Tag = Tag::OctetString;
}
impl FixedTag for &OctetStringRef {
    const TAG: Tag = Tag::OctetString;
}

impl OrdIsValueOrd for &OctetStringRef {}

impl<'a> From<&'a OctetStringRef> for AnyRef<'a> {
    fn from(octet_string: &'a OctetStringRef) -> AnyRef<'a> {
        AnyRef::from_tag_and_value(Tag::OctetString, &octet_string.inner)
    }
}

impl<'a> From<&'a OctetStringRef> for &'a [u8] {
    fn from(octet_string: &'a OctetStringRef) -> &'a [u8] {
        octet_string.as_bytes()
    }
}

impl<'a> TryFrom<&'a [u8]> for &'a OctetStringRef {
    type Error = Error;

    fn try_from(byte_slice: &'a [u8]) -> Result<Self, Error> {
        OctetStringRef::new(byte_slice)
    }
}

/// Hack for simplifying the custom derive use case.
impl<'a> TryFrom<&&'a [u8]> for &'a OctetStringRef {
    type Error = Error;

    fn try_from(byte_slice: &&'a [u8]) -> Result<Self, Error> {
        OctetStringRef::new(byte_slice)
    }
}

impl<'a, const N: usize> TryFrom<&'a [u8; N]> for &'a OctetStringRef {
    type Error = Error;

    fn try_from(byte_slice: &'a [u8; N]) -> Result<Self, Error> {
        OctetStringRef::new(byte_slice)
    }
}

impl<'a, const N: usize> TryFrom<&'a OctetStringRef> for [u8; N] {
    type Error = Error;

    fn try_from(octet_string: &'a OctetStringRef) -> Result<Self, Self::Error> {
        octet_string
            .as_bytes()
            .try_into()
            .map_err(|_| Tag::OctetString.length_error().into())
    }
}

#[cfg(feature = "heapless")]
impl<const N: usize> TryFrom<&OctetStringRef> for heapless::Vec<u8, N> {
    type Error = Error;

    fn try_from(octet_string: &OctetStringRef) -> Result<Self, Self::Error> {
        octet_string
            .as_bytes()
            .try_into()
            .map_err(|_| Tag::OctetString.length_error().into())
    }
}

#[cfg(feature = "heapless")]
impl<'a, const N: usize> TryFrom<&'a heapless::Vec<u8, N>> for &'a OctetStringRef {
    type Error = Error;

    fn try_from(byte_vec: &'a heapless::Vec<u8, N>) -> Result<Self, Error> {
        OctetStringRef::new(byte_vec)
    }
}

#[cfg(feature = "alloc")]
pub use self::allocating::OctetString;

#[cfg(feature = "alloc")]
mod allocating {
    use super::*;
    use crate::BytesOwned;
    use alloc::{
        borrow::{Borrow, Cow, ToOwned},
        boxed::Box,
        vec::Vec,
    };

    /// ASN.1 `OCTET STRING` type: owned form.
    ///
    /// Octet strings represent contiguous sequences of octets, a.k.a. bytes.
    ///
    /// This type provides the same functionality as [`OctetStringRef`] but owns
    /// the backing data.
    #[derive(Clone, Debug, Eq, PartialEq, PartialOrd, Ord)]
    pub struct OctetString {
        /// Inner bytestring type.
        pub(super) inner: BytesOwned,
    }

    impl OctetString {
        /// Create a new ASN.1 `OCTET STRING`.
        pub fn new(bytes: impl Into<Box<[u8]>>) -> Result<Self, Error> {
            let inner = BytesOwned::new(bytes)?;

            // Ensure the bytes parse successfully as an `OctetStringRef`
            OctetStringRef::new(inner.as_slice())?;

            Ok(Self { inner })
        }

        /// Borrow the inner byte slice.
        pub fn as_bytes(&self) -> &[u8] {
            self.inner.as_slice()
        }

        /// Take ownership of the octet string.
        pub fn into_bytes(self) -> Box<[u8]> {
            self.inner.into()
        }

        /// Get the length of the inner byte slice.
        pub fn len(&self) -> Length {
            self.inner.len()
        }

        /// Is the inner byte slice empty?
        pub fn is_empty(&self) -> bool {
            self.inner.is_empty()
        }
    }

    impl_any_conversions!(OctetString);

    impl AsRef<[u8]> for OctetString {
        fn as_ref(&self) -> &[u8] {
            self.as_bytes()
        }
    }

    impl Borrow<OctetStringRef> for OctetString {
        fn borrow(&self) -> &OctetStringRef {
            OctetStringRef::from_bytes_ref(self.inner.as_ref())
        }
    }

    impl<'a> DecodeValue<'a> for OctetString {
        type Error = Error;

        fn decode_value<R: Reader<'a>>(reader: &mut R, header: Header) -> Result<Self, Error> {
            let inner = BytesOwned::decode_value_parts(reader, header, Self::TAG)?;
            Ok(Self { inner })
        }
    }

    impl EncodeValue for OctetString {
        fn value_len(&self) -> Result<Length, Error> {
            self.inner.value_len()
        }

        fn encode_value(&self, writer: &mut impl Writer) -> Result<(), Error> {
            self.inner.encode_value(writer)
        }
    }

    impl FixedTag for OctetString {
        const TAG: Tag = Tag::OctetString;
    }

    impl OrdIsValueOrd for OctetString {}

    impl<'a> From<&'a OctetString> for &'a OctetStringRef {
        fn from(octet_string: &'a OctetString) -> &'a OctetStringRef {
            OctetStringRef::from_bytes_ref(octet_string.inner.as_ref())
        }
    }

    impl From<&OctetStringRef> for OctetString {
        fn from(octet_string_ref: &OctetStringRef) -> OctetString {
            Self {
                inner: octet_string_ref.inner.to_owned(),
            }
        }
    }

    impl From<&OctetStringRef> for Vec<u8> {
        fn from(octet_string: &OctetStringRef) -> Vec<u8> {
            Vec::from(octet_string.as_bytes())
        }
    }

    /// Hack for simplifying the custom derive use case.
    impl<'a> TryFrom<&'a Vec<u8>> for &'a OctetStringRef {
        type Error = Error;

        fn try_from(byte_vec: &'a Vec<u8>) -> Result<Self, Error> {
            OctetStringRef::new(byte_vec)
        }
    }

    impl From<OctetString> for Vec<u8> {
        fn from(octet_string: OctetString) -> Vec<u8> {
            octet_string.into_bytes().into()
        }
    }

    impl ToOwned for OctetStringRef {
        type Owned = OctetString;

        fn to_owned(&self) -> OctetString {
            self.into()
        }
    }

    impl<'a> TryFrom<&'a Cow<'a, [u8]>> for &'a OctetStringRef {
        type Error = Error;

        fn try_from(byte_slice: &'a Cow<'a, [u8]>) -> Result<Self, Error> {
            OctetStringRef::new(byte_slice)
        }
    }

    impl<'a> TryFrom<&'a OctetStringRef> for Cow<'a, [u8]> {
        type Error = Error;

        fn try_from(octet_string: &'a OctetStringRef) -> Result<Self, Self::Error> {
            Ok(Cow::Borrowed(octet_string.as_bytes()))
        }
    }

    // Implement by hand because the derive would create invalid values.
    // Use the constructor to create a valid value.
    #[cfg(feature = "arbitrary")]
    impl<'a> arbitrary::Arbitrary<'a> for OctetString {
        fn arbitrary(u: &mut arbitrary::Unstructured<'a>) -> arbitrary::Result<Self> {
            Self::new(Vec::arbitrary(u)?).map_err(|_| arbitrary::Error::IncorrectFormat)
        }

        fn size_hint(depth: usize) -> (usize, Option<usize>) {
            arbitrary::size_hint::and(u8::size_hint(depth), Vec::<u8>::size_hint(depth))
        }
    }
}

#[cfg(feature = "bytes")]
mod bytes {
    use super::{OctetString, OctetStringRef};
    use crate::{
        DecodeValue, EncodeValue, Error, FixedTag, Header, Length, Reader, Result, Tag, Writer,
    };
    use alloc::vec::Vec;
    use bytes::Bytes;

    impl<'a> DecodeValue<'a> for Bytes {
        type Error = Error;

        fn decode_value<R: Reader<'a>>(reader: &mut R, header: Header) -> Result<Self> {
            OctetString::decode_value(reader, header).map(Into::into)
        }
    }

    impl EncodeValue for Bytes {
        fn value_len(&self) -> Result<Length> {
            self.len().try_into()
        }

        fn encode_value(&self, writer: &mut impl Writer) -> Result<()> {
            writer.write(self.as_ref())
        }
    }

    impl FixedTag for Bytes {
        const TAG: Tag = Tag::OctetString;
    }

    impl From<&OctetStringRef> for Bytes {
        fn from(octet_string: &OctetStringRef) -> Bytes {
            Vec::from(octet_string).into()
        }
    }

    impl From<OctetString> for Bytes {
        fn from(octet_string: OctetString) -> Bytes {
            Vec::from(octet_string).into()
        }
    }
}

#[cfg(test)]
#[allow(clippy::unwrap_used)]
mod tests {
    use crate::{
        Decode,
        asn1::{OctetStringRef, PrintableStringRef},
    };
    use hex_literal::hex;

    #[test]
    fn octet_string_decode() {
        // PrintableString "hi"
        const EXAMPLE: &[u8] = &hex!(
            "040c" // primitive definite length OCTET STRING
            "48656c6c6f2c20776f726c64" // "Hello, world"
        );

        let decoded = <&OctetStringRef>::from_der(EXAMPLE).unwrap();
        assert_eq!(decoded.as_bytes(), b"Hello, world");
    }

    #[test]
    fn octet_string_decode_into() {
        // PrintableString "hi"
        let der = b"\x13\x02\x68\x69";
        let oct = OctetStringRef::new(der).unwrap();

        let res = oct.decode_into::<PrintableStringRef<'_>>().unwrap();
        assert_eq!(AsRef::<str>::as_ref(&res), "hi");
    }

    #[test]
    #[cfg(all(feature = "alloc", feature = "ber"))]
    fn decode_ber_primitive_definite() {
        use crate::{Decode, asn1::OctetString};
        use hex_literal::hex;

        const EXAMPLE: &[u8] = &hex!(
            "040c" // primitive definite length OCTET STRING
            "48656c6c6f2c20776f726c64" // "Hello, world"
        );

        let decoded = OctetString::from_ber(EXAMPLE).unwrap();
        assert_eq!(decoded.as_bytes(), b"Hello, world");

        let decoded = OctetString::from_der(EXAMPLE).unwrap();
        assert_eq!(decoded.as_bytes(), b"Hello, world");
    }

    #[test]
    #[cfg(all(feature = "alloc", feature = "ber"))]
    fn decode_ber_constructed_indefinite() {
        use crate::{Decode, asn1::OctetString};
        use hex_literal::hex;

        const EXAMPLE_BER: &[u8] = &hex!(
            "2480" // Constructed indefinite length OCTET STRING
            "040648656c6c6f2c" // Segment containing "Hello,"
            "040620776f726c64" // Segment containing " world"
            "0000" // End-of-contents marker
        );

        let decoded = OctetString::from_ber(EXAMPLE_BER).unwrap();
        assert_eq!(decoded.as_bytes(), b"Hello, world");
    }

    #[test]
    #[cfg(all(feature = "alloc", feature = "ber"))]
    fn decode_ber_constructed_definite() {
        use crate::{Decode, Error, ErrorKind, Length, Tag, asn1::OctetString};
        use hex_literal::hex;

        const EXAMPLE_BER: &[u8] = &hex!(
            "2410" // Constructed definite length OCTET STRING
            "040648656c6c6f2c" // Segment containing "Hello,"
            "040620776f726c64" // Segment containing " world"
        );

        let err = OctetString::from_ber(EXAMPLE_BER).err().unwrap();
        let expected = Error::new(
            ErrorKind::Noncanonical {
                tag: Tag::OctetString,
            },
            Length::new(1),
        );
        assert_eq!(expected, err);
    }

    #[test]
    #[cfg(all(feature = "alloc", feature = "ber"))]
    fn decode_context_specific_ber_explicit() {
        use crate::{
            EncodingRules, SliceReader, TagNumber,
            asn1::{ContextSpecific, OctetString},
        };
        use hex_literal::hex;

        let tag_number = TagNumber(0);

        const EXAMPLE_BER: &[u8] = &hex!(
            "A080" // indefinite length explicit tag
            "2480" // Constructed indefinite length OCTET STRING
            "040648656c6c6f2c" // Segment containing "Hello,"
            "040620776f726c64" // Segment containing " world"
            "0000" // End-of-contents marker
            "0000" // End-of-contents marker
        );

        let mut reader =
            SliceReader::new_with_encoding_rules(EXAMPLE_BER, EncodingRules::Ber).unwrap();

        let decoded = ContextSpecific::<OctetString>::decode_explicit(&mut reader, tag_number)
            .unwrap()
            .unwrap()
            .value;

        assert_eq!(decoded.as_bytes(), b"Hello, world");
    }

    #[test]
    #[cfg(all(feature = "alloc", feature = "ber"))]
    fn decode_context_specific_ber_implicit() {
        use crate::{
            EncodingRules, SliceReader, TagNumber,
            asn1::{ContextSpecific, OctetString},
        };
        use hex_literal::hex;

        let tag_number = TagNumber(0);

        const EXAMPLE_BER: &[u8] = &hex!(
            "A080" // implicit tag, constructed indefinite length OCTET STRING
            "040648656c6c6f2c" // Segment containing "Hello,"
            "040620776f726c64" // Segment containing " world"
            "0000" // End-of-contents marker
        );

        let mut reader =
            SliceReader::new_with_encoding_rules(EXAMPLE_BER, EncodingRules::Ber).unwrap();

        let decoded = ContextSpecific::<OctetString>::decode_implicit(&mut reader, tag_number)
            .unwrap()
            .unwrap()
            .value;

        assert_eq!(decoded.as_bytes(), b"Hello, world");
    }

    #[test]
    #[cfg(all(feature = "alloc", feature = "ber"))]
    fn decode_ber_recursive_unsupported() {
        use crate::{Decode, Error, ErrorKind, Length, asn1::OctetString};
        use hex_literal::hex;

        const EXAMPLE_BER: &[u8] = &hex!(
            "2480" // Constructed indefinite length OCTET STRING
                "2480" // Constructed indefinite length OCTET STRING
                    "040648656c6c6f2c" // Segment containing "Hello,"
                    "040620776f726c64" // Segment containing " world"
                "0000" // End-of-contents marker
                "040620776f726c64" // Segment containing " world"
            "0000" // End-of-contents marker
        );

        let err = OctetString::from_ber(EXAMPLE_BER).err().unwrap();
        let expected = Error::new(ErrorKind::IndefiniteLength, Length::new(4));
        assert_eq!(expected, err);
    }
}
