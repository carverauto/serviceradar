macro_rules! impl_any_conversions {
    ($type: ty) => {
        impl_any_conversions!($type, );
    };
    ($type: ty, $($li: lifetime)?) => {
        impl<'__der: $($li),*, $($li),*> TryFrom<$crate::AnyRef<'__der>> for $type {
            type Error = $crate::Error;

            fn try_from(any: $crate::AnyRef<'__der>) -> $crate::Result<$type> {
                any.decode_as()
            }
        }

        #[cfg(feature = "alloc")]
        impl<'__der: $($li),*, $($li),*> TryFrom<&'__der $crate::Any> for $type {
            type Error = $crate::Error;

            fn try_from(any: &'__der $crate::Any) -> $crate::Result<$type> {
                any.decode_as()
            }
        }
    };
}

macro_rules! impl_string_type {
    ($type: ty, $($li: lifetime)?) => {
        impl_any_conversions!($type, $($li),*);

        mod __impl_string {
            use super::*;

            use crate::{
                ord::OrdIsValueOrd, BytesRef, DecodeValue, EncodeValue, Header, Length, Reader,
                Result, Writer,
            };
            use core::{fmt, str};

            impl<$($li),*> AsRef<str> for $type {
                fn as_ref(&self) -> &str {
                    self.as_str()
                }
            }

            impl<$($li),*> AsRef<[u8]> for $type {
                fn as_ref(&self) -> &[u8] {
                    self.as_bytes()
                }
            }

            impl<'__der: $($li),*, $($li),*> DecodeValue<'__der> for $type {
                type Error = $crate::Error;

                fn decode_value<R: Reader<'__der>>(reader: &mut R, header: Header) -> $crate::Result<Self> {
                    Self::new(<&'__der BytesRef>::decode_value(reader, header)?.as_slice())
                }
            }

            impl<$($li),*> EncodeValue for $type {
                fn value_len(&self) -> Result<Length> {
                    self.inner.value_len()
                }

                fn encode_value(&self, writer: &mut impl Writer) -> Result<()> {
                    self.inner.encode_value(writer)
                }
            }

            impl<$($li),*> OrdIsValueOrd for $type {}

            impl<$($li),*> fmt::Display for $type {
                fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
                    f.write_str(self.as_str())
                }
            }
        }
    };
}

macro_rules! impl_custom_class {
    ($class_type_name: ident, $class_enum_name: ident, $asn1_class_name: literal, $class_bits_str: literal) => {
        #[doc = concat!("`", $asn1_class_name, "` field which wraps an owned inner value.")]
        ///
        /// This type decodes/encodes a field which is specific to a particular context
        /// and is identified by a [`TagNumber`].
        #[derive(Copy, Clone, Debug, Eq, PartialEq, PartialOrd, Ord)]
        pub struct $class_type_name<T> {
            #[doc = concat!("`", $asn1_class_name, "` tag number sans the leading `", $class_bits_str, "` class")]
            /// identifier bit and `0b100000` constructed flag.
            pub tag_number: TagNumber,

            /// Tag mode: `EXPLICIT` VS `IMPLICIT`.
            pub tag_mode: TagMode,

            /// Value of the field.
            pub value: T,
        }

        impl<T> $class_type_name<T> {
            #[doc = concat!("Attempt to decode an `EXPLICIT` ASN.1 `", $asn1_class_name, "` field with the")]
            /// provided [`TagNumber`].
            ///
            /// This method has the following behavior which decodes tag numbers one by one
            /// in extension fields, which are denoted in an ASN.1 schema using
            /// the `...` ellipsis extension marker:
            ///
            #[doc = concat!("- Returns `Ok(None)` if class other than [`Class::", stringify!($class_enum_name), "`] tag")]
            ///   is encountered.
            /// - Returns `Ok(None)` if a field with a different tag number is encountered.
            ///   These fields are not consumed in this case.
            /// - Returns [`ErrorKind::Noncanonical`] if constructed bit is primitive.
            /// - Returns `Ok(Some(..))` if tag number matches.
            pub fn decode_explicit<'a, R: Reader<'a>>(
                reader: &mut R,
                tag_number: TagNumber,
            ) -> Result<Option<Self>, T::Error>
            where
                T: Decode<'a>,
            {
                if !Tag::peek_matches(reader, Class::$class_enum_name, tag_number)? {
                    return Ok(None);
                }
                Ok(Some(Self::decode(reader)?))
            }

            #[doc = concat!("Attempt to decode an `IMPLICIT` ASN.1 `", $asn1_class_name, "` field with the")]
            /// provided [`TagNumber`].
            ///
            /// This method otherwise behaves the same as `decode_explicit`,
            /// but should be used in cases where the particular fields are `IMPLICIT`
            /// as opposed to `EXPLICIT`.
            ///
            /// Differences from `EXPLICIT`:
            /// - Returns [`ErrorKind::Noncanonical`] if constructed bit
            ///   does not match constructed bit of the base encoding.
            pub fn decode_implicit<'a, R: Reader<'a>>(
                reader: &mut R,
                tag_number: TagNumber,
            ) -> Result<Option<Self>, T::Error>
            where
                T: DecodeValue<'a> + IsConstructed,
            {
                // Peek tag number
                if !Tag::peek_matches(reader, Class::$class_enum_name, tag_number)? {
                    return Ok(None);
                }

                // Decode IMPLICIT header
                let header = Header::decode(reader)?;

                // the encoding shall be constructed if the base encoding is constructed
                if header.tag().is_constructed() != T::CONSTRUCTED
                    && reader.encoding_rules().is_der() {
                    return Err(reader.error(header.tag().non_canonical_error()).into());
                }

                // read_value checks if header matches decoded length
                let value = crate::reader::read_value(reader, header, T::decode_value)?;

                Ok(Some(Self {
                    tag_number,
                    tag_mode: TagMode::Implicit,
                    value,
                }))
            }
        }

        impl<'a, T> Choice<'a> for $class_type_name<T>
        where
            T: Decode<'a> + Tagged,
        {
            fn can_decode(tag: Tag) -> bool {
                tag.class() == Class::$class_enum_name
            }
        }

        impl<'a, T> Decode<'a> for $class_type_name<T>
        where
            T: Decode<'a>,
        {
            type Error = T::Error;

            fn decode<R: Reader<'a>>(reader: &mut R) -> Result<Self, Self::Error> {
                // Decode EXPLICIT header
                let header = Header::decode(reader)?;

                // encoding shall be constructed
                if !header.tag().is_constructed() {
                    return Err(reader.error(header.tag().non_canonical_error()).into());
                }
                match header.tag() {
                    Tag::$class_enum_name { number, .. } => Ok(Self {
                        tag_number: number,
                        tag_mode: TagMode::default(),
                        value: crate::reader::read_value(reader, header, |reader, _| {
                            // Decode inner tag-length-value of EXPLICIT
                            T::decode(reader)
                        })?,
                    }),
                    tag => Err(reader.error(tag.unexpected_error(None)).into())
                }
            }
        }

        impl<T> EncodeValue for $class_type_name<T>
        where
            T: EncodeValue + Tagged,
        {
            fn value_len(&self) -> Result<Length, Error> {
                match self.tag_mode {
                    TagMode::Explicit => self.value.encoded_len(),
                    TagMode::Implicit => self.value.value_len(),
                }
            }

            fn encode_value(&self, writer: &mut impl Writer) -> Result<(), Error> {
                match self.tag_mode {
                    TagMode::Explicit => self.value.encode(writer),
                    TagMode::Implicit => self.value.encode_value(writer),
                }
            }
        }

        impl<T> Tagged for $class_type_name<T>
        where
            T: Tagged,
        {
            fn tag(&self) -> Tag {
                let constructed = match self.tag_mode {
                    // ISO/IEC 8825-1:2021
                    // 8.14.3 If implicit tagging (see Rec. ITU-T X.680 | ISO/IEC 8824-1, 31.2.7) was not used in the definition of the type, the
                    // encoding shall be constructed and the contents octets shall be the complete base encoding [Encode].
                    TagMode::Explicit => true,

                    // ISO/IEC 8825-1:2021
                    // 8.14.4 If implicit tagging was used in the definition of the type, then:
                    // a) the encoding shall be constructed if the base encoding is constructed, and shall be primitive otherwise; and
                    // b) the contents octets shall be the same as the contents octets [EncodeValue] of the base encoding.
                    //
                    // TODO(dishmaker): use IsConstructed trait for IMPLICIT
                    TagMode::Implicit => self.value.tag().is_constructed(),
                };

                Tag::$class_enum_name {
                    number: self.tag_number,
                    constructed,
                }
            }
        }

        impl<'a, T> TryFrom<AnyRef<'a>> for $class_type_name<T>
        where
            T: Decode<'a>,
        {
            type Error = T::Error;

            fn try_from(any: AnyRef<'a>) -> Result<$class_type_name<T>, Self::Error> {
                match any.tag() {
                    Tag::$class_enum_name {
                        number,
                        constructed: true,
                    } => Ok(Self {
                        tag_number: number,
                        tag_mode: TagMode::default(),
                        value: T::from_der(any.value())?,
                    }),
                    tag => Err(tag.unexpected_error(None).to_error().into()),
                }
            }
        }

        impl<T> ValueOrd for $class_type_name<T>
        where
            T: EncodeValue + ValueOrd + Tagged,
        {
            fn value_cmp(&self, other: &Self) -> Result<Ordering, Error> {
                match self.tag_mode {
                    TagMode::Explicit => self.der_cmp(other),
                    TagMode::Implicit => self.value_cmp(other),
                }
            }
        }
    };
}

macro_rules! impl_custom_class_ref {
    ($ref_class_type_name: ident, $class_type_name: ident, $asn1_class_name: literal, $class_bits_str: literal) => {
        #[doc = concat!("`", $asn1_class_name, "` field reference.")]
        ///
        ///
        /// This type encodes a field which is specific to a particular context
        /// and is identified by a [`TagNumber`].
        #[derive(Copy, Clone, Debug, Eq, PartialEq, PartialOrd, Ord)]
        pub struct $ref_class_type_name<'a, T> {
            #[doc = concat!("`", $asn1_class_name, "` tag number sans the leading `", $class_bits_str, "` class")]
            /// identifier bit and `0b100000` constructed flag.
            pub tag_number: TagNumber,

            /// Tag mode: `EXPLICIT` VS `IMPLICIT`.
            pub tag_mode: TagMode,

            /// Value of the field.
            pub value: &'a T,
        }

        impl<'a, T> $ref_class_type_name<'a, T> {
            /// Convert to a [`EncodeValue`] object using [`EncodeValueRef`].
            fn encoder(&self) -> $class_type_name<EncodeValueRef<'a, T>> {
                $class_type_name {
                    tag_number: self.tag_number,
                    tag_mode: self.tag_mode,
                    value: EncodeValueRef(self.value),
                }
            }
        }

        impl<T> EncodeValue for $ref_class_type_name<'_, T>
        where
            T: EncodeValue + Tagged,
        {
            fn value_len(&self) -> Result<Length, Error> {
                self.encoder().value_len()
            }

            fn encode_value(&self, writer: &mut impl Writer) -> Result<(), Error> {
                self.encoder().encode_value(writer)
            }
        }

        impl<T> Tagged for $ref_class_type_name<'_, T>
        where
            T: Tagged,
        {
            fn tag(&self) -> Tag {
                self.encoder().tag()
            }
        }
    };
}
