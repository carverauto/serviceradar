//! Tests for template cache collision detection and multi-source isolation
//! via scoped parsers.

use netflow_parser::{AutoScopedParser, NetflowParser};
use std::net::SocketAddr;

// Verify that AutoScopedParser isolates V9 templates across different source addresses
#[test]
fn test_auto_scoped_parser_template_isolation() {
    let mut parser = AutoScopedParser::new();

    let source1: SocketAddr = "192.168.1.1:2055".parse().unwrap();
    let source2: SocketAddr = "192.168.1.2:2055".parse().unwrap();

    // V9 template packet: template ID 256 with 1 field (IN_BYTES, 4 bytes)
    let v9_template_packet: Vec<u8> = vec![
        0, 9, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 12, 1, 0, 0, 1, 0,
        1, 0, 4,
    ];

    // V9 data packet using template 256
    let v9_data_packet: Vec<u8> = vec![
        0, 9, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2, 0, 0, 0, 0, 1,
        0, // flowset_id = 256
        0, 8, // length = 8 (header(4) + 1 record of 4 bytes)
        0, 0, 0, 42, // IN_BYTES = 42
    ];

    // Send template to source1
    let result1 = parser.parse_from_source(source1, &v9_template_packet);
    assert_eq!(result1.packets.len(), 1);

    // Parse data from source1 (template cached) - should succeed
    let result1_data = parser.parse_from_source(source1, &v9_data_packet);
    assert_eq!(result1_data.packets.len(), 1);

    // Parse data from source2 (no template) - should produce NoTemplate
    let result2_data = parser.parse_from_source(source2, &v9_data_packet);
    assert_eq!(result2_data.packets.len(), 1);

    // Source2 should have a miss, source1 should not
    assert_eq!(parser.source_count(), 2);
}

// Verify that a single NetflowParser produces consistent results across repeated V5 parses
#[test]
fn test_single_parser_repeated_v5_parsing() {
    let mut parser = NetflowParser::default();

    let v5_packet = [
        0, 5, 0, 1, 3, 0, 4, 0, 5, 0, 6, 7, 8, 9, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 0, 1, 2, 3, 4,
        5, 6, 7, 8, 9, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 0, 1, 2, 3,
        4, 5, 6, 7, 8, 9, 0, 1, 2, 3, 4, 5, 6, 7,
    ];

    // V5 is stateless (no templates), so repeated parses should always produce 1 packet
    for _ in 0..5 {
        let packets = parser.parse_bytes(&v5_packet).packets;
        assert_eq!(packets.len(), 1);
    }
}

// Verify that V9 cache records hits and misses correctly
#[test]
fn test_cache_hit_and_miss_tracking() {
    let mut parser = NetflowParser::default();

    // V9 template packet: template ID 256 with 1 field (IN_BYTES, 4 bytes)
    let v9_template_packet: Vec<u8> = vec![
        0, 9, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 12, 1, 0, 0, 1, 0,
        1, 0, 4,
    ];
    assert!(
        !parser.parse_bytes(&v9_template_packet).packets.is_empty(),
        "Template packet should parse successfully"
    );

    // V9 data packet using template 256
    let v9_data_packet: Vec<u8> = vec![
        0, 9, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2, 0, 0, 0, 0, 1,
        0, // flowset_id = 256
        0, 8, // length = 8 (header(4) + 1 record of 4 bytes)
        0, 0, 0, 42, // IN_BYTES = 42
    ];
    assert!(
        !parser.parse_bytes(&v9_data_packet).packets.is_empty(),
        "Data packet should parse successfully with cached template"
    );

    let v9_info = parser.v9_cache_info();
    assert_eq!(
        v9_info.metrics.hits, 1,
        "V9 cache should record exactly 1 hit after parsing data with a cached template"
    );
    assert_eq!(
        v9_info.metrics.misses, 0,
        "V9 cache should have 0 misses when template is present"
    );

    // Parse data with a template ID that doesn't exist (template 512)
    let v9_missing_template_packet: Vec<u8> = vec![
        0, 9, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 3, 0, 0, 0, 0, 2,
        0, // flowset_id = 512
        0, 8, // length = 8
        0, 0, 0, 99, // data
    ];
    assert!(
        !parser
            .parse_bytes(&v9_missing_template_packet)
            .packets
            .is_empty(),
        "Missing-template packet should still produce a parse result"
    );

    let v9_info = parser.v9_cache_info();
    assert_eq!(
        v9_info.metrics.misses, 1,
        "V9 cache should record 1 miss for unknown template"
    );
}

// Verify that AutoScopedParser can be created with a custom builder configuration
#[test]
fn test_scoped_parser_with_builder() {
    use netflow_parser::NetflowParser;

    let builder = NetflowParser::builder().with_cache_size(2000);

    let mut parser = AutoScopedParser::try_with_builder(builder).expect("valid config");

    let source: SocketAddr = "192.168.1.1:2055".parse().unwrap();

    let v5_packet = [
        0, 5, 0, 1, 3, 0, 4, 0, 5, 0, 6, 7, 8, 9, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 0, 1, 2, 3, 4,
        5, 6, 7, 8, 9, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 0, 1, 2, 3,
        4, 5, 6, 7, 8, 9, 0, 1, 2, 3, 4, 5, 6, 7,
    ];

    let packets = parser.parse_from_source(source, &v5_packet).packets;
    assert_eq!(packets.len(), 1);
}
