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

    // Build JSON in stages to avoid macro recursion limit
    let mut result = serde_json::Map::new();

    // Basic fields
    result.insert(
        "flow_type".to_string(),
        json!(flow_type_name(flow_msg.r#type)),
    );
    result.insert(
        "time_received_ns".to_string(),
        json!(flow_msg.time_received_ns),
    );
    result.insert(
        "time_flow_start_ns".to_string(),
        json!(flow_msg.time_flow_start_ns),
    );
    result.insert(
        "time_flow_end_ns".to_string(),
        json!(flow_msg.time_flow_end_ns),
    );

    // Addresses
    result.insert(
        "sampler_address".to_string(),
        json!(bytes_to_ip(&flow_msg.sampler_address)),
    );
    result.insert(
        "src_addr".to_string(),
        json!(bytes_to_ip(&flow_msg.src_addr)),
    );
    result.insert(
        "dst_addr".to_string(),
        json!(bytes_to_ip(&flow_msg.dst_addr)),
    );
    result.insert(
        "next_hop".to_string(),
        json!(bytes_to_ip(&flow_msg.next_hop)),
    );
    result.insert(
        "bgp_next_hop".to_string(),
        json!(bytes_to_ip(&flow_msg.bgp_next_hop)),
    );

    // Ports and protocol
    result.insert("src_port".to_string(), json!(flow_msg.src_port));
    result.insert("dst_port".to_string(), json!(flow_msg.dst_port));
    result.insert("proto".to_string(), json!(flow_msg.proto));

    // Traffic
    result.insert("bytes".to_string(), json!(flow_msg.bytes));
    result.insert("packets".to_string(), json!(flow_msg.packets));
    result.insert("sampling_rate".to_string(), json!(flow_msg.sampling_rate));
    result.insert("sequence_num".to_string(), json!(flow_msg.sequence_num));

    // Interfaces
    result.insert("in_if".to_string(), json!(flow_msg.in_if));
    result.insert("out_if".to_string(), json!(flow_msg.out_if));

    // AS numbers
    result.insert("src_as".to_string(), json!(flow_msg.src_as));
    result.insert("dst_as".to_string(), json!(flow_msg.dst_as));
    result.insert("next_hop_as".to_string(), json!(flow_msg.next_hop_as));

    // TCP/IP flags
    result.insert("tcp_flags".to_string(), json!(flow_msg.tcp_flags));
    result.insert("ip_tos".to_string(), json!(flow_msg.ip_tos));
    result.insert("ip_ttl".to_string(), json!(flow_msg.ip_ttl));
    result.insert("ip_flags".to_string(), json!(flow_msg.ip_flags));

    // VLANs
    result.insert("vlan_id".to_string(), json!(flow_msg.vlan_id));
    result.insert("src_vlan".to_string(), json!(flow_msg.src_vlan));
    result.insert("dst_vlan".to_string(), json!(flow_msg.dst_vlan));

    // MACs
    result.insert("src_mac".to_string(), json!(format_mac(flow_msg.src_mac)));
    result.insert("dst_mac".to_string(), json!(format_mac(flow_msg.dst_mac)));

    // Other fields
    result.insert(
        "forwarding_status".to_string(),
        json!(flow_msg.forwarding_status),
    );
    result.insert("icmp_type".to_string(), json!(flow_msg.icmp_type));
    result.insert("icmp_code".to_string(), json!(flow_msg.icmp_code));
    result.insert(
        "ipv6_flow_label".to_string(),
        json!(flow_msg.ipv6_flow_label),
    );
    result.insert("fragment_id".to_string(), json!(flow_msg.fragment_id));
    result.insert(
        "fragment_offset".to_string(),
        json!(flow_msg.fragment_offset),
    );
    result.insert("src_net".to_string(), json!(flow_msg.src_net));
    result.insert("dst_net".to_string(), json!(flow_msg.dst_net));
    result.insert("etype".to_string(), json!(flow_msg.etype));

    // BGP and MPLS
    result.insert(
        "bgp_communities".to_string(),
        json!(flow_msg.bgp_communities),
    );
    result.insert("as_path".to_string(), json!(flow_msg.as_path));
    result.insert("mpls_label".to_string(), json!(flow_msg.mpls_label));
    result.insert("mpls_ttl".to_string(), json!(flow_msg.mpls_ttl));

    // Observation
    result.insert(
        "observation_domain_id".to_string(),
        json!(flow_msg.observation_domain_id),
    );
    result.insert(
        "observation_point_id".to_string(),
        json!(flow_msg.observation_point_id),
    );

    Ok(Value::Object(result))
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
#[path = "flow_proto_tests.rs"]
mod tests;
