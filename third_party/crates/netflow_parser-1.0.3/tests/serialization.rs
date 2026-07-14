//! Tests for JSON serialization of parsed NetFlow packets.

use netflow_parser::{NetflowPacket, NetflowParser};

// Verify V5 packet serializes to JSON containing version identifier and number
#[test]
fn test_v5_serialization() {
    let v5_packet = [
        0, 5, 0, 1, 3, 0, 4, 0, 5, 0, 6, 7, 8, 9, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 0, 1, 2, 3, 4,
        5, 6, 7, 8, 9, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 0, 1, 2, 3,
        4, 5, 6, 7, 8, 9, 0, 1, 2, 3, 4, 5, 6, 7,
    ];

    let parsed = NetflowParser::default().parse_bytes(&v5_packet).packets;
    let json = serde_json::to_string(&parsed).expect("Failed to serialize");

    assert!(json.contains("\"V5\""));
    assert!(json.contains("\"version\":5"));
}

// Verify V5 parse produces exactly one packet with correct JSON
#[test]
fn test_v5_serialization_single_packet() {
    let v5_packet = [
        0, 5, 0, 1, 3, 0, 4, 0, 5, 0, 6, 7, 8, 9, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 0, 1, 2, 3, 4,
        5, 6, 7, 8, 9, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 0, 1, 2, 3,
        4, 5, 6, 7, 8, 9, 0, 1, 2, 3, 4, 5, 6, 7,
    ];

    let parsed = NetflowParser::default().parse_bytes(&v5_packet).packets;
    assert_eq!(
        parsed.len(),
        1,
        "V5 packet with count=1 must produce exactly 1 packet"
    );

    let json = serde_json::to_string(&parsed).expect("Failed to serialize");
    assert!(json.contains("\"V5\""));
    assert!(json.contains("\"version\":5"));
}

// Verify V5 packet pretty-prints to JSON with newlines and version data
#[test]
fn test_v5_json_pretty_print() {
    let v5_packet = [
        0, 5, 0, 1, 3, 0, 4, 0, 5, 0, 6, 7, 8, 9, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 0, 1, 2, 3, 4,
        5, 6, 7, 8, 9, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 0, 1, 2, 3,
        4, 5, 6, 7, 8, 9, 0, 1, 2, 3, 4, 5, 6, 7,
    ];

    let parsed = NetflowParser::default().parse_bytes(&v5_packet).packets;
    let json = serde_json::to_string_pretty(&parsed).expect("Failed to serialize");

    assert!(json.contains("\"V5\""));
    assert!(json.contains('\n')); // Pretty printed should have newlines
}

// Verify V5 header serializes independently with correct version and count fields
#[test]
fn test_v5_header_serialization() {
    let v5_packet = [
        0, 5, 0, 1, 3, 0, 4, 0, 5, 0, 6, 7, 8, 9, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 0, 1, 2, 3, 4,
        5, 6, 7, 8, 9, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 0, 1, 2, 3,
        4, 5, 6, 7, 8, 9, 0, 1, 2, 3, 4, 5, 6, 7,
    ];

    let parsed = NetflowParser::default().parse_bytes(&v5_packet).packets;

    if let NetflowPacket::V5(v5) = parsed.first().unwrap() {
        let header_json =
            serde_json::to_string(&v5.header).expect("Failed to serialize header");
        assert!(header_json.contains("\"version\":5"));
        assert!(header_json.contains("\"count\":1"));
    } else {
        panic!("Expected V5 packet");
    }
}

// Verify that parsing an unknown version number returns an empty result
#[test]
fn test_invalid_packet_handling() {
    // Invalid version number - parser returns empty vec for unknown versions
    let invalid_packet = [0, 99, 0, 0];

    let parsed = NetflowParser::default()
        .parse_bytes(&invalid_packet)
        .packets;

    // Parser filters out unknown versions, so result should be empty
    assert_eq!(parsed.len(), 0);
}
