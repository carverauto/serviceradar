use crate::flowpb;
use log::debug;
use netflow_parser::NetflowPacket;
use netflow_parser::protocol::ProtocolTypes;
use netflow_parser::static_versions::v5::V5;
use netflow_parser::variable_versions::data_number::{DataNumber, FieldValue};
use netflow_parser::variable_versions::ipfix_lookup::{IANAIPFixField, IPFixField};
use netflow_parser::variable_versions::ipfix_lookup::ReverseInformationElement;
use netflow_parser::variable_versions::v9_lookup::V9Field;
use std::net::{IpAddr, SocketAddr};

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

    pub fn convert_v5(&self, packet: &V5) -> Vec<flowpb::FlowMessage> {
        let mut messages = Vec::with_capacity(packet.flowsets.len());

        for flow in &packet.flowsets {
            let mut msg = flowpb::FlowMessage {
                r#type: i32::from(flowpb::flow_message::FlowType::NetflowV5),
                time_received_ns: self.receive_time_ns,
                sampler_address: ip_to_bytes(&self.sampler_addr.ip()),
                sequence_num: packet.header.flow_sequence,
                ..Default::default()
            };

            msg.src_addr = flow.src_addr.octets().to_vec();
            msg.dst_addr = flow.dst_addr.octets().to_vec();
            msg.src_port = u32::from(flow.src_port);
            msg.dst_port = u32::from(flow.dst_port);
            msg.proto = u32::from(flow.protocol_number);
            msg.protocol_name = protocol_type_name(ProtocolTypes::from(flow.protocol_number));
            msg.bytes = u64::from(flow.d_octets);
            msg.packets = u64::from(flow.d_pkts);
            msg.bytes_out = msg.bytes;
            msg.packets_out = msg.packets;

            let uptime_ms = packet.header.sys_up_time;
            let unix_secs = packet.header.unix_secs;
            let unix_nsecs = packet.header.unix_nsecs;

            let base_time_ns = (u64::from(unix_secs))
                .checked_mul(1_000_000_000)
                .and_then(|secs_ns| secs_ns.checked_add(u64::from(unix_nsecs)))
                .unwrap_or(0);
            msg.time_flow_start_ns = calculate_flow_time(base_time_ns, uptime_ms, flow.first);
            msg.time_flow_end_ns = calculate_flow_time(base_time_ns, uptime_ms, flow.last);

            msg.in_if = u32::from(flow.input);
            msg.out_if = u32::from(flow.output);
            msg.next_hop = flow.next_hop.octets().to_vec();
            msg.src_as = u32::from(flow.src_as);
            msg.dst_as = u32::from(flow.dst_as);
            msg.tcp_flags = u32::from(flow.tcp_flags);
            msg.ip_tos = u32::from(flow.tos);
            msg.src_net = u32::from(flow.src_mask);
            msg.dst_net = u32::from(flow.dst_mask);

            messages.push(msg);
        }

        messages
    }

    pub fn convert_v9(
        &self,
        packet: &netflow_parser::variable_versions::v9::V9,
    ) -> Vec<flowpb::FlowMessage> {
        use netflow_parser::variable_versions::v9::FlowSetBody;

        let mut messages = Vec::new();

        for flowset in &packet.flowsets {
            match &flowset.body {
                FlowSetBody::Data(data) => {
                    for fields in &data.fields {
                        let mut msg = flowpb::FlowMessage {
                            r#type: i32::from(flowpb::flow_message::FlowType::NetflowV9),
                            time_received_ns: self.receive_time_ns,
                            sampler_address: ip_to_bytes(&self.sampler_addr.ip()),
                            sequence_num: packet.header.sequence_number,
                            ..Default::default()
                        };

                        for (field_type, field_value) in fields {
                            match field_type {
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
                                V9Field::L4SrcPort => msg.src_port = field_value_to_u32(field_value),
                                V9Field::L4DstPort => msg.dst_port = field_value_to_u32(field_value),
                                V9Field::Protocol => {
                                    msg.proto = field_value_to_u32(field_value);
                                    msg.protocol_name = field_value_to_protocol_name(field_value);
                                }
                                V9Field::InBytes => msg.bytes = field_value_to_u64(field_value),
                                V9Field::InPkts => msg.packets = field_value_to_u64(field_value),
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
                                V9Field::InputSnmp => msg.in_if = field_value_to_u32(field_value),
                                V9Field::OutputSnmp => msg.out_if = field_value_to_u32(field_value),
                                V9Field::InSrcMac => msg.src_mac = field_value_to_mac_u64(field_value),
                                V9Field::InDstMac | V9Field::OutDstMac => {
                                    if msg.dst_mac == 0 {
                                        msg.dst_mac = field_value_to_mac_u64(field_value);
                                    }
                                }
                                V9Field::SrcAs => msg.src_as = field_value_to_u32(field_value),
                                V9Field::DstAs => msg.dst_as = field_value_to_u32(field_value),
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
                                V9Field::TcpFlags => msg.tcp_flags = field_value_to_u32(field_value),
                                V9Field::SrcTos => msg.ip_tos = field_value_to_u32(field_value),
                                V9Field::SrcVlan => msg.src_vlan = field_value_to_u32(field_value),
                                V9Field::DstVlan => msg.dst_vlan = field_value_to_u32(field_value),
                                V9Field::Ipv6FlowLabel => {
                                    msg.ipv6_flow_label = field_value_to_u32(field_value)
                                }
                                V9Field::IcmpType => {
                                    let val = field_value_to_u32(field_value);
                                    msg.icmp_type = (val >> 8) & 0xFF;
                                    msg.icmp_code = val & 0xFF;
                                }
                                _ => {}
                            }
                        }

                        msg.bytes_out = msg.bytes;
                        msg.packets_out = msg.packets;

                        messages.push(msg);
                    }
                }
                FlowSetBody::NoTemplate(info) => {
                    debug!(
                        "V9 flowset skipped - no template for ID {} (available: {:?}, {} bytes raw data)",
                        info.template_id,
                        info.available_templates,
                        info.raw_data.len()
                    );
                }
                _ => {}
            }
        }

        messages
    }

    pub fn convert_ipfix(
        &self,
        packet: &netflow_parser::variable_versions::ipfix::IPFix,
    ) -> Vec<flowpb::FlowMessage> {
        use netflow_parser::variable_versions::ipfix::FlowSetBody;

        let mut messages = Vec::new();

        for flowset in &packet.flowsets {
            match &flowset.body {
                FlowSetBody::Data(data) => {
                    for fields in &data.fields {
                        let mut msg = flowpb::FlowMessage {
                            r#type: i32::from(flowpb::flow_message::FlowType::Ipfix),
                            time_received_ns: self.receive_time_ns,
                            sampler_address: ip_to_bytes(&self.sampler_addr.ip()),
                            sequence_num: packet.header.sequence_number,
                            observation_domain_id: packet.header.observation_domain_id,
                            ..Default::default()
                        };

                        for (field_type, field_value) in fields {
                            match field_type {
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
                                IPFixField::IANA(IANAIPFixField::SourceTransportPort) => {
                                    msg.src_port = field_value_to_u32(field_value)
                                }
                                IPFixField::IANA(IANAIPFixField::DestinationTransportPort) => {
                                    msg.dst_port = field_value_to_u32(field_value)
                                }
                                IPFixField::IANA(IANAIPFixField::ProtocolIdentifier) => {
                                    msg.proto = field_value_to_u32(field_value);
                                    msg.protocol_name = field_value_to_protocol_name(field_value);
                                }
                                IPFixField::IANA(IANAIPFixField::OctetDeltaCount) => {
                                    let value = field_value_to_u64(field_value);
                                    msg.bytes = value;
                                    msg.bytes_out = value;
                                }
                                IPFixField::IANA(IANAIPFixField::OctetTotalCount) => {
                                    if msg.bytes_out == 0 {
                                        let value = field_value_to_u64(field_value);
                                        msg.bytes = value;
                                        msg.bytes_out = value;
                                    }
                                }
                                IPFixField::IANA(IANAIPFixField::PacketDeltaCount) => {
                                    let value = field_value_to_u64(field_value);
                                    msg.packets = value;
                                    msg.packets_out = value;
                                }
                                IPFixField::IANA(IANAIPFixField::PacketTotalCount) => {
                                    if msg.packets_out == 0 {
                                        let value = field_value_to_u64(field_value);
                                        msg.packets = value;
                                        msg.packets_out = value;
                                    }
                                }
                                IPFixField::IANA(IANAIPFixField::InitiatorOctets) => {
                                    if msg.bytes_out == 0 {
                                        let value = field_value_to_u64(field_value);
                                        msg.bytes = value;
                                        msg.bytes_out = value;
                                    }
                                }
                                IPFixField::IANA(IANAIPFixField::ResponderOctets) => {
                                    if msg.bytes_in == 0 {
                                        msg.bytes_in = field_value_to_u64(field_value);
                                    }
                                }
                                IPFixField::IANA(IANAIPFixField::InitiatorPackets) => {
                                    if msg.packets_out == 0 {
                                        let value = field_value_to_u64(field_value);
                                        msg.packets = value;
                                        msg.packets_out = value;
                                    }
                                }
                                IPFixField::IANA(IANAIPFixField::ResponderPackets) => {
                                    if msg.packets_in == 0 {
                                        msg.packets_in = field_value_to_u64(field_value);
                                    }
                                }
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
                                IPFixField::IANA(IANAIPFixField::IngressInterface) => {
                                    msg.in_if = field_value_to_u32(field_value)
                                }
                                IPFixField::IANA(IANAIPFixField::EgressInterface) => {
                                    msg.out_if = field_value_to_u32(field_value)
                                }
                                IPFixField::IANA(IANAIPFixField::SourceMacaddress) => {
                                    msg.src_mac = field_value_to_mac_u64(field_value)
                                }
                                IPFixField::IANA(IANAIPFixField::DestinationMacaddress) => {
                                    msg.dst_mac = field_value_to_mac_u64(field_value)
                                }
                                IPFixField::IANA(IANAIPFixField::BgpSourceAsNumber) => {
                                    msg.src_as = field_value_to_u32(field_value)
                                }
                                IPFixField::IANA(IANAIPFixField::BgpDestinationAsNumber) => {
                                    msg.dst_as = field_value_to_u32(field_value)
                                }
                                IPFixField::IANA(IANAIPFixField::BgpNextAdjacentAsNumber) => {
                                    msg.next_hop_as = field_value_to_u32(field_value)
                                }
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
                                IPFixField::IANA(IANAIPFixField::VlanId) => {
                                    msg.vlan_id = field_value_to_u32(field_value)
                                }
                                IPFixField::IANA(IANAIPFixField::Dot1qVlanId) => {
                                    msg.src_vlan = field_value_to_u32(field_value)
                                }
                                IPFixField::IANA(IANAIPFixField::PostDot1qVlanId) => {
                                    msg.dst_vlan = field_value_to_u32(field_value)
                                }
                                IPFixField::IANA(IANAIPFixField::FlowLabelIpv6) => {
                                    msg.ipv6_flow_label = field_value_to_u32(field_value)
                                }
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
                                IPFixField::ReverseInformationElement(
                                    ReverseInformationElement::ReverseOctetDeltaCount,
                                )
                                | IPFixField::ReverseInformationElement(
                                    ReverseInformationElement::ReverseOctetTotalCount,
                                )
                                | IPFixField::ReverseInformationElement(
                                    ReverseInformationElement::ReversePostOctetDeltaCount,
                                )
                                | IPFixField::ReverseInformationElement(
                                    ReverseInformationElement::ReversePostOctetTotalCount,
                                ) => {
                                    if msg.bytes_in == 0 {
                                        msg.bytes_in = field_value_to_u64(field_value);
                                    }
                                }
                                IPFixField::ReverseInformationElement(
                                    ReverseInformationElement::ReversePacketDeltaCount,
                                )
                                | IPFixField::ReverseInformationElement(
                                    ReverseInformationElement::ReversePacketTotalCount,
                                )
                                | IPFixField::ReverseInformationElement(
                                    ReverseInformationElement::ReversePostPacketDeltaCount,
                                )
                                | IPFixField::ReverseInformationElement(
                                    ReverseInformationElement::ReversePostPacketTotalCount,
                                ) => {
                                    if msg.packets_in == 0 {
                                        msg.packets_in = field_value_to_u64(field_value);
                                    }
                                }
                                _ => {
                                    debug!("Unhandled IPFIX field: {:?}", field_type);
                                }
                            }
                        }

                        messages.push(msg);
                    }
                }
                FlowSetBody::NoTemplate(info) => {
                    debug!(
                        "IPFIX flowset skipped - no template for ID {} (available: {:?}, {} bytes raw data)",
                        info.template_id,
                        info.available_templates,
                        info.raw_data.len()
                    );
                }
                _ => {}
            }
        }

        messages
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
    if sys_uptime_ms >= flow_uptime_ms {
        let offset_ms = u64::from(sys_uptime_ms.saturating_sub(flow_uptime_ms));
        base_time_ns.saturating_sub(offset_ms.saturating_mul(1_000_000))
    } else {
        base_time_ns
    }
}

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
        FieldValue::Duration(d) => u32::try_from(d.as_millis()).unwrap_or(u32::MAX),
        FieldValue::ProtocolType(pt) => u32::from(u8::from(*pt)),
        FieldValue::Float64(f) => f.max(0.0).min(f64::from(u32::MAX)) as u32,
        _ => 0,
    }
}

fn field_value_to_u64(value: &FieldValue) -> u64 {
    match value {
        FieldValue::DataNumber(dn) => data_number_to_u64(dn),
        FieldValue::Duration(d) => d.as_millis().try_into().unwrap_or(u64::MAX),
        FieldValue::ProtocolType(pt) => u64::from(u8::from(*pt)),
        FieldValue::Float64(f) => f.max(0.0).min(u64::MAX as f64) as u64,
        _ => 0,
    }
}

fn field_value_to_mac_u64(value: &FieldValue) -> u64 {
    match value {
        FieldValue::MacAddr(mac_str) => {
            let bytes: Vec<u8> = mac_str
                .split(':')
                .filter_map(|s| u8::from_str_radix(s, 16).ok())
                .collect();
            mac_to_u64(&bytes)
        }
        _ => 0,
    }
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

impl From<Converter> for Vec<flowpb::FlowMessage> {
    fn from(converter: Converter) -> Self {
        match converter.packet {
            NetflowPacket::V5(ref v5) => converter.convert_v5(v5),
            NetflowPacket::V7(_) => vec![],
            NetflowPacket::V9(ref v9) => converter.convert_v9(v9),
            NetflowPacket::IPFix(ref ipfix) => converter.convert_ipfix(ipfix),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use netflow_parser::protocol::ProtocolTypes;
    use std::time::Duration;

    #[test]
    fn test_mac_to_u64() {
        let mac = [0x00, 0x11, 0x22, 0x33, 0x44, 0x55];
        let result = mac_to_u64(&mac);
        assert_eq!(result, 0x001122334455);
    }

    #[test]
    fn test_calculate_flow_time() {
        let base = 1_000_000_000_000;
        let sys_uptime = 10000;
        let flow_uptime = 5000;
        let result = calculate_flow_time(base, sys_uptime, flow_uptime);
        assert_eq!(result, base - 5_000_000_000);
    }

    #[test]
    fn test_ip_to_bytes_v4() {
        let ip = IpAddr::V4([192, 168, 1, 1].into());
        let bytes = ip_to_bytes(&ip);
        assert_eq!(bytes, vec![192, 168, 1, 1]);
    }

    #[test]
    fn test_data_number_to_u32_unsigned() {
        assert_eq!(data_number_to_u32(&DataNumber::U8(255)), 255);
        assert_eq!(data_number_to_u32(&DataNumber::U16(65535)), 65535);
        assert_eq!(data_number_to_u32(&DataNumber::U32(42)), 42);
    }

    #[test]
    fn test_data_number_to_u32_saturates_large() {
        assert_eq!(
            data_number_to_u32(&DataNumber::U64(u64::from(u32::MAX) + 1)),
            u32::MAX
        );
    }

    #[test]
    fn test_data_number_to_u32_signed_negative() {
        assert_eq!(data_number_to_u32(&DataNumber::I8(-1)), 0);
        assert_eq!(data_number_to_u32(&DataNumber::I32(-1)), 0);
    }

    #[test]
    fn test_field_value_to_u32_protocol_type() {
        let fv = FieldValue::ProtocolType(ProtocolTypes::Tcp);
        assert_eq!(field_value_to_u32(&fv), 6);
    }

    #[test]
    fn test_field_value_to_u32_duration() {
        let fv = FieldValue::Duration(Duration::from_millis(28_796_274));
        assert_eq!(field_value_to_u32(&fv), 28_796_274);
    }

    #[test]
    fn test_field_value_to_u64_data_number() {
        let fv = FieldValue::DataNumber(DataNumber::U32(35000));
        assert_eq!(field_value_to_u64(&fv), 35000);
    }

    #[test]
    fn test_is_valid_flow() {
        use crate::listener::is_valid_flow;

        let valid = flowpb::FlowMessage { bytes: 100, packets: 1, ..Default::default() };
        let invalid = flowpb::FlowMessage { bytes: 0, packets: 0, ..Default::default() };
        assert!(is_valid_flow(&valid));
        assert!(!is_valid_flow(&invalid));
    }

    #[test]
    fn test_protocol_type_name() {
        assert_eq!(protocol_type_name(ProtocolTypes::Tcp), "TCP");
        assert_eq!(protocol_type_name(ProtocolTypes::Udp), "UDP");
    }
}
