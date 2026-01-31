use crate::error::ConversionError;
use anyhow::Result;
use log::debug;
use netflow_parser::NetflowPacket;
use netflow_parser::static_versions::v5::V5;
use netflow_parser::variable_versions::data_number::FieldValue;
use netflow_parser::variable_versions::ipfix_lookup::{IANAIPFixField, IPFixField};
use netflow_parser::variable_versions::v9_lookup::V9Field;
use std::net::{IpAddr, SocketAddr};

// Include generated protobuf code
pub mod flowpb {
    include!(concat!(env!("OUT_DIR"), "/flowpb.rs"));
}

pub struct Converter {
    pub packet: NetflowPacket,
    sampler_addr: SocketAddr,
    receive_time_ns: u64,
}

impl Converter {
    pub fn new(packet: NetflowPacket, sampler_addr: SocketAddr, receive_time_ns: u64) -> Self {
        Self {
            packet,
            sampler_addr,
            receive_time_ns,
        }
    }

    pub fn convert_v5(&self, packet: &V5) -> Result<Vec<flowpb::FlowMessage>, ConversionError> {
        let mut messages = Vec::with_capacity(packet.flowsets.len());

        for flow in &packet.flowsets {
            let mut msg = flowpb::FlowMessage {
                r#type: i32::from(flowpb::flow_message::FlowType::NetflowV5),
                time_received_ns: self.receive_time_ns,
                sampler_address: ip_to_bytes(&self.sampler_addr.ip()),
                sequence_num: packet.header.flow_sequence,
                ..Default::default()
            };

            // Source/destination addresses
            msg.src_addr = flow.src_addr.octets().to_vec();
            msg.dst_addr = flow.dst_addr.octets().to_vec();

            // Ports
            msg.src_port = u32::from(flow.src_port);
            msg.dst_port = u32::from(flow.dst_port);

            // Protocol
            msg.proto = u32::from(flow.protocol_number);

            // Bytes and packets
            msg.bytes = u64::from(flow.d_octets);
            msg.packets = u64::from(flow.d_pkts);

            // Timestamps (convert Unix seconds to nanoseconds)
            let uptime_ms = packet.header.sys_up_time;
            let unix_secs = packet.header.unix_secs;
            let unix_nsecs = packet.header.unix_nsecs;

            let base_time_ns = (u64::from(unix_secs))
                .checked_mul(1_000_000_000)
                .and_then(|secs_ns| secs_ns.checked_add(u64::from(unix_nsecs)))
                .unwrap_or(0);
            msg.time_flow_start_ns = calculate_flow_time(base_time_ns, uptime_ms, flow.first);
            msg.time_flow_end_ns = calculate_flow_time(base_time_ns, uptime_ms, flow.last);

            // Interfaces
            msg.in_if = u32::from(flow.input);
            msg.out_if = u32::from(flow.output);

            // Next hop
            msg.next_hop = flow.next_hop.octets().to_vec();

            // AS numbers
            msg.src_as = u32::from(flow.src_as);
            msg.dst_as = u32::from(flow.dst_as);

            // TCP flags
            msg.tcp_flags = u32::from(flow.tcp_flags);

            // IP ToS
            msg.ip_tos = u32::from(flow.tos);

            // Prefix masks
            msg.src_net = u32::from(flow.src_mask);
            msg.dst_net = u32::from(flow.dst_mask);

            messages.push(msg);
        }

        Ok(messages)
    }

    pub fn convert_v9(
        &self,
        packet: &netflow_parser::variable_versions::v9::V9,
    ) -> Result<Vec<flowpb::FlowMessage>, ConversionError> {
        use netflow_parser::variable_versions::v9::FlowSetBody;

        let mut messages = Vec::new();

        for flowset in &packet.flowsets {
            if let FlowSetBody::Data(data) = &flowset.body {
                for fields in &data.fields {
                    let mut msg = flowpb::FlowMessage {
                        r#type: i32::from(flowpb::flow_message::FlowType::NetflowV9),
                        time_received_ns: self.receive_time_ns,
                        sampler_address: ip_to_bytes(&self.sampler_addr.ip()),
                        sequence_num: packet.header.sequence_number,
                        ..Default::default()
                    };

                    // Extract fields using helper
                    for (field_type, field_value) in fields {
                        match field_type {
                            // IP Addresses - prefer IPv4, fallback handled separately
                            V9Field::Ipv4SrcAddr => {
                                if msg.src_addr.is_empty() {
                                    msg.src_addr = field_value_to_ip_bytes(field_value);
                                }
                            }
                            V9Field::Ipv6SrcAddr => {
                                if msg.src_addr.is_empty() {
                                    msg.src_addr = field_value_to_ip_bytes(field_value);
                                }
                            }
                            V9Field::Ipv4DstAddr => {
                                if msg.dst_addr.is_empty() {
                                    msg.dst_addr = field_value_to_ip_bytes(field_value);
                                }
                            }
                            V9Field::Ipv6DstAddr => {
                                if msg.dst_addr.is_empty() {
                                    msg.dst_addr = field_value_to_ip_bytes(field_value);
                                }
                            }

                            // Ports
                            V9Field::L4SrcPort => msg.src_port = field_value_to_u32(field_value),
                            V9Field::L4DstPort => msg.dst_port = field_value_to_u32(field_value),

                            // Protocol
                            V9Field::Protocol => msg.proto = field_value_to_u32(field_value),

                            // Volume
                            V9Field::InBytes => msg.bytes = field_value_to_u64(field_value),
                            V9Field::InPkts => msg.packets = field_value_to_u64(field_value),

                            // Timing (relative to uptime)
                            V9Field::FirstSwitched => {
                                let flow_uptime = field_value_to_u32(field_value);
                                let uptime_ms = packet.header.sys_up_time;
                                let unix_secs = packet.header.unix_secs;
                                let base_time_ns = (u64::from(unix_secs))
                                    .checked_mul(1_000_000_000)
                                    .unwrap_or(0);
                                msg.time_flow_start_ns =
                                    calculate_flow_time(base_time_ns, uptime_ms, flow_uptime);
                            }
                            V9Field::LastSwitched => {
                                let flow_uptime = field_value_to_u32(field_value);
                                let uptime_ms = packet.header.sys_up_time;
                                let unix_secs = packet.header.unix_secs;
                                let base_time_ns = (u64::from(unix_secs))
                                    .checked_mul(1_000_000_000)
                                    .unwrap_or(0);
                                msg.time_flow_end_ns =
                                    calculate_flow_time(base_time_ns, uptime_ms, flow_uptime);
                            }

                            // Interfaces
                            V9Field::InputSnmp => msg.in_if = field_value_to_u32(field_value),
                            V9Field::OutputSnmp => msg.out_if = field_value_to_u32(field_value),

                            // MAC addresses
                            V9Field::InSrcMac => msg.src_mac = field_value_to_mac_u64(field_value),
                            V9Field::InDstMac | V9Field::OutDstMac => {
                                if msg.dst_mac == 0 {
                                    msg.dst_mac = field_value_to_mac_u64(field_value);
                                }
                            }

                            // AS numbers
                            V9Field::SrcAs => msg.src_as = field_value_to_u32(field_value),
                            V9Field::DstAs => msg.dst_as = field_value_to_u32(field_value),

                            // Next hop
                            V9Field::Ipv4NextHop => {
                                if msg.next_hop.is_empty() {
                                    msg.next_hop = field_value_to_ip_bytes(field_value);
                                }
                            }
                            V9Field::Ipv6NextHop => {
                                if msg.next_hop.is_empty() {
                                    msg.next_hop = field_value_to_ip_bytes(field_value);
                                }
                            }

                            // Network masks
                            V9Field::SrcMask => msg.src_net = field_value_to_u32(field_value),
                            V9Field::DstMask => msg.dst_net = field_value_to_u32(field_value),
                            V9Field::Ipv6SrcMask => {
                                if msg.src_net == 0 {
                                    msg.src_net = field_value_to_u32(field_value);
                                }
                            }
                            V9Field::Ipv6DstMask => {
                                if msg.dst_net == 0 {
                                    msg.dst_net = field_value_to_u32(field_value);
                                }
                            }

                            // Flags and ToS
                            V9Field::TcpFlags => msg.tcp_flags = field_value_to_u32(field_value),
                            V9Field::SrcTos => msg.ip_tos = field_value_to_u32(field_value),

                            // VLAN
                            V9Field::SrcVlan => msg.src_vlan = field_value_to_u32(field_value),
                            V9Field::DstVlan => msg.dst_vlan = field_value_to_u32(field_value),

                            // IPv6 Flow Label
                            V9Field::Ipv6FlowLabel => {
                                msg.ipv6_flow_label = field_value_to_u32(field_value)
                            }

                            // ICMP
                            V9Field::IcmpType => {
                                // ICMP type/code are combined in one field sometimes
                                let val = field_value_to_u32(field_value);
                                msg.icmp_type = (val >> 8) & 0xFF;
                                msg.icmp_code = val & 0xFF;
                            }

                            _ => {
                                // Ignore unhandled fields for now
                            }
                        }
                    }

                    messages.push(msg);
                }
            }
        }

        Ok(messages)
    }

    pub fn convert_ipfix(
        &self,
        packet: &netflow_parser::variable_versions::ipfix::IPFix,
    ) -> Result<Vec<flowpb::FlowMessage>, ConversionError> {
        use netflow_parser::variable_versions::ipfix::FlowSetBody;

        let mut messages = Vec::new();

        for flowset in &packet.flowsets {
            if let FlowSetBody::Data(data) = &flowset.body {
                for fields in &data.fields {
                    let mut msg = flowpb::FlowMessage {
                        r#type: i32::from(flowpb::flow_message::FlowType::Ipfix),
                        time_received_ns: self.receive_time_ns,
                        sampler_address: ip_to_bytes(&self.sampler_addr.ip()),
                        sequence_num: packet.header.sequence_number,
                        observation_domain_id: packet.header.observation_domain_id,
                        ..Default::default()
                    };

                    // Extract fields
                    for (field_type, field_value) in fields {
                        match field_type {
                            // IP Addresses - prefer IPv4, fallback to IPv6
                            IPFixField::IANA(IANAIPFixField::SourceIpv4address) => {
                                if msg.src_addr.is_empty() {
                                    msg.src_addr = field_value_to_ip_bytes(field_value);
                                }
                            }
                            IPFixField::IANA(IANAIPFixField::SourceIpv6address) => {
                                if msg.src_addr.is_empty() {
                                    msg.src_addr = field_value_to_ip_bytes(field_value);
                                }
                            }
                            IPFixField::IANA(IANAIPFixField::DestinationIpv4address) => {
                                if msg.dst_addr.is_empty() {
                                    msg.dst_addr = field_value_to_ip_bytes(field_value);
                                }
                            }
                            IPFixField::IANA(IANAIPFixField::DestinationIpv6address) => {
                                if msg.dst_addr.is_empty() {
                                    msg.dst_addr = field_value_to_ip_bytes(field_value);
                                }
                            }

                            // Ports
                            IPFixField::IANA(IANAIPFixField::SourceTransportPort) => {
                                msg.src_port = field_value_to_u32(field_value)
                            }
                            IPFixField::IANA(IANAIPFixField::DestinationTransportPort) => {
                                msg.dst_port = field_value_to_u32(field_value)
                            }

                            // Protocol
                            IPFixField::IANA(IANAIPFixField::ProtocolIdentifier) => {
                                msg.proto = field_value_to_u32(field_value)
                            }

                            // Volume - prefer Delta counts
                            IPFixField::IANA(IANAIPFixField::OctetDeltaCount) => {
                                msg.bytes = field_value_to_u64(field_value)
                            }
                            IPFixField::IANA(IANAIPFixField::OctetTotalCount) => {
                                if msg.bytes == 0 {
                                    msg.bytes = field_value_to_u64(field_value)
                                }
                            }
                            IPFixField::IANA(IANAIPFixField::PacketDeltaCount) => {
                                msg.packets = field_value_to_u64(field_value)
                            }
                            IPFixField::IANA(IANAIPFixField::PacketTotalCount) => {
                                if msg.packets == 0 {
                                    msg.packets = field_value_to_u64(field_value)
                                }
                            }

                            // Timing - handle both absolute and relative timestamps
                            IPFixField::IANA(IANAIPFixField::FlowStartMilliseconds) => {
                                msg.time_flow_start_ns = field_value_to_u64(field_value)
                                    .checked_mul(1_000_000)
                                    .unwrap_or(0);
                            }
                            IPFixField::IANA(IANAIPFixField::FlowStartSysUpTime) => {
                                if msg.time_flow_start_ns == 0 {
                                    let flow_uptime = field_value_to_u32(field_value);
                                    let export_time = packet.header.export_time;
                                    let base_time_ns = (u64::from(export_time))
                                        .checked_mul(1_000_000_000)
                                        .unwrap_or(0);
                                    // Note: For IPFIX, we'd need system uptime from the header
                                    // For now, use a simplified calculation
                                    msg.time_flow_start_ns = base_time_ns.saturating_sub(
                                        (u64::from(flow_uptime)).saturating_mul(1_000_000),
                                    );
                                }
                            }
                            IPFixField::IANA(IANAIPFixField::FlowEndMilliseconds) => {
                                msg.time_flow_end_ns = field_value_to_u64(field_value)
                                    .checked_mul(1_000_000)
                                    .unwrap_or(0);
                            }
                            IPFixField::IANA(IANAIPFixField::FlowEndSysUpTime) => {
                                if msg.time_flow_end_ns == 0 {
                                    let flow_uptime = field_value_to_u32(field_value);
                                    let export_time = packet.header.export_time;
                                    let base_time_ns = (u64::from(export_time))
                                        .checked_mul(1_000_000_000)
                                        .unwrap_or(0);
                                    msg.time_flow_end_ns = base_time_ns.saturating_sub(
                                        (u64::from(flow_uptime)).saturating_mul(1_000_000),
                                    );
                                }
                            }

                            // Interfaces
                            IPFixField::IANA(IANAIPFixField::IngressInterface) => {
                                msg.in_if = field_value_to_u32(field_value)
                            }
                            IPFixField::IANA(IANAIPFixField::EgressInterface) => {
                                msg.out_if = field_value_to_u32(field_value)
                            }

                            // MAC addresses
                            IPFixField::IANA(IANAIPFixField::SourceMacaddress) => {
                                msg.src_mac = field_value_to_mac_u64(field_value)
                            }
                            IPFixField::IANA(IANAIPFixField::DestinationMacaddress) => {
                                msg.dst_mac = field_value_to_mac_u64(field_value)
                            }

                            // AS numbers
                            IPFixField::IANA(IANAIPFixField::BgpSourceAsNumber) => {
                                msg.src_as = field_value_to_u32(field_value)
                            }
                            IPFixField::IANA(IANAIPFixField::BgpDestinationAsNumber) => {
                                msg.dst_as = field_value_to_u32(field_value)
                            }
                            IPFixField::IANA(IANAIPFixField::BgpNextAdjacentAsNumber) => {
                                msg.next_hop_as = field_value_to_u32(field_value)
                            }

                            // Next hop
                            IPFixField::IANA(IANAIPFixField::IpNextHopIpv4address) => {
                                if msg.next_hop.is_empty() {
                                    msg.next_hop = field_value_to_ip_bytes(field_value);
                                }
                            }
                            IPFixField::IANA(IANAIPFixField::IpNextHopIpv6address) => {
                                if msg.next_hop.is_empty() {
                                    msg.next_hop = field_value_to_ip_bytes(field_value);
                                }
                            }
                            IPFixField::IANA(IANAIPFixField::BgpNextHopIpv4address) => {
                                msg.bgp_next_hop = field_value_to_ip_bytes(field_value);
                            }
                            IPFixField::IANA(IANAIPFixField::BgpNextHopIpv6address) => {
                                if msg.bgp_next_hop.is_empty() {
                                    msg.bgp_next_hop = field_value_to_ip_bytes(field_value);
                                }
                            }

                            // Network masks / prefix lengths
                            IPFixField::IANA(IANAIPFixField::SourceIpv4prefixLength) => {
                                msg.src_net = field_value_to_u32(field_value)
                            }
                            IPFixField::IANA(IANAIPFixField::DestinationIpv4prefixLength) => {
                                msg.dst_net = field_value_to_u32(field_value)
                            }
                            IPFixField::IANA(IANAIPFixField::SourceIpv6prefixLength) => {
                                if msg.src_net == 0 {
                                    msg.src_net = field_value_to_u32(field_value)
                                }
                            }
                            IPFixField::IANA(IANAIPFixField::DestinationIpv6prefixLength) => {
                                if msg.dst_net == 0 {
                                    msg.dst_net = field_value_to_u32(field_value)
                                }
                            }

                            // Flags and ToS
                            IPFixField::IANA(IANAIPFixField::TcpControlBits) => {
                                msg.tcp_flags = field_value_to_u32(field_value)
                            }
                            IPFixField::IANA(IANAIPFixField::IpClassOfService) => {
                                msg.ip_tos = field_value_to_u32(field_value)
                            }
                            IPFixField::IANA(IANAIPFixField::MinimumTtl) => {
                                msg.ip_ttl = field_value_to_u32(field_value)
                            }
                            IPFixField::IANA(IANAIPFixField::MaximumTtl) => {
                                if msg.ip_ttl == 0 {
                                    msg.ip_ttl = field_value_to_u32(field_value)
                                }
                            }

                            // VLAN
                            IPFixField::IANA(IANAIPFixField::VlanId) => {
                                msg.vlan_id = field_value_to_u32(field_value)
                            }
                            IPFixField::IANA(IANAIPFixField::Dot1qVlanId) => {
                                msg.src_vlan = field_value_to_u32(field_value)
                            }
                            IPFixField::IANA(IANAIPFixField::PostDot1qVlanId) => {
                                msg.dst_vlan = field_value_to_u32(field_value)
                            }

                            // IPv6 Flow Label
                            IPFixField::IANA(IANAIPFixField::FlowLabelIpv6) => {
                                msg.ipv6_flow_label = field_value_to_u32(field_value)
                            }

                            // ICMP
                            IPFixField::IANA(IANAIPFixField::IcmpTypeCodeIpv4) => {
                                let val = field_value_to_u32(field_value);
                                msg.icmp_type = (val >> 8) & 0xFF;
                                msg.icmp_code = val & 0xFF;
                            }
                            IPFixField::IANA(IANAIPFixField::IcmpTypeCodeIpv6) => {
                                if msg.icmp_type == 0 && msg.icmp_code == 0 {
                                    let val = field_value_to_u32(field_value);
                                    msg.icmp_type = (val >> 8) & 0xFF;
                                    msg.icmp_code = val & 0xFF;
                                }
                            }

                            _ => {
                                // Ignore unhandled fields
                                debug!("Unhandled IPFIX field: {:?}", field_type);
                            }
                        }
                    }

                    messages.push(msg);
                }
            }
        }

        Ok(messages)
    }
}

// Helper functions

fn ip_to_bytes(ip: &IpAddr) -> Vec<u8> {
    match ip {
        IpAddr::V4(addr) => addr.octets().to_vec(),
        IpAddr::V6(addr) => addr.octets().to_vec(),
    }
}

fn mac_to_u64(mac: &[u8]) -> u64 {
    let mut result = 0u64;
    for (i, &byte) in mac.iter().take(6).enumerate() {
        result |= (u64::from(byte)) << (40 - i * 8);
    }
    result
}

fn calculate_flow_time(base_time_ns: u64, sys_uptime_ms: u32, flow_uptime_ms: u32) -> u64 {
    // Calculate the flow timestamp based on system uptime and flow uptime
    if sys_uptime_ms >= flow_uptime_ms {
        let offset_ms = u64::from(sys_uptime_ms.saturating_sub(flow_uptime_ms));
        base_time_ns.saturating_sub(offset_ms.saturating_mul(1_000_000))
    } else {
        // Handle uptime wrap-around (uptime counter reset)
        base_time_ns
    }
}

// Field value conversion helpers
fn field_value_to_ip_bytes(value: &FieldValue) -> Vec<u8> {
    match value {
        FieldValue::Ip4Addr(addr) => addr.octets().to_vec(),
        FieldValue::Ip6Addr(addr) => addr.octets().to_vec(),
        _ => vec![],
    }
}

fn field_value_to_u32(value: &FieldValue) -> u32 {
    value.try_into().unwrap_or_default()
}

fn field_value_to_u64(value: &FieldValue) -> u64 {
    value.try_into().unwrap_or_default()
}

fn field_value_to_mac_u64(value: &FieldValue) -> u64 {
    match value {
        FieldValue::MacAddr(mac_str) => {
            // Parse MAC address string like "00:11:22:33:44:55"
            let bytes: Vec<u8> = mac_str
                .split(':')
                .filter_map(|s| u8::from_str_radix(s, 16).ok())
                .collect();
            mac_to_u64(&bytes)
        }
        _ => 0,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_mac_to_u64() {
        let mac = [0x00, 0x11, 0x22, 0x33, 0x44, 0x55];
        let result = mac_to_u64(&mac);
        assert_eq!(result, 0x001122334455);
    }

    #[test]
    fn test_calculate_flow_time() {
        let base = 1_000_000_000_000; // 1 second in nanoseconds
        let sys_uptime = 10000; // 10 seconds
        let flow_uptime = 5000; // 5 seconds

        let result = calculate_flow_time(base, sys_uptime, flow_uptime);
        // Should be 5 seconds before base time
        assert_eq!(result, base - 5_000_000_000);
    }

    #[test]
    fn test_ip_to_bytes_v4() {
        let ip = IpAddr::V4([192, 168, 1, 1].into());
        let bytes = ip_to_bytes(&ip);
        assert_eq!(bytes, vec![192, 168, 1, 1]);
    }
}
