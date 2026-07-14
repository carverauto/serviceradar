//! ASN.1 `ANY` type.

#![cfg_attr(feature = "arbitrary", allow(clippy::arithmetic_side_effects))]

use crate::{
    BytesRef, Choice, Decode, DecodeValue, DerOrd, EncodeValue, EncodingRules, Error, ErrorKind,
    Header, Length, Reader, SliceReader, Tag, Tagged, ValueOrd, Writer,
};
use core::cmp::Ordering;

/// ASN.1 `ANY`: represents any explicitly tagged ASN.1 value.
///
/// This is a zero-copy reference type which borrows from the input data.
///
/// Technically `ANY` hasn't been a recommended part of ASN.1 since the X.209
/// revision from 1988. It was deprecated and replaced by Information Object
/// Classes in X.680 in 1994, and X.690 no longer refers to it whatsoever.
///
/// Nevertheless, this crate defines an `ANY` type as it remains a familiar
/// and useful concept which is still extensively used in things like
/// PKI-related RFCs.
#[cfg_attr(feature = "arbitrary", derive(arbitrary::Arbitrary))]
#[derive(Copy, Clone, Debug, Eq, Hash, PartialEq, PartialOrd, Ord)]
pub struct AnyRef<'a> {
    /// Tag representing the type of the encoded value.
    tag: Tag,

    /// Inner value encoded as bytes.
    value: &'a BytesRef,
}

impl<'a> AnyRef<'a> {
    /// [`AnyRef`] representation of the ASN.1 `NULL` type.
    pub const NULL: Self = Self {
        tag: Tag::Null,
        value: BytesRef::new_unchecked(&[]),
    };

    /// Create a new [`AnyRef`] from the provided [`Tag`] and DER bytes.
    pub const fn new(tag: Tag, bytes: &'a [u8]) -> Result<Self, Error> {
        match BytesRef::new(bytes) {
            Ok(value) => Ok(Self { tag, value }),
            Err(_) => Err(Error::from_kind(ErrorKind::Length { tag })),
        }
    }

    /// Infallible creation of an [`AnyRef`] from a [`BytesRef`].
    pub(crate) fn from_tag_and_value(tag: Tag, value: &'a BytesRef) -> Self {
        Self { tag, value }
    }

    /// Get the raw value for this [`AnyRef`] type as a byte slice.
    pub fn value(self) -> &'a [u8] {
        self.value.as_slice()
    }

    /// Returns [`Tag`] and [`Length`] of self.
    pub fn header(&self) -> Header {
        Header::new(self.tag, self.value.len())
    }

    /// Attempt to decode this [`AnyRef`] type into the inner value.
    pub fn decode_as<T>(self) -> Result<T, <T as DecodeValue<'a>>::Error>
    where
        T: Choice<'a> + DecodeValue<'a>,
    {
        self.decode_as_encoding(EncodingRules::Der)
    }

    /// Attempt to decode this [`AnyRef`] type into the inner value.
    pub fn decode_as_encoding<T>(
        self,
        encoding: EncodingRules,
    ) -> Result<T, <T as DecodeValue<'a>>::Error>
    where
        T: Choice<'a> + DecodeValue<'a>,
    {
        if !T::can_decode(self.tag) {
            return Err(self.tag.unexpected_error(None).to_error().into());
        }

        let mut decoder = SliceReader::new_with_encoding_rules(self.value(), encoding)?;
        let result = T::decode_value(&mut decoder, self.header())?;
        decoder.finish()?;
        Ok(result)
    }

    /// Is this value an ASN.1 `NULL` value?
    pub fn is_null(self) -> bool {
        self == Self::NULL
    }

    /// Attempt to decode this value an ASN.1 `SEQUENCE`, creating a new
    /// nested reader and calling the provided argument with it.
    pub fn sequence<F, T, E>(self, f: F) -> Result<T, E>
    where
        F: FnOnce(&mut SliceReader<'a>) -> Result<T, E>,
        E: From<Error>,
    {
        self.tag.assert_eq(Tag::Sequence)?;
        let mut reader = SliceReader::new(self.value.as_slice())?;
        let result = f(&mut reader)?;
        reader.finish()?;
        Ok(result)
    }
}

impl<'a> Choice<'a> for AnyRef<'a> {
    fn can_decode(_: Tag) -> bool {
        true
    }
}

impl<'a> Decode<'a> for AnyRef<'a> {
    type Error = Error;

    fn decode<R: Reader<'a>>(reader: &mut R) -> Result<AnyRef<'a>, Error> {
        let header = Header::decode(reader)?;
        Self::decode_value(reader, header)
    }
}

impl<'a> DecodeValue<'a> for AnyRef<'a> {
    type Error = Error;

    fn decode_value<R: Reader<'a>>(reader: &mut R, header: Header) -> Result<Self, Error> {
        Ok(Self {
            tag: header.tag(),
            value: <&'a BytesRef>::decode_value(reader, header)?,
        })
    }
}

impl EncodeValue for AnyRef<'_> {
    fn value_len(&self) -> Result<Length, Error> {
        Ok(self.value.len())
    }

    fn encode_value(&self, writer: &mut impl Writer) -> Result<(), Error> {
        writer.write(self.value())
    }
}

impl Tagged for AnyRef<'_> {
    fn tag(&self) -> Tag {
        self.tag
    }
}

impl ValueOrd for AnyRef<'_> {
    fn value_cmp(&self, other: &Self) -> Result<Ordering, Error> {
        self.value.der_cmp(other.value)
    }
}

impl<'a> From<AnyRef<'a>> for &'a BytesRef {
    fn from(any: AnyRef<'a>) -> &'a BytesRef {
        any.value
    }
}

impl<'a> TryFrom<&'a [u8]> for AnyRef<'a> {
    type Error = Error;

    fn try_from(bytes: &'a [u8]) -> Result<AnyRef<'a>, Error> {
        AnyRef::from_der(bytes)
    }
}

#[cfg(feature = "alloc")]
pub use self::allocating::Any;

#[cfg(feature = "alloc")]
mod allocating {
    use super::*;
    use crate::{BytesOwned, encode::encode_value_to_slice, reader::read_value, referenced::*};
    use alloc::boxed::Box;

    /// ASN.1 `ANY`: represents any explicitly tagged ASN.1 value.
    ///
    /// This type provides the same functionality as [`AnyRef`] but owns the
    /// backing data.
    #[cfg_attr(feature = "arbitrary", derive(arbitrary::Arbitrary))]
    #[derive(Clone, Debug, Eq, Hash, PartialEq, PartialOrd, Ord)]
    pub struct Any {
        /// Tag representing the type of the encoded value.
        tag: Tag,

        /// Inner value encoded as bytes.
        value: BytesOwned,
    }

    impl Any {
        /// Create a new [`Any`] from the provided [`Tag`] and DER bytes.
        pub fn new(tag: Tag, bytes: impl Into<Box<[u8]>>) -> Result<Self, Error> {
            let value = BytesOwned::new(bytes)?;
            Ok(Self { tag, value })
        }

        /// Allow access to value
        pub fn value(&self) -> &[u8] {
            self.value.as_slice()
        }

        /// Returns [`Tag`] and [`Length`] of self.
        pub fn header(&self) -> Header {
            Header::new(self.tag, self.value.len())
        }

        /// Attempt to decode this [`Any`] type into the inner value.
        pub fn decode_as<'a, T>(&'a self) -> Result<T, <T as DecodeValue<'a>>::Error>
        where
            T: Choice<'a> + DecodeValue<'a>,
        {
            self.decode_as_encoding(EncodingRules::Der)
        }

        /// Attempt to decode this [`Any`] type into the inner value with the given encoding rules.
        pub fn decode_as_encoding<'a, T>(
            &'a self,
            encoding: EncodingRules,
        ) -> Result<T, <T as DecodeValue<'a>>::Error>
        where
            T: Choice<'a> + DecodeValue<'a>,
        {
            self.to_ref().decode_as_encoding(encoding)
        }

        /// Encode the provided type as an [`Any`] value.
        pub fn encode_from<T>(msg: &T) -> Result<Self, Error>
        where
            T: Tagged + EncodeValue,
        {
            let encoded_len = usize::try_from(msg.value_len()?)?;
            let mut buf = vec![0u8; encoded_len];
            encode_value_to_slice(&mut buf, msg)?;
            Any::new(msg.tag(), buf)
        }

        /// Attempt to decode this value an ASN.1 `SEQUENCE`, creating a new
        /// nested reader and calling the provided argument with it.
        pub fn sequence<'a, F, T, E>(&'a self, f: F) -> Result<T, E>
        where
            F: FnOnce(&mut SliceReader<'a>) -> Result<T, E>,
            E: From<Error>,
        {
            AnyRef::from(self).sequence(f)
        }

        /// [`Any`] representation of the ASN.1 `NULL` type.
        pub fn null() -> Self {
            Self {
                tag: Tag::Null,
                value: BytesOwned::default(),
            }
        }

        /// Create a new [`AnyRef`] from the provided [`Any`] owned tag and bytes.
        pub fn to_ref(&self) -> AnyRef<'_> {
            AnyRef {
                tag: self.tag,
                value: self.value.as_ref(),
            }
        }
    }

    impl Choice<'_> for Any {
        fn can_decode(_: Tag) -> bool {
            true
        }
    }

    impl<'a> Decode<'a> for Any {
        type Error = Error;

        fn decode<R: Reader<'a>>(reader: &mut R) -> Result<Self, Error> {
            let header = Header::decode(reader)?;
            read_value(reader, header, Self::decode_value)
        }
    }

    impl<'a> DecodeValue<'a> for Any {
        type Error = Error;

        fn decode_value<R: Reader<'a>>(reader: &mut R, header: Header) -> Result<Self, Error> {
            Ok(Self {
                tag: header.tag(),
                value: BytesOwned::decode_value(reader, header)?,
            })
        }
    }

    impl EncodeValue for Any {
        fn value_len(&self) -> Result<Length, Error> {
            Ok(self.value.len())
        }

        fn encode_value(&self, writer: &mut impl Writer) -> Result<(), Error> {
            writer.write(self.value.as_slice())
        }
    }

    impl<'a> From<&'a Any> for AnyRef<'a> {
        fn from(any: &'a Any) -> AnyRef<'a> {
            any.to_ref()
        }
    }

    impl Tagged for Any {
        fn tag(&self) -> Tag {
            self.tag
        }
    }

    impl ValueOrd for Any {
        fn value_cmp(&self, other: &Self) -> Result<Ordering, Error> {
            self.value.der_cmp(&other.value)
        }
    }

    impl<'a, T> From<T> for Any
    where
        T: Into<AnyRef<'a>>,
    {
        fn from(input: T) -> Any {
            let anyref: AnyRef<'a> = input.into();
            Self {
                tag: anyref.tag(),
                value: BytesOwned::from(anyref.value),
            }
        }
    }

    impl<'a> RefToOwned<'a> for AnyRef<'a> {
        type Owned = Any;
        fn ref_to_owned(&self) -> Self::Owned {
            Any {
                tag: self.tag(),
                value: BytesOwned::from(self.value),
            }
        }
    }

    impl OwnedToRef for Any {
        type Borrowed<'a> = AnyRef<'a>;
        fn owned_to_ref(&self) -> Self::Borrowed<'_> {
            self.into()
        }
    }

    impl Any {
        /// Is this value an ASN.1 `NULL` value?
        pub fn is_null(&self) -> bool {
            self.owned_to_ref() == AnyRef::NULL
        }
    }
}
