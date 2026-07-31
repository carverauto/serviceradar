//! MPLS Top Label Type field decoding (IPFIX field ID 46).
//!
//! Identifies the control protocol that allocated the top-of-stack MPLS label.
//! Values from the IANA IPFIX MPLS label type registry.

use nom::IResult;
use nom_derive::Parse;
use serde::Serialize;

/// Decoded MPLS top label type from an IPFIX field (ID 46).
#[derive(Debug, PartialEq, Eq, Clone, Copy, Serialize)]
pub enum MplsTopLabelType {
    /// 0: Unknown.
    Unknown,
    /// 1: TE-MIDPT — Any TE tunnel mid-point or tail label.
    TeMidpoint,
    /// 2: Pseudowire — Any PWE3 or Cisco AToM based label.
    Pseudowire,
    /// 3: VPN — Any label associated with VPN.
    Vpn,
    /// 4: BGP — Any label associated with BGP or BGP routing.
    Bgp,
    /// 5: LDP — Any label associated with dynamically assigned labels using LDP.
    Ldp,
    /// 6: Path Computation Element.
    PathComputationElement,
    /// 7: OSPFv2 Segment Routing.
    OspfV2SegmentRouting,
    /// 8: OSPFv3 Segment Routing.
    OspfV3SegmentRouting,
    /// 9: IS-IS Segment Routing.
    IsIsSegmentRouting,
    /// 10: BGP Segment Routing Prefix-SID.
    BgpSegmentRoutingPrefixSid,
    /// Unassigned label type.
    Unassigned(u8),
}

impl MplsTopLabelType {
    /// Parse a `MplsTopLabelType` from a byte slice by reading a single `u8`.
    pub fn parse(input: &[u8]) -> IResult<&[u8], Self> {
        let (remaining, value) = u8::parse(input)?;
        Ok((remaining, Self::from(value)))
    }
}

impl std::fmt::Display for MplsTopLabelType {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            MplsTopLabelType::Unknown => write!(f, "Unknown"),
            MplsTopLabelType::TeMidpoint => write!(f, "TE-MIDPT"),
            MplsTopLabelType::Pseudowire => write!(f, "Pseudowire"),
            MplsTopLabelType::Vpn => write!(f, "VPN"),
            MplsTopLabelType::Bgp => write!(f, "BGP"),
            MplsTopLabelType::Ldp => write!(f, "LDP"),
            MplsTopLabelType::PathComputationElement => write!(f, "PCE"),
            MplsTopLabelType::OspfV2SegmentRouting => write!(f, "OSPFv2-SR"),
            MplsTopLabelType::OspfV3SegmentRouting => write!(f, "OSPFv3-SR"),
            MplsTopLabelType::IsIsSegmentRouting => write!(f, "IS-IS-SR"),
            MplsTopLabelType::BgpSegmentRoutingPrefixSid => write!(f, "BGP-SR-Prefix-SID"),
            MplsTopLabelType::Unassigned(v) => write!(f, "Unassigned({v})"),
        }
    }
}

impl From<u8> for MplsTopLabelType {
    fn from(value: u8) -> Self {
        match value {
            0 => MplsTopLabelType::Unknown,
            1 => MplsTopLabelType::TeMidpoint,
            2 => MplsTopLabelType::Pseudowire,
            3 => MplsTopLabelType::Vpn,
            4 => MplsTopLabelType::Bgp,
            5 => MplsTopLabelType::Ldp,
            6 => MplsTopLabelType::PathComputationElement,
            7 => MplsTopLabelType::OspfV2SegmentRouting,
            8 => MplsTopLabelType::OspfV3SegmentRouting,
            9 => MplsTopLabelType::IsIsSegmentRouting,
            10 => MplsTopLabelType::BgpSegmentRoutingPrefixSid,
            v => MplsTopLabelType::Unassigned(v),
        }
    }
}

impl From<MplsTopLabelType> for u8 {
    fn from(label_type: MplsTopLabelType) -> Self {
        match label_type {
            MplsTopLabelType::Unknown => 0,
            MplsTopLabelType::TeMidpoint => 1,
            MplsTopLabelType::Pseudowire => 2,
            MplsTopLabelType::Vpn => 3,
            MplsTopLabelType::Bgp => 4,
            MplsTopLabelType::Ldp => 5,
            MplsTopLabelType::PathComputationElement => 6,
            MplsTopLabelType::OspfV2SegmentRouting => 7,
            MplsTopLabelType::OspfV3SegmentRouting => 8,
            MplsTopLabelType::IsIsSegmentRouting => 9,
            MplsTopLabelType::BgpSegmentRoutingPrefixSid => 10,
            MplsTopLabelType::Unassigned(v) => v,
        }
    }
}

impl PartialOrd for MplsTopLabelType {
    fn partial_cmp(&self, other: &Self) -> Option<std::cmp::Ordering> {
        Some(self.cmp(other))
    }
}

impl Ord for MplsTopLabelType {
    fn cmp(&self, other: &Self) -> std::cmp::Ordering {
        u8::from(*self).cmp(&u8::from(*other))
    }
}

#[cfg(test)]
mod mpls_top_label_type_tests {
    use super::MplsTopLabelType;
    use insta::assert_yaml_snapshot;

    #[test]
    fn test_display() {
        assert_eq!(MplsTopLabelType::from(0).to_string(), "Unknown");
        assert_eq!(MplsTopLabelType::from(1).to_string(), "TE-MIDPT");
        assert_eq!(MplsTopLabelType::from(5).to_string(), "LDP");
        assert_eq!(MplsTopLabelType::from(10).to_string(), "BGP-SR-Prefix-SID");
        assert_eq!(MplsTopLabelType::from(20).to_string(), "Unassigned(20)");
    }

    #[test]
    fn test_round_trip() {
        for byte in 0..=255u8 {
            let lt = MplsTopLabelType::from(byte);
            let back = u8::from(lt);
            assert_eq!(byte, back, "round-trip failed for {byte}");
        }
    }

    #[test]
    fn test_known_values() {
        assert_eq!(MplsTopLabelType::from(0), MplsTopLabelType::Unknown);
        assert_eq!(MplsTopLabelType::from(3), MplsTopLabelType::Vpn);
        assert_eq!(MplsTopLabelType::from(5), MplsTopLabelType::Ldp);
        assert_eq!(MplsTopLabelType::from(20), MplsTopLabelType::Unassigned(20));
    }

    #[test]
    fn test_all_mpls_top_label_types() {
        let types: Vec<_> = (0..=15u8).map(MplsTopLabelType::from).collect();
        assert_yaml_snapshot!(types);
    }
}
