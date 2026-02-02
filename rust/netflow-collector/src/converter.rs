use crate::error::ConversionError;
use anyhow::Result;
use log::debug;
use netflow_parser::NetflowPacket;
use netflow_parser::protocol::ProtocolTypes;
use netflow_parser::static_versions::v5::V5;
use netflow_parser::variable_versions::data_number::{DataNumber, FieldValue};
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
            msg.protocol_name = protocol_type_name(ProtocolTypes::from(flow.protocol_number));

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
                            V9Field::Protocol => {
                                msg.proto = field_value_to_u32(field_value);
                                msg.protocol_name = field_value_to_protocol_name(field_value);
                            }

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
                                msg.proto = field_value_to_u32(field_value);
                                msg.protocol_name = field_value_to_protocol_name(field_value);
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

fn data_number_to_u32(dn: &DataNumber) -> u32 {
    match *dn {
        DataNumber::U8(v) => u32::from(v),
        DataNumber::I8(v) => v.max(0) as u32,
        DataNumber::U16(v) => u32::from(v),
        DataNumber::I16(v) => v.max(0) as u32,
        DataNumber::U24(v) => v,
        DataNumber::I24(v) => v.max(0) as u32,
        DataNumber::U32(v) => v,
        DataNumber::I32(v) => v.max(0) as u32,
        DataNumber::U64(v) => v.min(u64::from(u32::MAX)) as u32,
        DataNumber::I64(v) => v.max(0).min(i64::from(u32::MAX)) as u32,
        DataNumber::U128(v) => v.min(u128::from(u32::MAX)) as u32,
        DataNumber::I128(v) => v.max(0).min(i128::from(u32::MAX)) as u32,
    }
}

fn data_number_to_u64(dn: &DataNumber) -> u64 {
    match *dn {
        DataNumber::U8(v) => u64::from(v),
        DataNumber::I8(v) => v.max(0) as u64,
        DataNumber::U16(v) => u64::from(v),
        DataNumber::I16(v) => v.max(0) as u64,
        DataNumber::U24(v) => u64::from(v),
        DataNumber::I24(v) => v.max(0) as u64,
        DataNumber::U32(v) => u64::from(v),
        DataNumber::I32(v) => v.max(0) as u64,
        DataNumber::U64(v) => v,
        DataNumber::I64(v) => v.max(0) as u64,
        DataNumber::U128(v) => v.min(u128::from(u64::MAX)) as u64,
        DataNumber::I128(v) => v.max(0).min(i128::from(u64::MAX)) as u64,
    }
}

fn field_value_to_u32(value: &FieldValue) -> u32 {
    match value {
        FieldValue::DataNumber(dn) => data_number_to_u32(dn),
        FieldValue::ProtocolType(pt) => u32::from(u8::from(*pt)),
        FieldValue::Float64(f) => f.max(0.0).min(f64::from(u32::MAX)) as u32,
        _ => 0,
    }
}

fn field_value_to_u64(value: &FieldValue) -> u64 {
    match value {
        FieldValue::DataNumber(dn) => data_number_to_u64(dn),
        FieldValue::ProtocolType(pt) => u64::from(u8::from(*pt)),
        FieldValue::Float64(f) => f.max(0.0).min(u64::MAX as f64) as u64,
        _ => 0,
    }
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

/// Returns true if the flow message contains meaningful traffic data.
/// Flows with 0 bytes AND 0 packets are degenerate records (e.g. options templates,
/// metadata records, or incomplete template data) and should be filtered out.
pub fn is_valid_flow(msg: &flowpb::FlowMessage) -> bool {
    msg.bytes > 0 || msg.packets > 0
}

fn protocol_type_name(pt: ProtocolTypes) -> String {
    format!("{pt:?}").to_uppercase()
}

fn field_value_to_protocol_name(value: &FieldValue) -> String {
    match value {
        FieldValue::ProtocolType(pt) => protocol_type_name(*pt),
        FieldValue::DataNumber(dn) => {
            let n = data_number_to_u32(dn) as u8;
            protocol_type_name(ProtocolTypes::from(n))
        }
        _ => String::new(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use netflow_parser::protocol::ProtocolTypes;

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

    // --- data_number_to_u32 tests ---

    #[test]
    fn test_data_number_to_u32_unsigned_widening() {
        assert_eq!(data_number_to_u32(&DataNumber::U8(255)), 255);
        assert_eq!(data_number_to_u32(&DataNumber::U16(65535)), 65535);
        assert_eq!(data_number_to_u32(&DataNumber::U24(16_777_215)), 16_777_215);
        assert_eq!(data_number_to_u32(&DataNumber::U32(42)), 42);
    }

    #[test]
    fn test_data_number_to_u32_saturates_large() {
        assert_eq!(
            data_number_to_u32(&DataNumber::U64(u64::from(u32::MAX) + 1)),
            u32::MAX
        );
        assert_eq!(
            data_number_to_u32(&DataNumber::U128(u128::from(u32::MAX) + 100)),
            u32::MAX
        );
    }

    #[test]
    fn test_data_number_to_u32_signed_negative_clamps_to_zero() {
        assert_eq!(data_number_to_u32(&DataNumber::I8(-1)), 0);
        assert_eq!(data_number_to_u32(&DataNumber::I16(-500)), 0);
        assert_eq!(data_number_to_u32(&DataNumber::I32(-1)), 0);
        assert_eq!(data_number_to_u32(&DataNumber::I64(-1)), 0);
        assert_eq!(data_number_to_u32(&DataNumber::I128(-1)), 0);
        assert_eq!(data_number_to_u32(&DataNumber::I24(-1)), 0);
    }

    #[test]
    fn test_data_number_to_u32_signed_positive() {
        assert_eq!(data_number_to_u32(&DataNumber::I8(127)), 127);
        assert_eq!(data_number_to_u32(&DataNumber::I16(1000)), 1000);
        assert_eq!(data_number_to_u32(&DataNumber::I32(35000)), 35000);
        assert_eq!(data_number_to_u32(&DataNumber::I64(100)), 100);
    }

    // --- data_number_to_u64 tests ---

    #[test]
    fn test_data_number_to_u64_unsigned_widening() {
        assert_eq!(data_number_to_u64(&DataNumber::U8(200)), 200);
        assert_eq!(data_number_to_u64(&DataNumber::U16(50000)), 50000);
        assert_eq!(data_number_to_u64(&DataNumber::U32(35000)), 35000);
        assert_eq!(data_number_to_u64(&DataNumber::U64(99999)), 99999);
    }

    #[test]
    fn test_data_number_to_u64_saturates_u128() {
        assert_eq!(
            data_number_to_u64(&DataNumber::U128(u128::from(u64::MAX) + 1)),
            u64::MAX
        );
    }

    #[test]
    fn test_data_number_to_u64_signed_negative_clamps_to_zero() {
        assert_eq!(data_number_to_u64(&DataNumber::I8(-10)), 0);
        assert_eq!(data_number_to_u64(&DataNumber::I64(-999)), 0);
        assert_eq!(data_number_to_u64(&DataNumber::I128(-1)), 0);
    }

    // --- field_value_to_u32 tests ---

    #[test]
    fn test_field_value_to_u32_data_number() {
        let fv = FieldValue::DataNumber(DataNumber::U8(6));
        assert_eq!(field_value_to_u32(&fv), 6);

        let fv = FieldValue::DataNumber(DataNumber::U32(35000));
        assert_eq!(field_value_to_u32(&fv), 35000);
    }

    #[test]
    fn test_field_value_to_u32_protocol_type() {
        let fv = FieldValue::ProtocolType(ProtocolTypes::Tcp);
        assert_eq!(field_value_to_u32(&fv), 6);

        let fv = FieldValue::ProtocolType(ProtocolTypes::Udp);
        assert_eq!(field_value_to_u32(&fv), 17);

        let fv = FieldValue::ProtocolType(ProtocolTypes::Icmp);
        assert_eq!(field_value_to_u32(&fv), 1);
    }

    #[test]
    fn test_field_value_to_u32_float64() {
        let fv = FieldValue::Float64(42.7);
        assert_eq!(field_value_to_u32(&fv), 42);
    }

    #[test]
    fn test_field_value_to_u32_non_numeric_returns_zero() {
        let fv = FieldValue::String("hello".to_string());
        assert_eq!(field_value_to_u32(&fv), 0);

        let fv = FieldValue::Ip4Addr([10, 0, 0, 1].into());
        assert_eq!(field_value_to_u32(&fv), 0);

        let fv = FieldValue::Vec(vec![1, 2, 3]);
        assert_eq!(field_value_to_u32(&fv), 0);
    }

    // --- field_value_to_u64 tests ---

    #[test]
    fn test_field_value_to_u64_data_number() {
        // The key bug scenario: IN_BYTES sent as 4-byte field -> DataNumber::U32
        let fv = FieldValue::DataNumber(DataNumber::U32(35000));
        assert_eq!(field_value_to_u64(&fv), 35000);

        let fv = FieldValue::DataNumber(DataNumber::U64(999999));
        assert_eq!(field_value_to_u64(&fv), 999999);
    }

    #[test]
    fn test_field_value_to_u64_protocol_type() {
        let fv = FieldValue::ProtocolType(ProtocolTypes::Tcp);
        assert_eq!(field_value_to_u64(&fv), 6);
    }

    #[test]
    fn test_field_value_to_u64_non_numeric_returns_zero() {
        let fv = FieldValue::String("test".to_string());
        assert_eq!(field_value_to_u64(&fv), 0);

        let fv = FieldValue::MacAddr("00:11:22:33:44:55".to_string());
        assert_eq!(field_value_to_u64(&fv), 0);
    }

    // --- protocol_type_name tests ---

    #[test]
    fn test_protocol_type_name_common_protocols() {
        assert_eq!(protocol_type_name(ProtocolTypes::Tcp), "TCP");
        assert_eq!(protocol_type_name(ProtocolTypes::Udp), "UDP");
        assert_eq!(protocol_type_name(ProtocolTypes::Icmp), "ICMP");
        assert_eq!(protocol_type_name(ProtocolTypes::Gre), "GRE");
        assert_eq!(protocol_type_name(ProtocolTypes::Esp), "ESP");
    }

    #[test]
    fn test_protocol_type_name_ipv6_icmp() {
        assert_eq!(protocol_type_name(ProtocolTypes::Ipv6Icmp), "IPV6ICMP");
    }

    #[test]
    fn test_protocol_type_name_unknown() {
        assert_eq!(protocol_type_name(ProtocolTypes::Unknown), "UNKNOWN");
    }

    // --- field_value_to_protocol_name tests ---

    #[test]
    fn test_field_value_to_protocol_name_protocol_type() {
        let fv = FieldValue::ProtocolType(ProtocolTypes::Tcp);
        assert_eq!(field_value_to_protocol_name(&fv), "TCP");

        let fv = FieldValue::ProtocolType(ProtocolTypes::Udp);
        assert_eq!(field_value_to_protocol_name(&fv), "UDP");
    }

    #[test]
    fn test_field_value_to_protocol_name_data_number() {
        // Protocol number 6 = TCP
        let fv = FieldValue::DataNumber(DataNumber::U8(6));
        assert_eq!(field_value_to_protocol_name(&fv), "TCP");

        // Protocol number 17 = UDP
        let fv = FieldValue::DataNumber(DataNumber::U16(17));
        assert_eq!(field_value_to_protocol_name(&fv), "UDP");

        // Protocol number 1 = ICMP
        let fv = FieldValue::DataNumber(DataNumber::U32(1));
        assert_eq!(field_value_to_protocol_name(&fv), "ICMP");
    }

    #[test]
    fn test_field_value_to_protocol_name_non_numeric_returns_empty() {
        let fv = FieldValue::String("hello".to_string());
        assert_eq!(field_value_to_protocol_name(&fv), "");

        let fv = FieldValue::Ip4Addr([10, 0, 0, 1].into());
        assert_eq!(field_value_to_protocol_name(&fv), "");
    }

    // --- is_valid_flow tests ---

    #[test]
    fn test_is_valid_flow_zero_bytes_zero_packets_is_invalid() {
        let msg = flowpb::FlowMessage {
            bytes: 0,
            packets: 0,
            ..Default::default()
        };
        assert!(!is_valid_flow(&msg));
    }

    #[test]
    fn test_is_valid_flow_with_bytes_is_valid() {
        let msg = flowpb::FlowMessage {
            bytes: 100,
            packets: 0,
            ..Default::default()
        };
        assert!(is_valid_flow(&msg));
    }

    #[test]
    fn test_is_valid_flow_with_packets_is_valid() {
        let msg = flowpb::FlowMessage {
            bytes: 0,
            packets: 1,
            ..Default::default()
        };
        assert!(is_valid_flow(&msg));
    }

    #[test]
    fn test_is_valid_flow_with_both_is_valid() {
        let msg = flowpb::FlowMessage {
            bytes: 1500,
            packets: 3,
            ..Default::default()
        };
        assert!(is_valid_flow(&msg));
    }
}
