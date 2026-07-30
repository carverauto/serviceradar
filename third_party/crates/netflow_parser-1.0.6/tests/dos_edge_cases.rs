//! Tests for security edge cases: malformed packets, excessive field counts,
//! cache eviction under pressure, and error buffer size limits.

use netflow_parser::{NetflowError, NetflowPacket, NetflowParser};
use std::time::Duration;

/// Test that excessive field counts in V9 templates are rejected
#[test]
fn test_v9_max_field_count_exceeded() {
    let mut parser = NetflowParser::builder()
        .with_v9_max_field_count(100) // Restrictive limit for testing
        .build()
        .expect("Failed to build parser");

    // V9 template packet with field_count = 200 (exceeds limit of 100)
    let mut packet = vec![
        0x00, 0x09, // Version 9
        0x00, 0x01, // Count = 1
        0x00, 0x00, 0x00, 0x01, // SysUptime
        0x00, 0x00, 0x00, 0x01, // Unix seconds
        0x00, 0x00, 0x00, 0x01, // Sequence
        0x00, 0x00, 0x00, 0x01, // Source ID
        // FlowSet
        0x00, 0x00, // FlowSet ID = 0 (template)
        0x00, 0x00, // Length (will calculate)
        0x01, 0x00, // Template ID = 256
        0x00, 0xC8, // Field count = 200 (exceeds limit)
    ];

    // Add dummy fields (4 bytes each: type u16 + length u16)
    for i in 0..200u16 {
        packet.extend_from_slice(&(i + 1).to_be_bytes()); // Field type
        packet.extend_from_slice(&4u16.to_be_bytes()); // Field length
    }

    // Update FlowSet length: 4 (flowset header) + 4 (template record header) + 200*4 (fields)
    let flowset_length = (4 + 4 + 200 * 4) as u16;
    packet[22..24].copy_from_slice(&flowset_length.to_be_bytes());

    let _result = parser.parse_bytes(&packet);

    // The template should be rejected by is_valid() because field_count (200) > max (100).
    // The parser returns the packet with no data records, but may not set an error since
    // invalid templates are silently skipped. Verify the template was NOT cached.
    assert!(
        !parser.has_v9_template(256),
        "Template with excessive field count should not be cached"
    );
}

/// Test that excessive field counts in IPFIX templates are handled
#[test]
fn test_ipfix_max_field_count_handling() {
    let mut parser = NetflowParser::builder()
        .with_ipfix_max_field_count(50) // Restrictive limit for testing
        .build()
        .expect("Failed to build parser");

    // IPFIX template packet with many fields (tests large template handling)
    let mut packet = vec![
        0x00, 0x0A, // Version 10 (IPFIX)
        0x00, 0x00, // Length (will calculate)
        0x00, 0x00, 0x00, 0x01, // Export time
        0x00, 0x00, 0x00, 0x01, // Sequence
        0x00, 0x00, 0x00, 0x01, // Observation domain
        // Template Set
        0x00, 0x02, // Set ID = 2 (template)
        0x00, 0x00, // Length (will calculate)
        0x01, 0x00, // Template ID = 256
        0x00, 0x64, // Field count = 100
    ];

    // Add dummy fields (4 bytes each: type u16 + length u16)
    for i in 0..100u16 {
        packet.extend_from_slice(&(i + 1).to_be_bytes()); // Field type
        packet.extend_from_slice(&4u16.to_be_bytes()); // Field length
    }

    // Update lengths: 4 (set header) + 4 (template record header) + 100*4 (fields)
    let set_length = (4 + 4 + 100 * 4) as u16;
    packet[18..20].copy_from_slice(&set_length.to_be_bytes());
    let total_length = 16 + set_length; // Message header + set
    packet[2..4].copy_from_slice(&total_length.to_be_bytes());

    let result = parser.parse_bytes(&packet);

    // The template should be rejected by is_valid() because field_count (100) > max (50).
    // Verify the template was NOT cached.
    assert!(
        !parser.has_ipfix_template(256),
        "IPFIX template with excessive field count should not be cached"
    );

    // Parser should not error (invalid templates are silently skipped)
    assert!(
        result.error.is_none(),
        "Parser should handle oversized template gracefully without error"
    );
}

/// Test template cache eviction when cache fills up
#[test]
fn test_template_cache_eviction() {
    let mut parser = NetflowParser::builder()
        .with_v9_cache_size(5) // Small cache to trigger eviction
        .build()
        .expect("Failed to build parser");

    // Create 10 different V9 template packets (will evict first 5)
    for template_id in 256..266u16 {
        let mut packet = vec![
            0x00, 0x09, // Version 9
            0x00, 0x01, // Count = 1
            0x00, 0x00, 0x00, 0x01, // SysUptime
            0x00, 0x00, 0x00, 0x01, // Unix seconds
            0x00, 0x00, 0x00, 0x01, // Sequence
            0x00, 0x00, 0x00, 0x01, // Source ID = 1
            // FlowSet
            0x00, 0x00, // FlowSet ID = 0 (template)
            0x00, 0x0C, // Length = 12
        ];
        packet.extend_from_slice(&template_id.to_be_bytes()); // Template ID
        packet.extend_from_slice(&[0x00, 0x01]); // Field count = 1
        packet.extend_from_slice(&[0x00, 0x01]); // Field type = 1
        packet.extend_from_slice(&[0x00, 0x04]); // Field length = 4

        let result = parser.parse_bytes(&packet);
        assert!(
            result.is_ok(),
            "Template {} should parse successfully",
            template_id
        );
    }

    // Check cache stats - should show evictions occurred
    let stats = parser.v9_cache_info();
    assert_eq!(stats.current_size, 5, "Cache should be at max size");
    assert_eq!(stats.max_size_per_cache, 5, "Max size should be 5");

    // Verify first template (256) was evicted by trying to use it
    let data_packet = vec![
        0x00, 0x09, // Version 9
        0x00, 0x01, // Count = 1
        0x00, 0x00, 0x00, 0x01, // SysUptime
        0x00, 0x00, 0x00, 0x01, // Unix seconds
        0x00, 0x00, 0x00, 0x02, // Sequence
        0x00, 0x00, 0x00, 0x01, // Source ID = 1
        // Data FlowSet
        0x01, 0x00, // FlowSet ID = 256 (data using template 256)
        0x00, 0x08, // Length = 8
        0x00, 0x00, 0x00, 0x01, // Data (4 bytes)
    ];

    let result = parser.parse_bytes(&data_packet);

    // V9 returns a NoTemplate flowset for the evicted template (not an error).
    assert!(
        result.error.is_none(),
        "Evicted-template data packet should parse without error"
    );
    let v9 = match result.packets.first() {
        Some(NetflowPacket::V9(v9)) => v9,
        _ => panic!("Expected a V9 packet"),
    };
    assert!(
        v9.flowsets.iter().any(|fs| matches!(
            &fs.body,
            netflow_parser::variable_versions::v9::FlowSetBody::NoTemplate(_)
        )),
        "Should have NoTemplate flowset for evicted template"
    );
}

/// Test error buffer size configuration limits error samples
#[test]
fn test_error_buffer_size_configuration() {
    let mut parser = NetflowParser::builder()
        .with_max_error_sample_size(32) // Very small buffer for testing
        .build()
        .expect("Failed to build parser");

    // Create a large invalid packet (1000 bytes of garbage after V9 header)
    let mut packet = vec![
        0x00, 0x09, // Version 9
        0x00, 0x01, // Count = 1
        0x00, 0x00, 0x00, 0x01, // SysUptime
        0x00, 0x00, 0x00, 0x01, // Unix seconds
        0x00, 0x00, 0x00, 0x01, // Sequence
        0x00, 0x00, 0x00, 0x01, // Source ID
    ];

    // Add 1000 bytes of garbage
    packet.extend(vec![0xFF; 1000]);

    let result = parser.parse_bytes(&packet);

    // Should have error
    assert!(result.error.is_some(), "Should error on malformed packet");

    // Verify parser was configured with small error buffer
    // (the actual error content may still be verbose due to Debug formatting,
    // but the raw sample in ParseError should be limited)
    match &result.error {
        Some(NetflowError::ParseError { remaining, .. }) => {
            // The remaining buffer sample should be limited by max_error_sample_size
            assert!(
                remaining.len() <= 32,
                "Error sample should be limited to 32 bytes, got {}",
                remaining.len()
            );
        }
        Some(NetflowError::Partial { .. }) => {
            // Partial errors don't include raw samples, which is also acceptable
            println!("Got Partial error (acceptable)");
        }
        Some(other) => {
            // Other error types are acceptable as long as parser doesn't panic.
            // The error sample is bounded by the error type itself (no raw buffer).
            panic!("Unexpected error type for malformed V9 packet: {:?}", other);
        }
        None => panic!("Expected error on malformed packet"),
    }
}

/// Test rapid template collision scenarios (same template ID, different definitions)
#[test]
fn test_rapid_template_collisions() {
    let mut parser = NetflowParser::default();

    // Send template 256 with 1 field
    let template1 = vec![
        0x00, 0x09, // Version 9
        0x00, 0x01, // Count = 1
        0x00, 0x00, 0x00, 0x01, // SysUptime
        0x00, 0x00, 0x00, 0x01, // Unix seconds
        0x00, 0x00, 0x00, 0x01, // Sequence
        0x00, 0x00, 0x00, 0x01, // Source ID = 1
        0x00, 0x00, // FlowSet ID = 0 (template)
        0x00, 0x0C, // Length = 12
        0x01, 0x00, // Template ID = 256
        0x00, 0x01, // Field count = 1
        0x00, 0x01, // Field type = 1
        0x00, 0x04, // Field length = 4
    ];

    let result1 = parser.parse_bytes(&template1);
    assert!(result1.is_ok(), "First template should succeed");

    // Send same template ID but with 2 fields (collision/override)
    let template2 = vec![
        0x00, 0x09, // Version 9
        0x00, 0x01, // Count = 1
        0x00, 0x00, 0x00, 0x01, // SysUptime
        0x00, 0x00, 0x00, 0x02, // Unix seconds
        0x00, 0x00, 0x00, 0x02, // Sequence
        0x00, 0x00, 0x00, 0x01, // Source ID = 1
        0x00, 0x00, // FlowSet ID = 0 (template)
        0x00, 0x10, // Length = 16
        0x01, 0x00, // Template ID = 256 (same as before)
        0x00, 0x02, // Field count = 2 (different!)
        0x00, 0x01, // Field type = 1
        0x00, 0x04, // Field length = 4
        0x00, 0x02, // Field type = 2
        0x00, 0x04, // Field length = 4
    ];

    let result2 = parser.parse_bytes(&template2);
    assert!(result2.is_ok(), "Second template should succeed (override)");

    // Verify the new template is cached (has 2 fields worth of data = 8 bytes)
    let data_packet = vec![
        0x00, 0x09, // Version 9
        0x00, 0x01, // Count = 1
        0x00, 0x00, 0x00, 0x01, // SysUptime
        0x00, 0x00, 0x00, 0x03, // Unix seconds
        0x00, 0x00, 0x00, 0x03, // Sequence
        0x00, 0x00, 0x00, 0x01, // Source ID = 1
        0x01, 0x00, // FlowSet ID = 256 (data)
        0x00, 0x0C, // Length = 12
        0x00, 0x00, 0x00, 0x01, // Field 1 data
        0x00, 0x00, 0x00, 0x02, // Field 2 data
    ];

    let result3 = parser.parse_bytes(&data_packet);
    assert!(
        result3.is_ok(),
        "Data packet should parse with new template"
    );
    assert_eq!(result3.packets.len(), 1, "Should have parsed 1 packet");

    // Verify the parsed data actually uses the overridden 2-field template
    if let NetflowPacket::V9(v9) = &result3.packets[0] {
        let data_flowsets: Vec<_> = v9
            .flowsets
            .iter()
            .filter_map(|fs| {
                if let netflow_parser::variable_versions::v9::FlowSetBody::Data(data) = &fs.body
                {
                    Some(data)
                } else {
                    None
                }
            })
            .collect();
        assert_eq!(data_flowsets.len(), 1, "Should have 1 data flowset");
        assert_eq!(
            data_flowsets[0].fields.len(),
            1,
            "Should have 1 data record"
        );
        assert_eq!(
            data_flowsets[0].fields[0].len(),
            2,
            "Record should have 2 fields (from the overridden template)"
        );
    } else {
        panic!("Expected V9 packet");
    }
}

/// Test cache metrics accuracy under load
#[test]
fn test_cache_metrics_accuracy() {
    let mut parser = NetflowParser::builder()
        .with_v9_cache_size(10)
        .build()
        .expect("Failed to build parser");

    // Add template
    let template = vec![
        0x00, 0x09, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00,
        0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x0C, 0x01, 0x00, 0x00, 0x01,
        0x00, 0x01, 0x00, 0x04,
    ];

    let _ = parser.parse_bytes(&template);

    let initial_stats = parser.v9_cache_info();
    let initial_hits = initial_stats.metrics.hits;

    // Use the template 5 times (should increment hits)
    for _ in 0..5 {
        let data = vec![
            0x00, 0x09, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x02, 0x00, 0x00,
            0x00, 0x02, 0x00, 0x00, 0x00, 0x01, 0x01, 0x00, 0x00, 0x08, 0x00, 0x00, 0x00, 0x01,
        ];
        let _ = parser.parse_bytes(&data);
    }

    let final_stats = parser.v9_cache_info();
    let final_hits = final_stats.metrics.hits;

    // Should have 5 more hits
    assert_eq!(
        final_hits - initial_hits,
        5,
        "Should have 5 cache hits from data packets"
    );
}

/// Test template TTL expiration
#[test]
fn test_template_ttl_expiration() {
    use netflow_parser::variable_versions::ttl::TtlConfig;

    let mut parser = NetflowParser::builder()
        .with_v9_ttl(TtlConfig::new(Duration::from_millis(100))) // 100ms TTL
        .build()
        .expect("Failed to build parser");

    // Add template
    let template = vec![
        0x00, 0x09, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00,
        0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x0C, 0x01, 0x00, 0x00, 0x01,
        0x00, 0x01, 0x00, 0x04,
    ];

    let result1 = parser.parse_bytes(&template);
    assert!(result1.is_ok(), "Template should be added");

    // Immediately use template (should work)
    let data = vec![
        0x00, 0x09, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x02, 0x00, 0x00,
        0x00, 0x02, 0x00, 0x00, 0x00, 0x01, 0x01, 0x00, 0x00, 0x08, 0x00, 0x00, 0x00, 0x01,
    ];

    let result2 = parser.parse_bytes(&data);
    assert!(
        result2.is_ok(),
        "Data packet should parse with fresh template"
    );

    // Wait for TTL to expire (generous margin for CI)
    std::thread::sleep(Duration::from_millis(500));

    // Try to use template again (should fail - expired)
    let result3 = parser.parse_bytes(&data);

    // V9 returns a NoTemplate flowset for the expired template (not an error).
    assert!(
        result3.error.is_none(),
        "Expired-template data packet should parse without error"
    );
    let v9 = match result3.packets.first() {
        Some(NetflowPacket::V9(v9)) => v9,
        _ => panic!("Expected a V9 packet"),
    };
    assert!(
        v9.flowsets.iter().any(|fs| matches!(
            &fs.body,
            netflow_parser::variable_versions::v9::FlowSetBody::NoTemplate(_)
        )),
        "Should have NoTemplate flowset for expired template"
    );
}

/// Test zero-size cache configuration is rejected
#[test]
fn test_zero_cache_size_rejected() {
    let result = NetflowParser::builder().with_v9_cache_size(0).build();

    assert!(result.is_err(), "Should reject zero cache size");
    let error = result.unwrap_err();
    let error_msg = error.to_string();
    assert!(
        error_msg.contains("cache") || error_msg.contains("size"),
        "Error should mention cache/size issue, got: {}",
        error_msg
    );
}

/// Test handling of malformed flowset lengths
#[test]
fn test_malformed_flowset_length() {
    let mut parser = NetflowParser::default();

    // V9 packet with flowset length extending beyond packet
    let packet = vec![
        0x00, 0x09, // Version 9
        0x00, 0x01, // Count = 1
        0x00, 0x00, 0x00, 0x01, // SysUptime
        0x00, 0x00, 0x00, 0x01, // Unix seconds
        0x00, 0x00, 0x00, 0x01, // Sequence
        0x00, 0x00, 0x00, 0x01, // Source ID
        0x00, 0x00, // FlowSet ID = 0 (template)
        0xFF, 0xFF, // Length = 65535 (way too large!)
        0x01, 0x00, // Template ID
        0x00, 0x01, // Field count
    ];

    let result = parser.parse_bytes(&packet);

    // Should handle gracefully (incomplete or parse error)
    assert!(
        result.error.is_some(),
        "Malformed flowset length must produce an error"
    );
}

/// Test that max_records_per_flowset limits V9 data record parsing
#[test]
fn test_v9_max_records_per_flowset() {
    // First, send a V9 template: template_id=256, 1 field (IN_BYTES=1, len=4)
    let template_packet = vec![
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
        0x00, 0x01, // Field count = 1
        0x00, 0x01, // Field type = IN_BYTES
        0x00, 0x04, // Field length = 4
    ];

    let mut parser = NetflowParser::builder()
        .with_max_records_per_flowset(2) // Only allow 2 records per flowset
        .build()
        .expect("Failed to build parser");

    // Parse template
    let result = parser.parse_bytes(&template_packet);
    assert!(result.error.is_none(), "Template parse failed");

    // Data flowset with 5 records (5 * 4 bytes = 20 bytes of data)
    let mut data_packet = vec![
        0x00, 0x09, // Version 9
        0x00, 0x01, // Count = 1
        0x00, 0x00, 0x00, 0x02, // SysUptime
        0x00, 0x00, 0x00, 0x02, // Unix seconds
        0x00, 0x00, 0x00, 0x02, // Sequence
        0x00, 0x00, 0x00, 0x01, // Source ID
        // Data FlowSet
        0x01, 0x00, // FlowSet ID = 256 (matches template)
        0x00, 0x18, // Length = 24 (4 header + 20 data)
    ];
    // 5 records, 4 bytes each
    for i in 0u32..5 {
        data_packet.extend_from_slice(&(i + 1).to_be_bytes());
    }

    let result = parser.parse_bytes(&data_packet);
    assert!(
        result.error.is_none(),
        "Data parse failed: {:?}",
        result.error
    );

    if let Some(NetflowPacket::V9(v9)) = result.packets.first() {
        // Find the data flowset
        let data_flowset = v9.flowsets.iter().find(|fs| {
            matches!(
                fs.body,
                netflow_parser::variable_versions::v9::FlowSetBody::Data(_)
            )
        });
        assert!(data_flowset.is_some(), "Expected data flowset");
        if let netflow_parser::variable_versions::v9::FlowSetBody::Data(data) =
            &data_flowset.unwrap().body
        {
            assert_eq!(
                data.fields.len(),
                2,
                "Expected 2 records (limited by max_records_per_flowset), got {}",
                data.fields.len()
            );
        }
    } else {
        panic!("Expected V9 packet");
    }
}

/// Test that max_records_per_flowset limits IPFIX data record parsing
#[test]
fn test_ipfix_max_records_per_flowset() {
    // IPFIX template: template_id=256, 1 field (octetDeltaCount=1, len=4)
    let mut template_packet = vec![
        0x00, 0x0A, // Version 10 (IPFIX)
        0x00, 0x00, // Length (will fill)
        0x00, 0x00, 0x00, 0x01, // Export time
        0x00, 0x00, 0x00, 0x01, // Sequence
        0x00, 0x00, 0x00, 0x01, // Observation Domain ID
        // Template Set
        0x00, 0x02, // Set ID = 2 (template)
        0x00, 0x0C, // Length = 12
        0x01, 0x00, // Template ID = 256
        0x00, 0x01, // Field count = 1
        0x00, 0x01, // Field type = octetDeltaCount
        0x00, 0x04, // Field length = 4
    ];
    let len = template_packet.len() as u16;
    template_packet[2..4].copy_from_slice(&len.to_be_bytes());

    let mut parser = NetflowParser::builder()
        .with_max_records_per_flowset(3) // Only allow 3 records
        .build()
        .expect("Failed to build parser");

    let result = parser.parse_bytes(&template_packet);
    assert!(result.error.is_none(), "Template parse failed");

    // Data set with 6 records (6 * 4 = 24 bytes data)
    let mut data_packet = vec![
        0x00, 0x0A, // Version 10
        0x00, 0x00, // Length (will fill)
        0x00, 0x00, 0x00, 0x02, // Export time
        0x00, 0x00, 0x00, 0x02, // Sequence
        0x00, 0x00, 0x00, 0x01, // Observation Domain ID
        // Data Set
        0x01, 0x00, // Set ID = 256
        0x00, 0x1C, // Length = 28 (4 header + 24 data)
    ];
    for i in 0u32..6 {
        data_packet.extend_from_slice(&(i + 1).to_be_bytes());
    }
    let len = data_packet.len() as u16;
    data_packet[2..4].copy_from_slice(&len.to_be_bytes());

    let result = parser.parse_bytes(&data_packet);
    assert!(
        result.error.is_none(),
        "Data parse failed: {:?}",
        result.error
    );

    if let Some(NetflowPacket::IPFix(ipfix)) = result.packets.first() {
        let data_flowset = ipfix.flowsets.iter().find(|fs| {
            matches!(
                fs.body,
                netflow_parser::variable_versions::ipfix::FlowSetBody::Data(_)
            )
        });
        assert!(data_flowset.is_some(), "Expected data flowset");
        if let netflow_parser::variable_versions::ipfix::FlowSetBody::Data(data) =
            &data_flowset.unwrap().body
        {
            assert_eq!(
                data.fields.len(),
                3,
                "Expected 3 records (limited by max_records_per_flowset), got {}",
                data.fields.len()
            );
        }
    } else {
        panic!("Expected IPFIX packet");
    }
}

/// Test that max_records_per_flowset of 0 is rejected
#[test]
fn test_zero_max_records_per_flowset_rejected() {
    let result = NetflowParser::builder()
        .with_max_records_per_flowset(0)
        .build();
    assert!(result.is_err(), "Should reject max_records_per_flowset = 0");
}

// ── V5 edge-case tests ─────────────────────────────────────────────────

/// Build a minimal V5 packet with a given flow count header and actual flow data.
fn build_v5_packet(count: u16, actual_flows: u16) -> Vec<u8> {
    let mut packet = vec![
        0x00, 0x05, // Version 5
    ];
    packet.extend_from_slice(&count.to_be_bytes()); // Count
    packet.extend_from_slice(&[0x00, 0x00, 0x00, 0x01]); // SysUptime
    packet.extend_from_slice(&[0x00, 0x00, 0x00, 0x01]); // Unix seconds
    packet.extend_from_slice(&[0x00, 0x00, 0x00, 0x00]); // Unix nsecs
    packet.extend_from_slice(&[0x00, 0x00, 0x00, 0x01]); // Flow sequence
    packet.push(0x00); // Engine type
    packet.push(0x00); // Engine id
    packet.extend_from_slice(&[0x00, 0x00]); // Sampling interval
    // Each V5 flow is 48 bytes
    for i in 0..actual_flows {
        let mut flow = [0u8; 48];
        // Put some distinguishing data: src_addr = 10.0.0.i
        flow[0] = 10;
        flow[3] = (i & 0xFF) as u8;
        // protocol = TCP (6)
        flow[38] = 6;
        packet.extend_from_slice(&flow);
    }
    packet
}

/// V5 with count=0 must be rejected
#[test]
fn test_v5_count_zero_rejected() {
    let mut parser = NetflowParser::default();
    let packet = build_v5_packet(0, 0);
    let result = parser.parse_bytes(&packet);
    assert!(
        result.error.is_some(),
        "V5 with count=0 must produce an error"
    );
}

/// V5 with count > 30 (MAX_FLOWS) must be rejected
#[test]
fn test_v5_count_exceeds_max_flows() {
    let mut parser = NetflowParser::default();
    let packet = build_v5_packet(31, 31);
    let result = parser.parse_bytes(&packet);
    assert!(
        result.error.is_some(),
        "V5 with count=31 (>30) must produce an error"
    );
}

/// V5 at the maximum flow count (30) must succeed
#[test]
fn test_v5_max_flow_count_succeeds() {
    let mut parser = NetflowParser::default();
    let packet = build_v5_packet(30, 30);
    let result = parser.parse_bytes(&packet);
    assert!(
        result.error.is_none(),
        "V5 with count=30 should parse successfully: {:?}",
        result.error
    );
    assert_eq!(result.packets.len(), 1);
    if let NetflowPacket::V5(v5) = &result.packets[0] {
        assert_eq!(v5.flowsets.len(), 30, "Should have 30 flowsets");
    } else {
        panic!("Expected V5 packet");
    }
}

/// V5 with truncated flow data (count says 2, only 1 flow of data)
#[test]
fn test_v5_truncated_flow_data() {
    let mut parser = NetflowParser::default();
    let packet = build_v5_packet(2, 1); // Claims 2 flows, only has 1
    let result = parser.parse_bytes(&packet);
    assert!(
        result.error.is_some(),
        "V5 with truncated flow data must produce an error"
    );
}

/// V5 with a single valid flow
#[test]
fn test_v5_single_flow() {
    let mut parser = NetflowParser::default();
    let packet = build_v5_packet(1, 1);
    let result = parser.parse_bytes(&packet);
    assert!(
        result.error.is_none(),
        "V5 with 1 flow should succeed: {:?}",
        result.error
    );
    assert_eq!(result.packets.len(), 1);
    if let NetflowPacket::V5(v5) = &result.packets[0] {
        assert_eq!(v5.flowsets.len(), 1);
        assert_eq!(
            v5.flowsets[0].src_addr,
            std::net::Ipv4Addr::new(10, 0, 0, 0)
        );
        assert_eq!(v5.flowsets[0].protocol_number, 6);
    } else {
        panic!("Expected V5 packet");
    }
}

// ── V7 edge-case tests ─────────────────────────────────────────────────

/// Build a minimal V7 packet with a given flow count header and actual flow data.
fn build_v7_packet(count: u16, actual_flows: u16) -> Vec<u8> {
    let mut packet = vec![
        0x00, 0x07, // Version 7
    ];
    packet.extend_from_slice(&count.to_be_bytes()); // Count
    packet.extend_from_slice(&[0x00, 0x00, 0x00, 0x01]); // SysUptime
    packet.extend_from_slice(&[0x00, 0x00, 0x00, 0x01]); // Unix seconds
    packet.extend_from_slice(&[0x00, 0x00, 0x00, 0x00]); // Unix nsecs
    packet.extend_from_slice(&[0x00, 0x00, 0x00, 0x01]); // Flow sequence
    packet.extend_from_slice(&[0x00, 0x00, 0x00, 0x00]); // Reserved
    // Each V7 flow is 52 bytes
    for i in 0..actual_flows {
        let mut flow = [0u8; 52];
        // src_addr = 192.168.0.i
        flow[0] = 192;
        flow[1] = 168;
        flow[3] = (i & 0xFF) as u8;
        // protocol = UDP (17)
        flow[38] = 17;
        // router_src = 10.0.0.1
        flow[48] = 10;
        flow[51] = 1;
        packet.extend_from_slice(&flow);
    }
    packet
}

/// V7 with count=0 must be rejected
#[test]
fn test_v7_count_zero_rejected() {
    let mut parser = NetflowParser::default();
    let packet = build_v7_packet(0, 0);
    let result = parser.parse_bytes(&packet);
    assert!(
        result.error.is_some(),
        "V7 with count=0 must produce an error"
    );
}

/// V7 with count > 28 (MAX_FLOWS) must be rejected
#[test]
fn test_v7_count_exceeds_max_flows() {
    let mut parser = NetflowParser::default();
    let packet = build_v7_packet(29, 29);
    let result = parser.parse_bytes(&packet);
    assert!(
        result.error.is_some(),
        "V7 with count=29 (>28) must produce an error"
    );
}

/// V7 at the maximum flow count (28) must succeed
#[test]
fn test_v7_max_flow_count_succeeds() {
    let mut parser = NetflowParser::default();
    let packet = build_v7_packet(28, 28);
    let result = parser.parse_bytes(&packet);
    assert!(
        result.error.is_none(),
        "V7 with count=28 should parse successfully: {:?}",
        result.error
    );
    assert_eq!(result.packets.len(), 1);
    if let NetflowPacket::V7(v7) = &result.packets[0] {
        assert_eq!(v7.flowsets.len(), 28, "Should have 28 flowsets");
    } else {
        panic!("Expected V7 packet");
    }
}

/// V7 with truncated flow data (count says 3, only 2 flows of data)
#[test]
fn test_v7_truncated_flow_data() {
    let mut parser = NetflowParser::default();
    let packet = build_v7_packet(3, 2); // Claims 3 flows, only has 2
    let result = parser.parse_bytes(&packet);
    assert!(
        result.error.is_some(),
        "V7 with truncated flow data must produce an error"
    );
}

/// V7 with a single valid flow verifies field extraction
#[test]
fn test_v7_single_flow_field_extraction() {
    let mut parser = NetflowParser::default();
    let packet = build_v7_packet(1, 1);
    let result = parser.parse_bytes(&packet);
    assert!(
        result.error.is_none(),
        "V7 with 1 flow should succeed: {:?}",
        result.error
    );
    assert_eq!(result.packets.len(), 1);
    if let NetflowPacket::V7(v7) = &result.packets[0] {
        assert_eq!(v7.flowsets.len(), 1);
        assert_eq!(
            v7.flowsets[0].src_addr,
            std::net::Ipv4Addr::new(192, 168, 0, 0)
        );
        assert_eq!(v7.flowsets[0].protocol_number, 17);
        assert_eq!(
            v7.flowsets[0].router_src,
            std::net::Ipv4Addr::new(10, 0, 0, 1)
        );
    } else {
        panic!("Expected V7 packet");
    }
}

/// V5 header too short (less than 22 bytes after version)
#[test]
fn test_v5_header_too_short() {
    let mut parser = NetflowParser::default();
    // Version + only 10 bytes of header (need 22)
    let packet = vec![
        0x00, 0x05, // Version 5
        0x00, 0x01, // Count = 1
        0x00, 0x00, 0x00, 0x01, // SysUptime
        0x00, 0x00, 0x00, 0x01, // Unix seconds (only 10 bytes total, need 22)
    ];
    let result = parser.parse_bytes(&packet);
    assert!(
        result.error.is_some(),
        "V5 with truncated header must produce an error"
    );
}

/// V7 header too short (less than 22 bytes after version)
#[test]
fn test_v7_header_too_short() {
    let mut parser = NetflowParser::default();
    let packet = vec![
        0x00, 0x07, // Version 7
        0x00, 0x01, // Count = 1
        0x00, 0x00, 0x00, 0x01, // SysUptime
        0x00, 0x00, 0x00, 0x01, // Unix seconds (only 10 bytes total, need 22)
    ];
    let result = parser.parse_bytes(&packet);
    assert!(
        result.error.is_some(),
        "V7 with truncated header must produce an error"
    );
}
