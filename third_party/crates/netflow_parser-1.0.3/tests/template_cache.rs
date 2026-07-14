//! Tests for template cache behavior: custom sizes, metrics tracking,
//! template ID listing, and cache clearing.

use netflow_parser::NetflowParser;

// Verify that clearing V9 and IPFIX templates removes previously cached templates
#[test]
fn test_clear_templates() {
    let mut parser = NetflowParser::default();

    // Insert a V9 template so the cache is non-empty
    let v9_template_packet: Vec<u8> = vec![
        0, 9, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, // Template flowset
        0, 0, 0, 12, 1, 0, // template_id = 256
        0, 1, // field_count = 1
        0, 1, 0, 4, // field: IN_BYTES(1), length 4
    ];
    assert!(
        !parser.parse_bytes(&v9_template_packet).packets.is_empty(),
        "Template packet should parse successfully"
    );

    let v9_info = parser.v9_cache_info();
    assert!(
        v9_info.current_size > 0,
        "V9 cache should have a template before clearing"
    );

    parser.clear_v9_templates();

    let v9_info = parser.v9_cache_info();
    assert_eq!(
        v9_info.current_size, 0,
        "V9 cache should be empty after clearing"
    );

    parser.clear_ipfix_templates();

    let ipfix_info = parser.ipfix_cache_info();
    assert_eq!(ipfix_info.current_size, 0);
}

// Verify that with_cache_size sets the same max size for both V9 and IPFIX caches
#[test]
fn test_custom_cache_size() {
    let parser = NetflowParser::builder()
        .with_cache_size(500)
        .build()
        .expect("Failed to build parser");

    let v9_info = parser.v9_cache_info();
    assert_eq!(v9_info.max_size_per_cache, 500);

    let ipfix_info = parser.ipfix_cache_info();
    assert_eq!(ipfix_info.max_size_per_cache, 500);
}

// Verify that V9 and IPFIX cache sizes can be configured independently
#[test]
fn test_different_cache_sizes() {
    let parser = NetflowParser::builder()
        .with_v9_cache_size(750)
        .with_ipfix_cache_size(1500)
        .build()
        .expect("Failed to build parser");

    let v9_info = parser.v9_cache_info();
    assert_eq!(v9_info.max_size_per_cache, 750);

    let ipfix_info = parser.ipfix_cache_info();
    assert_eq!(ipfix_info.max_size_per_cache, 1500);
}

// Verify that template_ids() returns cached template IDs after parsing a template
#[test]
fn test_template_ids_after_parsing() {
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

    let v9_templates = parser.v9_template_ids();
    assert!(
        v9_templates.contains(&256),
        "V9 template IDs should include 256 after parsing template"
    );
    assert!(
        parser.has_v9_template(256),
        "has_v9_template(256) should return true after caching"
    );
}

// Verify that hit_rate returns a meaningful value after hits and misses
#[test]
fn test_hit_rate_after_activity() {
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

    // V9 data packet using template 256 (should hit)
    let v9_data_packet: Vec<u8> = vec![
        0, 9, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2, 0, 0, 0, 0, 1,
        0, // flowset_id = 256
        0, 8, // length = 8
        0, 0, 0, 42, // IN_BYTES = 42
    ];
    let result = parser.parse_bytes(&v9_data_packet);
    assert!(
        result.error.is_none(),
        "Data packet parse should succeed after template is cached"
    );

    let stats = parser.v9_cache_info();
    let hit_rate = stats.metrics.hit_rate();
    assert!(
        hit_rate.is_some(),
        "hit_rate should return Some after cache activity"
    );
    assert_eq!(
        hit_rate.unwrap(),
        1.0,
        "hit_rate should be 1.0 after 1 hit and 0 misses"
    );
}

// ---------------------------------------------------------------------------
// IPFIX template withdrawal tests (RFC 7011 §8.1)
// ---------------------------------------------------------------------------

/// Helper: build an IPFIX packet with a template set containing a single template.
fn ipfix_template_packet(template_id: u16, fields: &[(u16, u16)]) -> Vec<u8> {
    // Template record: template_id(2) + field_count(2) + fields(4 each)
    let template_record_len = 4 + fields.len() * 4;
    // Set: set_id(2) + set_length(2) + template record
    let set_len = (4 + template_record_len) as u16;
    // Message: header(16) + set
    let msg_len = 16 + set_len;

    let mut pkt = Vec::with_capacity(msg_len as usize);
    pkt.extend_from_slice(&0x000Au16.to_be_bytes()); // Version 10
    pkt.extend_from_slice(&msg_len.to_be_bytes());
    pkt.extend_from_slice(&1u32.to_be_bytes()); // Export Time
    pkt.extend_from_slice(&1u32.to_be_bytes()); // Sequence
    pkt.extend_from_slice(&1u32.to_be_bytes()); // Observation Domain
    pkt.extend_from_slice(&2u16.to_be_bytes()); // Set ID = 2 (template)
    pkt.extend_from_slice(&set_len.to_be_bytes());
    pkt.extend_from_slice(&template_id.to_be_bytes());
    pkt.extend_from_slice(&(fields.len() as u16).to_be_bytes());
    for &(field_type, field_length) in fields {
        pkt.extend_from_slice(&field_type.to_be_bytes());
        pkt.extend_from_slice(&field_length.to_be_bytes());
    }
    pkt
}

/// Helper: build an IPFIX withdrawal packet (template with field_count=0).
fn ipfix_withdrawal_packet(template_id: u16) -> Vec<u8> {
    let set_len: u16 = 8; // set header(4) + template_id(2) + field_count=0(2)
    let msg_len: u16 = 16 + set_len;

    let mut pkt = Vec::with_capacity(msg_len as usize);
    pkt.extend_from_slice(&0x000Au16.to_be_bytes());
    pkt.extend_from_slice(&msg_len.to_be_bytes());
    pkt.extend_from_slice(&1u32.to_be_bytes());
    pkt.extend_from_slice(&2u32.to_be_bytes()); // different sequence
    pkt.extend_from_slice(&1u32.to_be_bytes());
    pkt.extend_from_slice(&2u16.to_be_bytes()); // Set ID = 2 (template)
    pkt.extend_from_slice(&set_len.to_be_bytes());
    pkt.extend_from_slice(&template_id.to_be_bytes());
    pkt.extend_from_slice(&0u16.to_be_bytes()); // field_count = 0 (withdrawal)
    pkt
}

/// Helper: build an IPFIX options template withdrawal packet (field_count=0 in set ID 3).
fn ipfix_options_withdrawal_packet(template_id: u16) -> Vec<u8> {
    // Options template withdrawal: template_id(2) + field_count=0(2) + scope_field_count=0(2)
    let set_len: u16 = 10; // set header(4) + template_id(2) + field_count(2) + scope_count(2)
    let msg_len: u16 = 16 + set_len;

    let mut pkt = Vec::with_capacity(msg_len as usize);
    pkt.extend_from_slice(&0x000Au16.to_be_bytes());
    pkt.extend_from_slice(&msg_len.to_be_bytes());
    pkt.extend_from_slice(&1u32.to_be_bytes());
    pkt.extend_from_slice(&2u32.to_be_bytes());
    pkt.extend_from_slice(&1u32.to_be_bytes());
    pkt.extend_from_slice(&3u16.to_be_bytes()); // Set ID = 3 (options template)
    pkt.extend_from_slice(&set_len.to_be_bytes());
    pkt.extend_from_slice(&template_id.to_be_bytes());
    pkt.extend_from_slice(&0u16.to_be_bytes()); // field_count = 0 (withdrawal)
    pkt.extend_from_slice(&0u16.to_be_bytes()); // scope_field_count = 0
    pkt
}

/// Helper: build an IPFIX options template packet.
fn ipfix_options_template_pkt(template_id: u16) -> Vec<u8> {
    // Options template: scope(type=1,len=4) + option(type=3,len=4) + option(type=4,len=4)
    let set_len: u16 = 22; // set header(4) + tmpl header(6) + 3 fields(12)
    let msg_len: u16 = 16 + set_len;

    let mut pkt = Vec::with_capacity(msg_len as usize);
    pkt.extend_from_slice(&0x000Au16.to_be_bytes());
    pkt.extend_from_slice(&msg_len.to_be_bytes());
    pkt.extend_from_slice(&1u32.to_be_bytes());
    pkt.extend_from_slice(&1u32.to_be_bytes());
    pkt.extend_from_slice(&1u32.to_be_bytes());
    pkt.extend_from_slice(&3u16.to_be_bytes()); // Set ID = 3
    pkt.extend_from_slice(&set_len.to_be_bytes());
    pkt.extend_from_slice(&template_id.to_be_bytes());
    pkt.extend_from_slice(&3u16.to_be_bytes()); // field_count = 3
    pkt.extend_from_slice(&1u16.to_be_bytes()); // scope_field_count = 1
    // Scope field: type=1, length=4
    pkt.extend_from_slice(&1u16.to_be_bytes());
    pkt.extend_from_slice(&4u16.to_be_bytes());
    // Option field: type=3, length=4
    pkt.extend_from_slice(&3u16.to_be_bytes());
    pkt.extend_from_slice(&4u16.to_be_bytes());
    // Option field: type=4, length=4
    pkt.extend_from_slice(&4u16.to_be_bytes());
    pkt.extend_from_slice(&4u16.to_be_bytes());
    pkt
}

/// Individual IPFIX data template withdrawal removes that template.
#[test]
fn test_ipfix_individual_template_withdrawal() {
    let mut parser = NetflowParser::default();

    // Register two templates
    assert!(
        !parser
            .parse_bytes(&ipfix_template_packet(256, &[(1, 4)]))
            .packets
            .is_empty()
    );
    assert!(
        !parser
            .parse_bytes(&ipfix_template_packet(257, &[(2, 4)]))
            .packets
            .is_empty()
    );
    assert!(parser.has_ipfix_template(256));
    assert!(parser.has_ipfix_template(257));

    // Withdraw template 256 only
    assert!(
        !parser
            .parse_bytes(&ipfix_withdrawal_packet(256))
            .packets
            .is_empty()
    );
    assert!(
        !parser.has_ipfix_template(256),
        "Template 256 should be withdrawn"
    );
    assert!(parser.has_ipfix_template(257), "Template 257 should remain");
}

/// IPFIX "withdraw all data templates" (template_id=2, field_count=0) clears
/// all data templates per RFC 7011 §8.1.
#[test]
fn test_ipfix_withdraw_all_data_templates() {
    let mut parser = NetflowParser::default();

    // Register 3 data templates
    assert!(
        !parser
            .parse_bytes(&ipfix_template_packet(256, &[(1, 4)]))
            .packets
            .is_empty()
    );
    assert!(
        !parser
            .parse_bytes(&ipfix_template_packet(257, &[(2, 4)]))
            .packets
            .is_empty()
    );
    assert!(
        !parser
            .parse_bytes(&ipfix_template_packet(258, &[(3, 4)]))
            .packets
            .is_empty()
    );
    assert_eq!(parser.ipfix_cache_info().current_size, 3);

    // Also register an options template — should NOT be affected
    assert!(
        !parser
            .parse_bytes(&ipfix_options_template_pkt(259))
            .packets
            .is_empty()
    );
    assert_eq!(parser.ipfix_cache_info().current_size, 4);

    // Withdraw all data templates (template_id=2, field_count=0)
    assert!(
        !parser
            .parse_bytes(&ipfix_withdrawal_packet(2))
            .packets
            .is_empty()
    );

    // All 3 data templates should be gone, options template should remain
    assert!(!parser.has_ipfix_template(256));
    assert!(!parser.has_ipfix_template(257));
    assert!(!parser.has_ipfix_template(258));
    assert_eq!(
        parser.ipfix_cache_info().current_size,
        1,
        "Only the options template should remain after withdraw-all data"
    );
}

/// IPFIX "withdraw all options templates" (template_id=3, field_count=0) clears
/// all options templates per RFC 7011 §8.1.
#[test]
fn test_ipfix_withdraw_all_options_templates() {
    let mut parser = NetflowParser::default();

    // Register a data template — should NOT be affected
    assert!(
        !parser
            .parse_bytes(&ipfix_template_packet(256, &[(1, 4)]))
            .packets
            .is_empty()
    );

    // Register 2 options templates
    assert!(
        !parser
            .parse_bytes(&ipfix_options_template_pkt(258))
            .packets
            .is_empty()
    );
    assert!(
        !parser
            .parse_bytes(&ipfix_options_template_pkt(259))
            .packets
            .is_empty()
    );
    assert_eq!(parser.ipfix_cache_info().current_size, 3);

    // Withdraw all options templates (template_id=3, field_count=0)
    assert!(
        !parser
            .parse_bytes(&ipfix_options_withdrawal_packet(3))
            .packets
            .is_empty()
    );

    // Options templates should be gone, data template should remain
    assert!(
        parser.has_ipfix_template(256),
        "Data template should survive options withdraw-all"
    );
    assert_eq!(
        parser.ipfix_cache_info().current_size,
        1,
        "Only the data template should remain after withdraw-all options"
    );
}

/// IPFIX withdraw-all with pending flows drains them and records metrics.
#[test]
fn test_ipfix_withdraw_all_drains_pending_flows() {
    use netflow_parser::variable_versions::PendingFlowsConfig;

    let mut parser = NetflowParser::builder()
        .with_ipfix_pending_flows(PendingFlowsConfig::default())
        .build()
        .expect("valid config");

    // Cache a pending flow for template 256 (no template registered yet)
    let data_pkt = vec![
        0x00, 0x0A, 0x00, 0x18, 0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00, 0x02, 0x00, 0x00,
        0x00, 0x01, 0x01, 0x00, // Set ID = 256
        0x00, 0x08, // Set Length = 8
        0x00, 0x00, 0x00, 0x42,
    ];
    let _ = parser.parse_bytes(&data_pkt); // intentional: data without template → pending
    assert_eq!(parser.ipfix_cache_info().pending_flow_count, 1);

    // Register the template so it's in the cache
    assert!(
        !parser
            .parse_bytes(&ipfix_template_packet(256, &[(1, 4)]))
            .packets
            .is_empty()
    );
    // Pending flow was replayed
    assert_eq!(parser.ipfix_cache_info().pending_flow_count, 0);
    assert_eq!(parser.ipfix_cache_info().metrics.pending_replayed, 1);

    // Cache another pending flow for a different template (257, not registered)
    let mut data_257 = data_pkt.clone();
    data_257[16] = 0x01;
    data_257[17] = 0x01; // Set ID = 257
    let _ = parser.parse_bytes(&data_257); // intentional: data without template → pending
    assert_eq!(parser.ipfix_cache_info().pending_flow_count, 1);

    // Withdraw all data templates — should also drain pending flows for 256
    // (template 257 pending flow stays because it was never in the template cache)
    assert!(
        !parser
            .parse_bytes(&ipfix_withdrawal_packet(2))
            .packets
            .is_empty()
    );
    assert!(!parser.has_ipfix_template(256));

    // The pending flow for 257 should still be there (257 was never a data template)
    // The withdraw-all only drains pending flows for IDs that were IN the template cache
    assert_eq!(
        parser.ipfix_cache_info().metrics.pending_dropped,
        0,
        "No pending flows should be dropped (257 was not in template cache)"
    );
    assert_eq!(
        parser.ipfix_cache_info().pending_flow_count,
        1,
        "Pending flow for template 257 should still be cached"
    );
}
