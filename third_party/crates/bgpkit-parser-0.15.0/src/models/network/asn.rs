#[cfg(feature = "parser")]
use bytes::{BufMut, Bytes, BytesMut};
use std::cmp::Ordering;
use std::fmt::{Debug, Display, Formatter};
use std::hash::{Hash, Hasher};
use std::str::FromStr;

/// AS number length: 16 or 32 bits.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Ord, PartialOrd)]
#[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
pub enum AsnLength {
    Bits16,
    Bits32,
}

impl AsnLength {
    pub const fn is_four_byte(&self) -> bool {
        match self {
            AsnLength::Bits16 => false,
            AsnLength::Bits32 => true,
        }
    }
}

/// ASN -- Autonomous System Number
#[derive(Clone, Copy, Eq)]
#[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
#[cfg_attr(feature = "serde", serde(from = "u32", into = "u32"))]
pub struct Asn {
    asn: u32,
    #[cfg_attr(feature = "serde", serde(skip_serializing, default))]
    four_byte: bool,
}

impl Ord for Asn {
    fn cmp(&self, other: &Self) -> Ordering {
        self.asn.cmp(&other.asn)
    }
}

impl Hash for Asn {
    fn hash<H: Hasher>(&self, state: &mut H) {
        self.asn.hash(state);
    }
}

impl PartialEq for Asn {
    fn eq(&self, other: &Self) -> bool {
        self.asn == other.asn
    }
}

impl PartialOrd for Asn {
    fn partial_cmp(&self, other: &Self) -> Option<Ordering> {
        Some(self.cmp(other))
    }
}

impl Asn {
    pub const RESERVED: Self = Asn::new_16bit(0);
    #[doc(alias("AS_TRANS"))]
    pub const TRANSITION: Self = Asn::new_16bit(23456);

    /// Constructs a new 2-octet `Asn`.
    #[inline]
    pub const fn new_16bit(asn: u16) -> Self {
        Asn {
            asn: asn as u32,
            four_byte: false,
        }
    }

    /// Constructs a new 4-octet `Asn`.
    #[inline]
    pub const fn new_32bit(asn: u32) -> Self {
        Asn {
            asn,
            four_byte: true,
        }
    }

    /// Gets the size required to store this ASN
    pub const fn required_len(&self) -> AsnLength {
        if self.asn <= u16::MAX as u32 {
            return AsnLength::Bits16;
        }

        AsnLength::Bits32
    }

    /// Checks if the given ASN is reserved for private use.
    ///
    /// <https://datatracker.ietf.org/doc/rfc7249/>
    #[inline]
    pub const fn is_private(&self) -> bool {
        match self.asn {
            64512..=65534 => true,           // reserved by RFC6996
            4200000000..=4294967294 => true, // reserved by RFC6996
            _ => false,
        }
    }

    /// Checks if the given ASN is reserved. This is done by checking if the asn is included
    /// within IANA's "Special-Purpose AS Numbers" registry. This includes checking against private
    /// ASN ranges, ASNs reserved for documentation, and ASNs reserved for specific uses by various
    /// RFCs.
    ///
    /// Up to date as of 2023-03-01 (Registry was last updated 2015-08-07).
    ///
    /// For additional details see:
    ///  - <https://datatracker.ietf.org/doc/rfc7249/>
    ///  - <https://www.iana.org/assignments/iana-as-numbers-special-registry/iana-as-numbers-special-registry.xhtml>
    #[inline]
    pub const fn is_reserved(&self) -> bool {
        match self.asn {
            0 => true,                       // reserved by RFC7607
            112 => true,                     // reserved by RFC7534
            23456 => true,                   // reserved by RFC6793
            64496..=64511 => true,           // reserved by RFC5398
            64512..=65534 => true,           // reserved by RFC6996
            65535 => true,                   // reserved by RFC7300
            65536..=65551 => true,           // reserved by RFC5398
            4200000000..=4294967294 => true, // reserved by RFC6996
            4294967295 => true,              // reserved by RFC7300
            _ => false,
        }
    }

    /// Checks if the given ASN is reserved for use in documentation and sample code.
    ///
    /// <https://datatracker.ietf.org/doc/rfc7249/>
    #[inline]
    pub const fn is_reserved_for_documentation(&self) -> bool {
        match self.asn {
            64496..=64511 => true, // reserved by RFC5398
            65536..=65551 => true, // reserved by RFC5398
            _ => false,
        }
    }

    /// Return if an ASN is 4 bytes or not.
    #[inline]
    pub const fn is_four_byte(&self) -> bool {
        self.four_byte
    }

    /// Return AS number as u32.
    #[inline]
    pub const fn to_u32(&self) -> u32 {
        self.asn
    }
}

/// Creates an ASN with a value of 0. This is equivalent to [Asn::RESERVED].
impl Default for Asn {
    #[inline]
    fn default() -> Self {
        Asn::RESERVED
    }
}

// *************** //
// *************** //
// ASN conversions //
// *************** //
// *************** //

impl PartialEq<u32> for Asn {
    #[inline]
    fn eq(&self, other: &u32) -> bool {
        self.asn == *other
    }
}

impl From<u32> for Asn {
    #[inline]
    fn from(v: u32) -> Self {
        Asn::new_32bit(v)
    }
}

impl From<Asn> for u32 {
    #[inline]
    fn from(value: Asn) -> Self {
        value.asn
    }
}

impl From<&Asn> for u32 {
    #[inline]
    fn from(value: &Asn) -> Self {
        value.asn
    }
}

impl PartialEq<i32> for Asn {
    #[inline]
    fn eq(&self, other: &i32) -> bool {
        self.asn == *other as u32
    }
}

impl From<i32> for Asn {
    #[inline]
    fn from(v: i32) -> Self {
        Asn::new_32bit(v as u32)
    }
}

impl From<Asn> for i32 {
    #[inline]
    fn from(value: Asn) -> Self {
        value.asn as i32
    }
}

impl From<&Asn> for i32 {
    #[inline]
    fn from(value: &Asn) -> Self {
        value.asn as i32
    }
}

impl PartialEq<u16> for Asn {
    #[inline]
    fn eq(&self, other: &u16) -> bool {
        self.asn == *other as u32
    }
}

impl From<u16> for Asn {
    #[inline]
    fn from(v: u16) -> Self {
        Asn::new_16bit(v)
    }
}

impl From<Asn> for u16 {
    #[inline]
    fn from(value: Asn) -> Self {
        value.asn as u16
    }
}

impl From<&Asn> for u16 {
    #[inline]
    fn from(value: &Asn) -> Self {
        value.asn as u16
    }
}

impl Display for Asn {
    fn fmt(&self, f: &mut Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}", self.asn)
    }
}

impl Debug for Asn {
    fn fmt(&self, f: &mut Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}", self.asn)
    }
}

/// Parse an ASN matching the pattern `(AS)?[0-9]+`.
impl FromStr for Asn {
    type Err = <u32 as FromStr>::Err;

    #[inline]
    fn from_str(mut s: &str) -> Result<Self, Self::Err> {
        if let Some(number) = s.strip_prefix("AS") {
            s = number;
        }

        Ok(Asn::new_32bit(u32::from_str(s)?))
    }
}

#[cfg(feature = "parser")]
impl Asn {
    pub fn encode(&self) -> Bytes {
        let mut bytes = BytesMut::with_capacity(if self.four_byte { 4 } else { 2 });
        match self.four_byte {
            true => bytes.put_u32(self.asn),
            false => bytes.put_u16(self.asn as u16),
        }
        bytes.freeze()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[cfg(feature = "parser")]
    use crate::parser::ReadUtils;
    use std::str::FromStr;

    #[cfg(feature = "parser")]
    #[test]
    fn test_asn_encode() {
        let asn = Asn::new_32bit(123);
        let mut bytes = asn.encode();
        assert_eq!(123, bytes.read_u32().unwrap());
    }

    #[test]
    fn test_asn_is_reserved() {
        let asn = Asn::new_32bit(0);
        assert!(asn.is_reserved());

        let asn = Asn::new_32bit(23456);
        assert!(asn.is_reserved());

        let asn = Asn::new_32bit(64513);
        assert!(asn.is_reserved());

        let asn = Asn::new_32bit(65535);
        assert!(asn.is_reserved());

        let asn = Asn::new_32bit(65536);
        assert!(asn.is_reserved());

        let asn = Asn::new_32bit(4200000000);
        assert!(asn.is_reserved());

        let asn = Asn::new_32bit(4294967295);
        assert!(asn.is_reserved());

        let asn = Asn::new_32bit(112);
        assert!(asn.is_reserved());

        let asn = Asn::new_32bit(400644);
        assert!(!asn.is_reserved());
    }

    #[test]
    fn test_asn_is_reserved_for_documentation() {
        let asn = Asn::new_32bit(64497);
        assert!(asn.is_reserved_for_documentation());

        let asn = Asn::new_32bit(65537);
        assert!(asn.is_reserved_for_documentation());

        let asn = Asn::new_32bit(65535);
        assert!(!asn.is_reserved_for_documentation());
    }

    #[test]
    fn test_asn_is_private() {
        let asn = Asn::new_32bit(64512);
        assert!(asn.is_private());

        let asn = Asn::new_32bit(4200000000);
        assert!(asn.is_private());

        let asn = Asn::new_32bit(4200000001);
        assert!(asn.is_private());

        let asn = Asn::new_32bit(400644);
        assert!(!asn.is_private());
    }

    #[test]
    fn test_asn_display() {
        let asn = Asn::from_str("AS12345").unwrap();
        assert_eq!(12345, asn.to_u32());
        let asn = Asn::new_32bit(12345);
        assert_eq!("12345", format!("{asn}"));
        let asn = Asn::new_32bit(12345);
        assert_eq!("12345", format!("{asn:?}"));
    }

    #[test]
    fn test_default() {
        assert_eq!(0, Asn::default().asn)
    }

    #[test]
    fn test_conversion() {
        // test conversion from u32/u16/i32 to Asn
        let asn = Asn::from(12345);
        assert_eq!(12345, asn.to_u32());

        let asn = Asn::from(12345u16);
        assert_eq!(12345, asn.to_u32());

        let asn = Asn::from(12345i32);
        assert_eq!(12345, asn.to_u32());

        // test conversion from Asn to u32/u16/i32
        let asn = Asn::new_32bit(12345);
        assert_eq!(12345, u32::from(asn));
        assert_eq!(12345, u32::from(&asn));
        assert_eq!(12345, i32::from(asn));
        assert_eq!(12345, i32::from(&asn));
        assert_eq!(asn, 12345u16);
        assert_eq!(asn, 12345u32);

        let asn = Asn::new_16bit(12345);
        assert_eq!(12345, u16::from(asn));
        assert_eq!(12345, u16::from(&asn));
    }

    #[test]
    fn test_is_four_byte() {
        let asn = Asn::new_32bit(12345);
        assert!(asn.is_four_byte());
        let asn = Asn::new_16bit(12345);
        assert!(!asn.is_four_byte());
    }

    #[test]
    fn test_asn_comparison() {
        let asn1 = Asn::new_32bit(12345);
        let asn2 = Asn::new_32bit(12345);
        assert_eq!(asn1, asn2);
        assert!(asn1 <= asn2);
        assert!(asn1 >= asn2);

        let asn3 = Asn::new_32bit(12346);
        assert!(asn1 < asn3);
        assert!(asn1 <= asn3);
    }

    #[test]
    fn test_required_len() {
        let asn = Asn::new_32bit(65536);
        assert_eq!(AsnLength::Bits32, asn.required_len());
        let asn = Asn::new_32bit(65535);
        assert_eq!(AsnLength::Bits16, asn.required_len());
    }

    #[test]
    #[cfg(feature = "serde")]
    fn test_asn_length_serialization() {
        let length_16bit = AsnLength::Bits16;
        let serialized = serde_json::to_string(&length_16bit).unwrap();
        assert_eq!(serialized, "\"Bits16\"");
        let deserialized: AsnLength = serde_json::from_str(&serialized).unwrap();
        assert_eq!(deserialized, length_16bit);

        let length_32bit = AsnLength::Bits32;
        let serialized = serde_json::to_string(&length_32bit).unwrap();
        assert_eq!(serialized, "\"Bits32\"");
        let deserialized: AsnLength = serde_json::from_str(&serialized).unwrap();
        assert_eq!(deserialized, length_32bit);
    }
}
