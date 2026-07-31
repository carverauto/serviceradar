//! TCP Options field decoding (IPFIX field ID 209).
//!
//! A 64-bit bitmask where each bit indicates the presence of a specific
//! TCP option type. This field is deprecated in favor of tcpOptionsFull
//! but is still commonly encountered.

use nom::IResult;
use nom_derive::Parse;
use serde::Serialize;

/// Decoded TCP options bitmask from an IPFIX field (ID 209).
///
/// Wraps the raw `u64` value. Individual TCP option bits can be tested
/// using the raw value.
#[derive(Debug, PartialEq, Eq, Clone, Copy, Serialize, PartialOrd, Ord)]
pub struct TcpOptions(pub u64);

impl TcpOptions {
    /// Parse a `TcpOptions` from a byte slice by reading a `u64`.
    pub fn parse(input: &[u8]) -> IResult<&[u8], Self> {
        let (remaining, value) = u64::parse(input)?;
        Ok((remaining, Self::from(value)))
    }

    /// Returns the raw bitmask value.
    pub fn raw(&self) -> u64 {
        self.0
    }

    /// Test whether a specific bit (option type) is set.
    pub fn has_option(&self, bit: u8) -> bool {
        bit < 64 && self.0 & (1u64 << bit) != 0
    }
}

impl std::fmt::Display for TcpOptions {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "0x{:016X}", self.0)
    }
}

impl From<u64> for TcpOptions {
    fn from(value: u64) -> Self {
        Self(value)
    }
}

impl From<TcpOptions> for u64 {
    fn from(opts: TcpOptions) -> Self {
        opts.0
    }
}

#[cfg(test)]
mod tcp_options_tests {
    use super::TcpOptions;

    #[test]
    fn test_display() {
        assert_eq!(TcpOptions::from(0u64).to_string(), "0x0000000000000000");
        assert_eq!(TcpOptions::from(0xFFu64).to_string(), "0x00000000000000FF");
        assert_eq!(
            TcpOptions::from(0xFFFF_FFFF_FFFF_FFFFu64).to_string(),
            "0xFFFFFFFFFFFFFFFF"
        );
    }

    #[test]
    fn test_round_trip() {
        for value in [0u64, 1, 0xFF, 0xFFFF_FFFF_FFFF_FFFF] {
            let opts = TcpOptions::from(value);
            let back = u64::from(opts);
            assert_eq!(value, back);
        }
    }

    #[test]
    fn test_has_option() {
        let opts = TcpOptions::from(0x05u64); // bits 0 and 2
        assert!(opts.has_option(0));
        assert!(!opts.has_option(1));
        assert!(opts.has_option(2));
        assert!(!opts.has_option(64)); // out of range
    }
}
