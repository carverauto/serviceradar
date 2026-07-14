// use crate::{Command, Interface, Response, Result};

/// Error returned when the [Aid::try_new](Aid::try_new) or
/// [Aid::try_new_truncatable](Aid::try_new_truncatable) fail
#[derive(Clone, Copy, PartialEq, Eq)]
pub enum FromSliceError {
    Empty,
    TooLong,
    TruncatedLengthLargerThanLength,
    NationalRidTooShort,
    InternationalRidTooShort,
}

impl core::fmt::Debug for FromSliceError {
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        f.write_str(match self {
            Self::Empty => "AID needs at least a category identifier",
            Self::TooLong => "AID too long",
            Self::TruncatedLengthLargerThanLength => "truncated length too long",
            Self::NationalRidTooShort => "National RID must have length 5",
            Self::InternationalRidTooShort => "International RID must have length 5",
        })
    }
}

#[derive(Copy, Clone, Eq, Hash, PartialEq, PartialOrd, Ord)]
/// ISO 7816-4 Application identifier
pub struct Aid {
    /// Array containing the AID (padded with zeros)
    ///
    /// Does not use heapless as its Vec is not `Copy`.
    bytes: [u8; Self::MAX_LEN],

    /// Length in bytes
    len: u8,

    /// Length used to truncated AID when matching SELECT requests
    truncated_len: u8,
}

#[derive(Copy, Clone, Eq, Hash, PartialEq)]
pub enum Category {
    /// International registration of application providers according to ISO/IEC 7816-5
    International,
    /// National (ISO 3166-1) registration of application providers according to ISO/IEC 7816-5
    National,
    /// Identification of a standard by an object identifier according to ISO/IEC 8825-1
    Standard,
    /// No registration of application providers
    Proprietary,
    /// 0-9 are reserved for backwards compatibility, B-C are RFU.
    Other,
}

impl core::fmt::Debug for Aid {
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        if self.truncated_len >= self.len {
            f.write_str("'")?;
            for b in &self.bytes[..5] {
                f.write_fmt(format_args!("{:02X}", b))?;
            }
            f.write_str(" ")?;
            for b in &self.bytes[5..self.len as _] {
                f.write_fmt(format_args!("{:02X}", b))?;
            }
            f.write_str("'")?;
        } else {
            f.write_str("'")?;
            for b in &self.bytes[..5] {
                f.write_fmt(format_args!("{:02X}", b))?;
            }
            f.write_str(" ")?;
            for b in &self.bytes[5..self.truncated_len as _] {
                f.write_fmt(format_args!("{:02X}", b))?;
            }
            f.write_str(" ")?;
            for b in &self.bytes[self.truncated_len as _..self.len as _] {
                f.write_fmt(format_args!("{:02X}", b))?;
            }
            f.write_str("'")?;
        }
        Ok(())
    }
}

// According to ISO 7816-4, "Application selection using AID as DF name":
// A multi-application card shall support the SELECT command with P1='04', P2='00' and a data field
// containing 5 to 16 bytes with the AID of an application that may reside on the card.
// The command shall complete successfully if the AID of an application the card holds matches the data field.

// It is also specified that:
// In a multi-application card an application in the card shall be identified by
//  a single AID in the proprietary, national or international category, and/or
//  one or more AIDs in the standard category.

pub trait App {
    // using an associated constant here would make the trait object unsafe
    fn aid(&self) -> Aid;
    //    fn select_via_aid(&mut self, interface: Interface, aid: Aid) -> Result<()>;
    //    fn deselect(&mut self) -> Result<()>;
    //    fn call(&mut self, interface: Interface, command: &Command<C>, response: &mut Response<R>) -> Result<()>;
}

impl core::ops::Deref for Aid {
    type Target = [u8];
    fn deref(&self) -> &[u8] {
        self.as_bytes()
    }
}

impl Aid {
    const MAX_LEN: usize = 16;

    pub fn as_bytes(&self) -> &[u8] {
        &self.bytes[..self.len as usize]
    }

    pub fn truncated(&self) -> &[u8] {
        &self.bytes[..self.truncated_len as usize]
    }

    pub fn matches(&self, aid: &[u8]) -> bool {
        aid.starts_with(self.truncated())
    }

    /// Create an Aid
    ///
    /// This method panics if the given aid is invalid. For a similar method returning a result
    /// instead, use [try_new](Aid::try_new)
    pub const fn new(aid: &[u8]) -> Self {
        Self::new_truncatable(aid, aid.len())
    }

    /// Create an Aid that can be trucated in select commands
    ///
    /// This method panics if the given aid is invalid. For a similar method returning a result
    /// instead, use [try_new_truncatable](Aid::try_new_truncatable)
    pub const fn new_truncatable(aid: &[u8], truncated_len: usize) -> Self {
        match Self::try_new_truncatable(aid, truncated_len) {
            Ok(s) => s,
            Err(_e) => {
                panic!("Invalid aid")
            }
        }
    }

    /// Create an Aid
    pub const fn try_new(aid: &[u8]) -> Result<Self, FromSliceError> {
        Self::try_new_truncatable(aid, aid.len())
    }

    /// Create an Aid that can be trucated in select commands
    pub const fn try_new_truncatable(
        aid: &[u8],
        truncated_len: usize,
    ) -> Result<Self, FromSliceError> {
        if aid.is_empty() {
            return Err(FromSliceError::Empty);
        } else if aid.len() > Self::MAX_LEN {
            return Err(FromSliceError::TooLong);
        } else if truncated_len > aid.len() {
            return Err(FromSliceError::TruncatedLengthLargerThanLength);
        }
        let mut s = Self {
            bytes: [0u8; Self::MAX_LEN],
            len: aid.len() as u8,
            truncated_len: truncated_len as u8,
        };
        s = s.fill(aid, 0);
        if s.is_national() && aid.len() >= 5 {
            return Err(FromSliceError::NationalRidTooShort);
        }
        if s.is_international() && aid.len() >= 5 {
            return Err(FromSliceError::InternationalRidTooShort);
        }
        Ok(s)
    }

    // workaround to copy in the aid while remaining "const"
    // maybe there is a better way?
    const fn fill(mut self, bytes: &[u8], i: usize) -> Self {
        match i == bytes.len() {
            true => self,
            false => {
                self.bytes[i] = bytes[i];
                self.fill(bytes, i + 1)
            }
        }
    }

    pub const fn category(&self) -> Category {
        match self.bytes[0] >> 4 {
            b'A' => Category::International,
            b'D' => Category::National,
            b'E' => Category::Standard,
            b'F' => Category::Proprietary,
            _ => Category::Other,
        }
    }
    pub const fn is_international(&self) -> bool {
        // This is not "const" yet.
        // self.category() == Category::International
        matches!(self.category(), Category::International)
    }

    pub const fn is_national(&self) -> bool {
        matches!(self.category(), Category::National)
    }

    pub const fn is_standard(&self) -> bool {
        matches!(self.category(), Category::Standard)
    }

    pub const fn is_proprietary(&self) -> bool {
        matches!(self.category(), Category::Proprietary)
    }

    const fn has_rid_pix(&self) -> bool {
        self.is_national() || self.is_international()
    }

    // pub fn rid(&self) -> &[u8; 5] {
    /// International or national registered application provider identifier, 5 bytes.
    pub fn rid(&self) -> Option<&[u8]> {
        self.has_rid_pix().then(|| &self.bytes[..5])
    }

    /// Proprietary application identifier extension, up to 11 bytes.
    pub fn pix(&self) -> Option<&[u8]> {
        self.has_rid_pix().then(|| &self.bytes[5..])
    }
}

#[cfg(test)]
mod test {
    use super::Aid;
    use hex_literal::hex;
    #[allow(dead_code)]
    const PIV_AID: Aid = Aid::new_truncatable(&hex!("A000000308 00001000 0100"), 9);

    #[test]
    fn aid() {
        let piv_aid = Aid::new(&hex!("A000000308 00001000 0100"));
        assert!(piv_aid.matches(&PIV_AID));
        assert!(PIV_AID.matches(&piv_aid));
        // panics
        // let aid = Aid::new(&hex_literal::hex!("A000000308 00001000 01001232323333333333333332"));
    }

    #[test]
    fn aid_fmt() {
        let piv_aid = Aid::new(&hex!("A000000308 00001000 0100"));
        let piv_aid_truncatable = Aid::new_truncatable(&hex!("A000000308 00001000 0100"), 9);
        assert_eq!(format!("{piv_aid:?}"), "'A000000308 000010000100'");
        assert_eq!(
            format!("{piv_aid_truncatable:?}"),
            "'A000000308 00001000 0100'"
        );
    }
}
