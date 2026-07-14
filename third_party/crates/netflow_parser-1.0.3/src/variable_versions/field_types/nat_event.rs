//! NAT Event field decoding (IPFIX field ID 230).
//!
//! Identifies a NAT event type. Values from the IANA NAT Event Type
//! registry (RFC 8158).

use nom::IResult;
use nom_derive::Parse;
use serde::Serialize;

/// Decoded NAT event from an IPFIX field (ID 230).
#[derive(Debug, PartialEq, Eq, Clone, Copy, Serialize)]
pub enum NatEvent {
    /// 1: NAT translation create (historic).
    NatTranslationCreate,
    /// 2: NAT translation delete (historic).
    NatTranslationDelete,
    /// 3: NAT addresses exhausted.
    NatAddressesExhausted,
    /// 4: NAT44 session create.
    Nat44SessionCreate,
    /// 5: NAT44 session delete.
    Nat44SessionDelete,
    /// 6: NAT64 session create.
    Nat64SessionCreate,
    /// 7: NAT64 session delete.
    Nat64SessionDelete,
    /// 8: NAT44 BIB create.
    Nat44BibCreate,
    /// 9: NAT44 BIB delete.
    Nat44BibDelete,
    /// 10: NAT64 BIB create.
    Nat64BibCreate,
    /// 11: NAT64 BIB delete.
    Nat64BibDelete,
    /// 12: NAT ports exhausted.
    NatPortsExhausted,
    /// 13: Quota exceeded.
    QuotaExceeded,
    /// 14: Address binding create.
    AddressBindingCreate,
    /// 15: Address binding delete.
    AddressBindingDelete,
    /// 16: Port block allocation.
    PortBlockAllocation,
    /// 17: Port block de-allocation.
    PortBlockDeAllocation,
    /// 18: Threshold reached.
    ThresholdReached,
    /// Reserved or unassigned event type.
    Unknown(u8),
}

impl NatEvent {
    /// Parse a `NatEvent` from a byte slice by reading a single `u8`.
    pub fn parse(input: &[u8]) -> IResult<&[u8], Self> {
        let (remaining, value) = u8::parse(input)?;
        Ok((remaining, Self::from(value)))
    }
}

impl From<u8> for NatEvent {
    fn from(value: u8) -> Self {
        match value {
            1 => NatEvent::NatTranslationCreate,
            2 => NatEvent::NatTranslationDelete,
            3 => NatEvent::NatAddressesExhausted,
            4 => NatEvent::Nat44SessionCreate,
            5 => NatEvent::Nat44SessionDelete,
            6 => NatEvent::Nat64SessionCreate,
            7 => NatEvent::Nat64SessionDelete,
            8 => NatEvent::Nat44BibCreate,
            9 => NatEvent::Nat44BibDelete,
            10 => NatEvent::Nat64BibCreate,
            11 => NatEvent::Nat64BibDelete,
            12 => NatEvent::NatPortsExhausted,
            13 => NatEvent::QuotaExceeded,
            14 => NatEvent::AddressBindingCreate,
            15 => NatEvent::AddressBindingDelete,
            16 => NatEvent::PortBlockAllocation,
            17 => NatEvent::PortBlockDeAllocation,
            18 => NatEvent::ThresholdReached,
            v => NatEvent::Unknown(v),
        }
    }
}

impl From<NatEvent> for u8 {
    fn from(event: NatEvent) -> Self {
        match event {
            NatEvent::NatTranslationCreate => 1,
            NatEvent::NatTranslationDelete => 2,
            NatEvent::NatAddressesExhausted => 3,
            NatEvent::Nat44SessionCreate => 4,
            NatEvent::Nat44SessionDelete => 5,
            NatEvent::Nat64SessionCreate => 6,
            NatEvent::Nat64SessionDelete => 7,
            NatEvent::Nat44BibCreate => 8,
            NatEvent::Nat44BibDelete => 9,
            NatEvent::Nat64BibCreate => 10,
            NatEvent::Nat64BibDelete => 11,
            NatEvent::NatPortsExhausted => 12,
            NatEvent::QuotaExceeded => 13,
            NatEvent::AddressBindingCreate => 14,
            NatEvent::AddressBindingDelete => 15,
            NatEvent::PortBlockAllocation => 16,
            NatEvent::PortBlockDeAllocation => 17,
            NatEvent::ThresholdReached => 18,
            NatEvent::Unknown(v) => v,
        }
    }
}

impl std::fmt::Display for NatEvent {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            NatEvent::NatTranslationCreate => write!(f, "NAT translation create"),
            NatEvent::NatTranslationDelete => write!(f, "NAT translation delete"),
            NatEvent::NatAddressesExhausted => write!(f, "NAT addresses exhausted"),
            NatEvent::Nat44SessionCreate => write!(f, "NAT44 session create"),
            NatEvent::Nat44SessionDelete => write!(f, "NAT44 session delete"),
            NatEvent::Nat64SessionCreate => write!(f, "NAT64 session create"),
            NatEvent::Nat64SessionDelete => write!(f, "NAT64 session delete"),
            NatEvent::Nat44BibCreate => write!(f, "NAT44 BIB create"),
            NatEvent::Nat44BibDelete => write!(f, "NAT44 BIB delete"),
            NatEvent::Nat64BibCreate => write!(f, "NAT64 BIB create"),
            NatEvent::Nat64BibDelete => write!(f, "NAT64 BIB delete"),
            NatEvent::NatPortsExhausted => write!(f, "NAT ports exhausted"),
            NatEvent::QuotaExceeded => write!(f, "Quota exceeded"),
            NatEvent::AddressBindingCreate => write!(f, "Address binding create"),
            NatEvent::AddressBindingDelete => write!(f, "Address binding delete"),
            NatEvent::PortBlockAllocation => write!(f, "Port block allocation"),
            NatEvent::PortBlockDeAllocation => write!(f, "Port block de-allocation"),
            NatEvent::ThresholdReached => write!(f, "Threshold reached"),
            NatEvent::Unknown(v) => write!(f, "Unknown({})", v),
        }
    }
}

impl PartialOrd for NatEvent {
    fn partial_cmp(&self, other: &Self) -> Option<std::cmp::Ordering> {
        Some(self.cmp(other))
    }
}

impl Ord for NatEvent {
    fn cmp(&self, other: &Self) -> std::cmp::Ordering {
        u8::from(*self).cmp(&u8::from(*other))
    }
}

#[cfg(test)]
mod nat_event_tests {
    use super::NatEvent;
    use insta::assert_yaml_snapshot;

    #[test]
    fn test_round_trip() {
        for byte in 0..=255u8 {
            let event = NatEvent::from(byte);
            let back = u8::from(event);
            assert_eq!(byte, back, "round-trip failed for {byte}");
        }
    }

    #[test]
    fn test_known_values() {
        assert_eq!(NatEvent::from(4), NatEvent::Nat44SessionCreate);
        assert_eq!(NatEvent::from(12), NatEvent::NatPortsExhausted);
        assert_eq!(NatEvent::from(32), NatEvent::Unknown(32));
    }

    #[test]
    fn test_all_nat_events() {
        let events: Vec<_> = (0..=20u8).map(NatEvent::from).collect();
        assert_yaml_snapshot!(events);
    }

    #[test]
    fn test_display() {
        assert_eq!(
            format!("{}", NatEvent::NatTranslationCreate),
            "NAT translation create"
        );
        assert_eq!(
            format!("{}", NatEvent::Nat44SessionCreate),
            "NAT44 session create"
        );
        assert_eq!(format!("{}", NatEvent::Unknown(99)), "Unknown(99)");
    }
}
