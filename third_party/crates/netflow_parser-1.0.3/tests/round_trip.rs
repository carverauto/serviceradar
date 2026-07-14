//! Round-trip serialization tests: parse → to_be_bytes → assert equal.
//!
//! Verifies that parsing bytes and re-serializing produces identical output
//! for V5, V7, V9 (template + data), and IPFIX (template + data) packets,
//! as well as all individual IANA field types.

use netflow_parser::variable_versions::field_value::{FieldDataType, FieldValue};
use netflow_parser::{NetflowPacket, NetflowParser};

// ---------------------------------------------------------------------------
// V7 packet round-trip
// ---------------------------------------------------------------------------

#[test]
fn test_v7_round_trip() {
    // V7 header (24 bytes): version=7, count=1, sys_up_time, unix_secs, unix_nsecs, flow_seq, reserved
    // V7 flowset (52 bytes): one flow record
    let mut packet = vec![0u8; 24 + 52];
    // version = 7
    packet[0] = 0;
    packet[1] = 7;
    // count = 1
    packet[2] = 0;
    packet[3] = 1;
    // Fill remaining header + flowset with deterministic values
    for (i, byte) in packet.iter_mut().enumerate().skip(4) {
        *byte = (i % 256) as u8;
    }

    if let NetflowPacket::V7(v7) = NetflowParser::default()
        .parse_bytes(&packet)
        .packets
        .first()
        .unwrap()
    {
        assert_eq!(v7.to_be_bytes(), packet);
    } else {
        panic!("Expected V7 packet");
    }
}

// ---------------------------------------------------------------------------
// V9 template + data round-trip
// ---------------------------------------------------------------------------

#[test]
fn test_v9_template_and_data_round_trip() {
    // Template packet: defines template 256 with 4 aligned fields (each 4 bytes):
    //   sourceIPv4Address(8) len=4, destinationIPv4Address(12) len=4,
    //   ingressInterface(10) len=4, egressInterface(14) len=4
    // Record size = 16 bytes (4-byte aligned, no padding needed)
    //
    // V9 header (20 bytes): version=9, count=1, sysUpTime, unixSecs, seq=1, srcId=1
    // Template flowset: flowsetId=0, length=24, templateId=256, fieldCount=4, 4 fields
    let hex_template = "0009000100000e1061db09bd00000001000000010000001801000004\
                         00080004000c0004000a0004000e0004";

    let mut parser = NetflowParser::builder()
        .with_cache_size(100)
        .build()
        .unwrap();

    let template_bytes = hex::decode(hex_template).unwrap();
    let template_result = parser.parse_bytes(&template_bytes);
    assert!(template_result.error.is_none(), "Template parse failed");

    // Data packet: one record with the above template (16 bytes, aligned)
    //   src=192.168.1.1, dst=10.0.0.1, ingress=10, egress=20
    // Data flowset: flowsetId=256, length=20 (4 header + 16 data)
    let hex_data = "0009000100000e1061db09bd000000020000000101000014\
                    c0a801010a0000010000000a00000014";

    let data_bytes = hex::decode(hex_data).unwrap();
    let data_result = parser.parse_bytes(&data_bytes);
    assert!(data_result.error.is_none(), "Data parse failed");

    if let Some(NetflowPacket::V9(v9)) = data_result.packets.first() {
        let serialized = v9.to_be_bytes().expect("V9 serialization failed");
        assert_eq!(serialized, data_bytes, "V9 data packet round-trip failed");
    } else {
        panic!("Expected V9 data packet");
    }
}

#[test]
fn test_v9_template_only_round_trip() {
    // Same template as above: 4 aligned fields, no padding
    let hex_template = "0009000100000e1061db09bd00000001000000010000001801000004\
                         00080004000c0004000a0004000e0004";

    let mut parser = NetflowParser::builder()
        .with_cache_size(100)
        .build()
        .unwrap();

    let template_bytes = hex::decode(hex_template).unwrap();
    let result = parser.parse_bytes(&template_bytes);

    if let Some(NetflowPacket::V9(v9)) = result.packets.first() {
        let serialized = v9.to_be_bytes().expect("V9 template serialization failed");
        assert_eq!(
            serialized, template_bytes,
            "V9 template packet round-trip failed"
        );
    } else {
        panic!("Expected V9 template packet");
    }
}

// ---------------------------------------------------------------------------
// IPFIX template + data round-trip
// ---------------------------------------------------------------------------

#[test]
fn test_ipfix_template_and_data_round_trip() {
    // IPFIX template: Set ID=2, template_id=256, 4 aligned fields:
    //   sourceIPv4Address(8) len=4, destinationIPv4Address(12) len=4,
    //   ingressInterface(10) len=4, egressInterface(14) len=4
    // Record size = 16 bytes (4-byte aligned, no padding)
    // IPFIX header: version=10, length=40, exportTime, seqNum=8, obsDomainId
    // Template set: setId=2, length=24 (4 header + 4 template header + 16 fields)
    let hex_template = "000a002862a0b1b9000000086c6a7e11\
                         000200180100000400080004000c0004000a0004000e0004";

    let mut parser = NetflowParser::builder()
        .with_cache_size(100)
        .build()
        .unwrap();

    let template_bytes = hex::decode(hex_template).unwrap();
    let template_result = parser.parse_bytes(&template_bytes);
    assert!(
        template_result.error.is_none(),
        "IPFIX template parse failed"
    );

    // IPFIX data: src=192.168.1.1, dst=10.0.0.1, ingress=10, egress=20
    // Data set: setId=256, length=20 (4 header + 16 data)
    // IPFIX header: length=36 (16 header + 20 data set)
    let hex_data = "000a002462a0b1b9000000096c6a7e11\
                    01000014c0a801010a0000010000000a00000014";

    let data_bytes = hex::decode(hex_data).unwrap();
    let data_result = parser.parse_bytes(&data_bytes);

    if let Some(NetflowPacket::IPFix(ipfix)) = data_result.packets.first() {
        let serialized = ipfix.to_be_bytes().expect("IPFIX serialization failed");
        assert_eq!(
            serialized, data_bytes,
            "IPFIX data packet round-trip failed"
        );
    } else {
        panic!("Expected IPFIX data packet");
    }
}

#[test]
fn test_ipfix_template_only_round_trip() {
    let hex_template = "000a002462a0b1b9000000086c6a7e11\
                         000200140100000300080004000c000400040001";

    let mut parser = NetflowParser::builder()
        .with_cache_size(100)
        .build()
        .unwrap();

    let template_bytes = hex::decode(hex_template).unwrap();
    let result = parser.parse_bytes(&template_bytes);

    if let Some(NetflowPacket::IPFix(ipfix)) = result.packets.first() {
        let serialized = ipfix
            .to_be_bytes()
            .expect("IPFIX template serialization failed");
        assert_eq!(
            serialized, template_bytes,
            "IPFIX template packet round-trip failed"
        );
    } else {
        panic!("Expected IPFIX template packet");
    }
}

// ---------------------------------------------------------------------------
// V9 options template + data round-trip
// ---------------------------------------------------------------------------

#[test]
fn test_v9_options_template_and_data_round_trip() {
    // V9 options template: flowset_id=1
    // Template ID=257, scope_length=4 (1 scope field), options_length=4 (1 option field)
    // Scope field: System(1), length=4
    // Option field: TotalFlowsExp(42), length=4
    //
    // V9 header (20 bytes) + options template flowset:
    //   flowset_id=1, flowset_length=18 (4 header + 6 template header + 8 fields) + 2 padding = 20
    let mut parser = NetflowParser::builder()
        .with_cache_size(100)
        .build()
        .unwrap();

    // Build options template packet manually
    let mut template_packet = Vec::new();
    // V9 header
    template_packet.extend_from_slice(&9u16.to_be_bytes()); // version
    template_packet.extend_from_slice(&1u16.to_be_bytes()); // count=1
    template_packet.extend_from_slice(&0u32.to_be_bytes()); // sys_up_time
    template_packet.extend_from_slice(&0u32.to_be_bytes()); // unix_secs
    template_packet.extend_from_slice(&1u32.to_be_bytes()); // seq
    template_packet.extend_from_slice(&1u32.to_be_bytes()); // source_id
    // Options template flowset
    template_packet.extend_from_slice(&1u16.to_be_bytes()); // flowset_id=1 (options template)
    template_packet.extend_from_slice(&20u16.to_be_bytes()); // length=20 (4 header + 14 body + 2 padding)
    // template body: template_id + scope_length + options_length + scope_fields + option_fields
    template_packet.extend_from_slice(&257u16.to_be_bytes()); // template_id=257
    template_packet.extend_from_slice(&4u16.to_be_bytes()); // options_scope_length=4 (1 field * 4 bytes)
    template_packet.extend_from_slice(&4u16.to_be_bytes()); // options_length=4 (1 field * 4 bytes)
    template_packet.extend_from_slice(&1u16.to_be_bytes()); // scope field type=1 (System)
    template_packet.extend_from_slice(&4u16.to_be_bytes()); // scope field length=4
    template_packet.extend_from_slice(&42u16.to_be_bytes()); // option field type=42 (TotalFlowsExp)
    template_packet.extend_from_slice(&4u16.to_be_bytes()); // option field length=4
    // 2 bytes padding to 4-byte alignment (14 body bytes -> need 2 padding)
    template_packet.extend_from_slice(&[0u8; 2]);

    let result = parser.parse_bytes(&template_packet);
    assert!(
        result.error.is_none(),
        "V9 options template parse failed: {:?}",
        result.error
    );

    if let Some(NetflowPacket::V9(v9)) = result.packets.first() {
        let serialized = v9
            .to_be_bytes()
            .expect("V9 options template serialization failed");
        assert_eq!(
            serialized, template_packet,
            "V9 options template round-trip failed"
        );
    } else {
        panic!("Expected V9 options template packet");
    }

    // Now send options data using template 257
    let mut data_packet = Vec::new();
    // V9 header
    data_packet.extend_from_slice(&9u16.to_be_bytes()); // version
    data_packet.extend_from_slice(&1u16.to_be_bytes()); // count=1
    data_packet.extend_from_slice(&0u32.to_be_bytes()); // sys_up_time
    data_packet.extend_from_slice(&0u32.to_be_bytes()); // unix_secs
    data_packet.extend_from_slice(&2u32.to_be_bytes()); // seq
    data_packet.extend_from_slice(&1u32.to_be_bytes()); // source_id
    // Options data flowset
    data_packet.extend_from_slice(&257u16.to_be_bytes()); // flowset_id=257
    data_packet.extend_from_slice(&12u16.to_be_bytes()); // length=12 (4 header + 8 data)
    // scope data: 4 bytes for System scope
    data_packet.extend_from_slice(&[0x01, 0x02, 0x03, 0x04]);
    // option data: 4 bytes for TotalFlowsExp
    data_packet.extend_from_slice(&[0x00, 0x00, 0x00, 0x2A]);

    let data_result = parser.parse_bytes(&data_packet);
    assert!(
        data_result.error.is_none(),
        "V9 options data parse failed: {:?}",
        data_result.error
    );

    if let Some(NetflowPacket::V9(v9)) = data_result.packets.first() {
        let serialized = v9
            .to_be_bytes()
            .expect("V9 options data serialization failed");
        assert_eq!(serialized, data_packet, "V9 options data round-trip failed");
    } else {
        panic!("Expected V9 options data packet");
    }
}

// ---------------------------------------------------------------------------
// IPFIX options template + data round-trip
// ---------------------------------------------------------------------------

#[test]
fn test_ipfix_options_template_and_data_round_trip() {
    // IPFIX options template: Set ID=3
    // Template ID=258, field_count=2, scope_field_count=1
    // Scope field: sourceIPv4Address(8) len=4
    // Non-scope field: egressInterface(14) len=4
    let mut parser = NetflowParser::builder()
        .with_cache_size(100)
        .build()
        .unwrap();

    let template_set = {
        let mut set = Vec::new();
        set.extend_from_slice(&3u16.to_be_bytes()); // Set ID=3 (options template)
        set.extend_from_slice(&20u16.to_be_bytes()); // length=20 (4 header + 14 body + 2 padding)
        set.extend_from_slice(&258u16.to_be_bytes()); // template_id
        set.extend_from_slice(&2u16.to_be_bytes()); // field_count=2
        set.extend_from_slice(&1u16.to_be_bytes()); // scope_field_count=1
        set.extend_from_slice(&8u16.to_be_bytes()); // field: sourceIPv4Address
        set.extend_from_slice(&4u16.to_be_bytes()); // length=4
        set.extend_from_slice(&14u16.to_be_bytes()); // field: egressInterface
        set.extend_from_slice(&4u16.to_be_bytes()); // length=4
        set.extend_from_slice(&[0u8; 2]); // padding to 4-byte alignment
        set
    };

    let template_msg = build_ipfix_message(0x62A0B1B9, 20, 1, &template_set);
    let result = parser.parse_bytes(&template_msg);
    assert!(
        result.error.is_none(),
        "IPFIX options template parse failed: {:?}",
        result.error
    );

    if let Some(NetflowPacket::IPFix(ipfix)) = result.packets.first() {
        let serialized = ipfix
            .to_be_bytes()
            .expect("IPFIX options template serialization failed");
        assert_eq!(
            serialized, template_msg,
            "IPFIX options template round-trip failed"
        );
    } else {
        panic!("Expected IPFIX options template packet");
    }

    // Now send options data using template 258
    let data_set = {
        let mut set = Vec::new();
        set.extend_from_slice(&258u16.to_be_bytes()); // Set ID=258
        set.extend_from_slice(&12u16.to_be_bytes()); // length=12 (4 header + 8 data)
        set.extend_from_slice(&[192, 168, 1, 1]); // sourceIPv4Address (scope)
        set.extend_from_slice(&42u32.to_be_bytes()); // egressInterface (non-scope)
        set
    };

    let data_msg = build_ipfix_message(0x62A0B1B9, 21, 1, &data_set);
    let data_result = parser.parse_bytes(&data_msg);
    assert!(
        data_result.error.is_none(),
        "IPFIX options data parse failed: {:?}",
        data_result.error
    );

    if let Some(NetflowPacket::IPFix(ipfix)) = data_result.packets.first() {
        let serialized = ipfix
            .to_be_bytes()
            .expect("IPFIX options data serialization failed");
        assert_eq!(serialized, data_msg, "IPFIX options data round-trip failed");
    } else {
        panic!("Expected IPFIX options data packet");
    }
}

// ---------------------------------------------------------------------------
// Individual IANA field type round-trips via FieldValue
// ---------------------------------------------------------------------------

/// Helper: parse raw bytes as a given FieldDataType, then write_be_bytes, assert equal.
fn assert_field_round_trip(raw: &[u8], data_type: FieldDataType) {
    let (remaining, field_value) =
        FieldValue::from_field_type(raw, data_type, raw.len() as u16)
            .unwrap_or_else(|e| panic!("parse failed for {:?}: {:?}", data_type, e));
    assert!(
        remaining.is_empty(),
        "leftover bytes for {:?}: {} remaining",
        data_type,
        remaining.len()
    );
    let mut buf = Vec::new();
    field_value
        .write_be_bytes(&mut buf)
        .unwrap_or_else(|e| panic!("write failed for {:?}: {:?}", data_type, e));
    assert_eq!(
        buf, raw,
        "round-trip failed for {:?}: expected {:?}, got {:?}",
        data_type, raw, buf
    );
}

#[test]
fn test_field_round_trip_forwarding_status() {
    // 0x40 = status=1 (Forwarded), reason=0
    assert_field_round_trip(&[0x40], FieldDataType::ForwardingStatus);
    // 0xC3 = status=3 (Consumed), reason=3
    assert_field_round_trip(&[0xC3], FieldDataType::ForwardingStatus);
}

#[test]
fn test_field_round_trip_fragment_flags() {
    // 0x05 = reserved=true, more_fragments=true
    assert_field_round_trip(&[0x05], FieldDataType::FragmentFlags);
    // 0x02 = dont_fragment=true
    assert_field_round_trip(&[0x02], FieldDataType::FragmentFlags);
}

#[test]
fn test_field_round_trip_tcp_control_bits() {
    // 0x0012 = SYN + ACK
    assert_field_round_trip(&[0x00, 0x12], FieldDataType::TcpControlBits);
    // 0x01FF = all 9 flags set
    assert_field_round_trip(&[0x01, 0xFF], FieldDataType::TcpControlBits);
}

#[test]
fn test_field_round_trip_ipv6_extension_headers() {
    assert_field_round_trip(
        &[0x00, 0x00, 0x00, 0x3F],
        FieldDataType::Ipv6ExtensionHeaders,
    );
    assert_field_round_trip(
        &[0xFF, 0xFF, 0xFF, 0xFF],
        FieldDataType::Ipv6ExtensionHeaders,
    );
}

#[test]
fn test_field_round_trip_ipv4_options() {
    assert_field_round_trip(&[0x00, 0x7F, 0xFF, 0xFF], FieldDataType::Ipv4Options);
    assert_field_round_trip(&[0xFF, 0xFF, 0xFF, 0xFF], FieldDataType::Ipv4Options);
}

#[test]
fn test_field_round_trip_tcp_options() {
    assert_field_round_trip(
        &[0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08],
        FieldDataType::TcpOptions,
    );
    assert_field_round_trip(
        &[0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF],
        FieldDataType::TcpOptions,
    );
}

#[test]
fn test_field_round_trip_is_multicast() {
    assert_field_round_trip(&[0x00], FieldDataType::IsMulticast);
    assert_field_round_trip(&[0x01], FieldDataType::IsMulticast);
    assert_field_round_trip(&[0xFF], FieldDataType::IsMulticast);
}

#[test]
fn test_field_round_trip_mpls_label_exp() {
    // Only 3 bits are preserved (0-7)
    assert_field_round_trip(&[0x00], FieldDataType::MplsLabelExp);
    assert_field_round_trip(&[0x07], FieldDataType::MplsLabelExp);
}

#[test]
fn test_field_round_trip_flow_end_reason() {
    assert_field_round_trip(&[0x01], FieldDataType::FlowEndReason); // IdleTimeout
    assert_field_round_trip(&[0x05], FieldDataType::FlowEndReason); // LackOfResources
    assert_field_round_trip(&[0xFF], FieldDataType::FlowEndReason); // Unknown(255)
}

#[test]
fn test_field_round_trip_nat_event() {
    assert_field_round_trip(&[0x01], FieldDataType::NatEvent); // NatCreateEvent
    assert_field_round_trip(&[0x12], FieldDataType::NatEvent); // NatQuotaExceeded
    assert_field_round_trip(&[0xFF], FieldDataType::NatEvent); // Unknown(255)
}

#[test]
fn test_field_round_trip_firewall_event() {
    assert_field_round_trip(&[0x00], FieldDataType::FirewallEvent); // Ignored
    assert_field_round_trip(&[0x05], FieldDataType::FirewallEvent); // FlowUpdate
    assert_field_round_trip(&[0xAB], FieldDataType::FirewallEvent); // Unknown(171)
}

#[test]
fn test_field_round_trip_mpls_top_label_type() {
    assert_field_round_trip(&[0x00], FieldDataType::MplsTopLabelType); // Unknown
    assert_field_round_trip(&[0x06], FieldDataType::MplsTopLabelType); // Vpn
    assert_field_round_trip(&[0x7F], FieldDataType::MplsTopLabelType); // Unassigned(127)
}

#[test]
fn test_field_round_trip_nat_originating_address_realm() {
    assert_field_round_trip(&[0x01], FieldDataType::NatOriginatingAddressRealm); // Private
    assert_field_round_trip(&[0x02], FieldDataType::NatOriginatingAddressRealm); // Public
    assert_field_round_trip(&[0x00], FieldDataType::NatOriginatingAddressRealm); // Unknown(0)
}

// ---------------------------------------------------------------------------
// Already-covered types: verify they still work
// ---------------------------------------------------------------------------

#[test]
fn test_field_round_trip_ip4addr() {
    assert_field_round_trip(&[192, 168, 0, 1], FieldDataType::Ip4Addr);
}

#[test]
fn test_field_round_trip_ip6addr() {
    assert_field_round_trip(
        &[0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1],
        FieldDataType::Ip6Addr,
    );
}

#[test]
fn test_field_round_trip_mac_addr() {
    assert_field_round_trip(
        &[0x00, 0x1B, 0x44, 0x11, 0x3A, 0xB7],
        FieldDataType::MacAddr,
    );
}

#[test]
fn test_field_round_trip_protocol_type() {
    assert_field_round_trip(&[6], FieldDataType::ProtocolType); // TCP
    assert_field_round_trip(&[17], FieldDataType::ProtocolType); // UDP
}

#[test]
fn test_field_round_trip_unsigned_data_number() {
    // 1 byte
    assert_field_round_trip(&[42], FieldDataType::UnsignedDataNumber);
    // 2 bytes
    assert_field_round_trip(&[0x30, 0x39], FieldDataType::UnsignedDataNumber);
    // 4 bytes
    assert_field_round_trip(&[0x01, 0x02, 0x03, 0x04], FieldDataType::UnsignedDataNumber);
    // 8 bytes
    assert_field_round_trip(
        &[0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08],
        FieldDataType::UnsignedDataNumber,
    );
}

#[test]
fn test_field_round_trip_signed_data_number() {
    // 1 byte
    assert_field_round_trip(&[0x80], FieldDataType::SignedDataNumber); // -128
    // 2 bytes
    assert_field_round_trip(&[0xFF, 0x00], FieldDataType::SignedDataNumber);
    // 3 bytes
    assert_field_round_trip(&[0xFF, 0x80, 0x00], FieldDataType::SignedDataNumber);
    // 4 bytes
    assert_field_round_trip(&[0xFF, 0xFF, 0xFF, 0xFE], FieldDataType::SignedDataNumber);
    // 8 bytes
    assert_field_round_trip(
        &[0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFE],
        FieldDataType::SignedDataNumber,
    );
}

#[test]
fn test_field_round_trip_float64() {
    let bytes = 123.456f64.to_be_bytes();
    assert_field_round_trip(&bytes, FieldDataType::Float64);
}

#[test]
fn test_field_round_trip_duration_seconds() {
    // 4 bytes
    assert_field_round_trip(&[0x00, 0x00, 0x30, 0x39], FieldDataType::DurationSeconds);
    // 8 bytes
    assert_field_round_trip(
        &[0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x30, 0x39],
        FieldDataType::DurationSeconds,
    );
}

#[test]
fn test_field_round_trip_duration_millis() {
    // 4 bytes
    assert_field_round_trip(&[0x00, 0x01, 0x51, 0x80], FieldDataType::DurationMillis);
    // 8 bytes
    assert_field_round_trip(
        &[0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x51, 0x80],
        FieldDataType::DurationMillis,
    );
}

#[test]
fn test_field_round_trip_string() {
    assert_field_round_trip(b"hello", FieldDataType::String);
}

// ---------------------------------------------------------------------------
// FieldValue direct construction round-trips for write_be_bytes
// ---------------------------------------------------------------------------

#[test]
fn test_field_value_application_id_round_trip() {
    // 1 byte engine ID + 3 byte selector = 4 bytes total
    let raw = &[0x0A, 0x01, 0x02, 0x03];
    let (remaining, field_value) =
        FieldValue::from_field_type(raw, FieldDataType::ApplicationId, 4).unwrap();
    assert!(remaining.is_empty());

    let mut buf = Vec::new();
    field_value.write_be_bytes(&mut buf).unwrap();
    assert_eq!(buf, raw, "ApplicationId round-trip failed");
}

#[test]
fn test_field_value_application_id_1_byte() {
    // 1 byte engine ID only, no selector
    let raw = &[0x05];
    let (remaining, field_value) =
        FieldValue::from_field_type(raw, FieldDataType::ApplicationId, 1).unwrap();
    assert!(remaining.is_empty());

    let mut buf = Vec::new();
    field_value.write_be_bytes(&mut buf).unwrap();
    assert_eq!(buf, raw, "ApplicationId 1-byte round-trip failed");
}

// ---------------------------------------------------------------------------
// Typed field with wrong length falls back to Vec (still round-trips)
// ---------------------------------------------------------------------------

#[test]
fn test_field_wrong_length_fallback_round_trips() {
    // Ip4Addr expects 4 bytes; give it 8 → falls back to Vec
    let raw = &[1, 2, 3, 4, 5, 6, 7, 8];
    let (remaining, field_value) =
        FieldValue::from_field_type(raw, FieldDataType::Ip4Addr, 8).unwrap();
    assert!(remaining.is_empty());
    assert!(matches!(field_value, FieldValue::Vec(_)));

    let mut buf = Vec::new();
    field_value.write_be_bytes(&mut buf).unwrap();
    assert_eq!(buf, raw, "Vec fallback round-trip failed");
}

// ---------------------------------------------------------------------------
// IPFIX variable-length field round-trips (RFC 7011 Section 7)
// ---------------------------------------------------------------------------

/// Build an IPFIX message from raw template set bytes and data set bytes.
fn build_ipfix_message(export_time: u32, seq: u32, obs_domain: u32, sets: &[u8]) -> Vec<u8> {
    let total_len = (16 + sets.len()) as u16;
    let mut msg = Vec::with_capacity(total_len as usize);
    msg.extend_from_slice(&10u16.to_be_bytes()); // version
    msg.extend_from_slice(&total_len.to_be_bytes()); // length
    msg.extend_from_slice(&export_time.to_be_bytes());
    msg.extend_from_slice(&seq.to_be_bytes());
    msg.extend_from_slice(&obs_domain.to_be_bytes());
    msg.extend_from_slice(sets);
    msg
}

/// Build an IPFIX template set (Set ID = 2) with the given template_id and
/// field definitions as (field_type_number, field_length) pairs.
fn build_ipfix_template_set(template_id: u16, fields: &[(u16, u16)]) -> Vec<u8> {
    // Set header (4) + template header (4) + fields (4 each)
    let set_len = (4 + 4 + fields.len() * 4) as u16;
    let mut set = Vec::with_capacity(set_len as usize);
    set.extend_from_slice(&2u16.to_be_bytes()); // Set ID = 2 (template)
    set.extend_from_slice(&set_len.to_be_bytes());
    set.extend_from_slice(&template_id.to_be_bytes());
    set.extend_from_slice(&(fields.len() as u16).to_be_bytes());
    for &(type_num, length) in fields {
        set.extend_from_slice(&type_num.to_be_bytes());
        set.extend_from_slice(&length.to_be_bytes());
    }
    set
}

#[test]
fn test_ipfix_varlen_short_round_trip() {
    // Template: sourceIPv4Address(8) len=4, applicationDescription(94) len=65535
    let template_set = build_ipfix_template_set(256, &[(8, 4), (94, 65535)]);
    let template_msg = build_ipfix_message(0x62A0B1B9, 8, 1, &template_set);

    let mut parser = NetflowParser::builder()
        .with_cache_size(100)
        .build()
        .unwrap();

    let result = parser.parse_bytes(&template_msg);
    assert!(result.error.is_none(), "Template parse failed");

    // Data: src=192.168.1.1, varlen "abc" (1-byte prefix: 0x03)
    // Record = 4 + 1 + 3 = 8 bytes (4-byte aligned)
    let mut data_set = Vec::new();
    data_set.extend_from_slice(&256u16.to_be_bytes()); // Set ID
    data_set.extend_from_slice(&12u16.to_be_bytes()); // Set length = 4 header + 8 body
    data_set.extend_from_slice(&[192, 168, 1, 1]); // sourceIPv4Address
    data_set.push(3); // varlen prefix: length=3
    data_set.extend_from_slice(b"abc"); // applicationDescription

    let data_msg = build_ipfix_message(0x62A0B1B9, 9, 1, &data_set);
    let data_result = parser.parse_bytes(&data_msg);
    assert!(
        data_result.error.is_none(),
        "Data parse failed: {:?}",
        data_result.error
    );

    if let Some(NetflowPacket::IPFix(ipfix)) = data_result.packets.first() {
        let serialized = ipfix
            .to_be_bytes()
            .expect("IPFIX varlen serialization failed");
        assert_eq!(
            serialized, data_msg,
            "IPFIX varlen short field round-trip failed"
        );
    } else {
        panic!("Expected IPFIX data packet");
    }
}

#[test]
fn test_ipfix_varlen_long_round_trip() {
    // Template: single variable-length string field
    // Using interfaceDescription (83) as a variable-length string field
    let template_set = build_ipfix_template_set(257, &[(83, 65535)]);
    let template_msg = build_ipfix_message(0x62A0B1B9, 10, 1, &template_set);

    let mut parser = NetflowParser::builder()
        .with_cache_size(100)
        .build()
        .unwrap();

    let result = parser.parse_bytes(&template_msg);
    assert!(result.error.is_none(), "Template parse failed");

    // Data with 3-byte prefix (value length = 300 bytes, >= 255)
    let value_len: u16 = 300;
    let value: Vec<u8> = (0..value_len).map(|i| (i % 26 + 0x61) as u8).collect(); // "abcdef..."

    let body_len = 3 + value_len as usize; // 3-byte prefix + 300 bytes
    let padding_needed = (4 - (body_len % 4)) % 4;
    let set_len = 4 + body_len + padding_needed;

    let mut data_set = Vec::new();
    data_set.extend_from_slice(&257u16.to_be_bytes()); // Set ID
    data_set.extend_from_slice(&(set_len as u16).to_be_bytes());
    data_set.push(255); // varlen marker: length >= 255
    data_set.extend_from_slice(&value_len.to_be_bytes()); // 2-byte length
    data_set.extend_from_slice(&value);
    // Padding
    data_set.extend(std::iter::repeat_n(0u8, padding_needed));

    let data_msg = build_ipfix_message(0x62A0B1B9, 11, 1, &data_set);
    let data_result = parser.parse_bytes(&data_msg);
    assert!(
        data_result.error.is_none(),
        "Long varlen data parse failed: {:?}",
        data_result.error
    );

    if let Some(NetflowPacket::IPFix(ipfix)) = data_result.packets.first() {
        let serialized = ipfix
            .to_be_bytes()
            .expect("IPFIX long varlen serialization failed");
        assert_eq!(
            serialized, data_msg,
            "IPFIX varlen long field (3-byte prefix) round-trip failed"
        );
    } else {
        panic!("Expected IPFIX data packet");
    }
}

#[test]
fn test_ipfix_mixed_fixed_and_varlen_round_trip() {
    // Template: fixed(4) + varlen + fixed(4) — varlen field sandwiched between fixed
    // sourceIPv4Address(8) len=4, applicationDescription(94) len=65535, egressInterface(14) len=4
    let template_set = build_ipfix_template_set(258, &[(8, 4), (94, 65535), (14, 4)]);
    let template_msg = build_ipfix_message(0x62A0B1B9, 12, 1, &template_set);

    let mut parser = NetflowParser::builder()
        .with_cache_size(100)
        .build()
        .unwrap();

    let result = parser.parse_bytes(&template_msg);
    assert!(result.error.is_none(), "Template parse failed");

    // Data: src=10.0.0.1, varlen "test" (4 bytes, 1-byte prefix), egress=42
    // Record = 4 + 1 + 4 + 4 = 13 bytes → 3 bytes padding to reach 16
    let mut data_set = Vec::new();
    data_set.extend_from_slice(&258u16.to_be_bytes());
    let body_len = 4 + 1 + 4 + 4; // 13
    let padding = (4 - (body_len % 4)) % 4; // 3
    let set_len = 4 + body_len + padding;
    data_set.extend_from_slice(&(set_len as u16).to_be_bytes());
    data_set.extend_from_slice(&[10, 0, 0, 1]); // sourceIPv4Address
    data_set.push(4); // varlen prefix: length=4
    data_set.extend_from_slice(b"test"); // applicationDescription
    data_set.extend_from_slice(&42u32.to_be_bytes()); // egressInterface
    data_set.extend(std::iter::repeat_n(0u8, padding));

    let data_msg = build_ipfix_message(0x62A0B1B9, 13, 1, &data_set);
    let data_result = parser.parse_bytes(&data_msg);
    assert!(
        data_result.error.is_none(),
        "Mixed parse failed: {:?}",
        data_result.error
    );

    if let Some(NetflowPacket::IPFix(ipfix)) = data_result.packets.first() {
        let serialized = ipfix
            .to_be_bytes()
            .expect("Mixed varlen serialization failed");
        assert_eq!(
            serialized, data_msg,
            "IPFIX mixed fixed+varlen round-trip failed"
        );
    } else {
        panic!("Expected IPFIX data packet");
    }
}

// ---------------------------------------------------------------------------
// Additional individual field type round-trips
// ---------------------------------------------------------------------------

#[test]
fn test_field_round_trip_duration_micros_ntp() {
    // DurationMicrosNTP expects exactly 8 bytes (NTP timestamp: 4 bytes seconds + 4 bytes fraction)
    assert_field_round_trip(
        &[0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07],
        FieldDataType::DurationMicrosNTP,
    );
}

#[test]
fn test_field_round_trip_duration_nanos_ntp() {
    // DurationNanosNTP expects exactly 8 bytes (NTP timestamp: 4 bytes seconds + 4 bytes fraction)
    assert_field_round_trip(
        &[0xAA, 0xBB, 0xCC, 0xDD, 0x11, 0x22, 0x33, 0x44],
        FieldDataType::DurationNanosNTP,
    );
}

#[test]
fn test_field_round_trip_unsigned_data_number_16_bytes() {
    // 16 bytes should produce a U128 variant
    assert_field_round_trip(
        &[
            0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x0E,
            0x0F, 0x10,
        ],
        FieldDataType::UnsignedDataNumber,
    );
}

#[test]
fn test_field_round_trip_signed_data_number_16_bytes() {
    // 16 bytes should produce an I128 variant
    assert_field_round_trip(
        &[
            0xFF, 0xFE, 0xFD, 0xFC, 0xFB, 0xFA, 0xF9, 0xF8, 0xF7, 0xF6, 0xF5, 0xF4, 0xF3, 0xF2,
            0xF1, 0xF0,
        ],
        FieldDataType::SignedDataNumber,
    );
}

#[test]
fn test_field_round_trip_unsigned_data_number_3_bytes() {
    // 3 bytes should produce a U24 variant
    assert_field_round_trip(&[0x12, 0x34, 0x56], FieldDataType::UnsignedDataNumber);
}

// ---------------------------------------------------------------------------
// IPFIX enterprise field template + data round-trip
// ---------------------------------------------------------------------------

#[test]
#[cfg(feature = "parse_unknown_fields")]
fn test_ipfix_enterprise_field_round_trip() {
    // Build an IPFIX template with one enterprise field and one normal field.
    // Enterprise field format: field_type_number with bit 15 set (2 bytes),
    //   field_length (2 bytes), enterprise_number (4 bytes) = 8 bytes per enterprise field.
    // Normal field: field_type_number (2 bytes), field_length (2 bytes) = 4 bytes.
    //
    // Template: template_id=260, field_count=2
    //   Field 1: enterprise field, type=1 (with enterprise bit: 0x8001), length=4, enterprise=12345
    //   Field 2: normal field, sourceIPv4Address(8), length=4
    //
    // Template set: setId=2, length = 4 (set header) + 4 (template header) + 8 (enterprise field) + 4 (normal field) = 20

    let mut template_set = Vec::new();
    template_set.extend_from_slice(&2u16.to_be_bytes()); // Set ID = 2 (template)
    template_set.extend_from_slice(&20u16.to_be_bytes()); // Set length = 20
    template_set.extend_from_slice(&260u16.to_be_bytes()); // template_id
    template_set.extend_from_slice(&2u16.to_be_bytes()); // field_count = 2
    // Enterprise field: type with enterprise bit set
    template_set.extend_from_slice(&0x8001u16.to_be_bytes()); // field_type=1, enterprise bit set
    template_set.extend_from_slice(&4u16.to_be_bytes()); // field_length=4
    template_set.extend_from_slice(&12345u32.to_be_bytes()); // enterprise_number=12345
    // Normal field: sourceIPv4Address(8) len=4
    template_set.extend_from_slice(&8u16.to_be_bytes()); // field_type=8
    template_set.extend_from_slice(&4u16.to_be_bytes()); // field_length=4

    let template_msg = build_ipfix_message(0x62A0B1B9, 30, 1, &template_set);

    let mut parser = NetflowParser::builder()
        .with_cache_size(100)
        .build()
        .unwrap();

    let result = parser.parse_bytes(&template_msg);
    assert!(
        result.error.is_none(),
        "IPFIX enterprise template parse failed: {:?}",
        result.error
    );

    // Verify template round-trip
    if let Some(NetflowPacket::IPFix(ipfix)) = result.packets.first() {
        let serialized = ipfix
            .to_be_bytes()
            .expect("IPFIX enterprise template serialization failed");
        assert_eq!(
            serialized, template_msg,
            "IPFIX enterprise template round-trip failed"
        );
    } else {
        panic!("Expected IPFIX template packet");
    }

    // Data: 4 bytes for enterprise field + 4 bytes for sourceIPv4Address = 8 bytes
    let mut data_set = Vec::new();
    data_set.extend_from_slice(&260u16.to_be_bytes()); // Set ID = 260
    data_set.extend_from_slice(&12u16.to_be_bytes()); // Set length = 4 header + 8 data = 12
    data_set.extend_from_slice(&[0xDE, 0xAD, 0xBE, 0xEF]); // enterprise field data
    data_set.extend_from_slice(&[192, 168, 1, 1]); // sourceIPv4Address

    let data_msg = build_ipfix_message(0x62A0B1B9, 31, 1, &data_set);
    let data_result = parser.parse_bytes(&data_msg);
    assert!(
        data_result.error.is_none(),
        "IPFIX enterprise data parse failed: {:?}",
        data_result.error
    );

    if let Some(NetflowPacket::IPFix(ipfix)) = data_result.packets.first() {
        let serialized = ipfix
            .to_be_bytes()
            .expect("IPFIX enterprise data serialization failed");
        assert_eq!(
            serialized, data_msg,
            "IPFIX enterprise data round-trip failed"
        );
    } else {
        panic!("Expected IPFIX data packet");
    }
}

// ---------------------------------------------------------------------------
// V9 multiple templates in a single template flowset
// ---------------------------------------------------------------------------

#[test]
fn test_v9_multi_template_in_single_flowset() {
    // Build a V9 packet with one template flowset containing two template definitions:
    //   Template 256: 2 fields - sourceIPv4Address(8) len=4, destinationIPv4Address(12) len=4
    //   Template 257: 1 field  - ingressInterface(10) len=4
    //
    // Template flowset layout:
    //   flowset_id=0 (2 bytes), flowset_length (2 bytes)
    //   Template 256: template_id(2) + field_count(2) + 2 fields * 4 bytes = 12 bytes
    //   Template 257: template_id(2) + field_count(2) + 1 field  * 4 bytes =  8 bytes
    //   Total body = 12 + 8 = 20 bytes
    //   flowset_length = 4 (header) + 20 (body) = 24 bytes

    let mut packet = Vec::new();
    // V9 header (20 bytes)
    packet.extend_from_slice(&9u16.to_be_bytes()); // version
    packet.extend_from_slice(&1u16.to_be_bytes()); // count=1 (one flowset)
    packet.extend_from_slice(&0u32.to_be_bytes()); // sys_up_time
    packet.extend_from_slice(&0u32.to_be_bytes()); // unix_secs
    packet.extend_from_slice(&1u32.to_be_bytes()); // seq
    packet.extend_from_slice(&1u32.to_be_bytes()); // source_id

    // Template flowset
    packet.extend_from_slice(&0u16.to_be_bytes()); // flowset_id=0 (template)
    packet.extend_from_slice(&24u16.to_be_bytes()); // flowset_length=24

    // Template 256: 2 fields
    packet.extend_from_slice(&256u16.to_be_bytes()); // template_id=256
    packet.extend_from_slice(&2u16.to_be_bytes()); // field_count=2
    packet.extend_from_slice(&8u16.to_be_bytes()); // sourceIPv4Address
    packet.extend_from_slice(&4u16.to_be_bytes()); // length=4
    packet.extend_from_slice(&12u16.to_be_bytes()); // destinationIPv4Address
    packet.extend_from_slice(&4u16.to_be_bytes()); // length=4

    // Template 257: 1 field
    packet.extend_from_slice(&257u16.to_be_bytes()); // template_id=257
    packet.extend_from_slice(&1u16.to_be_bytes()); // field_count=1
    packet.extend_from_slice(&10u16.to_be_bytes()); // ingressInterface
    packet.extend_from_slice(&4u16.to_be_bytes()); // length=4

    let mut parser = NetflowParser::builder()
        .with_cache_size(100)
        .build()
        .unwrap();

    let result = parser.parse_bytes(&packet);
    assert!(
        result.error.is_none(),
        "V9 multi-template parse failed: {:?}",
        result.error
    );

    // Both templates should be cached
    assert!(
        parser.has_v9_template(256),
        "Template 256 should be cached after multi-template flowset"
    );
    assert!(
        parser.has_v9_template(257),
        "Template 257 should be cached after multi-template flowset"
    );
}

#[test]
fn test_ipfix_fixed_only_template_no_varlen_overhead() {
    // Verify that a template with only fixed-length fields does NOT
    // populate template_field_lengths (optimization check).
    let hex_template = "000a002862a0b1b9000000086c6a7e11\
                         000200180100000400080004000c0004000a0004000e0004";

    let mut parser = NetflowParser::builder()
        .with_cache_size(100)
        .build()
        .unwrap();

    let template_bytes = hex::decode(hex_template).unwrap();
    let _ = parser.parse_bytes(&template_bytes);

    // Parse data
    let hex_data = "000a002462a0b1b9000000096c6a7e11\
                    01000014c0a801010a0000010000000a00000014";
    let data_bytes = hex::decode(hex_data).unwrap();
    let data_result = parser.parse_bytes(&data_bytes);

    if let Some(NetflowPacket::IPFix(ipfix)) = data_result.packets.first() {
        // Verify round-trip still works
        let serialized = ipfix.to_be_bytes().expect("serialization failed");
        assert_eq!(serialized, data_bytes);

        // Verify template_field_lengths is empty (optimization)
        for flowset in &ipfix.flowsets {
            if let netflow_parser::variable_versions::ipfix::FlowSetBody::Data(data) =
                &flowset.body
            {
                assert!(
                    !data.has_varlen_metadata(),
                    "template_field_lengths should be empty for fixed-length-only templates"
                );
            }
        }
    } else {
        panic!("Expected IPFIX data packet");
    }
}
