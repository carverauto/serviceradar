use anyhow::Result;
use netflow_parser::{NetflowPacket, NetflowParser, variable_versions::*};
use prost::Message;
use std::net::{IpAddr, SocketAddr};
use std::time::{SystemTime, UNIX_EPOCH};

// Include generated protobuf code
pub mod flowpb {
    include!(concat!(env!("OUT_DIR"), "/flowpb.rs"));
}

/// Convert a netflow_parser NetflowPacket to flowpb::FlowMessage protobuf
pub fn netflow_to_proto(
    packet: NetflowPacket,
    sampler_addr: SocketAddr,
    receive_time_ns: u64,
) -> Result<Vec<flowpb::FlowMessage>> {
    match packet {
        NetflowPacket::V5(v5) => convert_v5(v5, sampler_addr, receive_time_ns),
        NetflowPacket::V7(v7) => convert_v7(v7, sampler_addr, receive_time_ns),
        NetflowPacket::V9(v9) => convert_v9(v9, sampler_addr, receive_time_ns),
        NetflowPacket::IPFix(ipfix) => convert_ipfix(ipfix, sampler_addr, receive_time_ns),
        _ => Ok(vec![]),
    }
}

fn convert_v5(
    packet: netflow_parser::static_versions::V5,
    sampler_addr: SocketAddr,
    receive_time_ns: u64,
) -> Result<Vec<flowpb::FlowMessage>> {
    let mut messages = Vec::with_capacity(packet.flow_sets.len());

    for flow in packet.flow_sets {
        let mut msg = flowpb::FlowMessage {
            r#type: flowpb::flow_message::FlowType::NetflowV5 as i32,
            time_received_ns: receive_time_ns,
            sampler_address: ip_to_bytes(&sampler_addr.ip()),
            sequence_num: packet.header.flow_sequence,
            ..Default::default()
        };

        // Source/destination addresses
        msg.src_addr = flow.src_addr.octets().to_vec();
        msg.dst_addr = flow.dest_addr.octets().to_vec();

        // Ports
        msg.src_port = flow.src_port as u32;
        msg.dst_port = flow.dest_port as u32;

        // Protocol
        msg.proto = flow.protocol as u32;

        // Bytes and packets
        msg.bytes = flow.d_octets as u64;
        msg.packets = flow.d_pkts as u64;

        // Timestamps (convert Unix seconds to nanoseconds)
        let uptime_ms = packet.header.sys_uptime;
        let unix_secs = packet.header.unix_secs;
        let unix_nsecs = packet.header.unix_nsecs;

        let base_time_ns = (unix_secs as u64 * 1_000_000_000) + (unix_nsecs as u64);
        msg.time_flow_start_ns = calculate_flow_time(base_time_ns, uptime_ms, flow.first);
        msg.time_flow_end_ns = calculate_flow_time(base_time_ns, uptime_ms, flow.last);

        // Interfaces
        msg.in_if = flow.input as u32;
        msg.out_if = flow.output as u32;

        // Next hop
        msg.next_hop = flow.next_hop.octets().to_vec();

        // AS numbers
        msg.src_as = flow.src_as as u32;
        msg.dst_as = flow.dest_as as u32;

        // TCP flags
        msg.tcp_flags = flow.tcp_flags as u32;

        // IP ToS
        msg.ip_tos = flow.tos as u32;

        // Prefix masks
        msg.src_net = flow.src_mask as u32;
        msg.dst_net = flow.dest_mask as u32;

        messages.push(msg);
    }

    Ok(messages)
}

fn convert_v7(
    packet: netflow_parser::static_versions::V7,
    sampler_addr: SocketAddr,
    receive_time_ns: u64,
) -> Result<Vec<flowpb::FlowMessage>> {
    let mut messages = Vec::with_capacity(packet.flow_sets.len());

    for flow in packet.flow_sets {
        let mut msg = flowpb::FlowMessage {
            r#type: flowpb::flow_message::FlowType::NetflowV5 as i32, // V7 uses same type
            time_received_ns: receive_time_ns,
            sampler_address: ip_to_bytes(&sampler_addr.ip()),
            sequence_num: packet.header.flow_sequence,
            ..Default::default()
        };

        // Source/destination addresses
        msg.src_addr = flow.src_addr.octets().to_vec();
        msg.dst_addr = flow.dest_addr.octets().to_vec();

        // Ports
        msg.src_port = flow.src_port as u32;
        msg.dst_port = flow.dest_port as u32;

        // Protocol
        msg.proto = flow.protocol as u32;

        // Bytes and packets
        msg.bytes = flow.d_octets as u64;
        msg.packets = flow.d_pkts as u64;

        // Timestamps
        let uptime_ms = packet.header.sys_uptime;
        let unix_secs = packet.header.unix_secs;
        let unix_nsecs = packet.header.unix_nsecs;

        let base_time_ns = (unix_secs as u64 * 1_000_000_000) + (unix_nsecs as u64);
        msg.time_flow_start_ns = calculate_flow_time(base_time_ns, uptime_ms, flow.first);
        msg.time_flow_end_ns = calculate_flow_time(base_time_ns, uptime_ms, flow.last);

        // Interfaces
        msg.in_if = flow.input as u32;
        msg.out_if = flow.output as u32;

        // Next hop
        msg.next_hop = flow.next_hop.octets().to_vec();

        // AS numbers
        msg.src_as = flow.src_as as u32;
        msg.dst_as = flow.dest_as as u32;

        // TCP flags
        msg.tcp_flags = flow.tcp_flags as u32;

        // IP ToS
        msg.ip_tos = flow.tos as u32;

        // Prefix masks
        msg.src_net = flow.src_mask as u32;
        msg.dst_net = flow.dest_mask as u32;

        // V7 specific fields
        msg.forwarding_status = flow.flags as u32;

        messages.push(msg);
    }

    Ok(messages)
}

fn convert_v9(
    packet: V9,
    sampler_addr: SocketAddr,
    receive_time_ns: u64,
) -> Result<Vec<flowpb::FlowMessage>> {
    let mut messages = Vec::new();

    for set in packet.sets {
        if let DataSetType::Data(data) = set {
            for record in data.records {
                let mut msg = flowpb::FlowMessage {
                    r#type: flowpb::flow_message::FlowType::NetflowV9 as i32,
                    time_received_ns: receive_time_ns,
                    sampler_address: ip_to_bytes(&sampler_addr.ip()),
                    sequence_num: packet.header.sequence,
                    observation_domain_id: packet.header.source_id,
                    ..Default::default()
                };

                // Extract fields from variable-length record
                for field in record.fields {
                    match field {
                        V9Field::IPV4_SRC_ADDR(addr) => msg.src_addr = addr.octets().to_vec(),
                        V9Field::IPV4_DST_ADDR(addr) => msg.dst_addr = addr.octets().to_vec(),
                        V9Field::IPV6_SRC_ADDR(addr) => msg.src_addr = addr.octets().to_vec(),
                        V9Field::IPV6_DST_ADDR(addr) => msg.dst_addr = addr.octets().to_vec(),
                        V9Field::L4_SRC_PORT(port) => msg.src_port = port as u32,
                        V9Field::L4_DST_PORT(port) => msg.dst_port = port as u32,
                        V9Field::PROTOCOL(proto) => msg.proto = proto as u32,
                        V9Field::IN_BYTES(bytes) => msg.bytes = bytes,
                        V9Field::IN_PKTS(pkts) => msg.packets = pkts,
                        V9Field::FIRST_SWITCHED(ts) => {
                            msg.time_flow_start_ns = calculate_flow_time(
                                receive_time_ns,
                                packet.header.sys_uptime,
                                ts,
                            );
                        }
                        V9Field::LAST_SWITCHED(ts) => {
                            msg.time_flow_end_ns = calculate_flow_time(
                                receive_time_ns,
                                packet.header.sys_uptime,
                                ts,
                            );
                        }
                        V9Field::INPUT_SNMP(snmp) => msg.in_if = snmp,
                        V9Field::OUTPUT_SNMP(snmp) => msg.out_if = snmp,
                        V9Field::IPV4_NEXT_HOP(addr) => msg.next_hop = addr.octets().to_vec(),
                        V9Field::IPV6_NEXT_HOP(addr) => msg.next_hop = addr.octets().to_vec(),
                        V9Field::SRC_AS(asn) => msg.src_as = asn,
                        V9Field::DST_AS(asn) => msg.dst_as = asn,
                        V9Field::BGP_IPV4_NEXT_HOP(addr) => msg.bgp_next_hop = addr.octets().to_vec(),
                        V9Field::BGP_IPV6_NEXT_HOP(addr) => msg.bgp_next_hop = addr.octets().to_vec(),
                        V9Field::TCP_FLAGS(flags) => msg.tcp_flags = flags as u32,
                        V9Field::SRC_TOS(tos) => msg.ip_tos = tos as u32,
                        V9Field::SRC_VLAN(vlan) => msg.src_vlan = vlan as u32,
                        V9Field::DST_VLAN(vlan) => msg.dst_vlan = vlan as u32,
                        V9Field::FORWARDING_STATUS(status) => msg.forwarding_status = status as u32,
                        V9Field::SRC_MASK(mask) => msg.src_net = mask as u32,
                        V9Field::DST_MASK(mask) => msg.dst_net = mask as u32,
                        V9Field::FLOW_SAMPLER_ID(id) => msg.sampling_rate = id as u64,
                        V9Field::IN_SRC_MAC(mac) => msg.src_mac = mac_to_u64(&mac),
                        V9Field::OUT_DST_MAC(mac) => msg.dst_mac = mac_to_u64(&mac),
                        V9Field::MPLS_LABEL_1(label) => {
                            if msg.mpls_label.is_empty() {
                                msg.mpls_label.push(label);
                            }
                        }
                        _ => {} // Skip unsupported fields
                    }
                }

                messages.push(msg);
            }
        }
    }

    Ok(messages)
}

fn convert_ipfix(
    packet: IPFix,
    sampler_addr: SocketAddr,
    receive_time_ns: u64,
) -> Result<Vec<flowpb::FlowMessage>> {
    let mut messages = Vec::new();

    for set in packet.sets {
        if let DataSetType::Data(data) = set {
            for record in data.records {
                let mut msg = flowpb::FlowMessage {
                    r#type: flowpb::flow_message::FlowType::Ipfix as i32,
                    time_received_ns: receive_time_ns,
                    sampler_address: ip_to_bytes(&sampler_addr.ip()),
                    sequence_num: packet.header.sequence,
                    observation_domain_id: packet.header.observation_domain_id,
                    ..Default::default()
                };

                // IPFIX uses the same field types as NetFlow v9
                for field in record.fields {
                    match field {
                        IPFixField::sourceIPv4Address(addr) => msg.src_addr = addr.octets().to_vec(),
                        IPFixField::destinationIPv4Address(addr) => msg.dst_addr = addr.octets().to_vec(),
                        IPFixField::sourceIPv6Address(addr) => msg.src_addr = addr.octets().to_vec(),
                        IPFixField::destinationIPv6Address(addr) => msg.dst_addr = addr.octets().to_vec(),
                        IPFixField::sourceTransportPort(port) => msg.src_port = port as u32,
                        IPFixField::destinationTransportPort(port) => msg.dst_port = port as u32,
                        IPFixField::protocolIdentifier(proto) => msg.proto = proto as u32,
                        IPFixField::octetDeltaCount(bytes) => msg.bytes = bytes,
                        IPFixField::packetDeltaCount(pkts) => msg.packets = pkts,
                        IPFixField::flowStartMilliseconds(ts) => msg.time_flow_start_ns = ts * 1_000_000,
                        IPFixField::flowEndMilliseconds(ts) => msg.time_flow_end_ns = ts * 1_000_000,
                        IPFixField::ingressInterface(snmp) => msg.in_if = snmp,
                        IPFixField::egressInterface(snmp) => msg.out_if = snmp,
                        IPFixField::ipNextHopIPv4Address(addr) => msg.next_hop = addr.octets().to_vec(),
                        IPFixField::ipNextHopIPv6Address(addr) => msg.next_hop = addr.octets().to_vec(),
                        IPFixField::bgpSourceAsNumber(asn) => msg.src_as = asn,
                        IPFixField::bgpDestinationAsNumber(asn) => msg.dst_as = asn(),
                        IPFixField::bgpNextHopIPv4Address(addr) => msg.bgp_next_hop = addr.octets().to_vec(),
                        IPFixField::bgpNextHopIPv6Address(addr) => msg.bgp_next_hop = addr.octets().to_vec(),
                        IPFixField::tcpControlBits(flags) => msg.tcp_flags = flags as u32,
                        IPFixField::ipClassOfService(tos) => msg.ip_tos = tos as u32,
                        IPFixField::vlanId(vlan) => msg.vlan_id = vlan as u32,
                        IPFixField::sourceIPv4PrefixLength(mask) => msg.src_net = mask as u32,
                        IPFixField::destinationIPv4PrefixLength(mask) => msg.dst_net = mask as u32,
                        IPFixField::flowEndReason(reason) => msg.forwarding_status = reason as u32,
                        IPFixField::observationPointId(id) => msg.observation_point_id = id as u32,
                        _ => {} // Skip unsupported fields
                    }
                }

                messages.push(msg);
            }
        }
    }

    Ok(messages)
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
        result |= (byte as u64) << (40 - i * 8);
    }
    result
}

fn calculate_flow_time(base_time_ns: u64, sys_uptime_ms: u32, flow_uptime_ms: u32) -> u64 {
    // Calculate the flow timestamp based on system uptime and flow uptime
    if sys_uptime_ms >= flow_uptime_ms {
        let offset_ms = (sys_uptime_ms - flow_uptime_ms) as u64;
        base_time_ns.saturating_sub(offset_ms * 1_000_000)
    } else {
        // Handle uptime wrap-around (uptime counter reset)
        base_time_ns
    }
}

pub fn get_current_time_ns() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .expect("Time went backwards")
        .as_nanos() as u64
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
