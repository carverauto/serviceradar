//! IPv6 Extension Headers field decoding (IPFIX field ID 64).
//!
//! A 32-bit bitmask indicating which IPv6 extension headers were observed.
//! Bit definitions per IANA IPFIX IPv6 Extension Headers registry.

use nom::IResult;
use nom_derive::Parse;
use serde::Serialize;

/// Decoded IPv6 extension headers bitmask from an IPFIX field (ID 64).
#[derive(Debug, PartialEq, Eq, Clone, Copy, Serialize)]
pub struct Ipv6ExtensionHeaders {
    /// Bit 0: Destination Options header
    pub destination_options: bool,
    /// Bit 1: Fragment header
    pub fragment: bool,
    /// Bit 2: Hop-by-Hop Options header
    pub hop_by_hop: bool,
    /// Bit 3: Routing header
    pub routing: bool,
    /// Bit 4: Authentication Header (AH)
    pub authentication: bool,
    /// Bit 5: Encapsulating Security Payload (ESP)
    pub esp: bool,
    /// Remaining bits (6-31) stored raw for forward compatibility.
    pub other_bits: u32,
}

impl Ipv6ExtensionHeaders {
    const KNOWN_MASK: u32 = 0x3F;

    /// Parse an `Ipv6ExtensionHeaders` from a byte slice by reading a `u32`.
    pub fn parse(input: &[u8]) -> IResult<&[u8], Self> {
        let (remaining, value) = u32::parse(input)?;
        Ok((remaining, Self::from(value)))
    }
}

impl From<u32> for Ipv6ExtensionHeaders {
    fn from(value: u32) -> Self {
        Self {
            destination_options: value & (1 << 0) != 0,
            fragment: value & (1 << 1) != 0,
            hop_by_hop: value & (1 << 2) != 0,
            routing: value & (1 << 3) != 0,
            authentication: value & (1 << 4) != 0,
            esp: value & (1 << 5) != 0,
            other_bits: value & !Self::KNOWN_MASK,
        }
    }
}

impl From<Ipv6ExtensionHeaders> for u32 {
    fn from(h: Ipv6ExtensionHeaders) -> Self {
        (h.destination_options as u32)
            | ((h.fragment as u32) << 1)
            | ((h.hop_by_hop as u32) << 2)
            | ((h.routing as u32) << 3)
            | ((h.authentication as u32) << 4)
            | ((h.esp as u32) << 5)
            | h.other_bits
    }
}

impl std::fmt::Display for Ipv6ExtensionHeaders {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        let mut headers = Vec::new();
        if self.destination_options {
            headers.push("DST");
        }
        if self.fragment {
            headers.push("FRAG");
        }
        if self.hop_by_hop {
            headers.push("HBH");
        }
        if self.routing {
            headers.push("RT");
        }
        if self.authentication {
            headers.push("AH");
        }
        if self.esp {
            headers.push("ESP");
        }
        if headers.is_empty() {
            write!(f, "none")
        } else {
            write!(f, "{}", headers.join("|"))
        }
    }
}

impl PartialOrd for Ipv6ExtensionHeaders {
    fn partial_cmp(&self, other: &Self) -> Option<std::cmp::Ordering> {
        Some(self.cmp(other))
    }
}

impl Ord for Ipv6ExtensionHeaders {
    fn cmp(&self, other: &Self) -> std::cmp::Ordering {
        u32::from(*self).cmp(&u32::from(*other))
    }
}

#[cfg(test)]
mod ipv6_extension_headers_tests {
    use super::Ipv6ExtensionHeaders;

    #[test]
    fn test_display() {
        assert_eq!(Ipv6ExtensionHeaders::from(0u32).to_string(), "none");
        assert_eq!(Ipv6ExtensionHeaders::from(1u32).to_string(), "DST");
        assert_eq!(Ipv6ExtensionHeaders::from(0x03u32).to_string(), "DST|FRAG");
        assert_eq!(
            Ipv6ExtensionHeaders::from(0x3Fu32).to_string(),
            "DST|FRAG|HBH|RT|AH|ESP"
        );
    }

    #[test]
    fn test_round_trip() {
        for value in [0u32, 1, 2, 4, 8, 16, 32, 0x3F, 0xFFFF_FFFF, 0x40, 0x100] {
            let h = Ipv6ExtensionHeaders::from(value);
            let back = u32::from(h);
            assert_eq!(value, back, "round-trip failed for {value:#010x}");
        }
    }

    #[test]
    fn test_known_values() {
        let empty = Ipv6ExtensionHeaders::from(0u32);
        assert!(!empty.destination_options && !empty.fragment && !empty.hop_by_hop);

        let dest = Ipv6ExtensionHeaders::from(1u32);
        assert!(dest.destination_options);
        assert!(!dest.fragment);

        let frag = Ipv6ExtensionHeaders::from(2u32);
        assert!(frag.fragment);

        let all_known = Ipv6ExtensionHeaders::from(0x3Fu32);
        assert!(
            all_known.destination_options
                && all_known.fragment
                && all_known.hop_by_hop
                && all_known.routing
                && all_known.authentication
                && all_known.esp
        );
    }
}
