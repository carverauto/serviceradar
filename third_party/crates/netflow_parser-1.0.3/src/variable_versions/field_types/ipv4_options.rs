//! IPv4 Options field decoding (IPFIX field ID 208).
//!
//! A 32-bit bitmask where each bit indicates the presence of a specific
//! IPv4 option type. Bit positions are defined by the IANA IPFIX registry.

use nom::IResult;
use nom_derive::Parse;
use serde::Serialize;

/// Decoded IPv4 options bitmask from an IPFIX field (ID 208).
///
/// Bit positions per IANA IPFIX IPv4 Options registry.
#[derive(Debug, PartialEq, Eq, Clone, Copy, Serialize)]
pub struct Ipv4Options {
    /// Bit 0: RR — Record Route (RFC 791)
    pub rr: bool,
    /// Bit 1: CIPSO — Commercial IP Security Option
    pub cipso: bool,
    /// Bit 2: E-SEC — Extended Security (RFC 1108)
    pub e_sec: bool,
    /// Bit 3: TS — Timestamp (RFC 791)
    pub ts: bool,
    /// Bit 4: LSR — Loose Source Route (RFC 791)
    pub lsr: bool,
    /// Bit 5: SEC — Security (RFC 1108)
    pub sec: bool,
    /// Bit 6: NOP — No Operation (RFC 791)
    pub nop: bool,
    /// Bit 7: EOOL — End of Options List (RFC 791)
    pub eool: bool,
    /// Bit 8: ENCODE
    pub encode: bool,
    /// Bit 9: VISA — Experimental Access Control
    pub visa: bool,
    /// Bit 10: FINN — Experimental Flow Control
    pub finn: bool,
    /// Bit 11: MTUR — MTU Reply (obsoleted)
    pub mtur: bool,
    /// Bit 12: MTUP — MTU Probe (obsoleted)
    pub mtup: bool,
    /// Bit 13: ZSU — Experimental Measurement
    pub zsu: bool,
    /// Bit 14: SSR — Strict Source Route (RFC 791)
    pub ssr: bool,
    /// Bit 15: SID — Stream ID (RFC 791)
    pub sid: bool,
    /// Bit 16: DPS — Dynamic Packet State
    pub dps: bool,
    /// Bit 17: NSAPA — NSAP Address
    pub nsapa: bool,
    /// Bit 18: SDB — Selective Directed Broadcast
    pub sdb: bool,
    /// Bit 19: RTRALT — Router Alert (RFC 2113)
    pub rtralt: bool,
    /// Bit 20: TR — Traceroute (RFC 3193)
    pub tr: bool,
    /// Bit 21: EIP — Extended Internet Protocol (RFC 1385)
    pub eip: bool,
    /// Bit 22: IMITD — IMI Traffic Descriptor
    pub imitd: bool,
    /// Remaining bits (23-31) stored raw for forward compatibility.
    pub other_bits: u32,
}

impl Ipv4Options {
    const KNOWN_MASK: u32 = 0x007F_FFFF; // bits 0-22

    /// Parse an `Ipv4Options` from a byte slice by reading a `u32`.
    pub fn parse(input: &[u8]) -> IResult<&[u8], Self> {
        let (remaining, value) = u32::parse(input)?;
        Ok((remaining, Self::from(value)))
    }
}

impl From<u32> for Ipv4Options {
    fn from(value: u32) -> Self {
        Self {
            rr: value & (1 << 0) != 0,
            cipso: value & (1 << 1) != 0,
            e_sec: value & (1 << 2) != 0,
            ts: value & (1 << 3) != 0,
            lsr: value & (1 << 4) != 0,
            sec: value & (1 << 5) != 0,
            nop: value & (1 << 6) != 0,
            eool: value & (1 << 7) != 0,
            encode: value & (1 << 8) != 0,
            visa: value & (1 << 9) != 0,
            finn: value & (1 << 10) != 0,
            mtur: value & (1 << 11) != 0,
            mtup: value & (1 << 12) != 0,
            zsu: value & (1 << 13) != 0,
            ssr: value & (1 << 14) != 0,
            sid: value & (1 << 15) != 0,
            dps: value & (1 << 16) != 0,
            nsapa: value & (1 << 17) != 0,
            sdb: value & (1 << 18) != 0,
            rtralt: value & (1 << 19) != 0,
            tr: value & (1 << 20) != 0,
            eip: value & (1 << 21) != 0,
            imitd: value & (1 << 22) != 0,
            other_bits: value & !Self::KNOWN_MASK,
        }
    }
}

impl From<Ipv4Options> for u32 {
    fn from(o: Ipv4Options) -> Self {
        (o.rr as u32)
            | ((o.cipso as u32) << 1)
            | ((o.e_sec as u32) << 2)
            | ((o.ts as u32) << 3)
            | ((o.lsr as u32) << 4)
            | ((o.sec as u32) << 5)
            | ((o.nop as u32) << 6)
            | ((o.eool as u32) << 7)
            | ((o.encode as u32) << 8)
            | ((o.visa as u32) << 9)
            | ((o.finn as u32) << 10)
            | ((o.mtur as u32) << 11)
            | ((o.mtup as u32) << 12)
            | ((o.zsu as u32) << 13)
            | ((o.ssr as u32) << 14)
            | ((o.sid as u32) << 15)
            | ((o.dps as u32) << 16)
            | ((o.nsapa as u32) << 17)
            | ((o.sdb as u32) << 18)
            | ((o.rtralt as u32) << 19)
            | ((o.tr as u32) << 20)
            | ((o.eip as u32) << 21)
            | ((o.imitd as u32) << 22)
            | o.other_bits
    }
}

impl std::fmt::Display for Ipv4Options {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        let mut opts = Vec::new();
        if self.rr {
            opts.push("RR");
        }
        if self.cipso {
            opts.push("CIPSO");
        }
        if self.e_sec {
            opts.push("E-SEC");
        }
        if self.ts {
            opts.push("TS");
        }
        if self.lsr {
            opts.push("LSR");
        }
        if self.sec {
            opts.push("SEC");
        }
        if self.nop {
            opts.push("NOP");
        }
        if self.eool {
            opts.push("EOOL");
        }
        if self.encode {
            opts.push("ENCODE");
        }
        if self.visa {
            opts.push("VISA");
        }
        if self.finn {
            opts.push("FINN");
        }
        if self.mtur {
            opts.push("MTUR");
        }
        if self.mtup {
            opts.push("MTUP");
        }
        if self.zsu {
            opts.push("ZSU");
        }
        if self.ssr {
            opts.push("SSR");
        }
        if self.sid {
            opts.push("SID");
        }
        if self.dps {
            opts.push("DPS");
        }
        if self.nsapa {
            opts.push("NSAPA");
        }
        if self.sdb {
            opts.push("SDB");
        }
        if self.rtralt {
            opts.push("RTRALT");
        }
        if self.tr {
            opts.push("TR");
        }
        if self.eip {
            opts.push("EIP");
        }
        if self.imitd {
            opts.push("IMITD");
        }
        if opts.is_empty() {
            write!(f, "none")
        } else {
            write!(f, "{}", opts.join("|"))
        }
    }
}

impl PartialOrd for Ipv4Options {
    fn partial_cmp(&self, other: &Self) -> Option<std::cmp::Ordering> {
        Some(self.cmp(other))
    }
}

impl Ord for Ipv4Options {
    fn cmp(&self, other: &Self) -> std::cmp::Ordering {
        u32::from(*self).cmp(&u32::from(*other))
    }
}

#[cfg(test)]
mod ipv4_options_tests {
    use super::Ipv4Options;

    #[test]
    fn test_display() {
        assert_eq!(Ipv4Options::from(0u32).to_string(), "none");
        assert_eq!(Ipv4Options::from(1u32).to_string(), "RR");
        assert_eq!(Ipv4Options::from(0x60u32).to_string(), "SEC|NOP");
        assert_eq!(
            Ipv4Options::from(0x7Fu32).to_string(),
            "RR|CIPSO|E-SEC|TS|LSR|SEC|NOP"
        );
    }

    #[test]
    fn test_round_trip() {
        for value in [0u32, 1, 0x10, 0x80000, 0x007F_FFFF, 0xFFFF_FFFF] {
            let opts = Ipv4Options::from(value);
            let back = u32::from(opts);
            assert_eq!(value, back, "round-trip failed for {value:#010x}");
        }
    }

    #[test]
    fn test_known_values() {
        let rr = Ipv4Options::from(1u32);
        assert!(rr.rr);
        assert!(!rr.lsr);

        let lsr = Ipv4Options::from(0x10u32);
        assert!(lsr.lsr);

        let rtralt = Ipv4Options::from(1u32 << 19);
        assert!(rtralt.rtralt);
    }
}
