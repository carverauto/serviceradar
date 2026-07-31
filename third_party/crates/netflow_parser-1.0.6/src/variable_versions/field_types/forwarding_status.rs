//! Forwarding Status field decoding (RFC 7270, field ID 89).
//!
//! The forwarding status is encoded as a single byte where:
//! - Bits 6-7 (upper 2 bits): Status category
//! - Bits 0-5 (lower 6 bits): Reason code within that category
//!
//! # Examples
//!
//! ```
//! use netflow_parser::variable_versions::field_types::ForwardingStatus;
//!
//! // Forwarded with unknown reason
//! let status = ForwardingStatus::from(0b01_000000);
//! assert_eq!(status, ForwardingStatus::Forwarded(ForwardingStatus::UNKNOWN_REASON));
//!
//! // Dropped due to ACL deny
//! let status = ForwardingStatus::from(0b10_000010);
//! assert_eq!(status, ForwardingStatus::DroppedAclDeny);
//!
//! // Round-trip
//! assert_eq!(u8::from(ForwardingStatus::ConsumedTerminatedPuntedToControl), 0b11_000001);
//! ```
//!
//! # References
//!
//! - <https://www.iana.org/assignments/ipfix/ipfix.xhtml#forwarding-status>
//! - <https://datatracker.ietf.org/doc/html/rfc7270>

use nom::IResult;
use nom_derive::Parse;
use serde::Serialize;

/// Decoded forwarding status from a NetFlow V9 / IPFIX field (ID 89).
///
/// Encodes both the high-level status category and the specific reason code.
/// The raw byte can be recovered via `u8::from(status)`.
#[derive(Debug, PartialEq, Eq, Clone, Copy, Serialize)]
pub enum ForwardingStatus {
    // -- Status 0: Unknown --
    /// Unknown status, preserving the reason byte (lower 6 bits).
    Unknown(u8),

    // -- Status 1: Forwarded --
    /// Forwarded, with a reason code (0 = unknown).
    Forwarded(u8),
    /// Forwarded: fragmented.
    ForwardedFragmented,
    /// Forwarded: not fragmented.
    ForwardedNotFragmented,

    // -- Status 2: Dropped --
    /// Dropped, with a reason code (0 = unknown).
    Dropped(u8),
    /// Dropped: ACL deny.
    DroppedAclDeny,
    /// Dropped: ACL drop.
    DroppedAclDrop,
    /// Dropped: unroutable.
    DroppedUnroutable,
    /// Dropped: adjacency.
    DroppedAdjacency,
    /// Dropped: fragmentation and DF set.
    DroppedFragmentationAndDf,
    /// Dropped: bad header checksum.
    DroppedBadHeaderChecksum,
    /// Dropped: bad total length.
    DroppedBadTotalLength,
    /// Dropped: bad header length.
    DroppedBadHeaderLength,
    /// Dropped: bad TTL.
    DroppedBadTtl,
    /// Dropped: policer.
    DroppedPolicer,
    /// Dropped: WRED.
    DroppedWred,
    /// Dropped: RPF.
    DroppedRpf,
    /// Dropped: for us.
    DroppedForUs,
    /// Dropped: bad output interface.
    DroppedBadOutputInterface,
    /// Dropped: hardware.
    DroppedHardware,

    // -- Status 3: Consumed --
    /// Consumed, with a reason code (0 = unknown).
    Consumed(u8),
    /// Consumed: terminated / punted to control plane.
    ConsumedTerminatedPuntedToControl,
    /// Consumed: terminated / incomplete adjacency.
    ConsumedTerminatedIncompleteAdjacency,
    /// Consumed: terminated / for us.
    ConsumedTerminatedForUs,
}

impl PartialOrd for ForwardingStatus {
    fn partial_cmp(&self, other: &Self) -> Option<std::cmp::Ordering> {
        Some(self.cmp(other))
    }
}

impl Ord for ForwardingStatus {
    fn cmp(&self, other: &Self) -> std::cmp::Ordering {
        u8::from(*self).cmp(&u8::from(*other))
    }
}

impl ForwardingStatus {
    /// Reason code value meaning "unknown" within a status category.
    pub const UNKNOWN_REASON: u8 = 0;

    /// Parse a `ForwardingStatus` from a byte slice by reading a single `u8`.
    pub fn parse(input: &[u8]) -> IResult<&[u8], Self> {
        let (remaining, value) = u8::parse(input)?;
        Ok((remaining, Self::from(value)))
    }

    /// Returns the status category (0=Unknown, 1=Forwarded, 2=Dropped, 3=Consumed).
    pub fn status_category(&self) -> u8 {
        match self {
            ForwardingStatus::Unknown(_) => 0,
            ForwardingStatus::Forwarded(_)
            | ForwardingStatus::ForwardedFragmented
            | ForwardingStatus::ForwardedNotFragmented => 1,
            ForwardingStatus::Dropped(_)
            | ForwardingStatus::DroppedAclDeny
            | ForwardingStatus::DroppedAclDrop
            | ForwardingStatus::DroppedUnroutable
            | ForwardingStatus::DroppedAdjacency
            | ForwardingStatus::DroppedFragmentationAndDf
            | ForwardingStatus::DroppedBadHeaderChecksum
            | ForwardingStatus::DroppedBadTotalLength
            | ForwardingStatus::DroppedBadHeaderLength
            | ForwardingStatus::DroppedBadTtl
            | ForwardingStatus::DroppedPolicer
            | ForwardingStatus::DroppedWred
            | ForwardingStatus::DroppedRpf
            | ForwardingStatus::DroppedForUs
            | ForwardingStatus::DroppedBadOutputInterface
            | ForwardingStatus::DroppedHardware => 2,
            ForwardingStatus::Consumed(_)
            | ForwardingStatus::ConsumedTerminatedPuntedToControl
            | ForwardingStatus::ConsumedTerminatedIncompleteAdjacency
            | ForwardingStatus::ConsumedTerminatedForUs => 3,
        }
    }

    /// Returns the reason code (lower 6 bits).
    pub fn reason_code(&self) -> u8 {
        match self {
            ForwardingStatus::Unknown(r) => *r,
            ForwardingStatus::Forwarded(r)
            | ForwardingStatus::Dropped(r)
            | ForwardingStatus::Consumed(r) => *r,
            ForwardingStatus::ForwardedFragmented => 1,
            ForwardingStatus::ForwardedNotFragmented => 2,
            ForwardingStatus::DroppedAclDeny => 2,
            ForwardingStatus::DroppedAclDrop => 3,
            ForwardingStatus::DroppedUnroutable => 4,
            ForwardingStatus::DroppedAdjacency => 5,
            ForwardingStatus::DroppedFragmentationAndDf => 6,
            ForwardingStatus::DroppedBadHeaderChecksum => 7,
            ForwardingStatus::DroppedBadTotalLength => 8,
            ForwardingStatus::DroppedBadHeaderLength => 9,
            ForwardingStatus::DroppedBadTtl => 10,
            ForwardingStatus::DroppedPolicer => 11,
            ForwardingStatus::DroppedWred => 12,
            ForwardingStatus::DroppedRpf => 13,
            ForwardingStatus::DroppedForUs => 14,
            ForwardingStatus::DroppedBadOutputInterface => 15,
            ForwardingStatus::DroppedHardware => 16,
            ForwardingStatus::ConsumedTerminatedPuntedToControl => 1,
            ForwardingStatus::ConsumedTerminatedIncompleteAdjacency => 2,
            ForwardingStatus::ConsumedTerminatedForUs => 3,
        }
    }
}

impl std::fmt::Display for ForwardingStatus {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            ForwardingStatus::Unknown(r) => write!(f, "Unknown({r})"),
            ForwardingStatus::Forwarded(r) => write!(f, "Forwarded({r})"),
            ForwardingStatus::ForwardedFragmented => write!(f, "Forwarded: Fragmented"),
            ForwardingStatus::ForwardedNotFragmented => write!(f, "Forwarded: Not Fragmented"),
            ForwardingStatus::Dropped(r) => write!(f, "Dropped({r})"),
            ForwardingStatus::DroppedAclDeny => write!(f, "Dropped: ACL Deny"),
            ForwardingStatus::DroppedAclDrop => write!(f, "Dropped: ACL Drop"),
            ForwardingStatus::DroppedUnroutable => write!(f, "Dropped: Unroutable"),
            ForwardingStatus::DroppedAdjacency => write!(f, "Dropped: Adjacency"),
            ForwardingStatus::DroppedFragmentationAndDf => {
                write!(f, "Dropped: Fragmentation and DF")
            }
            ForwardingStatus::DroppedBadHeaderChecksum => {
                write!(f, "Dropped: Bad Header Checksum")
            }
            ForwardingStatus::DroppedBadTotalLength => write!(f, "Dropped: Bad Total Length"),
            ForwardingStatus::DroppedBadHeaderLength => write!(f, "Dropped: Bad Header Length"),
            ForwardingStatus::DroppedBadTtl => write!(f, "Dropped: Bad TTL"),
            ForwardingStatus::DroppedPolicer => write!(f, "Dropped: Policer"),
            ForwardingStatus::DroppedWred => write!(f, "Dropped: WRED"),
            ForwardingStatus::DroppedRpf => write!(f, "Dropped: RPF"),
            ForwardingStatus::DroppedForUs => write!(f, "Dropped: For Us"),
            ForwardingStatus::DroppedBadOutputInterface => {
                write!(f, "Dropped: Bad Output Interface")
            }
            ForwardingStatus::DroppedHardware => write!(f, "Dropped: Hardware"),
            ForwardingStatus::Consumed(r) => write!(f, "Consumed({r})"),
            ForwardingStatus::ConsumedTerminatedPuntedToControl => {
                write!(f, "Consumed: Punted to Control")
            }
            ForwardingStatus::ConsumedTerminatedIncompleteAdjacency => {
                write!(f, "Consumed: Incomplete Adjacency")
            }
            ForwardingStatus::ConsumedTerminatedForUs => write!(f, "Consumed: For Us"),
        }
    }
}

impl From<u8> for ForwardingStatus {
    fn from(value: u8) -> Self {
        let status = value >> 6;
        let reason = value & 0x3F;
        match (status, reason) {
            (0, r) => ForwardingStatus::Unknown(r),
            (1, 1) => ForwardingStatus::ForwardedFragmented,
            (1, 2) => ForwardingStatus::ForwardedNotFragmented,
            (1, r) => ForwardingStatus::Forwarded(r),
            (2, 2) => ForwardingStatus::DroppedAclDeny,
            (2, 3) => ForwardingStatus::DroppedAclDrop,
            (2, 4) => ForwardingStatus::DroppedUnroutable,
            (2, 5) => ForwardingStatus::DroppedAdjacency,
            (2, 6) => ForwardingStatus::DroppedFragmentationAndDf,
            (2, 7) => ForwardingStatus::DroppedBadHeaderChecksum,
            (2, 8) => ForwardingStatus::DroppedBadTotalLength,
            (2, 9) => ForwardingStatus::DroppedBadHeaderLength,
            (2, 10) => ForwardingStatus::DroppedBadTtl,
            (2, 11) => ForwardingStatus::DroppedPolicer,
            (2, 12) => ForwardingStatus::DroppedWred,
            (2, 13) => ForwardingStatus::DroppedRpf,
            (2, 14) => ForwardingStatus::DroppedForUs,
            (2, 15) => ForwardingStatus::DroppedBadOutputInterface,
            (2, 16) => ForwardingStatus::DroppedHardware,
            (2, r) => ForwardingStatus::Dropped(r),
            (3, 1) => ForwardingStatus::ConsumedTerminatedPuntedToControl,
            (3, 2) => ForwardingStatus::ConsumedTerminatedIncompleteAdjacency,
            (3, 3) => ForwardingStatus::ConsumedTerminatedForUs,
            (3, r) => ForwardingStatus::Consumed(r),
            // status = value >> 6 can only be 0..=3, all covered above
            _ => unreachable!(),
        }
    }
}

impl From<ForwardingStatus> for u8 {
    fn from(status: ForwardingStatus) -> Self {
        (status.status_category() << 6) | status.reason_code()
    }
}

#[cfg(test)]
mod forwarding_status_tests {
    use super::ForwardingStatus;
    use insta::assert_yaml_snapshot;

    #[test]
    fn test_round_trip() {
        // All bytes should now round-trip exactly, including status=0 with reason bits.
        for byte in 0..=255u8 {
            let status = ForwardingStatus::from(byte);
            let back = u8::from(status);
            assert_eq!(
                byte, back,
                "round-trip failed for {byte:#04x} -> {status:?}"
            );
        }
    }

    #[test]
    fn test_known_values() {
        assert_eq!(
            ForwardingStatus::from(0b00_000000),
            ForwardingStatus::Unknown(0)
        );
        assert_eq!(
            ForwardingStatus::from(0b00_000101),
            ForwardingStatus::Unknown(5)
        );
        assert_eq!(
            ForwardingStatus::from(0b01_000000),
            ForwardingStatus::Forwarded(0)
        );
        assert_eq!(
            ForwardingStatus::from(0b01_000001),
            ForwardingStatus::ForwardedFragmented
        );
        assert_eq!(
            ForwardingStatus::from(0b01_000010),
            ForwardingStatus::ForwardedNotFragmented
        );
        assert_eq!(
            ForwardingStatus::from(0b10_000010),
            ForwardingStatus::DroppedAclDeny
        );
        assert_eq!(
            ForwardingStatus::from(0b10_010000),
            ForwardingStatus::DroppedHardware
        );
        assert_eq!(
            ForwardingStatus::from(0b11_000001),
            ForwardingStatus::ConsumedTerminatedPuntedToControl
        );
        assert_eq!(
            ForwardingStatus::from(0b11_000011),
            ForwardingStatus::ConsumedTerminatedForUs
        );
    }

    #[test]
    fn test_all_forwarding_statuses() {
        let statuses: Vec<_> = (0..=255u8).map(ForwardingStatus::from).collect();
        assert_yaml_snapshot!(statuses);
    }

    #[test]
    fn test_status_category() {
        assert_eq!(ForwardingStatus::Unknown(0).status_category(), 0);
        assert_eq!(ForwardingStatus::ForwardedFragmented.status_category(), 1);
        assert_eq!(ForwardingStatus::DroppedAclDeny.status_category(), 2);
        assert_eq!(
            ForwardingStatus::ConsumedTerminatedForUs.status_category(),
            3
        );
    }

    #[test]
    fn test_display() {
        assert_eq!(format!("{}", ForwardingStatus::Unknown(0)), "Unknown(0)");
        assert_eq!(
            format!("{}", ForwardingStatus::Forwarded(0)),
            "Forwarded(0)"
        );
        assert_eq!(
            format!("{}", ForwardingStatus::DroppedAclDeny),
            "Dropped: ACL Deny"
        );
        assert_eq!(
            format!("{}", ForwardingStatus::ConsumedTerminatedForUs),
            "Consumed: For Us"
        );
    }
}
