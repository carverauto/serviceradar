//! IsMulticast field decoding (IPFIX field ID 206).
//!
//! A single byte indicating whether the flow is multicast.
//! A non-zero value indicates multicast traffic.

use nom::IResult;
use nom_derive::Parse;
use serde::Serialize;

/// Decoded multicast indicator from an IPFIX field (ID 206).
///
/// Wraps the raw `u8` value. Use [`is_multicast()`](Self::is_multicast)
/// to check if the flow is multicast.
#[derive(Debug, PartialEq, Eq, Clone, Copy, Serialize, PartialOrd, Ord)]
pub struct IsMulticast(pub u8);

impl IsMulticast {
    /// Parse an `IsMulticast` from a byte slice by reading a single `u8`.
    pub fn parse(input: &[u8]) -> IResult<&[u8], Self> {
        let (remaining, value) = u8::parse(input)?;
        Ok((remaining, Self::from(value)))
    }

    /// Returns `true` if the flow is multicast (non-zero value).
    pub fn is_multicast(&self) -> bool {
        self.0 != 0
    }

    /// Returns the raw byte value.
    pub fn raw(&self) -> u8 {
        self.0
    }
}

impl std::fmt::Display for IsMulticast {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        if self.is_multicast() {
            write!(f, "multicast")
        } else {
            write!(f, "unicast")
        }
    }
}

impl From<u8> for IsMulticast {
    fn from(value: u8) -> Self {
        Self(value)
    }
}

impl From<IsMulticast> for u8 {
    fn from(m: IsMulticast) -> Self {
        m.0
    }
}

#[cfg(test)]
mod is_multicast_tests {
    use super::IsMulticast;

    #[test]
    fn test_display() {
        assert_eq!(IsMulticast::from(0).to_string(), "unicast");
        assert_eq!(IsMulticast::from(1).to_string(), "multicast");
        assert_eq!(IsMulticast::from(255).to_string(), "multicast");
    }

    #[test]
    fn test_round_trip() {
        for byte in 0..=255u8 {
            let m = IsMulticast::from(byte);
            assert_eq!(u8::from(m), byte);
        }
    }

    #[test]
    fn test_is_multicast() {
        assert!(!IsMulticast::from(0).is_multicast());
        assert!(IsMulticast::from(1).is_multicast());
        assert!(IsMulticast::from(0xFF).is_multicast());
    }
}
