//! Tests for pending flow caching: flows arriving before their template are cached
//! and automatically replayed when the template arrives.

use netflow_parser::variable_versions::ParserConfig;
use netflow_parser::variable_versions::v9::FlowSetBody as V9FlowSetBody;
use netflow_parser::{NetflowPacket, NetflowParser, PendingFlowsConfig};
use std::time::Duration;

/// Helper: build a V9 packet with a template flowset defining template_id=256
/// with one field: field_type=1 (InBytes), field_length=4
fn v9_template_packet() -> Vec<u8> {
    vec![
        0x00, 0x09, // Version 9
        0x00, 0x01, // Count = 1
        0x00, 0x00, 0x00, 0x01, // SysUptime
        0x00, 0x00, 0x00, 0x01, // Unix seconds
        0x00, 0x00, 0x00, 0x01, // Sequence
        0x00, 0x00, 0x00, 0x01, // Source ID
        // Template FlowSet
        0x00, 0x00, // FlowSet ID = 0 (template)
        0x00, 0x0C, // Length = 12
        0x01, 0x00, // Template ID = 256
        0x00, 0x01, // Field Count = 1
        0x00, 0x01, // Field Type = 1 (InBytes)
        0x00, 0x04, // Field Length = 4
    ]
}

/// Helper: build a V9 packet with a data flowset using template_id=256
fn v9_data_packet() -> Vec<u8> {
    vec![
        0x00, 0x09, // Version 9
        0x00, 0x01, // Count = 1
        0x00, 0x00, 0x00, 0x01, // SysUptime
        0x00, 0x00, 0x00, 0x02, // Unix seconds
        0x00, 0x00, 0x00, 0x02, // Sequence
        0x00, 0x00, 0x00, 0x01, // Source ID
        // Data FlowSet
        0x01, 0x00, // FlowSet ID = 256
        0x00, 0x08, // Length = 8
        0x00, 0x00, 0x00, 0x42, // Data (4 bytes = 66)
    ]
}

/// Helper: build an IPFIX packet with a template flowset defining template_id=256
/// with one field: field_type=1 (OctetDeltaCount), field_length=4
fn ipfix_template_packet() -> Vec<u8> {
    vec![
        0x00, 0x0A, // Version 10 (IPFIX)
        0x00, 0x1C, // Length = 28 (16 header + 12 template set)
        0x00, 0x00, 0x00, 0x01, // Export Time
        0x00, 0x00, 0x00, 0x01, // Sequence Number
        0x00, 0x00, 0x00, 0x01, // Observation Domain ID
        // Template Set
        0x00, 0x02, // Set ID = 2 (IPFIX template)
        0x00, 0x0C, // Set Length = 12
        0x01, 0x00, // Template ID = 256
        0x00, 0x01, // Field Count = 1
        0x00, 0x01, // Field Type = 1 (OctetDeltaCount)
        0x00, 0x04, // Field Length = 4
    ]
}

/// Helper: build an IPFIX packet with a data flowset using template_id=256
fn ipfix_data_packet() -> Vec<u8> {
    vec![
        0x00, 0x0A, // Version 10 (IPFIX)
        0x00, 0x18, // Length = 24 (16 header + 8 data set)
        0x00, 0x00, 0x00, 0x02, // Export Time
        0x00, 0x00, 0x00, 0x02, // Sequence Number
        0x00, 0x00, 0x00, 0x01, // Observation Domain ID
        // Data Set
        0x01, 0x00, // Set ID = 256
        0x00, 0x08, // Set Length = 8
        0x00, 0x00, 0x00, 0x42, // Data (4 bytes = 66)
    ]
}

/// Test that pending flow caching is disabled by default.
#[test]
fn test_pending_flows_disabled_by_default() {
    let mut parser = NetflowParser::default();

    // Send data before template — should produce a V9 packet with a
    // NoTemplate flowset (not an empty result or a parse error).
    let result = parser.parse_bytes(&v9_data_packet());
    let v9 = match result.packets.first() {
        Some(NetflowPacket::V9(v9)) => v9,
        _ => panic!("Expected a V9 packet, got {:?}", result),
    };
    assert!(
        v9.flowsets
            .iter()
            .any(|fs| matches!(&fs.body, V9FlowSetBody::NoTemplate(_))),
        "V9 packet should contain a NoTemplate flowset for the missing template"
    );

    // No pending flows should be cached (feature disabled)
    let stats = parser.v9_cache_info();
    assert_eq!(
        stats.pending_flow_count, 0,
        "No pending flows when feature is disabled"
    );
    assert_eq!(
        stats.metrics.pending_cached, 0,
        "pending_cached metric should be zero when feature is disabled"
    );
}

/// Test IPFIX: data before template -> template arrives -> replayed flows in output
#[test]
fn test_ipfix_pending_flow_replay() {
    let mut parser = NetflowParser::builder()
        .with_ipfix_pending_flows(PendingFlowsConfig::default())
        .build()
        .expect("Failed to build parser");

    // Step 1: Send data packet before template
    let result1 = parser.parse_bytes(&ipfix_data_packet());
    assert!(result1.is_ok(), "Data packet should parse (NoTemplate)");

    // Should have one pending flow cached
    let stats = parser.ipfix_cache_info();
    assert_eq!(stats.pending_flow_count, 1, "Should cache one pending flow");
    assert_eq!(
        stats.metrics.pending_cached, 1,
        "Should record pending_cached metric"
    );

    // Step 2: Send template packet - pending flows should be replayed
    let result2 = parser.parse_bytes(&ipfix_template_packet());
    assert!(result2.is_ok(), "Template packet should parse");

    // Check that replayed data is in the output
    let has_data_flowset = result2.packets.iter().any(|p| {
        if let NetflowPacket::IPFix(ipfix) = p {
            ipfix.flowsets.iter().any(|fs| {
                matches!(
                    &fs.body,
                    netflow_parser::variable_versions::ipfix::FlowSetBody::Data(_)
                )
            })
        } else {
            false
        }
    });
    assert!(
        has_data_flowset,
        "Template packet output should include replayed data flowset"
    );

    // Pending flows should now be drained
    let stats = parser.ipfix_cache_info();
    assert_eq!(
        stats.pending_flow_count, 0,
        "Pending flows should be drained after replay"
    );
    assert_eq!(
        stats.metrics.pending_replayed, 1,
        "Should record pending_replayed metric"
    );
}

/// Test V9: data before template -> template arrives -> replayed flows in output
#[test]
fn test_v9_pending_flow_replay() {
    let mut parser = NetflowParser::builder()
        .with_v9_pending_flows(PendingFlowsConfig::default())
        .build()
        .expect("Failed to build parser");

    // Step 1: Send data packet before template
    let result1 = parser.parse_bytes(&v9_data_packet());
    assert!(result1.is_ok(), "Data packet should parse (NoTemplate)");

    // Should have one pending flow cached
    let stats = parser.v9_cache_info();
    assert_eq!(stats.pending_flow_count, 1, "Should cache one pending flow");

    // Step 2: Send template packet - pending flows should be replayed
    let result2 = parser.parse_bytes(&v9_template_packet());
    assert!(result2.is_ok(), "Template packet should parse");

    // Check that replayed data is in the output
    let has_data_flowset = result2.packets.iter().any(|p| {
        if let NetflowPacket::V9(v9) = p {
            v9.flowsets.iter().any(|fs| {
                matches!(
                    &fs.body,
                    netflow_parser::variable_versions::v9::FlowSetBody::Data(_)
                )
            })
        } else {
            false
        }
    });
    assert!(
        has_data_flowset,
        "Template packet output should include replayed data flowset"
    );

    // Pending flows should now be drained
    let stats = parser.v9_cache_info();
    assert_eq!(
        stats.pending_flow_count, 0,
        "Pending flows should be drained after replay"
    );
    assert_eq!(
        stats.metrics.pending_replayed, 1,
        "Should record pending_replayed metric"
    );
}

/// Test TTL expiration of pending flows
#[test]
fn test_pending_flow_ttl_expiration() {
    let mut parser = NetflowParser::builder()
        .with_v9_pending_flows(PendingFlowsConfig::with_ttl(256, Duration::ZERO))
        .build()
        .expect("Failed to build parser");

    // Send data packet before template
    let _ = parser.parse_bytes(&v9_data_packet());
    assert_eq!(parser.v9_cache_info().pending_flow_count, 1);

    // Send template - pending flow should have already expired (TTL is zero)
    let result = parser.parse_bytes(&v9_template_packet());
    assert!(result.is_ok());

    // The pending flow should be dropped, not replayed
    let stats = parser.v9_cache_info();
    assert_eq!(
        stats.metrics.pending_replayed, 0,
        "Expired flow should not be replayed"
    );
    assert_eq!(
        stats.metrics.pending_dropped, 1,
        "Expired flow should be dropped"
    );
}

/// Test LRU eviction when pending cache is full
#[test]
fn test_pending_flow_lru_eviction() {
    let mut parser = NetflowParser::builder()
        .with_ipfix_pending_flows(PendingFlowsConfig::new(2)) // Max 2 template IDs
        .build()
        .expect("Failed to build parser");

    // Send data for template ID 256
    let _ = parser.parse_bytes(&ipfix_data_packet());

    // Send data for template ID 257 (different template)
    let mut data_257 = ipfix_data_packet();
    data_257[16] = 0x01;
    data_257[17] = 0x01; // Set ID = 257
    let _ = parser.parse_bytes(&data_257);

    // Send data for template ID 258 - should evict 256
    let mut data_258 = ipfix_data_packet();
    data_258[16] = 0x01;
    data_258[17] = 0x02; // Set ID = 258
    let _ = parser.parse_bytes(&data_258);

    // Cache should have exactly 2 entries (257 and 258); 256 was evicted
    let stats = parser.ipfix_cache_info();
    assert_eq!(stats.pending_flow_count, 2);
    assert_eq!(stats.metrics.pending_cached, 3);
    // The evicted template 256 had 1 entry, which should be counted as dropped
    assert_eq!(stats.metrics.pending_dropped, 1);
}

/// Test builder API propagation (both parsers receive config)
#[test]
fn test_builder_propagation() {
    let parser = NetflowParser::builder()
        .with_pending_flows(PendingFlowsConfig::new(128))
        .build()
        .expect("Failed to build parser");

    // V9 parser should have pending cache enabled
    assert!(
        parser.v9_parser().pending_flows_enabled(),
        "V9 parser should have pending cache"
    );

    // IPFIX parser should have pending cache enabled
    assert!(
        parser.ipfix_parser().pending_flows_enabled(),
        "IPFIX parser should have pending cache"
    );
}

/// Test that V9 only builder method only affects V9
#[test]
fn test_v9_only_pending_flows() {
    let parser = NetflowParser::builder()
        .with_v9_pending_flows(PendingFlowsConfig::new(128))
        .build()
        .expect("Failed to build parser");

    assert!(
        parser.v9_parser().pending_flows_enabled(),
        "V9 parser should have pending cache"
    );
    assert!(
        !parser.ipfix_parser().pending_flows_enabled(),
        "IPFIX parser should NOT have pending cache"
    );
}

/// Test that IPFIX only builder method only affects IPFIX
#[test]
fn test_ipfix_only_pending_flows() {
    let parser = NetflowParser::builder()
        .with_ipfix_pending_flows(PendingFlowsConfig::new(128))
        .build()
        .expect("Failed to build parser");

    assert!(
        !parser.v9_parser().pending_flows_enabled(),
        "V9 parser should NOT have pending cache"
    );
    assert!(
        parser.ipfix_parser().pending_flows_enabled(),
        "IPFIX parser should have pending cache"
    );
}

/// Test V9 NoTemplate doesn't stop parsing remaining flowsets
#[test]
fn test_v9_no_template_continues_parsing() {
    let mut parser = NetflowParser::default();

    // Build a V9 packet with:
    // 1. A data flowset for unknown template 256 (NoTemplate)
    // 2. A template flowset for template 257
    let packet = vec![
        0x00, 0x09, // Version 9
        0x00, 0x02, // Count = 2
        0x00, 0x00, 0x00, 0x01, // SysUptime
        0x00, 0x00, 0x00, 0x01, // Unix seconds
        0x00, 0x00, 0x00, 0x01, // Sequence
        0x00, 0x00, 0x00, 0x01, // Source ID
        // Data FlowSet (template 256 - not known yet)
        0x01, 0x00, // FlowSet ID = 256
        0x00, 0x08, // Length = 8
        0x00, 0x00, 0x00, 0x42, // Data
        // Template FlowSet for template 257
        0x00, 0x00, // FlowSet ID = 0 (template)
        0x00, 0x0C, // Length = 12
        0x01, 0x01, // Template ID = 257
        0x00, 0x01, // Field Count = 1
        0x00, 0x01, // Field Type = 1
        0x00, 0x04, // Field Length = 4
    ];

    let result = parser.parse_bytes(&packet);
    assert!(result.is_ok(), "Packet should parse successfully");

    // Should have parsed the V9 packet
    let v9_packets: Vec<_> = result
        .packets
        .iter()
        .filter_map(|p| {
            if let NetflowPacket::V9(v9) = p {
                Some(v9)
            } else {
                None
            }
        })
        .collect();

    assert_eq!(v9_packets.len(), 1, "Should have one V9 packet");

    let v9 = &v9_packets[0];
    // Should have 2 flowsets: NoTemplate + Template
    assert_eq!(v9.flowsets.len(), 2, "Should have 2 flowsets");

    let has_no_template = v9.flowsets.iter().any(|fs| {
        matches!(
            &fs.body,
            netflow_parser::variable_versions::v9::FlowSetBody::NoTemplate(_)
        )
    });
    let has_template = v9.flowsets.iter().any(|fs| {
        matches!(
            &fs.body,
            netflow_parser::variable_versions::v9::FlowSetBody::Template(_)
        )
    });

    assert!(has_no_template, "Should have NoTemplate flowset");
    assert!(
        has_template,
        "Should have Template flowset (parsing continued)"
    );

    // Template 257 should now be cached
    assert!(
        parser.has_v9_template(257),
        "Template 257 should be cached despite earlier NoTemplate"
    );
}

/// Test clear pending flows methods
#[test]
fn test_clear_pending_flows() {
    let mut parser = NetflowParser::builder()
        .with_pending_flows(PendingFlowsConfig::default())
        .build()
        .expect("Failed to build parser");

    // Cache some pending flows
    let _ = parser.parse_bytes(&v9_data_packet());
    let _ = parser.parse_bytes(&ipfix_data_packet());

    assert_eq!(parser.v9_cache_info().pending_flow_count, 1);
    assert_eq!(parser.ipfix_cache_info().pending_flow_count, 1);

    // Clear V9 pending flows
    parser.clear_v9_pending_flows();
    assert_eq!(parser.v9_cache_info().pending_flow_count, 0);
    assert_eq!(parser.ipfix_cache_info().pending_flow_count, 1);

    // Clear IPFIX pending flows
    parser.clear_ipfix_pending_flows();
    assert_eq!(parser.ipfix_cache_info().pending_flow_count, 0);
}

// ---------------------------------------------------------------------------
// Multi-field template helpers
// ---------------------------------------------------------------------------

/// V9 template with 3 fields: InBytes(1)=4, InPkts(2)=4, Protocol(4)=1 => record size=9
fn v9_multifield_template_packet() -> Vec<u8> {
    vec![
        0x00, 0x09, // Version 9
        0x00, 0x01, // Count = 1
        0x00, 0x00, 0x00, 0x01, // SysUptime
        0x00, 0x00, 0x00, 0x01, // Unix seconds
        0x00, 0x00, 0x00, 0x01, // Sequence
        0x00, 0x00, 0x00, 0x01, // Source ID
        // Template FlowSet
        0x00, 0x00, // FlowSet ID = 0 (template)
        0x00, 0x14, // Length = 20 (4 hdr + 4 tmpl hdr + 3*4 fields)
        0x01, 0x00, // Template ID = 256
        0x00, 0x03, // Field Count = 3
        0x00, 0x01, // InBytes
        0x00, 0x04, // Length = 4
        0x00, 0x02, // InPkts
        0x00, 0x04, // Length = 4
        0x00, 0x04, // Protocol
        0x00, 0x01, // Length = 1
    ]
}

/// V9 data for multi-field template: 1 record (9 bytes) + 3 bytes padding to 4-byte boundary
fn v9_multifield_data_packet() -> Vec<u8> {
    vec![
        0x00, 0x09, // Version 9
        0x00, 0x01, // Count = 1
        0x00, 0x00, 0x00, 0x01, // SysUptime
        0x00, 0x00, 0x00, 0x02, // Unix seconds
        0x00, 0x00, 0x00, 0x02, // Sequence
        0x00, 0x00, 0x00, 0x01, // Source ID
        // Data FlowSet
        0x01, 0x00, // FlowSet ID = 256
        0x00, 0x10, // Length = 16 (4 hdr + 9 data + 3 padding)
        // Record: InBytes=1000 (0x3E8), InPkts=50 (0x32), Protocol=6 (TCP)
        0x00, 0x00, 0x03, 0xE8, // InBytes = 1000
        0x00, 0x00, 0x00, 0x32, // InPkts = 50
        0x06, // Protocol = 6 (TCP)
        0x00, 0x00, 0x00, // Padding
    ]
}

/// V9 data with 2 records in one flowset (each 9 bytes = 18 + 2 padding)
fn v9_multifield_two_records_packet() -> Vec<u8> {
    vec![
        0x00, 0x09, // Version 9
        0x00, 0x01, // Count = 1
        0x00, 0x00, 0x00, 0x01, // SysUptime
        0x00, 0x00, 0x00, 0x03, // Unix seconds
        0x00, 0x00, 0x00, 0x03, // Sequence
        0x00, 0x00, 0x00, 0x01, // Source ID
        // Data FlowSet
        0x01, 0x00, // FlowSet ID = 256
        0x00, 0x18, // Length = 24 (4 hdr + 9*2 data + 2 padding)
        // Record 1: InBytes=2000, InPkts=100, Protocol=17 (UDP)
        0x00, 0x00, 0x07, 0xD0, // InBytes = 2000
        0x00, 0x00, 0x00, 0x64, // InPkts = 100
        0x11, // Protocol = 17 (UDP)
        // Record 2: InBytes=500, InPkts=10, Protocol=1 (ICMP)
        0x00, 0x00, 0x01, 0xF4, // InBytes = 500
        0x00, 0x00, 0x00, 0x0A, // InPkts = 10
        0x01, // Protocol = 1 (ICMP)
        0x00, 0x00, // Padding
    ]
}

/// IPFIX template with 3 fields: OctetDeltaCount(1)=4, PacketDeltaCount(2)=4, ProtocolIdentifier(4)=1
fn ipfix_multifield_template_packet() -> Vec<u8> {
    vec![
        0x00, 0x0A, // Version 10 (IPFIX)
        0x00, 0x24, // Length = 36 (16 header + 20 template set)
        0x00, 0x00, 0x00, 0x01, // Export Time
        0x00, 0x00, 0x00, 0x01, // Sequence Number
        0x00, 0x00, 0x00, 0x01, // Observation Domain ID
        // Template Set
        0x00, 0x02, // Set ID = 2 (template)
        0x00, 0x14, // Set Length = 20 (4 hdr + 4 tmpl hdr + 3*4 fields)
        0x01, 0x00, // Template ID = 256
        0x00, 0x03, // Field Count = 3
        0x00, 0x01, // OctetDeltaCount
        0x00, 0x04, // Length = 4
        0x00, 0x02, // PacketDeltaCount
        0x00, 0x04, // Length = 4
        0x00, 0x04, // ProtocolIdentifier
        0x00, 0x01, // Length = 1
    ]
}

/// IPFIX data for multi-field template: 1 record (9 bytes) + 3 pad
fn ipfix_multifield_data_packet() -> Vec<u8> {
    vec![
        0x00, 0x0A, // Version 10 (IPFIX)
        0x00, 0x20, // Length = 32 (16 header + 16 data set)
        0x00, 0x00, 0x00, 0x02, // Export Time
        0x00, 0x00, 0x00, 0x02, // Sequence Number
        0x00, 0x00, 0x00, 0x01, // Observation Domain ID
        // Data Set
        0x01, 0x00, // Set ID = 256
        0x00, 0x10, // Set Length = 16 (4 hdr + 9 data + 3 pad)
        // Record: OctetDeltaCount=1000, PacketDeltaCount=50, Protocol=6 (TCP)
        0x00, 0x00, 0x03, 0xE8, 0x00, 0x00, 0x00, 0x32, 0x06, 0x00, 0x00, 0x00, // Padding
    ]
}

/// IPFIX data with 2 records in one flowset (9*2 = 18 + 2 pad)
fn ipfix_multifield_two_records_packet() -> Vec<u8> {
    vec![
        0x00, 0x0A, // Version 10 (IPFIX)
        0x00, 0x28, // Length = 40 (16 header + 24 data set)
        0x00, 0x00, 0x00, 0x03, // Export Time
        0x00, 0x00, 0x00, 0x03, // Sequence Number
        0x00, 0x00, 0x00, 0x01, // Observation Domain ID
        // Data Set
        0x01, 0x00, // Set ID = 256
        0x00, 0x18, // Set Length = 24 (4 hdr + 18 data + 2 pad)
        // Record 1: 2000, 100, UDP(17)
        0x00, 0x00, 0x07, 0xD0, 0x00, 0x00, 0x00, 0x64, 0x11,
        // Record 2: 500, 10, ICMP(1)
        0x00, 0x00, 0x01, 0xF4, 0x00, 0x00, 0x00, 0x0A, 0x01, 0x00, 0x00, // Padding
    ]
}

// ---------------------------------------------------------------------------
// V9 options template helpers
// ---------------------------------------------------------------------------

/// V9 options template: template_id=258
/// 1 scope field: System(1), length=4
/// 2 option fields: TotalFlows(3), length=4 and TotalPkts(4), length=4
/// Total record size: 4 + 4 + 4 = 12 bytes
fn v9_options_template_packet() -> Vec<u8> {
    vec![
        0x00, 0x09, // Version 9
        0x00, 0x01, // Count = 1
        0x00, 0x00, 0x00, 0x01, // SysUptime
        0x00, 0x00, 0x00, 0x01, // Unix seconds
        0x00, 0x00, 0x00, 0x01, // Sequence
        0x00, 0x00, 0x00, 0x01, // Source ID
        // Options Template FlowSet
        0x00, 0x01, // FlowSet ID = 1 (options template)
        0x00, 0x18, // Length = 24 (4 hdr + 6 tmpl hdr + 1*4 scope + 2*4 opts + 2 pad)
        0x01, 0x02, // Template ID = 258
        0x00, 0x04, // Scope Length = 4 (1 scope field * 4 bytes)
        0x00, 0x08, // Option Length = 8 (2 option fields * 4 bytes)
        // Scope field: System(1), length=4
        0x00, 0x01, // Scope field type = 1 (System)
        0x00, 0x04, // Field length = 4
        // Option field 1: field_type=3, length=4
        0x00, 0x03, // Field type = 3
        0x00, 0x04, // Field length = 4
        // Option field 2: field_type=4, length=4
        0x00, 0x04, // Field type = 4
        0x00, 0x04, // Field length = 4
        0x00, 0x00, // Padding
    ]
}

/// V9 options data for template_id=258 (12 bytes data + 0 pad)
fn v9_options_data_packet() -> Vec<u8> {
    vec![
        0x00, 0x09, // Version 9
        0x00, 0x01, // Count = 1
        0x00, 0x00, 0x00, 0x01, // SysUptime
        0x00, 0x00, 0x00, 0x02, // Unix seconds
        0x00, 0x00, 0x00, 0x02, // Sequence
        0x00, 0x00, 0x00, 0x01, // Source ID
        // Data FlowSet for template 258
        0x01, 0x02, // FlowSet ID = 258
        0x00, 0x10, // Length = 16 (4 hdr + 12 data)
        // Scope data: System = 0x0A0A0A01
        0x0A, 0x0A, 0x0A, 0x01, // Option field 1 data: 0x00001000
        0x00, 0x00, 0x10, 0x00, // Option field 2 data: 0x00002000
        0x00, 0x00, 0x20, 0x00,
    ]
}

// ---------------------------------------------------------------------------
// IPFIX options template helpers
// ---------------------------------------------------------------------------

/// IPFIX options template: template_id=258
/// field_count=3, scope_field_count=1
/// Scope: field_type=1 (lineCardId), length=4
/// Option1: field_type=3, length=4
/// Option2: field_type=4, length=4
fn ipfix_options_template_packet() -> Vec<u8> {
    vec![
        0x00, 0x0A, // Version 10 (IPFIX)
        0x00, 0x26, // Length = 38 (16 header + 22 options template set)
        0x00, 0x00, 0x00, 0x01, // Export Time
        0x00, 0x00, 0x00, 0x01, // Sequence Number
        0x00, 0x00, 0x00, 0x01, // Observation Domain ID
        // Options Template Set
        0x00, 0x03, // Set ID = 3 (IPFIX options template)
        0x00, 0x16, // Set Length = 22 (4 hdr + 6 tmpl hdr + 3*4 fields)
        0x01, 0x02, // Template ID = 258
        0x00, 0x03, // Field Count = 3 (total: scope + options)
        0x00, 0x01, // Scope Field Count = 1
        // Field 1 (scope): type=1, length=4
        0x00, 0x01, // Field type = 1
        0x00, 0x04, // Length = 4
        // Field 2 (option): type=3, length=4
        0x00, 0x03, // Field type = 3
        0x00, 0x04, // Length = 4
        // Field 3 (option): type=4, length=4
        0x00, 0x04, // Field type = 4
        0x00, 0x04, // Length = 4
    ]
}

/// IPFIX options data for template_id=258 (12 bytes)
fn ipfix_options_data_packet() -> Vec<u8> {
    vec![
        0x00, 0x0A, // Version 10 (IPFIX)
        0x00, 0x20, // Length = 32 (16 header + 16 data set)
        0x00, 0x00, 0x00, 0x02, // Export Time
        0x00, 0x00, 0x00, 0x02, // Sequence Number
        0x00, 0x00, 0x00, 0x01, // Observation Domain ID
        // Data Set for template 258
        0x01, 0x02, // Set ID = 258
        0x00, 0x10, // Set Length = 16 (4 hdr + 12 data)
        // Scope data: 0x0A0A0A01
        0x0A, 0x0A, 0x0A, 0x01, // Option field 1: 0x00001000
        0x00, 0x00, 0x10, 0x00, // Option field 2: 0x00002000
        0x00, 0x00, 0x20, 0x00,
    ]
}

// ===========================================================================
// Tests: multi-field templates
// ===========================================================================

/// V9: multi-field template pending flow replay
#[test]
fn test_v9_multifield_pending_replay() {
    let mut parser = NetflowParser::builder()
        .with_v9_pending_flows(PendingFlowsConfig::default())
        .build()
        .expect("Failed to build parser");

    // Data before template
    let result1 = parser.parse_bytes(&v9_multifield_data_packet());
    assert!(result1.is_ok());
    assert_eq!(parser.v9_cache_info().pending_flow_count, 1);

    // Template arrives -> replay
    let result2 = parser.parse_bytes(&v9_multifield_template_packet());
    assert!(result2.is_ok());

    let has_data = result2.packets.iter().any(|p| {
        if let NetflowPacket::V9(v9) = p {
            v9.flowsets.iter().any(|fs| {
                matches!(
                    &fs.body,
                    netflow_parser::variable_versions::v9::FlowSetBody::Data(_)
                )
            })
        } else {
            false
        }
    });
    assert!(has_data, "Replayed multi-field data should appear");

    let stats = parser.v9_cache_info();
    assert_eq!(stats.pending_flow_count, 0);
    assert_eq!(stats.metrics.pending_replayed, 1);
}

/// IPFIX: multi-field template pending flow replay
#[test]
fn test_ipfix_multifield_pending_replay() {
    let mut parser = NetflowParser::builder()
        .with_ipfix_pending_flows(PendingFlowsConfig::default())
        .build()
        .expect("Failed to build parser");

    let result1 = parser.parse_bytes(&ipfix_multifield_data_packet());
    assert!(result1.is_ok());
    assert_eq!(parser.ipfix_cache_info().pending_flow_count, 1);

    let result2 = parser.parse_bytes(&ipfix_multifield_template_packet());
    assert!(result2.is_ok());

    let has_data = result2.packets.iter().any(|p| {
        if let NetflowPacket::IPFix(ipfix) = p {
            ipfix.flowsets.iter().any(|fs| {
                matches!(
                    &fs.body,
                    netflow_parser::variable_versions::ipfix::FlowSetBody::Data(_)
                )
            })
        } else {
            false
        }
    });
    assert!(has_data, "Replayed multi-field data should appear");

    let stats = parser.ipfix_cache_info();
    assert_eq!(stats.pending_flow_count, 0);
    assert_eq!(stats.metrics.pending_replayed, 1);
}

// ===========================================================================
// Tests: multiple records per flowset
// ===========================================================================

/// V9: pending flowset with 2 records replayed correctly
#[test]
fn test_v9_multiple_records_pending_replay() {
    let mut parser = NetflowParser::builder()
        .with_v9_pending_flows(PendingFlowsConfig::default())
        .build()
        .expect("Failed to build parser");

    // Data with 2 records, before template
    let result1 = parser.parse_bytes(&v9_multifield_two_records_packet());
    assert!(result1.is_ok());
    assert_eq!(parser.v9_cache_info().pending_flow_count, 1);

    // Template arrives
    let result2 = parser.parse_bytes(&v9_multifield_template_packet());
    assert!(result2.is_ok());

    // Find the replayed Data flowset and verify it has 2 records
    let record_count: usize = result2
        .packets
        .iter()
        .filter_map(|p| {
            if let NetflowPacket::V9(v9) = p {
                Some(v9)
            } else {
                None
            }
        })
        .flat_map(|v9| v9.flowsets.iter())
        .filter_map(|fs| {
            if let netflow_parser::variable_versions::v9::FlowSetBody::Data(data) = &fs.body {
                Some(data.fields.len())
            } else {
                None
            }
        })
        .sum();
    assert_eq!(
        record_count, 2,
        "Should replay 2 records from the pending flowset"
    );
    assert_eq!(parser.v9_cache_info().metrics.pending_replayed, 1);
}

/// IPFIX: pending flowset with 2 records replayed correctly
#[test]
fn test_ipfix_multiple_records_pending_replay() {
    let mut parser = NetflowParser::builder()
        .with_ipfix_pending_flows(PendingFlowsConfig::default())
        .build()
        .expect("Failed to build parser");

    let result1 = parser.parse_bytes(&ipfix_multifield_two_records_packet());
    assert!(result1.is_ok());
    assert_eq!(parser.ipfix_cache_info().pending_flow_count, 1);

    let result2 = parser.parse_bytes(&ipfix_multifield_template_packet());
    assert!(result2.is_ok());

    let record_count: usize = result2
        .packets
        .iter()
        .filter_map(|p| {
            if let NetflowPacket::IPFix(ipfix) = p {
                Some(ipfix)
            } else {
                None
            }
        })
        .flat_map(|ipfix| ipfix.flowsets.iter())
        .filter_map(|fs| {
            if let netflow_parser::variable_versions::ipfix::FlowSetBody::Data(data) = &fs.body
            {
                Some(data.fields.len())
            } else {
                None
            }
        })
        .sum();
    assert_eq!(
        record_count, 2,
        "Should replay 2 records from the pending flowset"
    );
    assert_eq!(parser.ipfix_cache_info().metrics.pending_replayed, 1);
}

// ===========================================================================
// Tests: options template pending flows
// ===========================================================================

/// V9: options data before options template -> replay as OptionsData
#[test]
fn test_v9_options_pending_replay() {
    let mut parser = NetflowParser::builder()
        .with_v9_pending_flows(PendingFlowsConfig::default())
        .build()
        .expect("Failed to build parser");

    // Options data arrives before options template
    let result1 = parser.parse_bytes(&v9_options_data_packet());
    assert!(result1.is_ok());
    assert_eq!(parser.v9_cache_info().pending_flow_count, 1);

    // Options template arrives -> should replay as OptionsData
    let result2 = parser.parse_bytes(&v9_options_template_packet());
    assert!(result2.is_ok());

    let has_options_data = result2.packets.iter().any(|p| {
        if let NetflowPacket::V9(v9) = p {
            v9.flowsets.iter().any(|fs| {
                matches!(
                    &fs.body,
                    netflow_parser::variable_versions::v9::FlowSetBody::OptionsData(_)
                )
            })
        } else {
            false
        }
    });
    assert!(has_options_data, "Should replay as OptionsData flowset");

    let stats = parser.v9_cache_info();
    assert_eq!(stats.pending_flow_count, 0);
    assert_eq!(stats.metrics.pending_replayed, 1);
}

/// IPFIX: options data before options template -> replay as OptionsData
#[test]
fn test_ipfix_options_pending_replay() {
    let mut parser = NetflowParser::builder()
        .with_ipfix_pending_flows(PendingFlowsConfig::default())
        .build()
        .expect("Failed to build parser");

    // Options data arrives before options template
    let result1 = parser.parse_bytes(&ipfix_options_data_packet());
    assert!(result1.is_ok());
    assert_eq!(parser.ipfix_cache_info().pending_flow_count, 1);

    // Options template arrives -> should replay as OptionsData
    let result2 = parser.parse_bytes(&ipfix_options_template_packet());
    assert!(result2.is_ok());

    let has_options_data = result2.packets.iter().any(|p| {
        if let NetflowPacket::IPFix(ipfix) = p {
            ipfix.flowsets.iter().any(|fs| {
                matches!(
                    &fs.body,
                    netflow_parser::variable_versions::ipfix::FlowSetBody::OptionsData(_)
                )
            })
        } else {
            false
        }
    });
    assert!(has_options_data, "Should replay as OptionsData flowset");

    let stats = parser.ipfix_cache_info();
    assert_eq!(stats.pending_flow_count, 0);
    assert_eq!(stats.metrics.pending_replayed, 1);
}

// ===========================================================================
// Tests: multiple pending flows for the same template ID
// ===========================================================================

/// V9: two data packets for the same template are both replayed
#[test]
fn test_v9_multiple_pending_same_template() {
    let mut parser = NetflowParser::builder()
        .with_v9_pending_flows(PendingFlowsConfig::default())
        .build()
        .expect("Failed to build parser");

    // Send two data packets for template 256 before the template arrives
    let _ = parser.parse_bytes(&v9_multifield_data_packet());
    let _ = parser.parse_bytes(&v9_multifield_two_records_packet());
    assert_eq!(
        parser.v9_cache_info().pending_flow_count,
        2,
        "Two entries cached under template 256"
    );
    assert_eq!(parser.v9_cache_info().metrics.pending_cached, 2);

    // Template arrives -> both should be replayed
    let result = parser.parse_bytes(&v9_multifield_template_packet());
    assert!(result.is_ok());

    let data_flowsets: Vec<_> = result
        .packets
        .iter()
        .filter_map(|p| {
            if let NetflowPacket::V9(v9) = p {
                Some(v9)
            } else {
                None
            }
        })
        .flat_map(|v9| v9.flowsets.iter())
        .filter(|fs| {
            matches!(
                &fs.body,
                netflow_parser::variable_versions::v9::FlowSetBody::Data(_)
            )
        })
        .collect();
    assert_eq!(
        data_flowsets.len(),
        2,
        "Both pending entries should be replayed as separate Data flowsets"
    );

    let stats = parser.v9_cache_info();
    assert_eq!(stats.pending_flow_count, 0);
    assert_eq!(stats.metrics.pending_replayed, 2);
}

/// IPFIX: two data packets for the same template are both replayed
#[test]
fn test_ipfix_multiple_pending_same_template() {
    let mut parser = NetflowParser::builder()
        .with_ipfix_pending_flows(PendingFlowsConfig::default())
        .build()
        .expect("Failed to build parser");

    let _ = parser.parse_bytes(&ipfix_multifield_data_packet());
    let _ = parser.parse_bytes(&ipfix_multifield_two_records_packet());
    assert_eq!(parser.ipfix_cache_info().pending_flow_count, 2);

    let result = parser.parse_bytes(&ipfix_multifield_template_packet());
    assert!(result.is_ok());

    let data_flowsets: Vec<_> = result
        .packets
        .iter()
        .filter_map(|p| {
            if let NetflowPacket::IPFix(ipfix) = p {
                Some(ipfix)
            } else {
                None
            }
        })
        .flat_map(|ipfix| ipfix.flowsets.iter())
        .filter(|fs| {
            matches!(
                &fs.body,
                netflow_parser::variable_versions::ipfix::FlowSetBody::Data(_)
            )
        })
        .collect();
    assert_eq!(
        data_flowsets.len(),
        2,
        "Both pending entries should be replayed as separate Data flowsets"
    );

    let stats = parser.ipfix_cache_info();
    assert_eq!(stats.pending_flow_count, 0);
    assert_eq!(stats.metrics.pending_replayed, 2);
}

// ===========================================================================
// Tests: same-packet template + data with existing pending flows
// ===========================================================================

/// V9: pending flows replayed when template arrives in a packet that also has its own data
#[test]
fn test_v9_pending_replay_with_same_packet_data() {
    let mut parser = NetflowParser::builder()
        .with_v9_pending_flows(PendingFlowsConfig::default())
        .build()
        .expect("Failed to build parser");

    // Cache a pending flow for template 256
    let _ = parser.parse_bytes(&v9_data_packet());
    assert_eq!(parser.v9_cache_info().pending_flow_count, 1);

    // Send a packet containing BOTH a template definition for 256 AND data using 256
    // V9 processes flowsets in order: template first, then data matches
    let combined_packet = vec![
        0x00, 0x09, // Version 9
        0x00, 0x02, // Count = 2
        0x00, 0x00, 0x00, 0x01, // SysUptime
        0x00, 0x00, 0x00, 0x03, // Unix seconds
        0x00, 0x00, 0x00, 0x03, // Sequence
        0x00, 0x00, 0x00, 0x01, // Source ID
        // Template FlowSet for 256
        0x00, 0x00, // FlowSet ID = 0 (template)
        0x00, 0x0C, // Length = 12
        0x01, 0x00, // Template ID = 256
        0x00, 0x01, // Field Count = 1
        0x00, 0x01, // InBytes
        0x00, 0x04, // Length = 4
        // Data FlowSet using 256
        0x01, 0x00, // FlowSet ID = 256
        0x00, 0x08, // Length = 8
        0x00, 0x00, 0x00, 0x99, // Data
    ];

    let result = parser.parse_bytes(&combined_packet);
    assert!(
        result.error.is_none(),
        "Combined packet should parse without error"
    );

    // Should produce exactly one V9 packet.
    let v9 = match result.packets.as_slice() {
        [NetflowPacket::V9(v9)] => v9,
        other => panic!("Expected exactly one V9 packet, got {}", other.len()),
    };

    // Expect exactly 3 flowsets: 1 Template + 1 in-packet Data + 1 replayed Data
    let data_count = v9
        .flowsets
        .iter()
        .filter(|fs| {
            matches!(
                &fs.body,
                netflow_parser::variable_versions::v9::FlowSetBody::Data(_)
            )
        })
        .count();
    assert_eq!(
        data_count, 2,
        "Should have exactly 1 in-packet Data + 1 replayed Data flowset"
    );

    let stats = parser.v9_cache_info();
    assert_eq!(stats.pending_flow_count, 0, "Pending should be drained");
    assert_eq!(stats.metrics.pending_replayed, 1);
}

// ===========================================================================
// Tests: out-of-order template arrivals
// ===========================================================================

/// V9: pending flows for 3 template IDs, templates arrive in reverse order
#[test]
fn test_v9_out_of_order_template_arrival() {
    let mut parser = NetflowParser::builder()
        .with_v9_pending_flows(PendingFlowsConfig::default())
        .build()
        .expect("Failed to build parser");

    // Helper to build V9 data packet with arbitrary template ID (single-field: 4 bytes data)
    let make_v9_data = |tmpl_id_hi: u8, tmpl_id_lo: u8| -> Vec<u8> {
        vec![
            0x00, 0x09, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x02, 0x00, 0x00,
            0x00, 0x02, 0x00, 0x00, 0x00, 0x01, tmpl_id_hi, tmpl_id_lo, // FlowSet ID
            0x00, 0x08, // Length = 8
            0x00, 0x00, 0x00, 0x42,
        ]
    };

    let make_v9_template = |tmpl_id_hi: u8, tmpl_id_lo: u8| -> Vec<u8> {
        vec![
            0x00, 0x09, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00,
            0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, // FlowSet ID = 0 (template)
            0x00, 0x0C, // Length = 12
            tmpl_id_hi, tmpl_id_lo, 0x00, 0x01, // 1 field
            0x00, 0x01, // InBytes
            0x00, 0x04, // Length=4
        ]
    };

    // Cache data for templates 256, 257, 258 in order
    let _ = parser.parse_bytes(&make_v9_data(0x01, 0x00)); // 256
    let _ = parser.parse_bytes(&make_v9_data(0x01, 0x01)); // 257
    let _ = parser.parse_bytes(&make_v9_data(0x01, 0x02)); // 258
    assert_eq!(parser.v9_cache_info().pending_flow_count, 3);

    // Template 258 arrives first
    let r1 = parser.parse_bytes(&make_v9_template(0x01, 0x02));
    assert!(r1.is_ok());
    assert_eq!(parser.v9_cache_info().pending_flow_count, 2);
    assert_eq!(parser.v9_cache_info().metrics.pending_replayed, 1);

    // Template 256 arrives second
    let r2 = parser.parse_bytes(&make_v9_template(0x01, 0x00));
    assert!(r2.is_ok());
    assert_eq!(parser.v9_cache_info().pending_flow_count, 1);
    assert_eq!(parser.v9_cache_info().metrics.pending_replayed, 2);

    // Template 257 arrives last
    let r3 = parser.parse_bytes(&make_v9_template(0x01, 0x01));
    assert!(r3.is_ok());
    assert_eq!(parser.v9_cache_info().pending_flow_count, 0);
    assert_eq!(parser.v9_cache_info().metrics.pending_replayed, 3);

    // Verify each result contained a replayed Data flowset
    for (i, result) in [r1, r2, r3].iter().enumerate() {
        let has_data = result.packets.iter().any(|p| {
            if let NetflowPacket::V9(v9) = p {
                v9.flowsets.iter().any(|fs| {
                    matches!(
                        &fs.body,
                        netflow_parser::variable_versions::v9::FlowSetBody::Data(_)
                    )
                })
            } else {
                false
            }
        });
        assert!(
            has_data,
            "Template arrival {} should include replayed data",
            i + 1
        );
    }
}

/// Test that max_entries_per_template is enforced and excess entries are dropped.
#[test]
fn test_max_entries_per_template_v9() {
    let mut config = PendingFlowsConfig::new(256);
    config.max_entries_per_template = 2; // Only allow 2 entries per template ID

    let mut parser = NetflowParser::builder()
        .with_v9_pending_flows(config)
        .build()
        .expect("Failed to build parser");

    // Send 4 data packets for the same template ID (256) before template arrives
    for _ in 0..4 {
        let _ = parser.parse_bytes(&v9_data_packet());
    }

    // Only 2 should be cached; 2 should be dropped
    let stats = parser.v9_cache_info();
    assert_eq!(stats.pending_flow_count, 2);
    assert_eq!(stats.metrics.pending_cached, 2);
    assert_eq!(stats.metrics.pending_dropped, 2);

    // Now send the template - only the 2 cached entries should be replayed
    let result = parser.parse_bytes(&v9_template_packet());
    assert!(result.is_ok());

    let stats = parser.v9_cache_info();
    assert_eq!(stats.pending_flow_count, 0);
    assert_eq!(stats.metrics.pending_replayed, 2);
}

/// Test that max_entries_per_template is enforced for IPFIX.
#[test]
fn test_max_entries_per_template_ipfix() {
    let mut config = PendingFlowsConfig::new(256);
    config.max_entries_per_template = 3;

    let mut parser = NetflowParser::builder()
        .with_ipfix_pending_flows(config)
        .build()
        .expect("Failed to build parser");

    // Send 5 data packets for template 256
    for _ in 0..5 {
        let _ = parser.parse_bytes(&ipfix_data_packet());
    }

    // Only 3 should be cached; 2 dropped
    let stats = parser.ipfix_cache_info();
    assert_eq!(stats.pending_flow_count, 3);
    assert_eq!(stats.metrics.pending_cached, 3);
    assert_eq!(stats.metrics.pending_dropped, 2);

    // Template arrives - 3 cached entries replayed
    let result = parser.parse_bytes(&ipfix_template_packet());
    assert!(result.is_ok());

    let stats = parser.ipfix_cache_info();
    assert_eq!(stats.pending_flow_count, 0);
    assert_eq!(stats.metrics.pending_replayed, 3);
}

/// Helper: build a V9 data packet with a large flowset body.
fn v9_data_packet_with_size(payload_size: usize) -> Vec<u8> {
    let flowset_len = (payload_size + 4) as u16; // +4 for flowset header
    let mut pkt = vec![
        0x00, 0x09, // Version 9
        0x00, 0x01, // Count = 1
        0x00, 0x00, 0x00, 0x01, // SysUptime
        0x00, 0x00, 0x00, 0x02, // Unix seconds
        0x00, 0x00, 0x00, 0x02, // Sequence
        0x00, 0x00, 0x00, 0x01, // Source ID
    ];
    // Data FlowSet header
    pkt.extend_from_slice(&0x0100u16.to_be_bytes()); // FlowSet ID = 256
    pkt.extend_from_slice(&flowset_len.to_be_bytes());
    // Payload bytes
    pkt.extend(vec![0xAA; payload_size]);
    pkt
}

/// Test that max_entry_size_bytes is enforced for V9 pending flows.
#[test]
fn test_max_entry_size_bytes_v9() {
    let mut config = PendingFlowsConfig::new(256);
    config.max_entry_size_bytes = 8; // Only allow entries up to 8 bytes

    let mut parser = NetflowParser::builder()
        .with_v9_pending_flows(config)
        .build()
        .expect("Failed to build parser");

    // Send a small data packet (4 bytes payload) - should be cached
    let _ = parser.parse_bytes(&v9_data_packet()); // 4 bytes of data
    assert_eq!(parser.v9_cache_info().pending_flow_count, 1);
    assert_eq!(parser.v9_cache_info().metrics.pending_cached, 1);
    assert_eq!(parser.v9_cache_info().metrics.pending_dropped, 0);

    // Send a large data packet (16 bytes payload) - should be dropped
    let _ = parser.parse_bytes(&v9_data_packet_with_size(16));
    assert_eq!(parser.v9_cache_info().pending_flow_count, 1);
    assert_eq!(parser.v9_cache_info().metrics.pending_cached, 1);
    assert_eq!(parser.v9_cache_info().metrics.pending_dropped, 1);
}

/// Helper: build an IPFIX data packet with a large payload.
fn ipfix_data_packet_with_size(payload_size: usize) -> Vec<u8> {
    let set_len = (payload_size + 4) as u16; // +4 for set header
    let msg_len = 16 + set_len; // 16 for IPFIX header
    let mut pkt = vec![
        0x00, 0x0A, // Version 10
    ];
    pkt.extend_from_slice(&msg_len.to_be_bytes());
    pkt.extend_from_slice(&[
        0x00, 0x00, 0x00, 0x02, // Export Time
        0x00, 0x00, 0x00, 0x02, // Sequence Number
        0x00, 0x00, 0x00, 0x01, // Observation Domain ID
    ]);
    // Data Set header
    pkt.extend_from_slice(&0x0100u16.to_be_bytes()); // Set ID = 256
    pkt.extend_from_slice(&set_len.to_be_bytes());
    pkt.extend(vec![0xBB; payload_size]);
    pkt
}

/// Test that max_entry_size_bytes is enforced for IPFIX pending flows.
#[test]
fn test_max_entry_size_bytes_ipfix() {
    let mut config = PendingFlowsConfig::new(256);
    config.max_entry_size_bytes = 8;

    let mut parser = NetflowParser::builder()
        .with_ipfix_pending_flows(config)
        .build()
        .expect("Failed to build parser");

    // Small packet (4 bytes) - cached
    let _ = parser.parse_bytes(&ipfix_data_packet());
    assert_eq!(parser.ipfix_cache_info().pending_flow_count, 1);
    assert_eq!(parser.ipfix_cache_info().metrics.pending_cached, 1);

    // Large packet (16 bytes) - dropped
    let _ = parser.parse_bytes(&ipfix_data_packet_with_size(16));
    assert_eq!(parser.ipfix_cache_info().pending_flow_count, 1);
    assert_eq!(parser.ipfix_cache_info().metrics.pending_dropped, 1);
}

// Verify that building a parser with max_pending_flows=0 is rejected for all configurations
#[test]
fn test_zero_pending_cache_size_rejected() {
    let result = NetflowParser::builder()
        .with_pending_flows(PendingFlowsConfig::new(0))
        .build();
    assert!(result.is_err(), "max_pending_flows=0 should be rejected");

    let result = NetflowParser::builder()
        .with_v9_pending_flows(PendingFlowsConfig::new(0))
        .build();
    assert!(result.is_err(), "V9 max_pending_flows=0 should be rejected");

    let result = NetflowParser::builder()
        .with_ipfix_pending_flows(PendingFlowsConfig::new(0))
        .build();
    assert!(
        result.is_err(),
        "IPFIX max_pending_flows=0 should be rejected"
    );
}

/// When cache drops an entry (per-template cap exceeded), the NoTemplate
/// flowset must remain in the output so callers can see the diagnostic info.
#[test]
fn test_dropped_cache_entry_keeps_no_template_in_output() {
    let mut config = PendingFlowsConfig::new(256);
    config.max_entries_per_template = 1; // Only 1 entry allowed per template

    let mut parser = NetflowParser::builder()
        .with_v9_pending_flows(config)
        .build()
        .expect("Failed to build parser");

    // First data packet for template 256 — should be cached and removed from output
    let result = parser.parse_bytes(&v9_data_packet());
    let first_packets: Vec<_> = result.packets;
    if let Some(NetflowPacket::V9(v9)) = first_packets.first() {
        let no_template_count = v9
            .flowsets
            .iter()
            .filter(|fs| matches!(&fs.body, V9FlowSetBody::NoTemplate(_)))
            .count();
        assert_eq!(
            no_template_count, 0,
            "Successfully cached entry should be removed from output"
        );
    }

    // Second data packet for same template — cap exceeded, should be kept in output
    let result = parser.parse_bytes(&v9_data_packet());
    let second_packets: Vec<_> = result.packets;
    if let Some(NetflowPacket::V9(v9)) = second_packets.first() {
        let no_template_count = v9
            .flowsets
            .iter()
            .filter(|fs| matches!(&fs.body, V9FlowSetBody::NoTemplate(_)))
            .count();
        assert_eq!(
            no_template_count, 1,
            "Dropped entry should keep NoTemplate in output"
        );
    } else {
        panic!("Expected V9 packet");
    }

    assert_eq!(parser.v9_cache_info().metrics.pending_cached, 1);
    assert_eq!(parser.v9_cache_info().metrics.pending_dropped, 1);
}

/// When a single packet contains multiple NoTemplate flowsets for the same
/// template ID and only some are cached (per-template cap), only the cached
/// flowsets should be removed. Dropped ones must remain in the output.
#[test]
fn test_partial_cache_same_template_in_single_packet() {
    let mut config = PendingFlowsConfig::new(256);
    config.max_entries_per_template = 1; // Only 1 entry per template

    let mut parser = NetflowParser::builder()
        .with_v9_pending_flows(config)
        .build()
        .expect("Failed to build parser");

    // Build a V9 packet with TWO data flowsets for template 256.
    // Only the first should be cached; the second should be dropped (cap=1).
    let packet = vec![
        0x00, 0x09, // Version 9
        0x00, 0x02, // Count = 2
        0x00, 0x00, 0x00, 0x01, // SysUptime
        0x00, 0x00, 0x00, 0x01, // Unix seconds
        0x00, 0x00, 0x00, 0x01, // Sequence
        0x00, 0x00, 0x00, 0x01, // Source ID
        // Data FlowSet 1 for template 256
        0x01, 0x00, // FlowSet ID = 256
        0x00, 0x08, // Length = 8
        0x00, 0x00, 0x00, 0x41, // Data = 65
        // Data FlowSet 2 for template 256
        0x01, 0x00, // FlowSet ID = 256
        0x00, 0x08, // Length = 8
        0x00, 0x00, 0x00, 0x42, // Data = 66
    ];

    let result = parser.parse_bytes(&packet);
    let packets: Vec<_> = result.packets;
    let v9 = match packets.first() {
        Some(NetflowPacket::V9(v9)) => v9,
        _ => panic!("Expected V9 packet"),
    };

    let no_template_flowsets: Vec<_> = v9
        .flowsets
        .iter()
        .filter(|fs| matches!(&fs.body, V9FlowSetBody::NoTemplate(_)))
        .collect();

    // First flowset cached -> removed.  Second flowset dropped -> kept.
    assert_eq!(
        no_template_flowsets.len(),
        1,
        "Dropped NoTemplate flowset should remain in output"
    );

    // Verify the kept flowset still has its raw data intact
    if let V9FlowSetBody::NoTemplate(info) = &no_template_flowsets[0].body {
        assert!(
            !info.raw_data.is_empty(),
            "Retained NoTemplate must preserve raw_data"
        );
    }

    assert_eq!(parser.v9_cache_info().metrics.pending_cached, 1);
    assert_eq!(parser.v9_cache_info().metrics.pending_dropped, 1);
}

/// Reconfiguring pending flows at runtime should trim entries that exceed the
/// new `max_entries_per_template` limit.
#[test]
fn test_resize_trims_excess_entries_per_template() {
    // Start with a generous per-template cap.
    let mut config = PendingFlowsConfig::new(256);
    config.max_entries_per_template = 10;

    let mut parser = NetflowParser::builder()
        .with_v9_pending_flows(config)
        .build()
        .expect("Failed to build parser");

    // Cache 5 data packets for template 256.
    for _ in 0..5 {
        let _ = parser.parse_bytes(&v9_data_packet());
    }
    assert_eq!(parser.v9_cache_info().pending_flow_count, 5);
    assert_eq!(parser.v9_cache_info().metrics.pending_cached, 5);
    assert_eq!(parser.v9_cache_info().metrics.pending_dropped, 0);

    // Shrink the per-template cap to 2.
    let mut stricter = PendingFlowsConfig::new(256);
    stricter.max_entries_per_template = 2;
    parser
        .v9_parser_mut()
        .set_pending_flows_config(Some(stricter))
        .expect("reconfigure should succeed");

    // 3 entries should have been dropped during resize.
    assert_eq!(parser.v9_cache_info().pending_flow_count, 2);
    assert_eq!(parser.v9_cache_info().metrics.pending_dropped, 3);
}

/// Reconfiguring pending flows at runtime should drop entries whose raw data
/// exceeds the new `max_entry_size_bytes` limit.
#[test]
fn test_resize_trims_oversize_entries() {
    // Start with a generous size limit.
    let mut config = PendingFlowsConfig::new(256);
    config.max_entry_size_bytes = 1024;

    let mut parser = NetflowParser::builder()
        .with_v9_pending_flows(config)
        .build()
        .expect("Failed to build parser");

    // Cache a small entry (4 bytes) and a larger entry (16 bytes).
    let _ = parser.parse_bytes(&v9_data_packet()); // 4-byte payload
    let _ = parser.parse_bytes(&v9_data_packet_with_size(16)); // 16-byte payload
    assert_eq!(parser.v9_cache_info().pending_flow_count, 2);
    assert_eq!(parser.v9_cache_info().metrics.pending_dropped, 0);

    // Lower the size limit to 8 bytes — the 16-byte entry should be dropped.
    let mut stricter = PendingFlowsConfig::new(256);
    stricter.max_entry_size_bytes = 8;
    parser
        .v9_parser_mut()
        .set_pending_flows_config(Some(stricter))
        .expect("reconfigure should succeed");

    assert_eq!(parser.v9_cache_info().pending_flow_count, 1);
    assert_eq!(parser.v9_cache_info().metrics.pending_dropped, 1);
}

/// Reconfiguring IPFIX pending flows at runtime should trim entries that
/// exceed the new limits, same as V9.
#[test]
fn test_resize_trims_ipfix_pending_flows() {
    let mut config = PendingFlowsConfig::new(256);
    config.max_entries_per_template = 10;

    let mut parser = NetflowParser::builder()
        .with_ipfix_pending_flows(config)
        .build()
        .expect("Failed to build parser");

    // Cache 4 IPFIX data packets for template 256.
    for _ in 0..4 {
        let _ = parser.parse_bytes(&ipfix_data_packet());
    }
    assert_eq!(parser.ipfix_cache_info().pending_flow_count, 4);
    assert_eq!(parser.ipfix_cache_info().metrics.pending_dropped, 0);

    // Shrink cap to 1.
    let mut stricter = PendingFlowsConfig::new(256);
    stricter.max_entries_per_template = 1;
    parser
        .ipfix_parser_mut()
        .set_pending_flows_config(Some(stricter))
        .expect("reconfigure should succeed");

    assert_eq!(parser.ipfix_cache_info().pending_flow_count, 1);
    assert_eq!(parser.ipfix_cache_info().metrics.pending_dropped, 3);
}

/// Caching into a template_id whose existing entries have all expired should
/// prune the stale entries (freeing per-template capacity) instead of
/// rejecting the new entry.
#[test]
fn test_cache_prunes_expired_entries_for_touched_template() {
    // TTL = 0 means every entry is expired by the next cache() call.
    let mut parser = NetflowParser::builder()
        .with_v9_pending_flows(PendingFlowsConfig::with_ttl(256, Duration::ZERO))
        .build()
        .expect("Failed to build parser");

    // First entry for template 256 — no existing entries to prune.
    let _ = parser.parse_bytes(&v9_data_packet());
    assert_eq!(parser.v9_cache_info().pending_flow_count, 1);
    assert_eq!(parser.v9_cache_info().metrics.pending_cached, 1);
    assert_eq!(parser.v9_cache_info().metrics.pending_dropped, 0);

    // Second entry — the first entry is now expired and should be pruned,
    // making room for the new one.
    let _ = parser.parse_bytes(&v9_data_packet());
    assert_eq!(parser.v9_cache_info().pending_flow_count, 1);
    assert_eq!(parser.v9_cache_info().metrics.pending_cached, 2);
    assert_eq!(parser.v9_cache_info().metrics.pending_dropped, 1);

    // Third entry — same: second entry expired, pruned, third inserted.
    let _ = parser.parse_bytes(&v9_data_packet());
    assert_eq!(parser.v9_cache_info().pending_flow_count, 1);
    assert_eq!(parser.v9_cache_info().metrics.pending_cached, 3);
    assert_eq!(parser.v9_cache_info().metrics.pending_dropped, 2);
}

/// When the cache is at its template-ID capacity and a new template_id is
/// inserted, expired entries across ALL templates should be purged first so
/// stale data doesn't force LRU eviction of still-valid entries.
#[test]
fn test_cache_purges_globally_before_lru_eviction() {
    let mut config = PendingFlowsConfig::with_ttl(2, Duration::ZERO); // capacity = 2
    config.max_entries_per_template = 10;

    let mut parser = NetflowParser::builder()
        .with_v9_pending_flows(config)
        .build()
        .expect("Failed to build parser");

    // Fill both slots with different template IDs.
    let _ = parser.parse_bytes(&v9_data_packet()); // template 256
    let mut pkt_257 = v9_data_packet();
    pkt_257[20] = 0x01;
    pkt_257[21] = 0x01; // template 257
    let _ = parser.parse_bytes(&pkt_257);

    assert_eq!(parser.v9_cache_info().pending_flow_count, 2);
    assert_eq!(parser.v9_cache_info().metrics.pending_cached, 2);
    assert_eq!(parser.v9_cache_info().metrics.pending_dropped, 0);

    // Insert a third template ID. Both existing templates' entries are
    // expired (TTL=0), so the global purge should clean them up instead
    // of blindly evicting the LRU.
    let mut pkt_258 = v9_data_packet();
    pkt_258[20] = 0x01;
    pkt_258[21] = 0x02; // template 258
    let _ = parser.parse_bytes(&pkt_258);

    // Only the fresh entry for 258 should remain; the two expired
    // template slots were purged.
    assert_eq!(parser.v9_cache_info().pending_flow_count, 1);
    assert_eq!(parser.v9_cache_info().metrics.pending_cached, 3);
    assert_eq!(parser.v9_cache_info().metrics.pending_dropped, 2);
}

/// Oversized flowset bodies should be truncated at parse time rather than
/// cloned in full when caching is enabled. The truncated NoTemplate stays
/// in the output for diagnostics and is never cached.
#[test]
fn test_oversized_entry_truncated_at_parse_time_v9() {
    let mut config = PendingFlowsConfig::new(256);
    config.max_entry_size_bytes = 8; // Only accept bodies <= 8 bytes

    let mut parser = NetflowParser::builder()
        .with_v9_pending_flows(config)
        .with_max_error_sample_size(4)
        .build()
        .expect("Failed to build parser");

    // V9 data packet with a 20-byte body for template 256 (no template loaded).
    // FlowSet header: ID=256, Length=24 (4 hdr + 20 body).
    let oversized_packet = vec![
        0x00, 0x09, // Version 9
        0x00, 0x01, // Count = 1
        0x00, 0x00, 0x00, 0x01, // SysUptime
        0x00, 0x00, 0x00, 0x02, // Unix seconds
        0x00, 0x00, 0x00, 0x02, // Sequence
        0x00, 0x00, 0x00, 0x01, // Source ID
        // Data FlowSet
        0x01, 0x00, // FlowSet ID = 256
        0x00, 0x18, // Length = 24
        // 20 bytes of body
        0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88,
        0x99, 0x00, 0xAA, 0xBB, 0xCC, 0xDD,
    ];

    let result = parser.parse_bytes(&oversized_packet);
    let packets: Vec<_> = result.packets;

    // The NoTemplate flowset should remain in the output (not cached).
    let v9 = match packets.first() {
        Some(NetflowPacket::V9(v9)) => v9,
        _ => panic!("Expected V9 packet"),
    };
    let no_templates: Vec<_> = v9
        .flowsets
        .iter()
        .filter(|fs| matches!(&fs.body, V9FlowSetBody::NoTemplate(_)))
        .collect();
    assert_eq!(
        no_templates.len(),
        1,
        "Oversized entry should stay in output"
    );

    // raw_data should be truncated to max_error_sample_size (4), not the full 20.
    if let V9FlowSetBody::NoTemplate(info) = &no_templates[0].body {
        assert_eq!(
            info.raw_data.len(),
            4,
            "raw_data should be truncated to max_error_sample_size"
        );
    }

    // Nothing should have been cached; the drop should be recorded.
    assert_eq!(parser.v9_cache_info().pending_flow_count, 0);
    assert_eq!(parser.v9_cache_info().metrics.pending_cached, 0);
    assert_eq!(parser.v9_cache_info().metrics.pending_dropped, 1);
}

/// Same as V9 test but for IPFIX: oversized flowset bodies are truncated
/// and kept in output rather than cloned and cached.
#[test]
fn test_oversized_entry_truncated_at_parse_time_ipfix() {
    let mut config = PendingFlowsConfig::new(256);
    config.max_entry_size_bytes = 8;

    let mut parser = NetflowParser::builder()
        .with_ipfix_pending_flows(config)
        .with_max_error_sample_size(4)
        .build()
        .expect("Failed to build parser");

    // IPFIX data packet with a 20-byte body for template 256.
    // Set header: ID=256, Length=24 (4 hdr + 20 body).
    // Message header length = 16 + 24 = 40 (0x28).
    let oversized_packet = vec![
        0x00, 0x0A, // Version 10 (IPFIX)
        0x00, 0x28, // Length = 40
        0x00, 0x00, 0x00, 0x01, // Export Time
        0x00, 0x00, 0x00, 0x01, // Sequence Number
        0x00, 0x00, 0x00, 0x01, // Observation Domain ID
        // Data Set
        0x01, 0x00, // Set ID = 256
        0x00, 0x18, // Set Length = 24
        // 20 bytes of body
        0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88,
        0x99, 0x00, 0xAA, 0xBB, 0xCC, 0xDD,
    ];

    let result = parser.parse_bytes(&oversized_packet);
    let packets: Vec<_> = result.packets;

    let ipfix = match packets.first() {
        Some(NetflowPacket::IPFix(ipfix)) => ipfix,
        _ => panic!("Expected IPFIX packet"),
    };

    // The NoTemplate flowset should remain in output.
    let no_templates: Vec<_> = ipfix
        .flowsets
        .iter()
        .filter(|fs| {
            matches!(
                &fs.body,
                netflow_parser::variable_versions::ipfix::FlowSetBody::NoTemplate(_)
            )
        })
        .collect();
    assert_eq!(
        no_templates.len(),
        1,
        "Oversized entry should stay in output"
    );

    if let netflow_parser::variable_versions::ipfix::FlowSetBody::NoTemplate(info) =
        &no_templates[0].body
    {
        assert_eq!(
            info.raw_data.len(),
            4,
            "raw_data should be truncated to max_error_sample_size"
        );
    }

    assert_eq!(parser.ipfix_cache_info().pending_flow_count, 0);
    assert_eq!(parser.ipfix_cache_info().metrics.pending_cached, 0);
    assert_eq!(parser.ipfix_cache_info().metrics.pending_dropped, 1);
}

/// When the cache rejects an entry (per-template cap), the returned raw_data
/// should be truncated to max_error_sample_size before being stored back in
/// the NoTemplate flowset, so callers don't hold a large diagnostic buffer.
#[test]
fn test_rejected_entry_raw_data_truncated_v9() {
    let mut config = PendingFlowsConfig::new(256);
    config.max_entries_per_template = 1; // reject the second entry

    let mut parser = NetflowParser::builder()
        .with_v9_pending_flows(config)
        .with_max_error_sample_size(4)
        .build()
        .expect("Failed to build parser");

    // V9 packet with a 20-byte flowset body for template 256.
    let big_body_packet = vec![
        0x00, 0x09, // Version 9
        0x00, 0x01, // Count = 1
        0x00, 0x00, 0x00, 0x01, // SysUptime
        0x00, 0x00, 0x00, 0x02, // Unix seconds
        0x00, 0x00, 0x00, 0x02, // Sequence
        0x00, 0x00, 0x00, 0x01, // Source ID
        // Data FlowSet
        0x01, 0x00, // FlowSet ID = 256
        0x00, 0x18, // Length = 24 (4 hdr + 20 body)
        0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88,
        0x99, 0x00, 0xAA, 0xBB, 0xCC, 0xDD,
    ];

    // First packet — cached and removed from output.
    let result = parser.parse_bytes(&big_body_packet);
    if let Some(NetflowPacket::V9(v9)) = result.packets.first() {
        assert_eq!(
            v9.flowsets
                .iter()
                .filter(|fs| matches!(&fs.body, V9FlowSetBody::NoTemplate(_)))
                .count(),
            0,
            "First entry should be cached"
        );
    }

    // Second packet — rejected by per-template cap, stays in output.
    let result = parser.parse_bytes(&big_body_packet);
    let v9 = match result.packets.first() {
        Some(NetflowPacket::V9(v9)) => v9,
        _ => panic!("Expected V9 packet"),
    };
    let no_templates: Vec<_> = v9
        .flowsets
        .iter()
        .filter(|fs| matches!(&fs.body, V9FlowSetBody::NoTemplate(_)))
        .collect();
    assert_eq!(no_templates.len(), 1);

    // raw_data should be truncated to max_error_sample_size (4), not the full 20.
    if let V9FlowSetBody::NoTemplate(info) = &no_templates[0].body {
        assert_eq!(
            info.raw_data.len(),
            4,
            "Rejected entry raw_data should be truncated to max_error_sample_size"
        );
    }
}

/// IPFIX counterpart: rejected cache entry raw_data is truncated.
#[test]
fn test_rejected_entry_raw_data_truncated_ipfix() {
    let mut config = PendingFlowsConfig::new(256);
    config.max_entries_per_template = 1;

    let mut parser = NetflowParser::builder()
        .with_ipfix_pending_flows(config)
        .with_max_error_sample_size(4)
        .build()
        .expect("Failed to build parser");

    // IPFIX packet with a 20-byte set body for template 256.
    let big_body_packet = vec![
        0x00, 0x0A, // Version 10 (IPFIX)
        0x00, 0x28, // Length = 40 (16 hdr + 24 set)
        0x00, 0x00, 0x00, 0x01, // Export Time
        0x00, 0x00, 0x00, 0x01, // Sequence Number
        0x00, 0x00, 0x00, 0x01, // Observation Domain ID
        // Data Set
        0x01, 0x00, // Set ID = 256
        0x00, 0x18, // Set Length = 24 (4 hdr + 20 body)
        0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88,
        0x99, 0x00, 0xAA, 0xBB, 0xCC, 0xDD,
    ];

    // First packet — cached.
    let _ = parser.parse_bytes(&big_body_packet);

    // Second packet — rejected, stays in output.
    let result = parser.parse_bytes(&big_body_packet);
    let ipfix = match result.packets.first() {
        Some(NetflowPacket::IPFix(ipfix)) => ipfix,
        _ => panic!("Expected IPFIX packet"),
    };
    let no_templates: Vec<_> = ipfix
        .flowsets
        .iter()
        .filter(|fs| {
            matches!(
                &fs.body,
                netflow_parser::variable_versions::ipfix::FlowSetBody::NoTemplate(_)
            )
        })
        .collect();
    assert_eq!(no_templates.len(), 1);

    if let netflow_parser::variable_versions::ipfix::FlowSetBody::NoTemplate(info) =
        &no_templates[0].body
    {
        assert_eq!(
            info.raw_data.len(),
            4,
            "Rejected entry raw_data should be truncated to max_error_sample_size"
        );
    }
}

/// When per-template cap is reached but all existing entries are expired,
/// would_accept() should still return true (counting only live entries) so the
/// parse site preserves the full raw_data and cache() can prune + accept.
#[test]
fn test_would_accept_accounts_for_ttl_v9() {
    let mut config = PendingFlowsConfig::with_ttl(256, Duration::ZERO);
    config.max_entries_per_template = 1;

    let mut parser = NetflowParser::builder()
        .with_v9_pending_flows(config)
        .build()
        .expect("Failed to build parser");

    // First entry cached normally.
    let _ = parser.parse_bytes(&v9_data_packet());
    assert_eq!(parser.v9_cache_info().pending_flow_count, 1);
    assert_eq!(parser.v9_cache_info().metrics.pending_cached, 1);

    // Second entry: the first is expired (TTL=0). would_accept() should see
    // 0 live entries and allow the full clone. cache() prunes the expired
    // entry and inserts the new one.
    let _ = parser.parse_bytes(&v9_data_packet());
    assert_eq!(parser.v9_cache_info().pending_flow_count, 1);
    assert_eq!(parser.v9_cache_info().metrics.pending_cached, 2);
    // 1 dropped = the pruned expired entry
    assert_eq!(parser.v9_cache_info().metrics.pending_dropped, 1);
}

/// Same as the V9 test but for IPFIX: would_accept() accounts for TTL.
#[test]
fn test_would_accept_accounts_for_ttl_ipfix() {
    let mut config = PendingFlowsConfig::with_ttl(256, Duration::ZERO);
    config.max_entries_per_template = 1;

    let mut parser = NetflowParser::builder()
        .with_ipfix_pending_flows(config)
        .build()
        .expect("Failed to build parser");

    let _ = parser.parse_bytes(&ipfix_data_packet());
    assert_eq!(parser.ipfix_cache_info().pending_flow_count, 1);
    assert_eq!(parser.ipfix_cache_info().metrics.pending_cached, 1);

    let _ = parser.parse_bytes(&ipfix_data_packet());
    assert_eq!(parser.ipfix_cache_info().pending_flow_count, 1);
    assert_eq!(parser.ipfix_cache_info().metrics.pending_cached, 2);
    assert_eq!(parser.ipfix_cache_info().metrics.pending_dropped, 1);
}

/// Same as the V9 test but for IPFIX, verifying the per-template TTL
/// pruning path fires through the IPFIX parser's cache logic.
#[test]
fn test_ipfix_cache_prunes_expired_entries() {
    let mut parser = NetflowParser::builder()
        .with_ipfix_pending_flows(PendingFlowsConfig::with_ttl(256, Duration::ZERO))
        .build()
        .expect("Failed to build parser");

    let _ = parser.parse_bytes(&ipfix_data_packet());
    assert_eq!(parser.ipfix_cache_info().pending_flow_count, 1);
    assert_eq!(parser.ipfix_cache_info().metrics.pending_dropped, 0);

    // Second entry prunes the expired first entry.
    let _ = parser.parse_bytes(&ipfix_data_packet());
    assert_eq!(parser.ipfix_cache_info().pending_flow_count, 1);
    assert_eq!(parser.ipfix_cache_info().metrics.pending_cached, 2);
    assert_eq!(parser.ipfix_cache_info().metrics.pending_dropped, 1);
}
