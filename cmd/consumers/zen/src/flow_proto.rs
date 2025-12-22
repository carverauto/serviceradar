use anyhow::Result;
use prost::Message;
use serde_json::{json, Value};

/// Include generated flowpb code
pub mod flowpb {
    include!(concat!(env!("OUT_DIR"), "/flowpb.rs"));
}

/// Convert flowpb::FlowMessage protobuf to JSON for rule engine
pub fn flow_to_json(data: &[u8]) -> Result<Value> {
    let flow_msg = flowpb::FlowMessage::decode(data)?;

    Ok(json!({
        "flow_type": flow_type_name(flow_msg.r#type),
        "time_received_ns": flow_msg.time_received_ns,
        "time_flow_start_ns": flow_msg.time_flow_start_ns,
        "time_flow_end_ns": flow_msg.time_flow_end_ns,
        "sampler_address": bytes_to_ip(&flow_msg.sampler_address),
        "src_addr": bytes_to_ip(&flow_msg.src_addr),
        "dst_addr": bytes_to_ip(&flow_msg.dst_addr),
        "src_port": flow_msg.src_port,
        "dst_port": flow_msg.dst_port,
        "proto": flow_msg.proto,
        "bytes": flow_msg.bytes,
        "packets": flow_msg.packets,
        "sampling_rate": flow_msg.sampling_rate,
        "sequence_num": flow_msg.sequence_num,
        "in_if": flow_msg.in_if,
        "out_if": flow_msg.out_if,
        "src_as": flow_msg.src_as,
        "dst_as": flow_msg.dst_as,
        "next_hop": bytes_to_ip(&flow_msg.next_hop),
        "next_hop_as": flow_msg.next_hop_as,
        "tcp_flags": flow_msg.tcp_flags,
        "ip_tos": flow_msg.ip_tos,
        "ip_ttl": flow_msg.ip_ttl,
        "ip_flags": flow_msg.ip_flags,
        "vlan_id": flow_msg.vlan_id,
        "src_vlan": flow_msg.src_vlan,
        "dst_vlan": flow_msg.dst_vlan,
        "src_mac": format_mac(flow_msg.src_mac),
        "dst_mac": format_mac(flow_msg.dst_mac),
        "forwarding_status": flow_msg.forwarding_status,
        "icmp_type": flow_msg.icmp_type,
        "icmp_code": flow_msg.icmp_code,
        "ipv6_flow_label": flow_msg.ipv6_flow_label,
        "fragment_id": flow_msg.fragment_id,
        "fragment_offset": flow_msg.fragment_offset,
        "src_net": flow_msg.src_net,
        "dst_net": flow_msg.dst_net,
        "bgp_next_hop": bytes_to_ip(&flow_msg.bgp_next_hop),
        "bgp_communities": flow_msg.bgp_communities,
        "as_path": flow_msg.as_path,
        "mpls_label": flow_msg.mpls_label,
        "mpls_ttl": flow_msg.mpls_ttl,
        "observation_domain_id": flow_msg.observation_domain_id,
        "observation_point_id": flow_msg.observation_point_id,
        "etype": flow_msg.etype,
    }))
}

fn flow_type_name(flow_type: i32) -> &'static str {
    match flow_type {
        0 => "FLOWUNKNOWN",
        1 => "SFLOW_5",
        2 => "NETFLOW_V5",
        3 => "NETFLOW_V9",
        4 => "IPFIX",
        _ => "UNKNOWN",
    }
}

fn bytes_to_ip(bytes: &[u8]) -> String {
    if bytes.is_empty() {
        return String::new();
    }

    if bytes.len() == 4 {
        // IPv4
        format!("{}.{}.{}.{}", bytes[0], bytes[1], bytes[2], bytes[3])
    } else if bytes.len() == 16 {
        // IPv6 - full format
        format!(
            "{:02x}{:02x}:{:02x}{:02x}:{:02x}{:02x}:{:02x}{:02x}:{:02x}{:02x}:{:02x}{:02x}:{:02x}{:02x}:{:02x}{:02x}",
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        )
    } else {
        String::new()
    }
}

fn format_mac(mac: u64) -> String {
    if mac == 0 {
        return String::new();
    }

    format!(
        "{:02x}:{:02x}:{:02x}:{:02x}:{:02x}:{:02x}",
        (mac >> 40) & 0xff,
        (mac >> 32) & 0xff,
        (mac >> 24) & 0xff,
        (mac >> 16) & 0xff,
        (mac >> 8) & 0xff,
        mac & 0xff,
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_bytes_to_ip_v4() {
        let bytes = vec![192, 168, 1, 1];
        assert_eq!(bytes_to_ip(&bytes), "192.168.1.1");
    }

    #[test]
    fn test_bytes_to_ip_v6() {
        let bytes = vec![
            0x20, 0x01, 0x0d, 0xb8, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x00, 0x01,
        ];
        assert_eq!(bytes_to_ip(&bytes), "2001:0db8:0000:0000:0000:0000:0000:0001");
    }

    #[test]
    fn test_bytes_to_ip_empty() {
        let bytes = vec![];
        assert_eq!(bytes_to_ip(&bytes), "");
    }

    #[test]
    fn test_format_mac() {
        let mac = 0x001122334455u64;
        assert_eq!(format_mac(mac), "00:11:22:33:44:55");
    }

    #[test]
    fn test_format_mac_zero() {
        assert_eq!(format_mac(0), "");
    }

    #[test]
    fn test_flow_type_name() {
        assert_eq!(flow_type_name(0), "FLOWUNKNOWN");
        assert_eq!(flow_type_name(2), "NETFLOW_V5");
        assert_eq!(flow_type_name(3), "NETFLOW_V9");
        assert_eq!(flow_type_name(4), "IPFIX");
    }
}
