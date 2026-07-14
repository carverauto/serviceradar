//! This module provides tools and utilities for handling SIMPLE-TLV data as
//! defined in [ISO7816-4][iso7816-4].
//!
//!
//!
//!
//! [iso7816-4]: https://www.iso.org/standard/54550.html
//!
use alloc::vec::Vec;
use core::convert::TryFrom;

use untrusted::{Input, Reader};

use crate::{Result, TlvError};

/// Tag for SIMPLE-TLV data as defined in [ISO7816-4].
/// > The tag field consists of a single byte encoding a tag number from 1 to 254.
/// > The values '00' and 'FF' are invalid for tag fields.
///
/// Tags can be generated using the [`TryFrom`][TryFrom] trait
/// from u8 or hex [str][str].
///
/// [TryFrom]: https://doc.rust-lang.org/std/convert/trait.TryFrom.html
/// [str]:https://doc.rust-lang.org/std/str/
///
/// # Example
/// ```rust
/// use std::convert::TryFrom;
/// use iso7816_tlv::simple::Tag;
/// # use iso7816_tlv::TlvError;
/// # fn main() -> Result<(), TlvError> {
///
/// // get tag from u8 or &str
/// assert!(Tag::try_from("80").is_ok());
/// assert!(Tag::try_from(8u8).is_ok());
/// assert!(Tag::try_from(0x80).is_ok());
/// assert!(Tag::try_from(127).is_ok());
///
/// assert!(Tag::try_from("er").is_err());
/// assert!(Tag::try_from("00").is_err());
/// assert!(Tag::try_from("ff").is_err());
///
/// // get tag as u8
/// let tag = Tag::try_from("80")?;
/// let _tag_as_u8: u8 = tag.into();
/// let _tag_as_u8 = Into::<u8>::into(tag);
/// # Ok(())
/// # }
/// #
/// ```
#[derive(PartialEq, Debug, Clone, Copy)]
pub struct Tag(u8);

impl Tag {
    /// Tries to convert a `u8` into a `Tag`. This is equivalent to the
    /// [`TryFrom`] impl for `u8`, except that this fn is const and can be used
    /// in some contexts that `TryFrom` cannot be used in, for example for
    /// defining constants:
    ///
    /// ```
    /// use iso7816_tlv::simple::Tag;
    ///
    /// const SOME_TAG_CONSTANT: Tag = match Tag::try_from_u8(0x42) {
    ///     Ok(tag) => tag,
    ///     Err(e) => panic!(),
    /// };
    /// ```
    ///
    /// # Errors
    /// This method returns `Err(TlvError::InvalidInput)` if `v` is not a legal
    /// tag (e.g., if v is `0x00` or `0xFF`).
    pub const fn try_from_u8(v: u8) -> Result<Self> {
        match v {
            0x00 | 0xFF => Err(TlvError::InvalidInput),
            _ => Ok(Self(v)),
        }
    }
}

/// Value for SIMPLE-TLV data as defined in [ISO7816-4].
/// > The value field consists of N consecutive bytes.
/// > N may be zero.
/// > In this case there is no value field.
///
/// In this case Value is an empty vector
pub type Value = Vec<u8>;

/// SIMPLE-TLV data object representation.
/// > Each SIMPLE-TLV data object shall consist of two or three consecutive fields:
/// > a mandatory tag field, a mandatory length field and a conditional value field
#[derive(PartialEq, Debug, Clone)]
pub struct Tlv {
    tag: Tag,
    value: Value,
}

// From impl may fail, not the converse
#[allow(clippy::from_over_into)]
impl Into<u8> for Tag {
    fn into(self) -> u8 {
        self.0
    }
}

impl TryFrom<u8> for Tag {
    type Error = TlvError;
    fn try_from(v: u8) -> Result<Self> {
        Self::try_from_u8(v)
    }
}

impl TryFrom<&str> for Tag {
    type Error = TlvError;
    fn try_from(v: &str) -> Result<Self> {
        let x = u8::from_str_radix(v, 16)?;
        Self::try_from(x)
    }
}

impl Tlv {
    /// Create a SIMPLE-TLV data object from valid tag and value.
    /// A value has a maximum size of `65_535` bytes.
    ///
    /// # Errors
    /// Fails with `TlvError::InvalidLength` if value is longer than `65_535` bytes.
    pub fn new(tag: Tag, value: Value) -> Result<Self> {
        if value.len() > 65_536 {
            Err(TlvError::InvalidLength)
        } else {
            Ok(Self { tag, value })
        }
    }

    /// Get SIMPLE-TLV  tag.
    #[must_use]
    pub fn tag(&self) -> Tag {
        self.tag
    }

    /// Get SIMPLE-TLV value length
    #[must_use]
    pub fn length(&self) -> usize {
        self.value.len()
    }

    /// Get SIMPLE-TLV value
    #[must_use]
    pub fn value(&self) -> &[u8] {
        self.value.as_slice()
    }

    /// serializes self into a byte vector.
    #[allow(clippy::cast_possible_truncation)]
    #[must_use]
    pub fn to_vec(&self) -> Vec<u8> {
        let mut ret = vec![self.tag.0];
        let len = self.value.len();
        if len >= 255 {
            ret.push(0xFF);
            ret.push((len >> 8) as u8);
        }
        ret.push(len as u8);
        ret.extend(&self.value);
        ret
    }

    fn read_len(r: &mut Reader) -> Result<usize> {
        let mut ret: usize = 0;
        let x = r.read_byte()?;
        if x == 0xFF {
            for _ in 0..2 {
                let x = r.read_byte()?;
                ret = ret << 8 | usize::from(x);
            }
        } else {
            ret = usize::from(x);
        }
        Ok(ret)
    }

    fn read(r: &mut Reader) -> Result<Self> {
        let tag = Tag::try_from(r.read_byte()?)?;
        let len = Self::read_len(r)?;
        let content = r.read_bytes(len)?;

        Ok(Self {
            tag,
            value: content.as_slice_less_safe().to_vec(),
        })
    }

    /// Parses a byte array into a SIMPLE-TLV structure.
    /// This also returns the unprocessed data.
    /// # Example (parse mulitple tlv in input)
    /// ```rust
    /// use iso7816_tlv::simple::Tlv;
    /// use hex_literal::hex;
    ///
    /// let in_data = hex!(
    ///   "03 01 01"
    ///   "04 01 04"
    ///   "07 07 85 66 C9 6A 14 49 04"
    ///   "01 08 57 5F 93 6E 01 00 00 00"
    ///   "09 01 00");
    /// let mut buf: &[u8] = &in_data;
    /// let mut parsed_manual = Vec::new();
    /// while !buf.is_empty() {
    ///   let (r, remaining) = Tlv::parse(buf);
    ///   buf = remaining;
    ///   if r.map(|res| parsed_manual.push(res)).is_err() {
    ///       break;
    ///   }
    /// }
    /// ```
    pub fn parse(input: &[u8]) -> (Result<Self>, &[u8]) {
        let mut r = Reader::new(Input::from(input));
        (
            Self::read(&mut r),
            r.read_bytes_to_end().as_slice_less_safe(),
        )
    }

    /// Parses a byte array into a vector of SIMPLE-TLV.
    /// # Note
    /// Errors are discarded and parsing stops at first error
    /// Prefer using the [`parse()`](Self::parse()) method and iterate over returned processed data.
    #[must_use]
    pub fn parse_all(input: &[u8]) -> Vec<Self> {
        let mut ret = Vec::new();
        let mut r = Reader::new(Input::from(input));
        while !r.at_end() {
            if Self::read(&mut r).map(|elem| ret.push(elem)).is_err() {
                break;
            }
        }
        ret
    }

    /// Parses a byte array into a SIMPLE-TLV structure.
    /// Input must exactly match a SIMPLE-TLV object.
    /// # Errors
    /// Fails with `TlvError::InvalidInput` if input does not match a SIMPLE-TLV object.
    pub fn from_bytes(input: &[u8]) -> Result<Self> {
        let (r, n) = Self::parse(input);
        if n.is_empty() {
            r
        } else {
            Err(TlvError::InvalidInput)
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use core::convert::TryFrom;
    use rand_core::{RngCore, SeedableRng};

    #[test]
    fn tag_import() -> Result<()> {
        assert!(Tag::try_from("80").is_ok());
        assert!(Tag::try_from(8_u8).is_ok());
        assert_eq!(0x8_u8, Tag::try_from(8_u8)?.into());

        assert!(Tag::try_from(0x80).is_ok());
        assert_eq!(0x80_u8, Tag::try_from(0x80_u8)?.into());

        assert!(Tag::try_from(127).is_ok());
        assert_eq!(127_u8, Tag::try_from(127_u8)?.into());

        assert!(Tag::try_from("er").is_err());
        assert!(Tag::try_from("00").is_err());
        assert!(Tag::try_from("ff").is_err());
        Ok(())
    }

    #[test]
    fn parse_1() -> Result<()> {
        let in_data = [
            0x84_u8, 0x01, 0x2C, 0x97, 0x00, 0x84, 0x01, 0x24, 0x9E, 0x01, 0x42,
        ];

        let (r, in_data) = Tlv::parse(&in_data);
        assert_eq!(8, in_data.len());
        assert!(r.is_ok());

        let t = r?;
        assert_eq!(0x84_u8, t.tag().into());
        assert_eq!(1, t.length());
        assert_eq!(&[0x2C], t.value());

        let (r, in_data) = Tlv::parse(in_data);
        assert_eq!(6, in_data.len());
        assert!(r.is_ok());

        let t = r?;
        assert_eq!(0x97_u8, t.tag().into());
        assert_eq!(0, t.length());

        let (r, in_data) = Tlv::parse(in_data);
        assert_eq!(3, in_data.len());
        assert!(r.is_ok());

        let t = r?;
        assert_eq!(0x84_u8, t.tag().into());
        assert_eq!(1, t.length());
        assert_eq!(&[0x24], t.value());

        let (r, in_data) = Tlv::parse(in_data);
        assert_eq!(0, in_data.len());
        assert!(r.is_ok());

        let t = r?;
        assert_eq!(0x9E_u8, t.tag().into());
        assert_eq!(1, t.length());
        assert_eq!(&[0x42], t.value());

        Ok(())
    }

    #[test]
    fn parse_multiple() {
        let in_data = hex!(
            "03 01 01"
            "04 01 04"
            "07 07 85 66 C9 6A 14 49 04"
            "01 08 57 5F 93 6E 01 00 00 00"
            "09 01 00"
        );
        let mut buf: &[u8] = &in_data;
        let mut parsed_manual = Vec::new();
        while !buf.is_empty() {
            let (r, remaining) = Tlv::parse(buf);
            buf = remaining;
            let pushed = r.map(|res| parsed_manual.push(res));
            if pushed.is_err() {
                break;
            }
        }
        let parsed_at_once = Tlv::parse_all(&in_data);
        assert_eq!(parsed_manual, parsed_at_once);
    }

    #[test]
    #[allow(clippy::cast_possible_truncation)]
    fn serialize_parse() -> Result<()> {
        let mut rng = rand_xorshift::XorShiftRng::seed_from_u64(10);
        for r in 1_u8..0xFF {
            let v_len = rng.next_u32() % 0xFFFF;
            let v: Value = (0..v_len).map(|_| rng.next_u32() as u8).collect();
            let tlv = Tlv::new(Tag::try_from(r)?, v.clone())?;
            let ser = tlv.to_vec();
            let tlv_2 = Tlv::from_bytes(&ser)?;
            assert_eq!(tlv, tlv_2);

            assert_eq!(r, tlv.tag().into());
            assert_eq!(v, tlv.value());
        }
        Ok(())
    }
}
