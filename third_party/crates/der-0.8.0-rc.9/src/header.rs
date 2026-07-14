//! ASN.1 DER headers.

#[cfg(feature = "ber")]
use crate::EncodingRules;
use crate::{Decode, DerOrd, Encode, Error, ErrorKind, Length, Reader, Result, Tag, Writer};

use core::cmp::Ordering;

/// ASN.1 DER headers: tag + length component of TLV-encoded values
#[derive(Copy, Clone, Debug, Eq, PartialEq)]
pub struct Header {
    /// Tag representing the type of the encoded value
    tag: Tag,

    /// Length of the encoded value
    length: Length,

    /// True if value is constructed, rather than primitive
    constructed: bool,
}

impl Header {
    /// Create a new [`Header`] from a [`Tag`] and a [`Length`].
    pub fn new(tag: Tag, length: Length) -> Self {
        #[cfg(feature = "ber")]
        let constructed = tag.is_constructed() || length.is_indefinite();
        #[cfg(not(feature = "ber"))]
        let constructed = tag.is_constructed();
        Self {
            tag,
            length,
            constructed,
        }
    }

    /// [`Tag`] of this header.
    pub fn tag(&self) -> Tag {
        self.tag
    }

    /// [`Length`] of this header.
    pub fn length(&self) -> Length {
        self.length
    }

    /// True if the [`Tag`] of this header has its constructed bit set.
    pub fn is_constructed(&self) -> bool {
        self.constructed
    }

    /// Copy of header with adjusted length.
    pub fn with_length(&self, length: Length) -> Self {
        Self {
            tag: self.tag,
            length,
            constructed: self.constructed,
        }
    }

    /// Peek forward in the reader, attempting to decode a [`Header`] at the current position.
    ///
    /// Does not modify the reader's state.
    pub fn peek<'a>(reader: &impl Reader<'a>) -> Result<Self> {
        Header::decode(&mut reader.clone())
    }
}

impl<'a> Decode<'a> for Header {
    type Error = Error;

    fn decode<R: Reader<'a>>(reader: &mut R) -> Result<Header> {
        let (tag, is_constructed) = Tag::decode_with_constructed_bit(reader)?;

        let length = Length::decode(reader).map_err(|e| {
            if e.kind() == ErrorKind::Overlength {
                reader.error(tag.length_error())
            } else {
                e
            }
        })?;

        #[cfg(feature = "ber")]
        if length.is_indefinite() && !is_constructed {
            debug_assert_eq!(reader.encoding_rules(), EncodingRules::Ber);
            return Err(reader.error(ErrorKind::IndefiniteLength));
        }

        #[cfg(not(feature = "ber"))]
        debug_assert_eq!(is_constructed, tag.is_constructed());

        Ok(Self {
            tag,
            length,
            constructed: is_constructed,
        })
    }
}

impl Encode for Header {
    fn encoded_len(&self) -> Result<Length> {
        self.tag.encoded_len()? + self.length.encoded_len()?
    }

    fn encode(&self, writer: &mut impl Writer) -> Result<()> {
        self.tag.encode(writer)?;
        self.length.encode(writer)
    }
}

impl DerOrd for Header {
    fn der_cmp(&self, other: &Self) -> Result<Ordering> {
        match self.tag.der_cmp(&other.tag)? {
            Ordering::Equal => self.length.der_cmp(&other.length),
            ordering => Ok(ordering),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::Header;
    use crate::{Encode, Length, Reader, SliceReader, Tag, TagNumber};
    use hex_literal::hex;

    #[test]
    fn peek() {
        // INTEGER: 42
        const EXAMPLE_MSG: &[u8] = &hex!("02012A00");

        let reader = SliceReader::new(EXAMPLE_MSG).expect("slice to be valid length");
        assert_eq!(reader.position(), Length::ZERO);

        let header = Header::peek(&reader).expect("peeked tag");
        assert_eq!(header.tag(), Tag::Integer);
        assert_eq!(header.length(), Length::ONE);
        assert_eq!(reader.position(), Length::ZERO); // Position unchanged
    }

    #[test]
    fn peek_max_header() {
        const MAX_HEADER: [u8; 11] = hex!("BF8FFFFFFF7F 84FFFFFFFF");
        let reader = SliceReader::new(&MAX_HEADER).expect("slice to be valid length");

        let header = Header::peek(&reader).expect("peeked tag");
        assert_eq!(
            header.tag,
            Tag::ContextSpecific {
                constructed: true,
                number: TagNumber(0xFFFFFFFF)
            }
        );
        assert_eq!(
            header.length(),
            Length::new_usize(0xFFFFFFFF).expect("u32 to fit")
        );
        assert_eq!(header.encoded_len(), Ok(Length::new(11)));
        assert_eq!(reader.position(), Length::ZERO); // Position unchanged
    }
    #[test]
    fn negative_peek_overlength_header() {
        const MAX_HEADER: [u8; 12] = hex!("BF8FFFFFFFFF7F 84FFFFFFFF");
        let reader = SliceReader::new(&MAX_HEADER).expect("slice to be valid length");
        // Should not decode
        Header::peek(&reader).expect_err("overlength error");
    }
}
