//! Flow End Reason field decoding (IPFIX field ID 136).
//!
//! Indicates why a flow was terminated. Values from the IANA
//! flowEndReason registry (RFC 5102).

use nom::IResult;
use nom_derive::Parse;
use serde::Serialize;

/// Decoded flow end reason from an IPFIX field (ID 136).
#[derive(Debug, PartialEq, Eq, Clone, Copy, Serialize)]
pub enum FlowEndReason {
    /// The flow was terminated because it was considered idle.
    IdleTimeout,
    /// The flow was terminated for reporting purposes while still active.
    ActiveTimeout,
    /// The metering process detected the end of the flow (e.g., TCP FIN).
    EndOfFlow,
    /// The flow was terminated due to an external event (e.g., shutdown).
    ForcedEnd,
    /// The flow was terminated due to lack of resources.
    LackOfResources,
    /// Unassigned or reserved reason code.
    Unknown(u8),
}

impl FlowEndReason {
    /// Parse a `FlowEndReason` from a byte slice by reading a single `u8`.
    pub fn parse(input: &[u8]) -> IResult<&[u8], Self> {
        let (remaining, value) = u8::parse(input)?;
        Ok((remaining, Self::from(value)))
    }
}

impl From<u8> for FlowEndReason {
    fn from(value: u8) -> Self {
        match value {
            1 => FlowEndReason::IdleTimeout,
            2 => FlowEndReason::ActiveTimeout,
            3 => FlowEndReason::EndOfFlow,
            4 => FlowEndReason::ForcedEnd,
            5 => FlowEndReason::LackOfResources,
            v => FlowEndReason::Unknown(v),
        }
    }
}

impl From<FlowEndReason> for u8 {
    fn from(reason: FlowEndReason) -> Self {
        match reason {
            FlowEndReason::IdleTimeout => 1,
            FlowEndReason::ActiveTimeout => 2,
            FlowEndReason::EndOfFlow => 3,
            FlowEndReason::ForcedEnd => 4,
            FlowEndReason::LackOfResources => 5,
            FlowEndReason::Unknown(v) => v,
        }
    }
}

impl std::fmt::Display for FlowEndReason {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            FlowEndReason::IdleTimeout => write!(f, "Idle timeout"),
            FlowEndReason::ActiveTimeout => write!(f, "Active timeout"),
            FlowEndReason::EndOfFlow => write!(f, "End of flow"),
            FlowEndReason::ForcedEnd => write!(f, "Forced end"),
            FlowEndReason::LackOfResources => write!(f, "Lack of resources"),
            FlowEndReason::Unknown(v) => write!(f, "Unknown({})", v),
        }
    }
}

impl PartialOrd for FlowEndReason {
    fn partial_cmp(&self, other: &Self) -> Option<std::cmp::Ordering> {
        Some(self.cmp(other))
    }
}

impl Ord for FlowEndReason {
    fn cmp(&self, other: &Self) -> std::cmp::Ordering {
        u8::from(*self).cmp(&u8::from(*other))
    }
}

#[cfg(test)]
mod flow_end_reason_tests {
    use super::FlowEndReason;
    use insta::assert_yaml_snapshot;

    #[test]
    fn test_round_trip() {
        for byte in 0..=255u8 {
            let reason = FlowEndReason::from(byte);
            let back = u8::from(reason);
            assert_eq!(byte, back, "round-trip failed for {byte}");
        }
    }

    #[test]
    fn test_known_values() {
        assert_eq!(FlowEndReason::from(1), FlowEndReason::IdleTimeout);
        assert_eq!(FlowEndReason::from(3), FlowEndReason::EndOfFlow);
        assert_eq!(FlowEndReason::from(10), FlowEndReason::Unknown(10));
    }

    #[test]
    fn test_all_flow_end_reasons() {
        let reasons: Vec<_> = (0..=10u8).map(FlowEndReason::from).collect();
        assert_yaml_snapshot!(reasons);
    }

    #[test]
    fn test_display() {
        assert_eq!(format!("{}", FlowEndReason::IdleTimeout), "Idle timeout");
        assert_eq!(format!("{}", FlowEndReason::EndOfFlow), "End of flow");
        assert_eq!(format!("{}", FlowEndReason::Unknown(42)), "Unknown(42)");
    }
}
