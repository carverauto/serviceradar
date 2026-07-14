//! BGP Tunnel Encapsulation data structures based on RFC 9012

use num_enum::{FromPrimitive, IntoPrimitive};
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr};

/// BGP Tunnel Encapsulation Types as defined in RFC 9012 and IANA registry
#[derive(Debug, PartialEq, Eq, Hash, Copy, Clone, FromPrimitive, IntoPrimitive)]
#[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
#[repr(u16)]
pub enum TunnelType {
    #[num_enum(default)]
    Reserved = 0,
    /// L2TPv3 over IP
    L2tpv3OverIp = 1,
    /// GRE
    Gre = 2,
    /// Transmit tunnel endpoint (DEPRECATED)
    TransmitTunnelEndpoint = 3,
    /// IPsec in Tunnel-mode (DEPRECATED)
    IpsecTunnelMode = 4,
    /// IP in IP tunnel with IPsec Transport Mode
    IpInIpWithIpsecTransport = 5,
    /// MPLS-in-IP tunnel with IPsec Transport Mode
    MplsInIpWithIpsecTransport = 6,
    /// IP in IP
    IpInIp = 7,
    /// VXLAN Encapsulation
    Vxlan = 8,
    /// NVGRE Encapsulation
    Nvgre = 9,
    /// MPLS Encapsulation
    Mpls = 10,
    /// MPLS in GRE Encapsulation
    MplsInGre = 11,
    /// VXLAN GPE Encapsulation
    VxlanGpe = 12,
    /// MPLS in UDP Encapsulation
    MplsInUdp = 13,
    /// IPv6 Tunnel
    Ipv6Tunnel = 14,
    /// SR Policy
    SrPolicy = 15,
    /// Bare
    Bare = 16,
    /// SR Tunnel (DEPRECATED)
    SrTunnel = 17,
    /// Cloud Security
    CloudSecurity = 18,
    /// Geneve Encapsulation
    Geneve = 19,
    /// Any Encapsulation
    AnyEncapsulation = 20,
    /// GTP Tunnel Type
    GtpTunnel = 21,
    /// Dynamic Path Selection (DPS) Tunnel Encapsulation
    DpsTunnel = 22,
}

/// BGP Tunnel Encapsulation Sub-TLV Types
#[derive(Debug, PartialEq, Eq, Hash, Copy, Clone, FromPrimitive, IntoPrimitive)]
#[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
#[repr(u16)]
pub enum SubTlvType {
    #[num_enum(default)]
    Reserved = 0,
    /// Encapsulation Sub-TLV
    Encapsulation = 1,
    /// Protocol Type Sub-TLV
    ProtocolType = 2,
    /// IPsec Tunnel Authenticator Sub-TLV (DEPRECATED)
    IpsecTunnelAuthenticator = 3,
    /// Color Sub-TLV
    Color = 4,
    /// Load-Balancing Block Sub-TLV
    LoadBalancingBlock = 5,
    /// Tunnel Egress Endpoint Sub-TLV
    TunnelEgressEndpoint = 6,
    /// DS Field Sub-TLV
    DsField = 7,
    /// UDP Destination Port Sub-TLV
    UdpDestinationPort = 8,
    /// Embedded Label Handling Sub-TLV
    EmbeddedLabelHandling = 9,
    /// MPLS Label Stack Sub-TLV
    MplsLabelStack = 10,
    /// Prefix-SID Sub-TLV
    PrefixSid = 11,
    /// Preference Sub-TLV
    Preference = 12,
    /// Binding SID Sub-TLV
    BindingSid = 13,
    /// ENLP Sub-TLV
    Enlp = 14,
    /// Priority Sub-TLV
    Priority = 15,
    /// SPI/SI Representation Sub-TLV
    SpiSiRepresentation = 16,
    /// IPv6 SID Structure Sub-TLV
    Ipv6SidStructure = 17,
    /// IPv4 SID Sub-TLV
    Ipv4Sid = 18,
    /// IPv6 SID Sub-TLV
    Ipv6Sid = 19,
    /// SRv6 Binding SID Sub-TLV
    Srv6BindingSid = 20,
    /// Segment List Sub-TLV
    SegmentList = 128,
    /// Policy Candidate Path Name Sub-TLV
    PolicyCandidatePathName = 129,
}

/// Sub-TLV structure for Tunnel Encapsulation
#[derive(Debug, PartialEq, Clone, Eq)]
#[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
pub struct SubTlv {
    pub sub_tlv_type: SubTlvType,
    pub value: Vec<u8>,
}

impl SubTlv {
    pub fn new(sub_tlv_type: SubTlvType, value: Vec<u8>) -> Self {
        Self {
            sub_tlv_type,
            value,
        }
    }

    pub fn length(&self) -> u16 {
        self.value.len() as u16
    }
}

/// Tunnel Encapsulation TLV
#[derive(Debug, PartialEq, Clone, Eq)]
#[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
pub struct TunnelEncapTlv {
    pub tunnel_type: TunnelType,
    pub sub_tlvs: Vec<SubTlv>,
}

impl TunnelEncapTlv {
    pub fn new(tunnel_type: TunnelType) -> Self {
        Self {
            tunnel_type,
            sub_tlvs: Vec::new(),
        }
    }

    pub fn add_sub_tlv(&mut self, sub_tlv: SubTlv) {
        self.sub_tlvs.push(sub_tlv);
    }

    /// Get the tunnel egress endpoint if present
    pub fn get_tunnel_egress_endpoint(&self) -> Option<IpAddr> {
        self.sub_tlvs
            .iter()
            .find(|tlv| tlv.sub_tlv_type == SubTlvType::TunnelEgressEndpoint)
            .and_then(|tlv| match tlv.value.len() {
                4 => {
                    let bytes = &tlv.value[0..4];
                    Some(IpAddr::V4(Ipv4Addr::new(
                        bytes[0], bytes[1], bytes[2], bytes[3],
                    )))
                }
                16 => {
                    let mut bytes = [0u8; 16];
                    bytes.copy_from_slice(&tlv.value[0..16]);
                    Some(IpAddr::V6(Ipv6Addr::from(bytes)))
                }
                _ => None,
            })
    }

    /// Get the color value if present
    pub fn get_color(&self) -> Option<u32> {
        self.sub_tlvs
            .iter()
            .find(|tlv| tlv.sub_tlv_type == SubTlvType::Color)
            .and_then(|tlv| {
                if tlv.value.len() >= 4 {
                    Some(u32::from_be_bytes([
                        tlv.value[0],
                        tlv.value[1],
                        tlv.value[2],
                        tlv.value[3],
                    ]))
                } else {
                    None
                }
            })
    }

    /// Get the UDP destination port if present
    pub fn get_udp_destination_port(&self) -> Option<u16> {
        self.sub_tlvs
            .iter()
            .find(|tlv| tlv.sub_tlv_type == SubTlvType::UdpDestinationPort)
            .and_then(|tlv| {
                if tlv.value.len() >= 2 {
                    Some(u16::from_be_bytes([tlv.value[0], tlv.value[1]]))
                } else {
                    None
                }
            })
    }

    /// Get the preference value if present
    pub fn get_preference(&self) -> Option<u32> {
        self.sub_tlvs
            .iter()
            .find(|tlv| tlv.sub_tlv_type == SubTlvType::Preference)
            .and_then(|tlv| {
                if tlv.value.len() >= 4 {
                    Some(u32::from_be_bytes([
                        tlv.value[0],
                        tlv.value[1],
                        tlv.value[2],
                        tlv.value[3],
                    ]))
                } else {
                    None
                }
            })
    }
}

/// BGP Tunnel Encapsulation Attribute
#[derive(Debug, PartialEq, Clone, Eq, Default)]
#[cfg_attr(feature = "serde", derive(serde::Serialize, serde::Deserialize))]
pub struct TunnelEncapAttribute {
    pub tunnel_tlvs: Vec<TunnelEncapTlv>,
}

impl TunnelEncapAttribute {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn add_tunnel_tlv(&mut self, tlv: TunnelEncapTlv) {
        self.tunnel_tlvs.push(tlv);
    }

    /// Get all tunnel TLVs of a specific type
    pub fn get_tunnels_by_type(&self, tunnel_type: TunnelType) -> Vec<&TunnelEncapTlv> {
        self.tunnel_tlvs
            .iter()
            .filter(|tlv| tlv.tunnel_type == tunnel_type)
            .collect()
    }

    /// Check if the attribute contains any tunnel of the specified type
    pub fn has_tunnel_type(&self, tunnel_type: TunnelType) -> bool {
        self.tunnel_tlvs
            .iter()
            .any(|tlv| tlv.tunnel_type == tunnel_type)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_tunnel_type_conversion() {
        assert_eq!(TunnelType::Vxlan as u16, 8);
        assert_eq!(TunnelType::Nvgre as u16, 9);
        assert_eq!(TunnelType::SrPolicy as u16, 15);
        assert_eq!(TunnelType::Geneve as u16, 19);
    }

    #[test]
    fn test_sub_tlv_type_conversion() {
        assert_eq!(SubTlvType::Color as u16, 4);
        assert_eq!(SubTlvType::TunnelEgressEndpoint as u16, 6);
        assert_eq!(SubTlvType::UdpDestinationPort as u16, 8);
        assert_eq!(SubTlvType::SegmentList as u16, 128);
    }

    #[test]
    fn test_tunnel_encap_tlv_creation() {
        let mut tlv = TunnelEncapTlv::new(TunnelType::Vxlan);

        // Add a color sub-TLV
        let color_sub_tlv = SubTlv::new(SubTlvType::Color, vec![0x00, 0x00, 0x00, 0x64]); // color 100
        tlv.add_sub_tlv(color_sub_tlv);

        // Add a UDP port sub-TLV
        let udp_port_sub_tlv = SubTlv::new(SubTlvType::UdpDestinationPort, vec![0x12, 0xB5]); // port 4789
        tlv.add_sub_tlv(udp_port_sub_tlv);

        assert_eq!(tlv.tunnel_type, TunnelType::Vxlan);
        assert_eq!(tlv.sub_tlvs.len(), 2);
        assert_eq!(tlv.get_color(), Some(100));
        assert_eq!(tlv.get_udp_destination_port(), Some(4789));
    }

    #[test]
    fn test_tunnel_encap_attribute() {
        let mut attr = TunnelEncapAttribute::new();

        let mut vxlan_tlv = TunnelEncapTlv::new(TunnelType::Vxlan);
        vxlan_tlv.add_sub_tlv(SubTlv::new(SubTlvType::Color, vec![0x00, 0x00, 0x00, 0x64]));

        let mut gre_tlv = TunnelEncapTlv::new(TunnelType::Gre);
        gre_tlv.add_sub_tlv(SubTlv::new(SubTlvType::Color, vec![0x00, 0x00, 0x00, 0xC8]));

        attr.add_tunnel_tlv(vxlan_tlv);
        attr.add_tunnel_tlv(gre_tlv);

        assert_eq!(attr.tunnel_tlvs.len(), 2);
        assert!(attr.has_tunnel_type(TunnelType::Vxlan));
        assert!(attr.has_tunnel_type(TunnelType::Gre));
        assert!(!attr.has_tunnel_type(TunnelType::Nvgre));

        let vxlan_tunnels = attr.get_tunnels_by_type(TunnelType::Vxlan);
        assert_eq!(vxlan_tunnels.len(), 1);
        assert_eq!(vxlan_tunnels[0].get_color(), Some(100));
    }

    #[test]
    fn test_tunnel_egress_endpoint_parsing() {
        let mut tlv = TunnelEncapTlv::new(TunnelType::Vxlan);

        // Test IPv4 egress endpoint
        let ipv4_endpoint = SubTlv::new(
            SubTlvType::TunnelEgressEndpoint,
            vec![192, 168, 1, 1], // 192.168.1.1
        );
        tlv.add_sub_tlv(ipv4_endpoint);

        if let Some(IpAddr::V4(addr)) = tlv.get_tunnel_egress_endpoint() {
            assert_eq!(addr, Ipv4Addr::new(192, 168, 1, 1));
        } else {
            panic!("Expected IPv4 address");
        }
    }

    #[test]
    fn test_sub_tlv_length() {
        let sub_tlv = SubTlv::new(SubTlvType::Color, vec![0x00, 0x00, 0x00, 0x64]);
        assert_eq!(sub_tlv.length(), 4);
    }

    #[test]
    #[cfg(feature = "serde")]
    fn test_serde_serialization() {
        let mut attr = TunnelEncapAttribute::new();
        let mut tlv = TunnelEncapTlv::new(TunnelType::Vxlan);
        tlv.add_sub_tlv(SubTlv::new(SubTlvType::Color, vec![0x00, 0x00, 0x00, 0x64]));
        attr.add_tunnel_tlv(tlv);

        let serialized = serde_json::to_string(&attr).unwrap();
        let deserialized: TunnelEncapAttribute = serde_json::from_str(&serialized).unwrap();

        assert_eq!(attr, deserialized);
    }
}
