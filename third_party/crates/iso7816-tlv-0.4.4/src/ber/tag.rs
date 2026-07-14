//! Tag definition and utilities for BER-TLV data as defined in [ISO7816-4]
//!

use core::convert::TryFrom;
use core::fmt;

use crate::{Result, TlvError};
use untrusted::Reader;

/// Class of a BER-TLV Tag field.
/// > Bits 8 and 7 of the first byte of the tag field indicate a class.
/// > - The value 00 indicates a data object of the universal class.
/// > - The value 01 indicates a data object of the application class.
/// > - The value 10 indicates a data object of the context-specific class.
/// > - The value 11 indicates a data object of the private class.
#[derive(PartialEq, Clone, Debug)]
pub enum Class {
    /// Universal class, not defined in ISO/IEC 7816
    Universal,
    /// Application class, identification defined in [ISO7816-4]
    Application,
    /// Context-specific class, defined in ISO/IEC 7816
    ContextSpecific,
    /// Private class, not defined in ISO/IEC 7816
    Private,
}

impl From<u8> for Class {
    fn from(val: u8) -> Self {
        match val & Tag::CLASS_MASK {
            0b0000_0000 => Self::Universal,
            0b0100_0000 => Self::Application,
            0b1000_0000 => Self::ContextSpecific,
            _ => Self::Private,
        }
    }
}

/// Tag for BER-TLV data as defined in [ISO7816-4].
///
/// Tags can be generated using the [`TryFrom`][TryFrom] trait
/// from integer types (see [Trait Implementations](struct.Tag.html#implementations) for valid input types)
/// or hex [str][str].
///
///
/// [TryFrom]: https://doc.rust-lang.org/std/convert/trait.TryFrom.html
/// [str]:https://doc.rust-lang.org/std/str/
///
/// Tags are now imported in a more permissivie way.
/// Invalid tags in ISO7816 meaning can be checked, see [`Self::iso7816_compliant`]
///
/// # Example
/// ```rust
/// use std::convert::TryFrom;
/// use iso7816_tlv::ber::Tag;
/// # use iso7816_tlv::TlvError;
///
/// # fn main() -> () {
/// assert!(Tag::try_from("80").is_ok());
/// assert!(Tag::try_from(8u8).is_ok());
/// assert!(Tag::try_from(8u16).is_ok());
/// assert!(Tag::try_from(8u32).is_ok());
/// assert!(Tag::try_from(8i32).is_ok());
/// assert!(Tag::try_from("7f22").is_ok());
///
/// assert!(Tag::try_from("error ").is_err());
/// assert!(Tag::try_from("7fffff01").is_err());
/// assert!(Tag::try_from("7f80ff").is_err());
/// // now more permissive interface :
/// assert!(Tag::try_from("7f00").is_ok());
/// assert!(Tag::try_from("7f1e").is_ok());
/// # }
/// #
/// ```
#[derive(PartialEq, Clone)]
pub struct Tag {
    raw: [u8; 3],
    len: usize,
}

impl Tag {
    const CLASS_MASK: u8 = 0b1100_0000;
    const CONSTRUCTED_MASK: u8 = 0b0010_0000;
    const VALUE_MASK: u8 = 0b0001_1111;
    const MORE_BYTES_MASK: u8 = 0b1000_0000;

    /// serializes the tag as byte array
    #[must_use]
    pub fn to_bytes(&self) -> &[u8] {
        &self.raw[self.raw.len() - self.len..]
    }

    /// length of the tag as byte array
    /// # Example
    /// ```rust
    /// use std::convert::TryFrom;
    /// use iso7816_tlv::ber::Tag;
    /// # use iso7816_tlv::TlvError;
    ///
    /// # fn main() -> Result<(), Box<TlvError>> {
    /// let tag = Tag::try_from("80")?;
    /// assert_eq!(1, tag.len_as_bytes());
    ///
    /// let tag = Tag::try_from("7f22")?;
    /// assert_eq!(2, tag.len_as_bytes());  
    ///
    /// let tag = Tag::try_from("7f8122")?;
    /// assert_eq!(3, tag.len_as_bytes());
    ///
    /// let tag = Tag::try_from("5fff22")?;
    /// assert_eq!(3, tag.len_as_bytes());
    ///
    /// let tag = Tag::try_from("5f2d")?;
    /// assert_eq!(2, tag.len_as_bytes());
    /// #  Ok(())
    /// # }
    /// #
    /// ```
    #[must_use]
    pub fn len_as_bytes(&self) -> usize {
        self.len
    }

    /// Wether the tag is constructed or not
    /// > Bit 6 of the first byte of the tag field indicates an encoding.
    /// > - The value 0 indicates a primitive encoding of the data object, i.e., the value field is not encoded in BER - TLV .
    /// > - The value 1 indicates a constructed encoding of the data object, i.e., the value field is encoded in BER - TLV
    ///
    /// # Example
    /// ```rust
    /// use std::convert::TryFrom;
    /// use iso7816_tlv::ber::Tag;
    /// # use iso7816_tlv::TlvError;
    ///
    /// # fn main() -> Result<(), Box<TlvError>> {
    /// let valid = Tag::try_from(0b0010_0000)?;
    /// assert!(valid.is_constructed());
    ///
    /// let invalid = Tag::try_from(0b0000_0001)?;
    /// assert!(!invalid.is_constructed());
    /// #  Ok(())
    /// # }
    /// #
    /// ```
    #[must_use]
    pub fn is_constructed(&self) -> bool {
        !matches!(self.raw[3 - self.len] & Self::CONSTRUCTED_MASK, 0)
    }

    /// Valid tags are defined as follow:
    /// > ISO/IEC 7816 supports tag fields of one, two and three bytes;
    /// > longer tag fields are reserved for future use
    ///
    /// > In tag fields of two or more bytes,
    /// > the values '00' to '1E' and '80' are invalid for the second byte.
    /// > - In two-byte tag fields, the second byte consists of bit 8 set to 0 and bits 7 to 1
    /// >   encoding a number greater than thirty.
    /// >   The second byte is valued from '1F' to '7F; the tag number is from 31 to 127.
    /// > - In three-byte tag fields, the second byte consists of bit 8 set to 1 and bits 7 to 1
    /// >   not all set to 0;
    /// >   the third byte consists of bit 8 set to 0 and bits 7 to 1 with any value.
    /// # Example
    /// ```rust
    /// use std::convert::TryFrom;
    /// use iso7816_tlv::ber::Tag;
    /// # use iso7816_tlv::TlvError;
    ///
    /// # fn main() -> Result<(), TlvError> {
    /// let t = Tag::try_from("7f00")?;
    /// assert!(!t.iso7816_compliant());
    /// // 9f1e is a valid EMV tag, but not ISO7816-4 compliant
    /// let t = Tag::try_from("9f1e")?;
    /// assert!(!t.iso7816_compliant());
    /// # Ok(())
    /// # }
    /// #
    #[must_use]
    pub fn iso7816_compliant(&self) -> bool {
        let first_byte_ok = if self.len == 1 {
            (self.raw[2] & Self::VALUE_MASK) != Self::VALUE_MASK
        } else {
            (self.raw[2] & Self::VALUE_MASK) == Self::VALUE_MASK
        };

        let other_bytes_ok = match self.len {
            1 => true,
            2 => {
                // In two-byte tag fields, the second byte consists of bit 8 set to 0 and bits 7 to 1 encoding a number greater
                // than thirty. The second byte is valued from '1F' to '7F; the tag number is from 31 to 127
                !(self.raw[2] < 0x1F_u8 || self.raw[2] > 0x7F_u8)
            }
            3 => {
                // The second byte is valued from '81' to 'FF'
                if self.raw[2] < 0x81_u8 {
                    false
                } else {
                    //and the third byte from '00' to '7F';
                    self.raw[3] & Self::MORE_BYTES_MASK == 0
                }
            }
            _ => false, //rfu
        };
        first_byte_ok & other_bytes_ok
    }

    /// Get the tag class.
    /// # Example
    /// ```rust
    /// use std::convert::TryFrom;
    /// use iso7816_tlv::ber::{Tag, Class};
    /// # use iso7816_tlv::TlvError;
    ///
    /// # fn main() -> Result<(), Box<TlvError>> {
    /// let tag = Tag::try_from(0b0010_0000)?;
    /// assert_eq!(Class::Universal, tag.class());
    /// let tag = Tag::try_from(0b1100_0000)?;
    /// assert_eq!(Class::Private, tag.class());
    ///
    /// #  Ok(())
    /// # }
    /// #
    /// ```
    #[must_use]
    pub fn class(&self) -> Class {
        self.raw[3 - self.len].into()
    }

    pub(crate) fn read(r: &mut Reader) -> Result<Self> {
        let first = r.read_byte()?;
        let mut value = u64::from(first);
        if first & Self::VALUE_MASK == Self::VALUE_MASK {
            loop {
                value = value.checked_shl(8).ok_or(TlvError::InvalidInput)?;
                let x = r.read_byte()?;
                value |= u64::from(x);
                if x & 0x80 == 0 {
                    break;
                }
            }
        }
        let r = Self::try_from(value)?;
        Ok(r)
    }
}

impl fmt::Display for Tag {
    fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result {
        let t = [0, self.raw[0], self.raw[1], self.raw[2]];
        let as_int: u32 = u32::from_be_bytes(t);
        write!(f, "Tag {:x} ({:?})", as_int, self.class())
    }
}

impl fmt::Debug for Tag {
    fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result {
        let t = [0, self.raw[0], self.raw[1], self.raw[2]];
        let as_int: u32 = u32::from_be_bytes(t);
        let constructed = if self.is_constructed() {
            "Contructed"
        } else {
            "Primitive"
        };
        write!(f, "Tag {:x} ({:?}; {})", as_int, self.class(), constructed)
    }
}

// From impl may fail, not the converse
#[allow(clippy::from_over_into)]
impl Into<u64> for Tag {
    fn into(self) -> u64 {
        let mut ret = 0_u64;
        for &b in self.to_bytes() {
            ret = ret << 8 | u64::from(b);
        }
        ret
    }
}

impl TryFrom<u64> for Tag {
    type Error = TlvError;
    fn try_from(v: u64) -> Result<Self> {
        let bytes = v.to_be_bytes();
        let mut first_non_zero = 0;
        for &x in &bytes {
            if x == 0 {
                first_non_zero += 1;
            } else {
                break;
            }
        }
        let raw = [
            bytes[bytes.len() - 3],
            bytes[bytes.len() - 2],
            bytes[bytes.len() - 1],
        ];
        let bytes = &bytes[first_non_zero..];

        let len = bytes.len();

        match len {
            0 => return Err(TlvError::InvalidInput),
            1 => {
                if (bytes[0] & Self::VALUE_MASK) == Self::VALUE_MASK {
                    return Err(TlvError::InvalidInput);
                }
            }
            2 => {
                if (bytes[1] & Self::MORE_BYTES_MASK) == Self::MORE_BYTES_MASK {
                    return Err(TlvError::InvalidInput);
                }
            }
            3 => {
                if (bytes[1] & Self::MORE_BYTES_MASK) == 0 {
                    return Err(TlvError::InvalidInput);
                }
                if (bytes[2] & Self::MORE_BYTES_MASK) == Self::MORE_BYTES_MASK {
                    return Err(TlvError::InvalidInput);
                }
            }
            _ => return Err(TlvError::TagIsRFU),
        }

        Ok(Self { raw, len })
    }
}

impl TryFrom<usize> for Tag {
    type Error = TlvError;
    fn try_from(v: usize) -> Result<Self> {
        Self::try_from(v as u64)
    }
}

impl TryFrom<u32> for Tag {
    type Error = TlvError;
    fn try_from(v: u32) -> Result<Self> {
        Self::try_from(u64::from(v))
    }
}

impl TryFrom<u16> for Tag {
    type Error = TlvError;
    fn try_from(v: u16) -> Result<Self> {
        Self::try_from(u64::from(v))
    }
}

impl TryFrom<u8> for Tag {
    type Error = TlvError;
    fn try_from(v: u8) -> Result<Self> {
        Self::try_from(u64::from(v))
    }
}

impl TryFrom<i32> for Tag {
    type Error = TlvError;
    #[allow(clippy::cast_sign_loss)]
    fn try_from(v: i32) -> Result<Self> {
        Self::try_from(v as u64)
    }
}

impl TryFrom<i16> for Tag {
    type Error = TlvError;
    #[allow(clippy::cast_sign_loss)]
    fn try_from(v: i16) -> Result<Self> {
        Self::try_from(v as u64)
    }
}

impl TryFrom<i8> for Tag {
    type Error = TlvError;
    #[allow(clippy::cast_sign_loss)]
    fn try_from(v: i8) -> Result<Self> {
        Self::try_from(v as u64)
    }
}

impl TryFrom<&str> for Tag {
    type Error = TlvError;
    fn try_from(v: &str) -> Result<Self> {
        let x = u64::from_str_radix(v, 16)?;
        Self::try_from(x)
    }
}

#[cfg(test)]
mod tests {
    // Note this useful idiom: importing names from outer (for mod tests) scope.
    use super::*;
    use untrusted::Input;

    #[test]
    fn tag_import_ok() -> Result<()> {
        assert!(Tag::try_from(0x1).is_ok());
        assert_eq!(0x1_u64, Tag::try_from(0x1)?.into());

        assert!(Tag::try_from(0x7f22).is_ok());
        assert_eq!(0x7f22_u64, Tag::try_from(0x7f22)?.into());

        assert!(Tag::try_from(0x7f_ff_22).is_ok());
        assert_eq!(0x7f_ff_22_u64, Tag::try_from(0x7f_ff_22)?.into());

        assert_eq!(Err(TlvError::InvalidInput), Tag::try_from(0));
        assert_eq!(Err(TlvError::InvalidInput), Tag::try_from(0x7f));
        assert_eq!(Err(TlvError::InvalidInput), Tag::try_from(0x7f80));
        assert_eq!(Err(TlvError::InvalidInput), Tag::try_from(0x7f_7f_00));
        assert_eq!(Err(TlvError::TagIsRFU), Tag::try_from(0x7f_80_80_00));

        assert!(Tag::try_from("7fff22").is_ok());
        assert_eq!(Err(TlvError::ParseIntError), Tag::try_from("bad one"));

        let t = Tag::try_from("5fff22")?;
        assert_eq!(3, t.len_as_bytes());

        let t = Tag::try_from("5f2d")?;
        assert_eq!(2, t.len_as_bytes());

        Ok(())
    }

    #[test]
    fn issue_14() -> Result<()> {
        let testcases = [0x7f1e, 0x007f_8001, 0x7f00, 0x9f1e, 0x9f00];
        for v in testcases {
            let t = Tag::try_from(v)?;
            assert!(!t.iso7816_compliant());
        }
        Ok(())
    }

    #[test]
    fn tag_import_2() {
        assert!(Tag::try_from("80").is_ok());
        assert!(Tag::try_from(8_u8).is_ok());
        assert!(Tag::try_from(8_u16).is_ok());
        assert!(Tag::try_from(8_u32).is_ok());
        assert!(Tag::try_from(8_i32).is_ok());
        assert!(Tag::try_from("7f22").is_ok());

        assert!(Tag::try_from("bad").is_err());
        assert!(Tag::try_from("7f80").is_err());
        // updte : now ok, but not iso7816 compliant
        assert!(Tag::try_from("7f00").is_ok());
        assert!(Tag::try_from("7f1e").is_ok());
    }
    #[test]
    fn tag_import() -> Result<()> {
        let vectors = ["01", "7f22", "7fff22"];
        for &v in &vectors {
            let x = Tag::try_from(v)?;
            assert_eq!(v.len() / 2, x.len_as_bytes());
            assert_eq!(v.len() / 2, x.to_bytes().len());
        }
        Ok(())
    }

    #[test]
    fn tag_read() -> Result<()> {
        let vectors: [&[u8]; 3] = [&[1], &[0x7f, 0x22], &[0x7f, 0xff, 0x22]];
        for &v in &vectors {
            let mut r = Reader::new(Input::from(v));
            let x = Tag::read(&mut r)?;
            assert_eq!(v.len(), x.len_as_bytes());
            assert_eq!(v.len(), x.to_bytes().len());
            assert_eq!(v, x.to_bytes());
        }

        let bad_vectors: [&[u8]; 2] = [&[0x7f, 0xff], &[0x7f, 0xff, 0xff]];
        for &v in &bad_vectors {
            let mut r = Reader::new(Input::from(v));
            assert_eq!(Err(TlvError::TruncatedInput), Tag::read(&mut r));
        }
        Ok(())
    }
}
