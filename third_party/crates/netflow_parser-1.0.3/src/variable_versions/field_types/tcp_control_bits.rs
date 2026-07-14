//! TCP Control Bits field decoding (IPFIX field ID 6).
//!
//! Encodes TCP header flags as a bitmask:
//! - Bit 0: FIN
//! - Bit 1: SYN
//! - Bit 2: RST
//! - Bit 3: PSH
//! - Bit 4: ACK
//! - Bit 5: URG
//! - Bit 6: ECE
//! - Bit 7: CWR
//! - Bit 8: NS (from RFC 3540, encoded in the upper byte)

use nom::IResult;
use nom_derive::Parse;
use serde::Serialize;

/// Decoded TCP control bits from an IPFIX field (ID 6).
#[derive(Debug, PartialEq, Eq, Clone, Copy, Serialize)]
pub struct TcpControlBits {
    pub fin: bool,
    pub syn: bool,
    pub rst: bool,
    pub psh: bool,
    pub ack: bool,
    pub urg: bool,
    pub ece: bool,
    pub cwr: bool,
    pub ns: bool,
}

impl TcpControlBits {
    /// Parse `TcpControlBits` from a byte slice by reading a `u16`.
    pub fn parse(input: &[u8]) -> IResult<&[u8], Self> {
        let (remaining, value) = u16::parse(input)?;
        Ok((remaining, Self::from(value)))
    }
}

impl From<u16> for TcpControlBits {
    fn from(value: u16) -> Self {
        // Only bits 0-8 are defined TCP flags; mask off any upper bits
        let value = value & 0x01FF;
        Self {
            fin: value & 0x0001 != 0,
            syn: value & 0x0002 != 0,
            rst: value & 0x0004 != 0,
            psh: value & 0x0008 != 0,
            ack: value & 0x0010 != 0,
            urg: value & 0x0020 != 0,
            ece: value & 0x0040 != 0,
            cwr: value & 0x0080 != 0,
            ns: value & 0x0100 != 0,
        }
    }
}

impl From<TcpControlBits> for u16 {
    fn from(bits: TcpControlBits) -> Self {
        (bits.fin as u16)
            | ((bits.syn as u16) << 1)
            | ((bits.rst as u16) << 2)
            | ((bits.psh as u16) << 3)
            | ((bits.ack as u16) << 4)
            | ((bits.urg as u16) << 5)
            | ((bits.ece as u16) << 6)
            | ((bits.cwr as u16) << 7)
            | ((bits.ns as u16) << 8)
    }
}

impl std::fmt::Display for TcpControlBits {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        let mut flags = Vec::new();
        if self.ns {
            flags.push("NS");
        }
        if self.cwr {
            flags.push("CWR");
        }
        if self.ece {
            flags.push("ECE");
        }
        if self.urg {
            flags.push("URG");
        }
        if self.ack {
            flags.push("ACK");
        }
        if self.psh {
            flags.push("PSH");
        }
        if self.rst {
            flags.push("RST");
        }
        if self.syn {
            flags.push("SYN");
        }
        if self.fin {
            flags.push("FIN");
        }
        if flags.is_empty() {
            write!(f, "none")
        } else {
            write!(f, "{}", flags.join("|"))
        }
    }
}

impl PartialOrd for TcpControlBits {
    fn partial_cmp(&self, other: &Self) -> Option<std::cmp::Ordering> {
        Some(self.cmp(other))
    }
}

impl Ord for TcpControlBits {
    fn cmp(&self, other: &Self) -> std::cmp::Ordering {
        u16::from(*self).cmp(&u16::from(*other))
    }
}

#[cfg(test)]
mod tcp_control_bits_tests {
    use super::TcpControlBits;
    use insta::assert_yaml_snapshot;

    #[test]
    fn test_round_trip() {
        for value in 0..=0x01FFu16 {
            let bits = TcpControlBits::from(value);
            let back = u16::from(bits);
            assert_eq!(value, back, "round-trip failed for {value:#06x}");
        }
    }

    #[test]
    fn test_known_values() {
        let syn = TcpControlBits::from(0x0002u16);
        assert!(syn.syn);
        assert!(!syn.ack);
        assert!(!syn.fin);

        let syn_ack = TcpControlBits::from(0x0012u16);
        assert!(syn_ack.syn);
        assert!(syn_ack.ack);

        let all = TcpControlBits::from(0x01FFu16);
        assert!(
            all.fin
                && all.syn
                && all.rst
                && all.psh
                && all.ack
                && all.urg
                && all.ece
                && all.cwr
                && all.ns
        );
    }

    #[test]
    fn test_upper_bits_masked() {
        // Bits 9-15 should be silently masked off
        let bits = TcpControlBits::from(0xFFFFu16);
        let back = u16::from(bits);
        assert_eq!(back, 0x01FF, "upper bits should be masked to 0x01FF");

        // Value with only upper bits set should produce all-false flags
        let bits = TcpControlBits::from(0xFE00u16);
        let back = u16::from(bits);
        assert_eq!(back, 0x0000, "upper-only bits should produce 0x0000");
    }

    #[test]
    fn test_all_single_flags() {
        let flags: Vec<_> = [
            0x0001, 0x0002, 0x0004, 0x0008, 0x0010, 0x0020, 0x0040, 0x0080, 0x0100u16,
        ]
        .iter()
        .map(|&v| TcpControlBits::from(v))
        .collect();
        assert_yaml_snapshot!(flags);
    }

    #[test]
    fn test_display() {
        assert_eq!(format!("{}", TcpControlBits::from(0x0000u16)), "none");
        assert_eq!(format!("{}", TcpControlBits::from(0x0002u16)), "SYN");
        assert_eq!(format!("{}", TcpControlBits::from(0x0012u16)), "ACK|SYN");
        assert_eq!(
            format!("{}", TcpControlBits::from(0x0013u16)),
            "ACK|SYN|FIN"
        );
    }
}
