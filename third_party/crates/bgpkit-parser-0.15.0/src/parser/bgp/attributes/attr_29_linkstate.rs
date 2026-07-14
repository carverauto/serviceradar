//! BGP Link-State attribute parsing - RFC 7752

use bytes::{Buf, BufMut, Bytes, BytesMut};
use std::net::{Ipv4Addr, Ipv6Addr};

use crate::error::ParserError;
use crate::models::*;
use crate::parser::ReadUtils;

/// Parse BGP Link-State attribute (type 29)
pub fn parse_link_state_attribute(mut data: Bytes) -> Result<AttributeValue, ParserError> {
    let mut attr = LinkStateAttribute::new();

    while data.remaining() >= 4 {
        let tlv_type = data.read_u16()?;
        let tlv_length = data.read_u16()?;

        if data.remaining() < tlv_length as usize {
            return Err(ParserError::TruncatedMsg(format!(
                "Expected {} bytes for TLV, but only {} remaining",
                tlv_length,
                data.remaining()
            )));
        }

        let tlv_data = data.read_n_bytes(tlv_length as usize)?;

        // Parse based on TLV type
        match tlv_type {
            // Node Attribute TLVs (1024-1039)
            1024..=1039 => {
                let node_attr_type = NodeAttributeType::from(tlv_type);
                if node_attr_type == NodeAttributeType::Reserved {
                    attr.add_unknown_attribute(Tlv::new(tlv_type, tlv_data.to_vec()));
                } else {
                    attr.add_node_attribute(node_attr_type, tlv_data.to_vec());
                }
            }
            // Link Attribute TLVs (1088-1103)
            1088..=1103 => {
                let link_attr_type = LinkAttributeType::from(tlv_type);
                if link_attr_type == LinkAttributeType::Reserved {
                    attr.add_unknown_attribute(Tlv::new(tlv_type, tlv_data.to_vec()));
                } else {
                    attr.add_link_attribute(link_attr_type, tlv_data.to_vec());
                }
            }
            // Link Attribute TLVs (1114-1120, 1122) - RFC 8571, RFC 9294
            1114..=1120 | 1122 => {
                let link_attr_type = LinkAttributeType::from(tlv_type);
                if link_attr_type == LinkAttributeType::Reserved {
                    attr.add_unknown_attribute(Tlv::new(tlv_type, tlv_data.to_vec()));
                } else {
                    attr.add_link_attribute(link_attr_type, tlv_data.to_vec());
                }
            }
            // Link Attribute TLVs (1172) - RFC 9085
            1172 => {
                let link_attr_type = LinkAttributeType::from(tlv_type);
                if link_attr_type == LinkAttributeType::Reserved {
                    attr.add_unknown_attribute(Tlv::new(tlv_type, tlv_data.to_vec()));
                } else {
                    attr.add_link_attribute(link_attr_type, tlv_data.to_vec());
                }
            }
            // Prefix Attribute TLVs (1152-1163, 1170-1171, 1174)
            1152..=1163 | 1170..=1171 | 1174 => {
                let prefix_attr_type = PrefixAttributeType::from(tlv_type);
                if prefix_attr_type == PrefixAttributeType::Reserved {
                    attr.add_unknown_attribute(Tlv::new(tlv_type, tlv_data.to_vec()));
                } else {
                    attr.add_prefix_attribute(prefix_attr_type, tlv_data.to_vec());
                }
            }
            // Unknown/Reserved TLVs
            _ => {
                attr.add_unknown_attribute(Tlv::new(tlv_type, tlv_data.to_vec()));
            }
        }
    }

    Ok(AttributeValue::LinkState(attr))
}

/// Parse BGP Link-State NLRI
pub fn parse_link_state_nlri(
    mut data: Bytes,
    _afi: Afi,
    safi: Safi,
    next_hop: Option<NextHopAddress>,
    is_reachable: bool,
) -> Result<Nlri, ParserError> {
    let mut nlri_list = Vec::new();

    while data.remaining() >= 4 {
        let nlri_type = data.read_u16()?;
        let nlri_len = data.read_u16()?;

        if data.remaining() < nlri_len as usize {
            return Err(ParserError::TruncatedMsg(format!(
                "Expected {} bytes for NLRI, but only {} remaining",
                nlri_len,
                data.remaining()
            )));
        }

        let nlri_data = data.read_n_bytes(nlri_len as usize)?;
        let parsed_nlri = parse_single_link_state_nlri(nlri_type, nlri_data.into())?;
        nlri_list.push(parsed_nlri);
    }

    let nlri = if is_reachable {
        Nlri::new_link_state_reachable(next_hop.map(|nh| nh.addr()), safi, nlri_list)
    } else {
        Nlri::new_link_state_unreachable(safi, nlri_list)
    };

    Ok(nlri)
}

/// Parse a single Link-State NLRI entry
fn parse_single_link_state_nlri(
    nlri_type: u16,
    mut data: Bytes,
) -> Result<LinkStateNlri, ParserError> {
    let nlri_type = NlriType::from(nlri_type);

    // Parse Protocol-ID (1 byte) and Identifier (8 bytes)
    if data.remaining() < 9 {
        return Err(ParserError::TruncatedMsg(format!(
            "Expected at least 9 bytes for Link-State NLRI header, but only {} remaining",
            data.remaining()
        )));
    }

    let protocol_id = ProtocolId::from(data.read_u8()?);
    let identifier = data.read_u64()?;

    // Parse descriptors based on NLRI type
    let (local_node_descriptors, remote_node_descriptors, link_descriptors, prefix_descriptors) =
        match nlri_type {
            NlriType::Node => {
                let local_desc = parse_node_descriptors(&mut data)?;
                (local_desc, None, None, None)
            }
            NlriType::Link => {
                let local_desc = parse_node_descriptors(&mut data)?;
                let remote_desc = parse_node_descriptors(&mut data)?;
                let link_desc = parse_link_descriptors(&mut data)?;
                (local_desc, Some(remote_desc), Some(link_desc), None)
            }
            NlriType::Ipv4TopologyPrefix | NlriType::Ipv6TopologyPrefix => {
                let local_desc = parse_node_descriptors(&mut data)?;
                let prefix_desc = parse_prefix_descriptors(&mut data)?;
                (local_desc, None, None, Some(prefix_desc))
            }
            _ => {
                // For other NLRI types, just parse local node descriptors
                let local_desc = parse_node_descriptors(&mut data)?;
                (local_desc, None, None, None)
            }
        };

    Ok(LinkStateNlri {
        nlri_type,
        protocol_id,
        identifier,
        local_node_descriptors,
        remote_node_descriptors,
        link_descriptors,
        prefix_descriptors,
    })
}

/// Parse Node Descriptor TLVs
fn parse_node_descriptors(data: &mut Bytes) -> Result<NodeDescriptor, ParserError> {
    let mut node_desc = NodeDescriptor::default();

    // Parse TLV length first
    if data.remaining() < 2 {
        return Ok(node_desc);
    }
    let desc_len = data.read_u16()?;

    if data.remaining() < desc_len as usize {
        return Err(ParserError::TruncatedMsg(format!(
            "Expected {} bytes for node descriptors, but only {} remaining",
            desc_len,
            data.remaining()
        )));
    }

    let mut desc_data: Bytes = data.read_n_bytes(desc_len as usize)?.into();

    while desc_data.remaining() >= 4 {
        let sub_tlv_type = desc_data.read_u16()?;
        let sub_tlv_len = desc_data.read_u16()?;

        if desc_data.remaining() < sub_tlv_len as usize {
            break;
        }

        let sub_tlv_data = desc_data.split_to(sub_tlv_len as usize);
        match NodeDescriptorType::from(sub_tlv_type) {
            NodeDescriptorType::AutonomousSystem => {
                if sub_tlv_len == 4 && sub_tlv_data.len() >= 4 {
                    let bytes = sub_tlv_data.as_ref();
                    node_desc.autonomous_system =
                        Some(u32::from_be_bytes([bytes[0], bytes[1], bytes[2], bytes[3]]));
                }
            }
            NodeDescriptorType::BgpLsIdentifier => {
                if sub_tlv_len == 4 && sub_tlv_data.len() >= 4 {
                    let bytes = sub_tlv_data.as_ref();
                    node_desc.bgp_ls_identifier =
                        Some(u32::from_be_bytes([bytes[0], bytes[1], bytes[2], bytes[3]]));
                }
            }
            NodeDescriptorType::OspfAreaId => {
                if sub_tlv_len == 4 && sub_tlv_data.len() >= 4 {
                    let bytes = sub_tlv_data.as_ref();
                    node_desc.ospf_area_id =
                        Some(u32::from_be_bytes([bytes[0], bytes[1], bytes[2], bytes[3]]));
                }
            }
            NodeDescriptorType::IgpRouterId => {
                node_desc.igp_router_id = Some(sub_tlv_data.to_vec());
            }
            _ => {
                node_desc
                    .unknown_tlvs
                    .push(Tlv::new(sub_tlv_type, sub_tlv_data.to_vec()));
            }
        }
    }

    Ok(node_desc)
}

/// Parse Link Descriptor TLVs
fn parse_link_descriptors(data: &mut Bytes) -> Result<LinkDescriptor, ParserError> {
    let mut link_desc = LinkDescriptor::default();

    // Parse TLV length first
    if data.remaining() < 2 {
        return Ok(link_desc);
    }
    let desc_len = data.read_u16()?;

    if data.remaining() < desc_len as usize {
        return Err(ParserError::TruncatedMsg(format!(
            "Expected {} bytes for link descriptors, but only {} remaining",
            desc_len,
            data.remaining()
        )));
    }

    let mut desc_data: Bytes = data.read_n_bytes(desc_len as usize)?.into();

    while desc_data.remaining() >= 4 {
        let sub_tlv_type = desc_data.read_u16()?;
        let sub_tlv_len = desc_data.read_u16()?;

        if desc_data.remaining() < sub_tlv_len as usize {
            break;
        }

        let sub_tlv_data = desc_data.split_to(sub_tlv_len as usize);

        match LinkDescriptorType::from(sub_tlv_type) {
            LinkDescriptorType::LinkLocalRemoteIdentifiers => {
                if sub_tlv_len == 8 && sub_tlv_data.len() >= 8 {
                    let bytes = sub_tlv_data.as_ref();
                    let local_id = u32::from_be_bytes([bytes[0], bytes[1], bytes[2], bytes[3]]);
                    let remote_id = u32::from_be_bytes([bytes[4], bytes[5], bytes[6], bytes[7]]);
                    link_desc.link_local_remote_identifiers = Some((local_id, remote_id));
                }
            }
            LinkDescriptorType::Ipv4InterfaceAddress => {
                if sub_tlv_len == 4 && sub_tlv_data.len() >= 4 {
                    let bytes = sub_tlv_data.as_ref();
                    link_desc.ipv4_interface_address =
                        Some(Ipv4Addr::new(bytes[0], bytes[1], bytes[2], bytes[3]));
                }
            }
            LinkDescriptorType::Ipv4NeighborAddress => {
                if sub_tlv_len == 4 && sub_tlv_data.len() >= 4 {
                    let bytes = sub_tlv_data.as_ref();
                    link_desc.ipv4_neighbor_address =
                        Some(Ipv4Addr::new(bytes[0], bytes[1], bytes[2], bytes[3]));
                }
            }
            LinkDescriptorType::Ipv6InterfaceAddress => {
                if sub_tlv_len == 16 && sub_tlv_data.len() >= 16 {
                    let bytes = sub_tlv_data.as_ref();
                    let mut addr_bytes = [0u8; 16];
                    addr_bytes.copy_from_slice(&bytes[..16]);
                    link_desc.ipv6_interface_address = Some(Ipv6Addr::from(addr_bytes));
                }
            }
            LinkDescriptorType::Ipv6NeighborAddress => {
                if sub_tlv_len == 16 && sub_tlv_data.len() >= 16 {
                    let bytes = sub_tlv_data.as_ref();
                    let mut addr_bytes = [0u8; 16];
                    addr_bytes.copy_from_slice(&bytes[..16]);
                    link_desc.ipv6_neighbor_address = Some(Ipv6Addr::from(addr_bytes));
                }
            }
            LinkDescriptorType::MultiTopologyId => {
                if sub_tlv_len == 2 && sub_tlv_data.len() >= 2 {
                    let bytes = sub_tlv_data.as_ref();
                    link_desc.multi_topology_id = Some(u16::from_be_bytes([bytes[0], bytes[1]]));
                }
            }
            _ => {
                link_desc
                    .unknown_tlvs
                    .push(Tlv::new(sub_tlv_type, sub_tlv_data.to_vec()));
            }
        }
    }

    Ok(link_desc)
}

/// Parse Prefix Descriptor TLVs
fn parse_prefix_descriptors(data: &mut Bytes) -> Result<PrefixDescriptor, ParserError> {
    let mut prefix_desc = PrefixDescriptor::default();

    // Parse TLV length first
    if data.remaining() < 2 {
        return Ok(prefix_desc);
    }
    let desc_len = data.read_u16()?;

    if data.remaining() < desc_len as usize {
        return Err(ParserError::TruncatedMsg(format!(
            "Expected {} bytes for prefix descriptors, but only {} remaining",
            desc_len,
            data.remaining()
        )));
    }

    let mut desc_data: Bytes = data.read_n_bytes(desc_len as usize)?.into();

    while desc_data.remaining() >= 4 {
        let sub_tlv_type = desc_data.read_u16()?;
        let sub_tlv_len = desc_data.read_u16()?;

        if desc_data.remaining() < sub_tlv_len as usize {
            break;
        }

        let sub_tlv_data = desc_data.split_to(sub_tlv_len as usize);

        match PrefixDescriptorType::from(sub_tlv_type) {
            PrefixDescriptorType::MultiTopologyId => {
                if sub_tlv_len == 2 && sub_tlv_data.len() >= 2 {
                    let bytes = sub_tlv_data.as_ref();
                    prefix_desc.multi_topology_id = Some(u16::from_be_bytes([bytes[0], bytes[1]]));
                }
            }
            PrefixDescriptorType::OspfRouteType => {
                if sub_tlv_len == 1 && !sub_tlv_data.is_empty() {
                    let bytes = sub_tlv_data.as_ref();
                    prefix_desc.ospf_route_type = Some(bytes[0]);
                }
            }
            PrefixDescriptorType::IpReachabilityInformation => {
                // Parse IP prefix from the TLV data
                if let Ok(prefix) = parse_ip_prefix_from_bytes(&sub_tlv_data) {
                    prefix_desc.ip_reachability_information = Some(prefix);
                }
            }
            _ => {
                prefix_desc
                    .unknown_tlvs
                    .push(Tlv::new(sub_tlv_type, sub_tlv_data.to_vec()));
            }
        }
    }

    Ok(prefix_desc)
}

/// Parse IP prefix from bytes (prefix length + address bytes)
fn parse_ip_prefix_from_bytes(data: &[u8]) -> Result<NetworkPrefix, ParserError> {
    if data.is_empty() {
        return Err(ParserError::TruncatedMsg("Empty prefix data".to_string()));
    }

    let prefix_len = data[0];
    let addr_bytes = &data[1..];

    if prefix_len <= 32 {
        // IPv4 prefix
        let needed_bytes = prefix_len.div_ceil(8) as usize;
        if addr_bytes.len() < needed_bytes {
            return Err(ParserError::TruncatedMsg(format!(
                "Expected {} bytes for IPv4 prefix, but only {} available",
                needed_bytes,
                addr_bytes.len()
            )));
        }

        let mut ipv4_bytes = [0u8; 4];
        ipv4_bytes[..needed_bytes.min(4)].copy_from_slice(&addr_bytes[..needed_bytes.min(4)]);
        let addr = Ipv4Addr::from(ipv4_bytes);

        let ipnet = ipnet::Ipv4Net::new(addr, prefix_len)
            .map_err(|_| ParserError::ParseError("Invalid IPv4 prefix".to_string()))?;
        Ok(NetworkPrefix::new(ipnet::IpNet::V4(ipnet), None))
    } else {
        // IPv6 prefix
        let needed_bytes = prefix_len.div_ceil(8) as usize;
        if addr_bytes.len() < needed_bytes {
            return Err(ParserError::TruncatedMsg(format!(
                "Expected {} bytes for IPv6 prefix, but only {} available",
                needed_bytes,
                addr_bytes.len()
            )));
        }

        let mut ipv6_bytes = [0u8; 16];
        ipv6_bytes[..needed_bytes.min(16)].copy_from_slice(&addr_bytes[..needed_bytes.min(16)]);
        let addr = Ipv6Addr::from(ipv6_bytes);

        let ipnet = ipnet::Ipv6Net::new(addr, prefix_len)
            .map_err(|_| ParserError::ParseError("Invalid IPv6 prefix".to_string()))?;
        Ok(NetworkPrefix::new(ipnet::IpNet::V6(ipnet), None))
    }
}

/// Encode BGP Link-State attribute
pub fn encode_link_state_attribute(attr: &LinkStateAttribute) -> Bytes {
    let mut bytes = BytesMut::new();

    // Encode node attributes
    for (attr_type, value) in &attr.node_attributes {
        let type_code = u16::from(*attr_type);
        bytes.put_u16(type_code);
        bytes.put_u16(value.len() as u16);
        bytes.extend_from_slice(value);
    }

    // Encode link attributes
    for (attr_type, value) in &attr.link_attributes {
        let type_code = u16::from(*attr_type);
        bytes.put_u16(type_code);
        bytes.put_u16(value.len() as u16);
        bytes.extend_from_slice(value);
    }

    // Encode prefix attributes
    for (attr_type, value) in &attr.prefix_attributes {
        let type_code = u16::from(*attr_type);
        bytes.put_u16(type_code);
        bytes.put_u16(value.len() as u16);
        bytes.extend_from_slice(value);
    }

    // Encode unknown attributes
    for tlv in &attr.unknown_attributes {
        bytes.put_u16(tlv.tlv_type);
        bytes.put_u16(tlv.length());
        bytes.extend_from_slice(&tlv.value);
    }

    bytes.freeze()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_parse_node_descriptors() {
        let mut data = BytesMut::new();
        // Length = 16 bytes (8 + 8) = 2 TLVs with headers and data
        data.put_u16(16);
        // AS Number TLV (512)
        data.put_u16(512);
        data.put_u16(4);
        data.put_u32(65001);
        // OSPF Area ID TLV (514)
        data.put_u16(514);
        data.put_u16(4);
        data.put_u32(0);

        let mut bytes = data.freeze();
        let result = parse_node_descriptors(&mut bytes).unwrap();

        assert_eq!(result.autonomous_system, Some(65001));
        assert_eq!(result.ospf_area_id, Some(0));
    }

    #[test]
    fn test_parse_link_descriptors() {
        let mut data = BytesMut::new();
        // Length = 12 bytes
        data.put_u16(12);
        // Link Local/Remote Identifiers TLV (258)
        data.put_u16(258);
        data.put_u16(8);
        data.put_u32(1); // Local ID
        data.put_u32(2); // Remote ID

        let mut bytes = data.freeze();
        let result = parse_link_descriptors(&mut bytes).unwrap();

        assert_eq!(result.link_local_remote_identifiers, Some((1, 2)));
    }

    #[test]
    fn test_parse_ip_prefix_from_bytes() {
        // Test IPv4 prefix 192.168.1.0/24
        let data = vec![24, 192, 168, 1];
        let result = parse_ip_prefix_from_bytes(&data).unwrap();

        match result.prefix {
            ipnet::IpNet::V4(net) => {
                assert_eq!(net.addr(), std::net::Ipv4Addr::new(192, 168, 1, 0));
                assert_eq!(net.prefix_len(), 24);
            }
            _ => panic!("Expected IPv4 prefix"),
        }
    }

    #[test]
    fn test_link_state_attribute_encoding() {
        let mut attr = LinkStateAttribute::new();
        attr.add_node_attribute(NodeAttributeType::NodeName, b"router1".to_vec());

        let encoded = encode_link_state_attribute(&attr);
        assert!(!encoded.is_empty());

        // Should contain the node name TLV
        // Type (1026) + Length (7) + "router1"
        assert!(encoded.len() >= 11);
    }
}
