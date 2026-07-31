//! Firewall Event field decoding (IPFIX field ID 233).
//!
//! Indicates a firewall event. Values from the IANA firewallEvent registry.

use nom::IResult;
use nom_derive::Parse;
use serde::Serialize;

/// Decoded firewall event from an IPFIX field (ID 233).
#[derive(Debug, PartialEq, Eq, Clone, Copy, Serialize)]
pub enum FirewallEvent {
    /// 0: Ignore (invalid).
    Ignore,
    /// 1: Flow created.
    FlowCreated,
    /// 2: Flow deleted.
    FlowDeleted,
    /// 3: Flow denied.
    FlowDenied,
    /// 4: Flow alert.
    FlowAlert,
    /// 5: Flow update.
    FlowUpdate,
    /// Unassigned event code.
    Unknown(u8),
}

impl FirewallEvent {
    /// Parse a `FirewallEvent` from a byte slice by reading a single `u8`.
    pub fn parse(input: &[u8]) -> IResult<&[u8], Self> {
        let (remaining, value) = u8::parse(input)?;
        Ok((remaining, Self::from(value)))
    }
}

impl From<u8> for FirewallEvent {
    fn from(value: u8) -> Self {
        match value {
            0 => FirewallEvent::Ignore,
            1 => FirewallEvent::FlowCreated,
            2 => FirewallEvent::FlowDeleted,
            3 => FirewallEvent::FlowDenied,
            4 => FirewallEvent::FlowAlert,
            5 => FirewallEvent::FlowUpdate,
            v => FirewallEvent::Unknown(v),
        }
    }
}

impl From<FirewallEvent> for u8 {
    fn from(event: FirewallEvent) -> Self {
        match event {
            FirewallEvent::Ignore => 0,
            FirewallEvent::FlowCreated => 1,
            FirewallEvent::FlowDeleted => 2,
            FirewallEvent::FlowDenied => 3,
            FirewallEvent::FlowAlert => 4,
            FirewallEvent::FlowUpdate => 5,
            FirewallEvent::Unknown(v) => v,
        }
    }
}

impl std::fmt::Display for FirewallEvent {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            FirewallEvent::Ignore => write!(f, "Ignore"),
            FirewallEvent::FlowCreated => write!(f, "Flow created"),
            FirewallEvent::FlowDeleted => write!(f, "Flow deleted"),
            FirewallEvent::FlowDenied => write!(f, "Flow denied"),
            FirewallEvent::FlowAlert => write!(f, "Flow alert"),
            FirewallEvent::FlowUpdate => write!(f, "Flow update"),
            FirewallEvent::Unknown(v) => write!(f, "Unknown({})", v),
        }
    }
}

impl PartialOrd for FirewallEvent {
    fn partial_cmp(&self, other: &Self) -> Option<std::cmp::Ordering> {
        Some(self.cmp(other))
    }
}

impl Ord for FirewallEvent {
    fn cmp(&self, other: &Self) -> std::cmp::Ordering {
        u8::from(*self).cmp(&u8::from(*other))
    }
}

#[cfg(test)]
mod firewall_event_tests {
    use super::FirewallEvent;
    use insta::assert_yaml_snapshot;

    #[test]
    fn test_round_trip() {
        for byte in 0..=255u8 {
            let event = FirewallEvent::from(byte);
            let back = u8::from(event);
            assert_eq!(byte, back, "round-trip failed for {byte}");
        }
    }

    #[test]
    fn test_known_values() {
        assert_eq!(FirewallEvent::from(0), FirewallEvent::Ignore);
        assert_eq!(FirewallEvent::from(1), FirewallEvent::FlowCreated);
        assert_eq!(FirewallEvent::from(3), FirewallEvent::FlowDenied);
        assert_eq!(FirewallEvent::from(255), FirewallEvent::Unknown(255));
    }

    #[test]
    fn test_all_firewall_events() {
        let events: Vec<_> = (0..=8u8).map(FirewallEvent::from).collect();
        assert_yaml_snapshot!(events);
    }

    #[test]
    fn test_display() {
        assert_eq!(format!("{}", FirewallEvent::Ignore), "Ignore");
        assert_eq!(format!("{}", FirewallEvent::FlowCreated), "Flow created");
        assert_eq!(format!("{}", FirewallEvent::Unknown(99)), "Unknown(99)");
    }
}
