//! BGP Link-State data structures based on RFC 7752

use crate::models::*;
use num_enum::{FromPrimitive, IntoPrimitive};
use std::collections::HashMap;
use std::net::{Ipv4Addr, Ipv6Addr};

/// BGP Link-State NLRI Types as defined in RFC 7752 and IANA registry
#[derive(Debug, PartialEq, Eq, Hash, Copy, Clone, FromPrimitive, IntoPrimitive)]
#[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
#[repr(u16)]
pub enum NlriType {
    #[num_enum(default)]
    Reserved = 0,
    Node = 1,
    Link = 2,
    Ipv4TopologyPrefix = 3,
    Ipv6TopologyPrefix = 4,
    SrPolicyCandidatePath = 5,
    Srv6Sid = 6,
    StubLink = 7,
}

/// Protocol Identifier as defined in RFC 7752
#[derive(Debug, PartialEq, Eq, Hash, Copy, Clone, FromPrimitive, IntoPrimitive)]
#[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
#[repr(u8)]
pub enum ProtocolId {
    #[num_enum(default)]
    Reserved = 0,
    IsisL1 = 1,
    IsisL2 = 2,
    Ospfv2 = 3,
    Direct = 4,
    Static = 5,
    Ospfv3 = 6,
    Bgp = 7,
    RsvpTe = 8,
    SegmentRouting = 9,
}

/// Node Descriptor Sub-TLV Types
#[derive(Debug, PartialEq, Eq, Hash, Copy, Clone, FromPrimitive, IntoPrimitive)]
#[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
#[repr(u16)]
pub enum NodeDescriptorType {
    #[num_enum(default)]
    Reserved = 0,
    AutonomousSystem = 512,
    BgpLsIdentifier = 513,
    OspfAreaId = 514,
    IgpRouterId = 515,
}

/// Link Descriptor Sub-TLV Types
#[derive(Debug, PartialEq, Eq, Hash, Copy, Clone, FromPrimitive, IntoPrimitive)]
#[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
#[repr(u16)]
pub enum LinkDescriptorType {
    #[num_enum(default)]
    Reserved = 0,
    LinkLocalRemoteIdentifiers = 258,
    Ipv4InterfaceAddress = 259,
    Ipv4NeighborAddress = 260,
    Ipv6InterfaceAddress = 261,
    Ipv6NeighborAddress = 262,
    MultiTopologyId = 263,
}

/// Prefix Descriptor Sub-TLV Types
#[derive(Debug, PartialEq, Eq, Hash, Copy, Clone, FromPrimitive, IntoPrimitive)]
#[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
#[repr(u16)]
pub enum PrefixDescriptorType {
    #[num_enum(default)]
    Reserved = 0,
    MultiTopologyId = 263,
    OspfRouteType = 264,
    IpReachabilityInformation = 265,
}

/// Node Attribute TLV Types
#[derive(Debug, PartialEq, Eq, Hash, Copy, Clone, FromPrimitive, IntoPrimitive)]
#[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
#[repr(u16)]
pub enum NodeAttributeType {
    #[num_enum(default)]
    Reserved = 0,
    NodeFlagBits = 1024,
    OpaqueNodeAttribute = 1025,
    NodeName = 1026,
    IsisAreaIdentifier = 1027,
    Ipv4RouterIdOfLocalNode = 1028,
    Ipv6RouterIdOfLocalNode = 1029,
    SrCapabilities = 1034,
    SrAlgorithm = 1035,
    SrLocalBlock = 1036,
    SrmsPreference = 1037,
}

/// Link Attribute TLV Types
#[derive(Debug, PartialEq, Eq, Hash, Copy, Clone, FromPrimitive, IntoPrimitive)]
#[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
#[repr(u16)]
pub enum LinkAttributeType {
    #[num_enum(default)]
    Reserved = 0,
    Ipv4RouterIdOfLocalNode = 1028,
    Ipv6RouterIdOfLocalNode = 1029,
    Ipv4RouterIdOfRemoteNode = 1030,
    Ipv6RouterIdOfRemoteNode = 1031,
    AdministrativeGroup = 1088,
    MaximumLinkBandwidth = 1089,
    MaxReservableLinkBandwidth = 1090,
    UnreservedBandwidth = 1091,
    TeDefaultMetric = 1092,
    LinkProtectionType = 1093,
    MplsProtocolMask = 1094,
    IgpMetric = 1095,
    SharedRiskLinkGroups = 1096,
    OpaqueLinkAttribute = 1097,
    LinkName = 1098,
    SrAdjacencySid = 1099,
    SrLanAdjacencySid = 1100,
    PeerNodeSid = 1101,
    PeerAdjacencySid = 1102,
    PeerSetSid = 1103,
    /// Unidirectional Link Delay - RFC 8571
    UnidirectionalLinkDelay = 1114,
    /// Min/Max Unidirectional Link Delay - RFC 8571
    MinMaxUnidirectionalLinkDelay = 1115,
    /// Unidirectional Delay Variation - RFC 8571
    UnidirectionalDelayVariation = 1116,
    /// Unidirectional Link Loss - RFC 8571
    UnidirectionalLinkLoss = 1117,
    /// Unidirectional Residual Bandwidth - RFC 8571
    UnidirectionalResidualBandwidth = 1118,
    /// Unidirectional Available Bandwidth - RFC 8571
    UnidirectionalAvailableBandwidth = 1119,
    /// Unidirectional Utilized Bandwidth - RFC 8571
    UnidirectionalUtilizedBandwidth = 1120,
    /// L2 Bundle Member Attributes - RFC 9085
    L2BundleMemberAttributes = 1172,
    /// Application-Specific Link Attributes - RFC 9294
    ApplicationSpecificLinkAttributes = 1122,
}

/// Prefix Attribute TLV Types
#[derive(Debug, PartialEq, Eq, Hash, Copy, Clone, FromPrimitive, IntoPrimitive)]
#[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
#[repr(u16)]
pub enum PrefixAttributeType {
    #[num_enum(default)]
    Reserved = 0,
    IgpFlags = 1152,
    IgpRouteTag = 1153,
    IgpExtendedRouteTag = 1154,
    PrefixMetric = 1155,
    OspfForwardingAddress = 1156,
    OpaquePrefixAttribute = 1157,
    PrefixSid = 1158,
    RangeSid = 1159,
    SidLabelIndex = 1161,
    SidLabelBinding = 1162,
    Srv6LocatorTlv = 1163,
    /// Prefix Attribute Flags - RFC 9085
    PrefixAttributeFlags = 1170,
    /// Source Router Identifier - RFC 9085
    SourceRouterIdentifier = 1171,
    /// Source OSPF Router-ID - RFC 9085
    SourceOspfRouterId = 1174,
}

/// TLV (Type-Length-Value) structure for Link-State information
#[derive(Debug, PartialEq, Clone, Eq)]
#[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
pub struct Tlv {
    pub tlv_type: u16,
    pub value: Vec<u8>,
}

impl Tlv {
    pub fn new(tlv_type: u16, value: Vec<u8>) -> Self {
        Self { tlv_type, value }
    }

    pub fn length(&self) -> u16 {
        self.value.len() as u16
    }
}

/// Node Descriptor TLVs
#[derive(Debug, PartialEq, Clone, Eq)]
#[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
#[derive(Default)]
pub struct NodeDescriptor {
    pub autonomous_system: Option<u32>,
    pub bgp_ls_identifier: Option<u32>,
    pub ospf_area_id: Option<u32>,
    pub igp_router_id: Option<Vec<u8>>,
    pub unknown_tlvs: Vec<Tlv>,
}

/// Link Descriptor TLVs
#[derive(Debug, PartialEq, Clone, Eq)]
#[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
#[derive(Default)]
pub struct LinkDescriptor {
    pub link_local_remote_identifiers: Option<(u32, u32)>,
    pub ipv4_interface_address: Option<Ipv4Addr>,
    pub ipv4_neighbor_address: Option<Ipv4Addr>,
    pub ipv6_interface_address: Option<Ipv6Addr>,
    pub ipv6_neighbor_address: Option<Ipv6Addr>,
    pub multi_topology_id: Option<u16>,
    pub unknown_tlvs: Vec<Tlv>,
}

/// Prefix Descriptor TLVs
#[derive(Debug, PartialEq, Clone, Eq)]
#[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
#[derive(Default)]
pub struct PrefixDescriptor {
    pub multi_topology_id: Option<u16>,
    pub ospf_route_type: Option<u8>,
    pub ip_reachability_information: Option<NetworkPrefix>,
    pub unknown_tlvs: Vec<Tlv>,
}

/// BGP Link-State NLRI structure
#[derive(Debug, PartialEq, Clone, Eq)]
#[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
pub struct LinkStateNlri {
    pub nlri_type: NlriType,
    pub protocol_id: ProtocolId,
    pub identifier: u64,
    pub local_node_descriptors: NodeDescriptor,
    pub remote_node_descriptors: Option<NodeDescriptor>,
    pub link_descriptors: Option<LinkDescriptor>,
    pub prefix_descriptors: Option<PrefixDescriptor>,
}

impl LinkStateNlri {
    pub fn new_node_nlri(
        protocol_id: ProtocolId,
        identifier: u64,
        local_node_descriptors: NodeDescriptor,
    ) -> Self {
        Self {
            nlri_type: NlriType::Node,
            protocol_id,
            identifier,
            local_node_descriptors,
            remote_node_descriptors: None,
            link_descriptors: None,
            prefix_descriptors: None,
        }
    }

    pub fn new_link_nlri(
        protocol_id: ProtocolId,
        identifier: u64,
        local_node_descriptors: NodeDescriptor,
        remote_node_descriptors: NodeDescriptor,
        link_descriptors: LinkDescriptor,
    ) -> Self {
        Self {
            nlri_type: NlriType::Link,
            protocol_id,
            identifier,
            local_node_descriptors,
            remote_node_descriptors: Some(remote_node_descriptors),
            link_descriptors: Some(link_descriptors),
            prefix_descriptors: None,
        }
    }

    pub fn new_prefix_nlri(
        nlri_type: NlriType, // Ipv4TopologyPrefix or Ipv6TopologyPrefix
        protocol_id: ProtocolId,
        identifier: u64,
        local_node_descriptors: NodeDescriptor,
        prefix_descriptors: PrefixDescriptor,
    ) -> Self {
        Self {
            nlri_type,
            protocol_id,
            identifier,
            local_node_descriptors,
            remote_node_descriptors: None,
            link_descriptors: None,
            prefix_descriptors: Some(prefix_descriptors),
        }
    }
}

/// BGP Link-State Attributes
#[derive(Debug, PartialEq, Clone, Eq)]
#[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
#[derive(Default)]
pub struct LinkStateAttribute {
    pub node_attributes: HashMap<NodeAttributeType, Vec<u8>>,
    pub link_attributes: HashMap<LinkAttributeType, Vec<u8>>,
    pub prefix_attributes: HashMap<PrefixAttributeType, Vec<u8>>,
    pub unknown_attributes: Vec<Tlv>,
}

impl LinkStateAttribute {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn add_node_attribute(&mut self, attr_type: NodeAttributeType, value: Vec<u8>) {
        self.node_attributes.insert(attr_type, value);
    }

    pub fn add_link_attribute(&mut self, attr_type: LinkAttributeType, value: Vec<u8>) {
        self.link_attributes.insert(attr_type, value);
    }

    pub fn add_prefix_attribute(&mut self, attr_type: PrefixAttributeType, value: Vec<u8>) {
        self.prefix_attributes.insert(attr_type, value);
    }

    pub fn add_unknown_attribute(&mut self, tlv: Tlv) {
        self.unknown_attributes.push(tlv);
    }

    pub fn get_node_name(&self) -> Option<String> {
        self.node_attributes
            .get(&NodeAttributeType::NodeName)
            .and_then(|bytes| String::from_utf8(bytes.clone()).ok())
    }

    pub fn get_link_name(&self) -> Option<String> {
        self.link_attributes
            .get(&LinkAttributeType::LinkName)
            .and_then(|bytes| String::from_utf8(bytes.clone()).ok())
    }

    pub fn get_node_flags(&self) -> Option<u8> {
        self.node_attributes
            .get(&NodeAttributeType::NodeFlagBits)
            .and_then(|bytes| bytes.first().copied())
    }

    pub fn get_administrative_group(&self) -> Option<u32> {
        self.link_attributes
            .get(&LinkAttributeType::AdministrativeGroup)
            .and_then(|bytes| {
                if bytes.len() >= 4 {
                    Some(u32::from_be_bytes([bytes[0], bytes[1], bytes[2], bytes[3]]))
                } else {
                    None
                }
            })
    }

    pub fn get_maximum_link_bandwidth(&self) -> Option<f32> {
        self.link_attributes
            .get(&LinkAttributeType::MaximumLinkBandwidth)
            .and_then(|bytes| {
                if bytes.len() >= 4 {
                    Some(f32::from_be_bytes([bytes[0], bytes[1], bytes[2], bytes[3]]))
                } else {
                    None
                }
            })
    }

    pub fn get_igp_metric(&self) -> Option<u32> {
        self.link_attributes
            .get(&LinkAttributeType::IgpMetric)
            .and_then(|bytes| match bytes.len() {
                1 => Some(bytes[0] as u32),
                2 => Some(u16::from_be_bytes([bytes[0], bytes[1]]) as u32),
                3 => Some(
                    (u32::from(bytes[0]) << 16) + (u32::from(bytes[1]) << 8) + u32::from(bytes[2]),
                ),
                _ => None,
            })
    }

    pub fn get_prefix_metric(&self) -> Option<u32> {
        self.prefix_attributes
            .get(&PrefixAttributeType::PrefixMetric)
            .and_then(|bytes| {
                if bytes.len() >= 4 {
                    Some(u32::from_be_bytes([bytes[0], bytes[1], bytes[2], bytes[3]]))
                } else {
                    None
                }
            })
    }

    /// Get unidirectional link delay in microseconds - RFC 8571
    pub fn get_unidirectional_link_delay(&self) -> Option<u32> {
        self.link_attributes
            .get(&LinkAttributeType::UnidirectionalLinkDelay)
            .and_then(|bytes| {
                if bytes.len() >= 4 {
                    Some(u32::from_be_bytes([bytes[0], bytes[1], bytes[2], bytes[3]]) & 0x00FFFFFF)
                } else {
                    None
                }
            })
    }

    /// Get min/max unidirectional link delay in microseconds - RFC 8571
    /// Returns (min_delay, max_delay)
    pub fn get_min_max_unidirectional_link_delay(&self) -> Option<(u32, u32)> {
        self.link_attributes
            .get(&LinkAttributeType::MinMaxUnidirectionalLinkDelay)
            .and_then(|bytes| {
                if bytes.len() >= 8 {
                    let min_delay =
                        u32::from_be_bytes([bytes[0], bytes[1], bytes[2], bytes[3]]) & 0x00FFFFFF;
                    let max_delay =
                        u32::from_be_bytes([bytes[4], bytes[5], bytes[6], bytes[7]]) & 0x00FFFFFF;
                    Some((min_delay, max_delay))
                } else {
                    None
                }
            })
    }

    /// Get unidirectional delay variation in microseconds - RFC 8571
    pub fn get_unidirectional_delay_variation(&self) -> Option<u32> {
        self.link_attributes
            .get(&LinkAttributeType::UnidirectionalDelayVariation)
            .and_then(|bytes| {
                if bytes.len() >= 4 {
                    Some(u32::from_be_bytes([bytes[0], bytes[1], bytes[2], bytes[3]]) & 0x00FFFFFF)
                } else {
                    None
                }
            })
    }

    /// Get unidirectional link loss percentage - RFC 8571
    /// Returns loss as a percentage (0.000003% to 50.331642%)
    pub fn get_unidirectional_link_loss(&self) -> Option<f32> {
        self.link_attributes
            .get(&LinkAttributeType::UnidirectionalLinkLoss)
            .and_then(|bytes| {
                if bytes.len() >= 4 {
                    let raw_value =
                        u32::from_be_bytes([bytes[0], bytes[1], bytes[2], bytes[3]]) & 0x00FFFFFF;
                    Some(raw_value as f32 * 0.000003)
                } else {
                    None
                }
            })
    }

    /// Get unidirectional residual bandwidth in bytes per second - RFC 8571
    pub fn get_unidirectional_residual_bandwidth(&self) -> Option<f32> {
        self.link_attributes
            .get(&LinkAttributeType::UnidirectionalResidualBandwidth)
            .and_then(|bytes| {
                if bytes.len() >= 4 {
                    Some(f32::from_be_bytes([bytes[0], bytes[1], bytes[2], bytes[3]]))
                } else {
                    None
                }
            })
    }

    /// Get unidirectional available bandwidth in bytes per second - RFC 8571
    pub fn get_unidirectional_available_bandwidth(&self) -> Option<f32> {
        self.link_attributes
            .get(&LinkAttributeType::UnidirectionalAvailableBandwidth)
            .and_then(|bytes| {
                if bytes.len() >= 4 {
                    Some(f32::from_be_bytes([bytes[0], bytes[1], bytes[2], bytes[3]]))
                } else {
                    None
                }
            })
    }

    /// Get unidirectional utilized bandwidth in bytes per second - RFC 8571
    pub fn get_unidirectional_utilized_bandwidth(&self) -> Option<f32> {
        self.link_attributes
            .get(&LinkAttributeType::UnidirectionalUtilizedBandwidth)
            .and_then(|bytes| {
                if bytes.len() >= 4 {
                    Some(f32::from_be_bytes([bytes[0], bytes[1], bytes[2], bytes[3]]))
                } else {
                    None
                }
            })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::str::FromStr;

    #[test]
    fn test_nlri_type_conversion() {
        assert_eq!(NlriType::Node as u16, 1);
        assert_eq!(NlriType::Link as u16, 2);
        assert_eq!(NlriType::Ipv4TopologyPrefix as u16, 3);
        assert_eq!(NlriType::Ipv6TopologyPrefix as u16, 4);
    }

    #[test]
    fn test_protocol_id_conversion() {
        assert_eq!(ProtocolId::IsisL1 as u8, 1);
        assert_eq!(ProtocolId::Ospfv2 as u8, 3);
        assert_eq!(ProtocolId::Ospfv3 as u8, 6);
    }

    #[test]
    fn test_node_nlri_creation() {
        let node_desc = NodeDescriptor {
            autonomous_system: Some(65001),
            igp_router_id: Some(vec![192, 168, 1, 1]),
            ..Default::default()
        };

        let nlri = LinkStateNlri::new_node_nlri(ProtocolId::Ospfv2, 123456, node_desc);

        assert_eq!(nlri.nlri_type, NlriType::Node);
        assert_eq!(nlri.protocol_id, ProtocolId::Ospfv2);
        assert_eq!(nlri.identifier, 123456);
        assert_eq!(nlri.local_node_descriptors.autonomous_system, Some(65001));
        assert!(nlri.remote_node_descriptors.is_none());
        assert!(nlri.link_descriptors.is_none());
        assert!(nlri.prefix_descriptors.is_none());
    }

    #[test]
    fn test_link_nlri_creation() {
        let local_desc = NodeDescriptor::default();
        let remote_desc = NodeDescriptor::default();
        let link_desc = LinkDescriptor::default();

        let nlri = LinkStateNlri::new_link_nlri(
            ProtocolId::IsisL1,
            789012,
            local_desc,
            remote_desc,
            link_desc,
        );

        assert_eq!(nlri.nlri_type, NlriType::Link);
        assert_eq!(nlri.protocol_id, ProtocolId::IsisL1);
        assert_eq!(nlri.identifier, 789012);
        assert!(nlri.remote_node_descriptors.is_some());
        assert!(nlri.link_descriptors.is_some());
        assert!(nlri.prefix_descriptors.is_none());
    }

    #[test]
    fn test_prefix_nlri_creation() {
        let local_desc = NodeDescriptor::default();
        let prefix_desc = PrefixDescriptor {
            ip_reachability_information: Some(NetworkPrefix::from_str("192.168.1.0/24").unwrap()),
            ..Default::default()
        };

        let nlri = LinkStateNlri::new_prefix_nlri(
            NlriType::Ipv4TopologyPrefix,
            ProtocolId::Ospfv2,
            345678,
            local_desc,
            prefix_desc,
        );

        assert_eq!(nlri.nlri_type, NlriType::Ipv4TopologyPrefix);
        assert_eq!(nlri.protocol_id, ProtocolId::Ospfv2);
        assert_eq!(nlri.identifier, 345678);
        assert!(nlri.remote_node_descriptors.is_none());
        assert!(nlri.link_descriptors.is_none());
        assert!(nlri.prefix_descriptors.is_some());
    }

    #[test]
    fn test_link_state_attribute() {
        let mut attr = LinkStateAttribute::new();

        // Test node name
        attr.add_node_attribute(NodeAttributeType::NodeName, b"router1".to_vec());
        assert_eq!(attr.get_node_name(), Some("router1".to_string()));

        // Test administrative group
        attr.add_link_attribute(
            LinkAttributeType::AdministrativeGroup,
            vec![0x00, 0x00, 0x00, 0xFF],
        );
        assert_eq!(attr.get_administrative_group(), Some(255));

        // Test IGP metric
        attr.add_link_attribute(LinkAttributeType::IgpMetric, vec![0x01, 0x00]);
        assert_eq!(attr.get_igp_metric(), Some(256));

        // Test prefix metric
        attr.add_prefix_attribute(
            PrefixAttributeType::PrefixMetric,
            vec![0x00, 0x00, 0x03, 0xE8],
        );
        assert_eq!(attr.get_prefix_metric(), Some(1000));
    }

    #[test]
    fn test_tlv_creation() {
        let tlv = Tlv::new(1024, vec![0x01, 0x02, 0x03]);
        assert_eq!(tlv.tlv_type, 1024);
        assert_eq!(tlv.value, vec![0x01, 0x02, 0x03]);
        assert_eq!(tlv.length(), 3);
    }

    #[test]
    #[cfg(feature = "serde")]
    fn test_serde_serialization() {
        let mut attr = LinkStateAttribute::new();
        attr.add_node_attribute(NodeAttributeType::NodeName, b"test".to_vec());

        let serialized = serde_json::to_string(&attr).unwrap();
        let deserialized: LinkStateAttribute = serde_json::from_str(&serialized).unwrap();

        assert_eq!(attr, deserialized);
    }
}
