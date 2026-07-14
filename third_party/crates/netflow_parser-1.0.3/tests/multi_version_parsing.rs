//! Tests for parsing and filtering across multiple NetFlow versions (V5, V7, V9, IPFIX).

use netflow_parser::{NetflowPacket, NetflowParser};

// Verify V5 packet parses with correct header version and flow count
#[test]
fn test_parse_v5_packet() {
    let v5_packet = [
        0, 5, 0, 1, 3, 0, 4, 0, 5, 0, 6, 7, 8, 9, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 0, 1, 2, 3, 4,
        5, 6, 7, 8, 9, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 0, 1, 2, 3,
        4, 5, 6, 7, 8, 9, 0, 1, 2, 3, 4, 5, 6, 7,
    ];

    let packets = NetflowParser::default().parse_bytes(&v5_packet).packets;
    assert_eq!(packets.len(), 1);

    match packets.first().unwrap() {
        NetflowPacket::V5(v5) => {
            assert_eq!(v5.header.version, 5);
            assert_eq!(v5.header.count, 1);
        }
        _ => panic!("Expected V5 packet"),
    }
}

// Verify V5 packet is filtered out when only V9 is allowed
#[test]
fn test_parse_v5_with_version_filter() {
    let v5_packet = [
        0, 5, 0, 1, 3, 0, 4, 0, 5, 0, 6, 7, 8, 9, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 0, 1, 2, 3, 4,
        5, 6, 7, 8, 9, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 0, 1, 2, 3,
        4, 5, 6, 7, 8, 9, 0, 1, 2, 3, 4, 5, 6, 7,
    ];

    // Allow only V9
    let mut parser = NetflowParser::builder()
        .with_allowed_versions(&[9])
        .build()
        .expect("Failed to build parser");

    let packets = parser.parse_bytes(&v5_packet).packets;
    assert_eq!(packets.len(), 0); // Should be filtered out
}

// Verify parsed packets can be filtered to only V5 using the is_v5 helper
#[test]
fn test_filter_v5_packets() {
    let v5_packet = [
        0, 5, 0, 1, 3, 0, 4, 0, 5, 0, 6, 7, 8, 9, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 0, 1, 2, 3, 4,
        5, 6, 7, 8, 9, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 0, 1, 2, 3,
        4, 5, 6, 7, 8, 9, 0, 1, 2, 3, 4, 5, 6, 7,
    ];

    let parsed = NetflowParser::default().parse_bytes(&v5_packet).packets;
    let v5_parsed: Vec<NetflowPacket> = parsed.into_iter().filter(|p| p.is_v5()).collect();

    assert_eq!(v5_parsed.len(), 1);
    assert!(v5_parsed.first().unwrap().is_v5());
}

// Verify V5 packet round-trips back to identical bytes via to_be_bytes
#[test]
fn test_v5_round_trip() {
    let packet = [
        0, 5, 0, 1, 3, 0, 4, 0, 5, 0, 6, 7, 8, 9, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 0, 1, 2, 3, 4,
        5, 6, 7, 8, 9, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 0, 1, 2, 3,
        4, 5, 6, 7, 8, 9, 0, 1, 2, 3, 4, 5, 6, 7,
    ];

    if let NetflowPacket::V5(v5) = NetflowParser::default()
        .parse_bytes(&packet)
        .packets
        .first()
        .unwrap()
    {
        assert_eq!(v5.to_be_bytes(), packet);
    } else {
        panic!("Expected V5 packet");
    }
}

// Verify iter_packets yields each packet and identifies it as V5
#[test]
fn test_iterator_api() {
    let v5_packet = [
        0, 5, 0, 1, 3, 0, 4, 0, 5, 0, 6, 7, 8, 9, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 0, 1, 2, 3, 4,
        5, 6, 7, 8, 9, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 0, 1, 2, 3,
        4, 5, 6, 7, 8, 9, 0, 1, 2, 3, 4, 5, 6, 7,
    ];

    let mut parser = NetflowParser::default();
    let mut count = 0;

    for packet in parser.iter_packets(&v5_packet) {
        count += 1;
        assert!(packet.unwrap().is_v5());
    }

    assert_eq!(count, 1);
}

// Verify iterator reports complete with no remaining bytes after full consumption
#[test]
fn test_iterator_completion() {
    let v5_packet = [
        0, 5, 0, 1, 3, 0, 4, 0, 5, 0, 6, 7, 8, 9, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 0, 1, 2, 3, 4,
        5, 6, 7, 8, 9, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 0, 1, 2, 3,
        4, 5, 6, 7, 8, 9, 0, 1, 2, 3, 4, 5, 6, 7,
    ];

    let mut parser = NetflowParser::default();
    let mut iter = parser.iter_packets(&v5_packet);

    while iter.next().is_some() {}

    assert!(iter.is_complete());
    assert_eq!(iter.remaining().len(), 0);
}

// Verify iterator supports filter_map chaining to count V5 packets
#[test]
fn test_iterator_filter() {
    let v5_packet = [
        0, 5, 0, 1, 3, 0, 4, 0, 5, 0, 6, 7, 8, 9, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 0, 1, 2, 3, 4,
        5, 6, 7, 8, 9, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 0, 1, 2, 3,
        4, 5, 6, 7, 8, 9, 0, 1, 2, 3, 4, 5, 6, 7,
    ];

    let mut parser = NetflowParser::default();
    let count = parser
        .iter_packets(&v5_packet)
        .filter_map(|p| p.ok())
        .filter(|p| p.is_v5())
        .count();

    assert_eq!(count, 1);
}

// ---------------------------------------------------------------------------
// parse_bytes_as_netflow_common_flowsets
// ---------------------------------------------------------------------------

/// Verify parse_bytes_as_netflow_common_flowsets converts V5 packets correctly.
#[cfg(feature = "netflow_common")]
#[test]
fn test_parse_bytes_as_netflow_common_v5() {
    let mut parser = NetflowParser::default();

    // Minimal V5 packet: header(24) + 1 flow(48) = 72 bytes
    let v5_packet: Vec<u8> = vec![
        0, 5, // version
        0, 1, // count = 1
        0, 0, 0, 0, // sys_uptime
        0, 0, 0, 0, // unix_secs
        0, 0, 0, 0, // unix_nsecs
        0, 0, 0, 0, // flow_sequence
        0, // engine_type
        0, // engine_id
        0, 0, // sampling_interval
        // Flow record (48 bytes)
        192, 168, 1, 1, // src_addr
        10, 0, 0, 1, // dst_addr
        0, 0, 0, 0, // next_hop
        0, 0, // input
        0, 0, // output
        0, 0, 0, 100, // packets
        0, 0, 0, 200, // octets
        0, 0, 0, 0, // first
        0, 0, 0, 0, // last
        0, 80, // src_port = 80
        0x1F, 0x90, // dst_port = 8080
        0,    // pad1
        0,    // tcp_flags
        6,    // protocol = TCP
        0,    // tos
        0, 0, // src_as
        0, 0, // dst_as
        0, // src_mask
        0, // dst_mask
        0, 0, // pad2
    ];

    let (flowsets, error) = parser.parse_bytes_as_netflow_common_flowsets(&v5_packet);
    assert!(error.is_none(), "V5 parse should succeed");
    assert_eq!(flowsets.len(), 1, "Should produce 1 common flowset from V5");
}

/// Verify parse_bytes_as_netflow_common_flowsets handles errors gracefully.
#[cfg(feature = "netflow_common")]
#[test]
fn test_parse_bytes_as_netflow_common_error() {
    let mut parser = NetflowParser::default();

    let garbage = vec![0xFF; 10];
    let (flowsets, error) = parser.parse_bytes_as_netflow_common_flowsets(&garbage);
    assert!(error.is_some(), "Garbage input should produce error");
    assert!(flowsets.is_empty(), "No flowsets from garbage input");
}
