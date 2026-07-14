//! ASN.1 tags.
#![cfg_attr(feature = "arbitrary", allow(clippy::arithmetic_side_effects))]

mod class;
mod mode;
mod number;

pub use self::{class::Class, mode::TagMode, number::TagNumber};

use crate::{Decode, DerOrd, Encode, Error, ErrorKind, Length, Reader, Result, Writer};
use core::{cmp::Ordering, fmt};

/// Indicator bit for constructed form encoding (i.e. vs primitive form)
const CONSTRUCTED_FLAG: u8 = 0b100000;

/// Types which have a constant ASN.1 [`Tag`].
pub trait FixedTag {
    /// ASN.1 tag
    const TAG: Tag;
}

/// Types which have an ASN.1 [`Tag`].
#[diagnostic::on_unimplemented(note = "Consider adding impl of `FixedTag` to `{Self}`")]
pub trait Tagged {
    /// Get the ASN.1 tag that this type is encoded with.
    fn tag(&self) -> Tag;
}

/// Types which are [`FixedTag`] always have a known [`Tag`] type.
impl<T: FixedTag + ?Sized> Tagged for T {
    fn tag(&self) -> Tag {
        T::TAG
    }
}

/// Types which have a constant ASN.1 constructed bit.
///
/// Auto-implemented on all types that implement [`FixedTag`].
#[diagnostic::on_unimplemented(note = "Consider adding impl of `FixedTag` to `{Self}`")]
pub trait IsConstructed {
    /// ASN.1 constructed bit
    const CONSTRUCTED: bool;
}

/// Types which are [`FixedTag`] always known if they are constructed (or primitive).
impl<T: FixedTag + ?Sized> IsConstructed for T {
    const CONSTRUCTED: bool = T::TAG.is_constructed();
}

/// ASN.1 tags.
///
/// Tags are the leading identifier octet of the Tag-Length-Value encoding
/// used by ASN.1 DER and identify the type of the subsequent value.
///
/// They are described in X.690 Section 8.1.2: Identifier octets, and
/// structured as follows:
///
/// ```text
/// | Class | P/C | Tag Number |
/// ```
///
/// - Bits 8/7: [`Class`]
/// - Bit 6: primitive (0) or constructed (1)
/// - Bits 5-1: tag number
#[cfg_attr(feature = "arbitrary", derive(arbitrary::Arbitrary))]
#[derive(Copy, Clone, Eq, Hash, PartialEq, PartialOrd, Ord)]
#[non_exhaustive]
pub enum Tag {
    /// `BOOLEAN` tag: `1`.
    Boolean,

    /// `INTEGER` tag: `2`.
    Integer,

    /// `BIT STRING` tag: `3`.
    BitString,

    /// `OCTET STRING` tag: `4`.
    OctetString,

    /// `NULL` tag: `5`.
    Null,

    /// `OBJECT IDENTIFIER` tag: `6`.
    ObjectIdentifier,

    /// `REAL` tag: `9`.
    Real,

    /// `ENUMERATED` tag: `10`.
    Enumerated,

    /// `UTF8String` tag: `12`.
    Utf8String,

    /// `RELATIVE OID` tag: `13`.
    RelativeOid,

    /// `SEQUENCE` tag: `16`.
    Sequence,

    /// `SET` and `SET OF` tag: `17`.
    Set,

    /// `NumericString` tag: `18`.
    NumericString,

    /// `PrintableString` tag: `19`.
    PrintableString,

    /// `TeletexString` tag: `20`.
    TeletexString,

    /// `VideotexString` tag: `21`.
    VideotexString,

    /// `IA5String` tag: `22`.
    Ia5String,

    /// `UTCTime` tag: `23`.
    UtcTime,

    /// `GeneralizedTime` tag: `24`.
    GeneralizedTime,

    /// `VisibleString` tag: `26`.
    VisibleString,

    /// `GeneralString` tag: `27`.
    GeneralString,

    /// `BMPString` tag: `30`.
    BmpString,

    /// Application tag.
    Application {
        /// Is this tag constructed? (vs primitive).
        constructed: bool,

        /// Tag number.
        number: TagNumber,
    },

    /// Context-specific tag.
    ContextSpecific {
        /// Is this tag constructed? (vs primitive).
        constructed: bool,

        /// Tag number.
        number: TagNumber,
    },

    /// Private tag number.
    Private {
        /// Is this tag constructed? (vs primitive).
        constructed: bool,

        /// Tag number.
        number: TagNumber,
    },
}

impl Tag {
    /// Maximum number of octets in a DER encoding of a [`Tag`] using the
    /// rules implemented by this crate.
    pub(crate) const MAX_SIZE: usize = 6;

    /// Decode a [`Tag`] in addition to returning the value of the constructed bit.
    pub(crate) fn decode_with_constructed_bit<'a>(
        reader: &mut impl Reader<'a>,
    ) -> Result<(Self, bool)> {
        let first_byte = reader.read_byte()?;
        let is_constructed = first_byte & CONSTRUCTED_FLAG != 0;

        let tag = match first_byte {
            0x01 => Tag::Boolean,
            0x02 => Tag::Integer,
            0x03 => Tag::BitString,
            0x04 => Tag::OctetString,
            0x05 => Tag::Null,
            0x06 => Tag::ObjectIdentifier,
            0x09 => Tag::Real,
            0x0A => Tag::Enumerated,
            0x0C => Tag::Utf8String,
            0x0D => Tag::RelativeOid,
            0x12 => Tag::NumericString,
            0x13 => Tag::PrintableString,
            0x14 => Tag::TeletexString,
            0x15 => Tag::VideotexString,
            0x16 => Tag::Ia5String,
            0x17 => Tag::UtcTime,
            0x18 => Tag::GeneralizedTime,
            0x1A => Tag::VisibleString,
            0x1B => Tag::GeneralString,
            0x1E => Tag::BmpString,
            #[cfg(feature = "ber")]
            0x24 if reader.encoding_rules().is_ber() => Tag::OctetString,
            0x30 => Tag::Sequence, // constructed
            0x31 => Tag::Set,      // constructed
            0x40..=0x7F => {
                let (constructed, number) = parse_parts(first_byte, reader)?;

                Tag::Application {
                    constructed,
                    number,
                }
            }
            0x80..=0xBF => {
                let (constructed, number) = parse_parts(first_byte, reader)?;

                Tag::ContextSpecific {
                    constructed,
                    number,
                }
            }
            0xC0..=0xFF => {
                let (constructed, number) = parse_parts(first_byte, reader)?;

                Tag::Private {
                    constructed,
                    number,
                }
            }
            // universal tag in long form
            0x1F => return Err(reader.error(ErrorKind::TagNumberInvalid)),
            byte => return Err(reader.error(ErrorKind::TagUnknown { byte })),
        };

        Ok((tag, is_constructed))
    }

    /// Peek at the next byte in the reader and attempt to decode it as a [`Tag`] value.
    ///
    /// Does not modify the reader's state.
    pub fn peek<'a>(reader: &impl Reader<'a>) -> Result<Self> {
        Self::decode(&mut reader.clone())
    }

    /// Returns true if given context-specific (or any given class) tag number matches the peeked tag.
    pub(crate) fn peek_matches<'a, R: Reader<'a>>(
        reader: &mut R,
        expected_class: Class,
        expected_tag_number: TagNumber,
    ) -> Result<bool> {
        if reader.is_finished() {
            return Ok(false);
        }

        let tag = Self::peek(reader)?;
        Ok(tag.class() == expected_class && tag.number() == expected_tag_number)
    }

    /// Assert that this [`Tag`] matches the provided expected tag.
    ///
    /// On mismatch, returns an [`Error`] with [`ErrorKind::TagUnexpected`].
    pub fn assert_eq(self, expected: Tag) -> Result<Tag> {
        if self == expected {
            Ok(self)
        } else {
            Err(self.unexpected_error(Some(expected)).into())
        }
    }

    /// Get the [`Class`] that corresponds to this [`Tag`].
    pub const fn class(self) -> Class {
        match self {
            Tag::Application { .. } => Class::Application,
            Tag::ContextSpecific { .. } => Class::ContextSpecific,
            Tag::Private { .. } => Class::Private,
            _ => Class::Universal,
        }
    }

    /// Get the [`TagNumber`] for this tag.
    pub const fn number(self) -> TagNumber {
        match self {
            Tag::Boolean => TagNumber(1),
            Tag::Integer => TagNumber(2),
            Tag::BitString => TagNumber(3),
            Tag::OctetString => TagNumber(4),
            Tag::Null => TagNumber(5),
            Tag::ObjectIdentifier => TagNumber(6),
            Tag::Real => TagNumber(9),
            Tag::Enumerated => TagNumber(10),
            Tag::Utf8String => TagNumber(12),
            Tag::RelativeOid => TagNumber(13),
            Tag::Sequence => TagNumber(16),
            Tag::Set => TagNumber(17),
            Tag::NumericString => TagNumber(18),
            Tag::PrintableString => TagNumber(19),
            Tag::TeletexString => TagNumber(20),
            Tag::VideotexString => TagNumber(21),
            Tag::Ia5String => TagNumber(22),
            Tag::UtcTime => TagNumber(23),
            Tag::GeneralizedTime => TagNumber(24),
            Tag::VisibleString => TagNumber(26),
            Tag::GeneralString => TagNumber(27),
            Tag::BmpString => TagNumber(30),
            Tag::Application { number, .. } => number,
            Tag::ContextSpecific { number, .. } => number,
            Tag::Private { number, .. } => number,
        }
    }

    /// Does this tag represent a constructed (as opposed to primitive) field?
    pub const fn is_constructed(self) -> bool {
        match self {
            Tag::Sequence | Tag::Set => true,
            Tag::Application { constructed, .. }
            | Tag::ContextSpecific { constructed, .. }
            | Tag::Private { constructed, .. } => constructed,
            _ => false,
        }
    }

    /// Is this an application tag?
    pub const fn is_application(self) -> bool {
        matches!(self.class(), Class::Application)
    }

    /// Is this a context-specific tag?
    pub const fn is_context_specific(self) -> bool {
        matches!(self.class(), Class::ContextSpecific)
    }

    /// Is this a private tag?
    pub const fn is_private(self) -> bool {
        matches!(self.class(), Class::Private)
    }

    /// Is this a universal tag?
    pub const fn is_universal(self) -> bool {
        matches!(self.class(), Class::Universal)
    }

    /// Create an [`Error`] for an invalid [`Length`].
    pub fn length_error(self) -> ErrorKind {
        ErrorKind::Length { tag: self }
    }

    /// Create an [`Error`] for an non-canonical value with the ASN.1 type
    /// identified by this tag.
    pub fn non_canonical_error(self) -> ErrorKind {
        ErrorKind::Noncanonical { tag: self }
    }

    /// Create an [`Error`] because the current tag was unexpected, with an
    /// optional expected tag.
    pub fn unexpected_error(self, expected: Option<Self>) -> ErrorKind {
        ErrorKind::TagUnexpected {
            expected,
            actual: self,
        }
    }

    /// Create an [`Error`] for an invalid value with the ASN.1 type identified
    /// by this tag.
    pub fn value_error(self) -> ErrorKind {
        ErrorKind::Value { tag: self }
    }
}

impl<'a> Decode<'a> for Tag {
    type Error = Error;

    fn decode<R: Reader<'a>>(reader: &mut R) -> Result<Self> {
        Self::decode_with_constructed_bit(reader).map(|(tag, _)| tag)
    }
}

fn parse_parts<'a, R: Reader<'a>>(first_byte: u8, reader: &mut R) -> Result<(bool, TagNumber)> {
    let constructed = first_byte & CONSTRUCTED_FLAG != 0;
    let first_number_part = first_byte & TagNumber::MASK;

    if first_number_part != TagNumber::MASK {
        return Ok((constructed, TagNumber(first_number_part.into())));
    }

    let mut multi_byte_tag_number = 0;

    for i in 0..Tag::MAX_SIZE - 1 {
        let byte = reader.read_byte()?;
        multi_byte_tag_number |= u32::from(byte & 0x7F);

        if byte & 0x80 == 0 {
            if multi_byte_tag_number < u32::from(TagNumber::MASK) {
                return Err(reader.error(ErrorKind::TagNumberInvalid));
            }

            return Ok((constructed, TagNumber(multi_byte_tag_number)));
        } else if i == 0 && multi_byte_tag_number == 0 {
            // 8.1.2.4.2c says "bits 7 to 1 of the first subsequent octet shall not all be zero"
            return Err(reader.error(ErrorKind::TagNumberInvalid));
        }

        if multi_byte_tag_number.leading_zeros() < 7 {
            return Err(reader.error(ErrorKind::TagNumberInvalid));
        }

        multi_byte_tag_number <<= 7;
    }

    // missing terminator byte
    Err(reader.error(ErrorKind::TagNumberInvalid))
}

impl Encode for Tag {
    #[allow(clippy::cast_possible_truncation)]
    fn encoded_len(&self) -> Result<Length> {
        let number = self.number().value();

        let length = if number <= 30 {
            Length::ONE
        } else {
            Length::new(number.ilog2() / 7 + 2)
        };

        Ok(length)
    }

    fn encode(&self, writer: &mut impl Writer) -> Result<()> {
        let mut first_byte = (self.class() as u8) | (u8::from(self.is_constructed()) << 5);

        let number = self.number().value();

        if number < u32::from(TagNumber::MASK) {
            first_byte |= (number & 0x1F) as u8;
            writer.write_byte(first_byte)?;
        } else {
            first_byte |= TagNumber::MASK;
            writer.write_byte(first_byte)?;

            let extra_bytes = number.ilog2() / 7 + 1;

            for shift in (0..extra_bytes).rev() {
                let mut byte = ((number >> (shift * 7)) & 0x7f) as u8;

                if shift != 0 {
                    byte |= 0x80;
                }

                writer.write_byte(byte)?;
            }
        }

        Ok(())
    }
}

impl DerOrd for Tag {
    fn der_cmp(&self, other: &Self) -> Result<Ordering> {
        Ok((self.class().cmp(&other.class()))
            .then_with(|| self.number().cmp(&other.number()))
            .then_with(|| self.is_constructed().cmp(&other.is_constructed())))
    }
}

impl fmt::Display for Tag {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        const FIELD_TYPE: [&str; 2] = ["primitive", "constructed"];

        match *self {
            Tag::Boolean => f.write_str("BOOLEAN"),
            Tag::Integer => f.write_str("INTEGER"),
            Tag::BitString => f.write_str("BIT STRING"),
            Tag::OctetString => f.write_str("OCTET STRING"),
            Tag::Null => f.write_str("NULL"),
            Tag::ObjectIdentifier => f.write_str("OBJECT IDENTIFIER"),
            Tag::Real => f.write_str("REAL"),
            Tag::Enumerated => f.write_str("ENUMERATED"),
            Tag::Utf8String => f.write_str("UTF8String"),
            Tag::RelativeOid => f.write_str("RELATIVE OID"),
            Tag::Set => f.write_str("SET"),
            Tag::NumericString => f.write_str("NumericString"),
            Tag::PrintableString => f.write_str("PrintableString"),
            Tag::TeletexString => f.write_str("TeletexString"),
            Tag::VideotexString => f.write_str("VideotexString"),
            Tag::Ia5String => f.write_str("IA5String"),
            Tag::UtcTime => f.write_str("UTCTime"),
            Tag::GeneralizedTime => f.write_str("GeneralizedTime"),
            Tag::VisibleString => f.write_str("VisibleString"),
            Tag::GeneralString => f.write_str("GeneralString"),
            Tag::BmpString => f.write_str("BMPString"),
            Tag::Sequence => f.write_str("SEQUENCE"),
            Tag::Application {
                constructed,
                number,
            } => write!(
                f,
                "APPLICATION [{}] ({})",
                number,
                FIELD_TYPE[usize::from(constructed)]
            ),
            Tag::ContextSpecific {
                constructed,
                number,
            } => write!(
                f,
                "CONTEXT-SPECIFIC [{}] ({})",
                number,
                FIELD_TYPE[usize::from(constructed)]
            ),
            Tag::Private {
                constructed,
                number,
            } => write!(
                f,
                "PRIVATE [{}] ({})",
                number,
                FIELD_TYPE[usize::from(constructed)]
            ),
        }
    }
}

impl fmt::Debug for Tag {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "Tag(0x{:02x}: {})", self.number().value(), self)
    }
}

#[cfg(test)]
mod tests {
    use core::cmp::Ordering;

    use hex_literal::hex;

    use super::{Class, Tag, TagNumber};
    use crate::{Decode, DerOrd, ErrorKind, Length, Reader, SliceReader};

    #[test]
    fn tag_class() {
        assert_eq!(Tag::Boolean.class(), Class::Universal);
        assert_eq!(Tag::Integer.class(), Class::Universal);
        assert_eq!(Tag::BitString.class(), Class::Universal);
        assert_eq!(Tag::OctetString.class(), Class::Universal);
        assert_eq!(Tag::Null.class(), Class::Universal);
        assert_eq!(Tag::ObjectIdentifier.class(), Class::Universal);
        assert_eq!(Tag::Real.class(), Class::Universal);
        assert_eq!(Tag::Enumerated.class(), Class::Universal);
        assert_eq!(Tag::Utf8String.class(), Class::Universal);
        assert_eq!(Tag::RelativeOid.class(), Class::Universal);
        assert_eq!(Tag::Set.class(), Class::Universal);
        assert_eq!(Tag::NumericString.class(), Class::Universal);
        assert_eq!(Tag::PrintableString.class(), Class::Universal);
        assert_eq!(Tag::TeletexString.class(), Class::Universal);
        assert_eq!(Tag::VideotexString.class(), Class::Universal);
        assert_eq!(Tag::Ia5String.class(), Class::Universal);
        assert_eq!(Tag::UtcTime.class(), Class::Universal);
        assert_eq!(Tag::GeneralizedTime.class(), Class::Universal);
        assert_eq!(Tag::Sequence.class(), Class::Universal);

        for num in 0..=30 {
            for &constructed in &[false, true] {
                let number = TagNumber(num);

                assert_eq!(
                    Tag::Application {
                        constructed,
                        number
                    }
                    .class(),
                    Class::Application
                );

                assert_eq!(
                    Tag::ContextSpecific {
                        constructed,
                        number
                    }
                    .class(),
                    Class::ContextSpecific
                );

                assert_eq!(
                    Tag::Private {
                        constructed,
                        number
                    }
                    .class(),
                    Class::Private
                );
            }
        }
    }

    #[test]
    fn decoding() {
        assert_eq!(
            Tag::Application {
                constructed: false,
                number: TagNumber(0x4001)
            },
            Tag::from_der(&hex!("5F818001")).expect("bits 7 to 1 are zero")
        );
        assert_eq!(
            Tag::ContextSpecific {
                constructed: false,
                number: TagNumber(0x200001)
            },
            Tag::from_der(&hex!("9F81808001")).expect("bits 7 to 1 are zero two times")
        );
        assert_eq!(
            Tag::Private {
                constructed: false,
                number: TagNumber(u32::MAX)
            },
            Tag::from_der(&hex!("DF8FFFFFFF7F")).expect("private tag 2^32-1")
        );
        assert_eq!(
            ErrorKind::TagNumberInvalid,
            Tag::from_der(&hex!("FF03"))
                .expect_err("valid tag number but must be in short form")
                .kind()
        );
        assert_eq!(
            ErrorKind::TagNumberInvalid,
            Tag::from_der(&hex!("1FFF"))
                .expect_err("universal tag with long form")
                .kind()
        );
        assert_eq!(
            ErrorKind::TagNumberInvalid,
            Tag::from_der(&hex!("5F8020"))
                .expect_err("leading zeros in long form")
                .kind()
        );
        assert_eq!(
            ErrorKind::TagNumberInvalid,
            Tag::from_der(&hex!("DF9F8F8F8F0F"))
                .expect_err("tag number larger than 32 bits")
                .kind()
        );
        assert_eq!(
            ErrorKind::Incomplete {
                expected_len: Length::new(3),
                actual_len: Length::new(2)
            },
            Tag::from_der(&hex!("5F9E"))
                .expect_err("incomplete tag in long form")
                .kind()
        );
    }

    #[test]
    fn tag_order() {
        // T-REC-X.680-202102
        // 8.6 The canonical order for tags is based on the outermost tag of each type and is defined as follows:
        // a) those elements or alternatives with universal class tags shall appear first, followed by those with
        // application class tags, followed by those with context-specific tags, followed by those with private class
        // tags;
        // b) within each class of tags, the elements or alternatives shall appear in ascending order of their tag
        // numbers.
        assert_eq!(Tag::Boolean.der_cmp(&Tag::Integer), Ok(Ordering::Less));
        assert_eq!(Tag::Integer.der_cmp(&Tag::Null), Ok(Ordering::Less));
        assert_eq!(Tag::Null.der_cmp(&Tag::Sequence), Ok(Ordering::Less));
        assert_eq!(Tag::Sequence.der_cmp(&Tag::Ia5String), Ok(Ordering::Less));
        assert_eq!(Tag::Ia5String.der_cmp(&Tag::BmpString), Ok(Ordering::Less));

        // universal class, then application class
        assert_eq!(
            Tag::BmpString.der_cmp(&Tag::Application {
                constructed: true,
                number: TagNumber(0)
            }),
            Ok(Ordering::Less)
        );
        // ascending tag numbers
        assert_eq!(
            Tag::Application {
                constructed: true,
                number: TagNumber(0)
            }
            .der_cmp(&Tag::Application {
                constructed: true,
                number: TagNumber(1)
            }),
            Ok(Ordering::Less)
        );

        // ignore constructed bit
        assert_eq!(
            Tag::Application {
                constructed: true,
                number: TagNumber(1)
            }
            .der_cmp(&Tag::Application {
                constructed: false,
                number: TagNumber(2)
            }),
            Ok(Ordering::Less)
        );

        // for same tag numbers, order by constructed bit
        assert_eq!(
            Tag::Application {
                constructed: false,
                number: TagNumber(2)
            }
            .der_cmp(&Tag::Application {
                constructed: true,
                number: TagNumber(2)
            }),
            Ok(Ordering::Less)
        );

        // application class is before context-specific class
        assert_eq!(
            Tag::Application {
                constructed: true,
                number: TagNumber(2)
            }
            .der_cmp(&Tag::ContextSpecific {
                constructed: true,
                number: TagNumber(0)
            }),
            Ok(Ordering::Less)
        );

        // context-specific class is before private class
        assert_eq!(
            Tag::ContextSpecific {
                constructed: true,
                number: TagNumber(10)
            }
            .der_cmp(&Tag::Private {
                constructed: true,
                number: TagNumber(0)
            }),
            Ok(Ordering::Less)
        );
    }

    #[test]
    fn peek() {
        let reader = SliceReader::new(&[0x02]).expect("valid reader");
        assert_eq!(reader.position(), Length::ZERO);
        assert_eq!(Tag::peek(&reader).expect("peeked tag"), Tag::Integer);
        assert_eq!(reader.position(), Length::ZERO); // Position unchanged
    }

    #[test]
    fn peek_long_tags() {
        let reader = SliceReader::new(&hex!("DF8FFFFFFF7F")).expect("valid reader");
        let tag = Tag::peek(&reader).expect("peeked tag");
        assert!(!tag.is_context_specific());
        assert!(!tag.is_application());
        assert!(tag.is_private());
        assert_eq!(
            tag,
            Tag::Private {
                constructed: false,
                number: TagNumber(u32::MAX)
            }
        );
    }

    #[test]
    fn negative_peek_long_tags() {
        let reader = SliceReader::new(&hex!("DF8FFFFFFFFF")).expect("valid reader");
        assert_eq!(
            Tag::peek(&reader)
                .expect_err("tag ends in 0xFF, so 7+ bytes needed")
                .kind(),
            ErrorKind::TagNumberInvalid,
        );
    }
}
