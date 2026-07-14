//! Tests for parser builder configuration: cache size, TTL, field count limits,
//! version filtering, and comprehensive builder chaining.

use netflow_parser::NetflowParser;
use netflow_parser::variable_versions::ttl::TtlConfig;
use std::time::Duration;

// Verify default parser allows versions 5, 7, 9, and 10 but not version 0
#[test]
fn test_default_parser_creation() {
    let parser = NetflowParser::default();
    // Default allows versions 5, 7, 9, 10
    assert!(parser.allowed_versions()[5]);
    assert!(parser.allowed_versions()[7]);
    assert!(parser.allowed_versions()[9]);
    assert!(parser.allowed_versions()[10]);
    assert!(!parser.allowed_versions()[0]);
}

// Verify builder sets the same cache size for both V9 and IPFIX caches
#[test]
fn test_parser_builder_with_cache_size() {
    let parser = NetflowParser::builder()
        .with_cache_size(2000)
        .build()
        .expect("Failed to build parser");

    let stats = parser.v9_cache_info();
    assert_eq!(stats.max_size_per_cache, 2000);

    let ipfix_info = parser.ipfix_cache_info();
    assert_eq!(ipfix_info.max_size_per_cache, 2000);
}

// Verify builder can set independent cache sizes for V9 and IPFIX
#[test]
fn test_parser_builder_with_different_cache_sizes() {
    let parser = NetflowParser::builder()
        .with_v9_cache_size(1000)
        .with_ipfix_cache_size(3000)
        .build()
        .expect("Failed to build parser");

    let v9_info = parser.v9_cache_info();
    assert_eq!(v9_info.max_size_per_cache, 1000);

    let ipfix_info = parser.ipfix_cache_info();
    assert_eq!(ipfix_info.max_size_per_cache, 3000);
}

// Verify builder accepts a TTL configuration and creates a valid parser
#[test]
fn test_parser_builder_with_ttl() {
    let parser = NetflowParser::builder()
        .with_ttl(TtlConfig::new(Duration::from_secs(3600)))
        .build()
        .expect("Failed to build parser");

    // Parser should be created successfully with default allowed versions
    assert!(parser.allowed_versions()[5]);
    assert!(parser.allowed_versions()[9]);
}

// Verify builder restricts allowed versions to only those specified
#[test]
fn test_parser_builder_with_allowed_versions() {
    let parser = NetflowParser::builder()
        .with_allowed_versions(&[5, 9])
        .build()
        .expect("Failed to build parser");

    assert!(parser.allowed_versions()[5]);
    assert!(parser.allowed_versions()[9]);
    assert!(!parser.allowed_versions()[7]);
}

// Verify builder sets the max error sample size on the parser
#[test]
fn test_parser_builder_with_max_error_sample_size() {
    let parser = NetflowParser::builder()
        .with_max_error_sample_size(512)
        .build()
        .expect("Failed to build parser");

    assert_eq!(parser.max_error_sample_size(), 512);
}

// Verify builder with max field count rejects templates exceeding the limit
#[test]
fn test_parser_builder_with_field_count_limits() {
    // Build a parser with a very restrictive field count limit
    let mut parser = NetflowParser::builder()
        .with_max_field_count(2)
        .build()
        .expect("Failed to build parser");

    // V9 template with 3 fields (exceeds limit of 2)
    #[rustfmt::skip]
    let v9_3field_template: Vec<u8> = vec![
        0x00, 0x09,             // version 9
        0x00, 0x01,             // count: 1 flowset
        0x00, 0x00, 0x00, 0x01, // sys_up_time
        0x00, 0x00, 0x00, 0x01, // unix_secs
        0x00, 0x00, 0x00, 0x01, // sequence
        0x00, 0x00, 0x00, 0x01, // source_id
        // Template flowset
        0x00, 0x00,             // flowset_id = 0 (template)
        0x00, 0x14,             // length = 20
        0x01, 0x00,             // template_id = 256
        0x00, 0x03,             // field_count = 3 (exceeds limit)
        0x00, 0x08, 0x00, 0x04, // field: src_addr (4 bytes)
        0x00, 0x0c, 0x00, 0x04, // field: dst_addr (4 bytes)
        0x00, 0x07, 0x00, 0x02, // field: src_port (2 bytes)
    ];

    let _result = parser.parse_bytes(&v9_3field_template);
    // Template should be rejected — parser should not have it cached
    assert!(
        !parser.has_v9_template(256),
        "Template with 3 fields should be rejected when max_field_count=2"
    );

    // V9 template with 2 fields (within limit) should be accepted
    #[rustfmt::skip]
    let v9_2field_template: Vec<u8> = vec![
        0x00, 0x09,             // version 9
        0x00, 0x01,             // count: 1 flowset
        0x00, 0x00, 0x00, 0x02, // sys_up_time
        0x00, 0x00, 0x00, 0x02, // unix_secs
        0x00, 0x00, 0x00, 0x02, // sequence
        0x00, 0x00, 0x00, 0x01, // source_id
        // Template flowset
        0x00, 0x00,             // flowset_id = 0 (template)
        0x00, 0x10,             // length = 16
        0x01, 0x01,             // template_id = 257
        0x00, 0x02,             // field_count = 2 (within limit)
        0x00, 0x08, 0x00, 0x04, // field: src_addr (4 bytes)
        0x00, 0x0c, 0x00, 0x04, // field: dst_addr (4 bytes)
    ];

    let result = parser.parse_bytes(&v9_2field_template);
    assert!(
        parser.has_v9_template(257),
        "Template with 2 fields should be accepted when max_field_count=2"
    );
    drop(result);
}

// Verify builder chains all options together and produces correct configuration.
// TTL and field count limits are verified functionally in dedicated tests
// (test_parser_builder_with_field_count_limits, ttl tests).
#[test]
fn test_parser_builder_comprehensive() {
    let mut parser = NetflowParser::builder()
        .with_v9_cache_size(1500)
        .with_ipfix_cache_size(2500)
        .with_v9_ttl(TtlConfig::new(Duration::from_secs(1800)))
        .with_ipfix_ttl(TtlConfig::new(Duration::from_secs(3600)))
        .with_allowed_versions(&[5, 9, 10])
        .with_max_error_sample_size(512)
        .with_v9_max_field_count(2)
        .with_ipfix_max_field_count(10000)
        .build()
        .expect("Failed to build parser");

    let v9_info = parser.v9_cache_info();
    assert_eq!(v9_info.max_size_per_cache, 1500);

    let ipfix_info = parser.ipfix_cache_info();
    assert_eq!(ipfix_info.max_size_per_cache, 2500);

    assert!(parser.allowed_versions()[5]);
    assert!(parser.allowed_versions()[9]);
    assert!(parser.allowed_versions()[10]);

    assert_eq!(parser.max_error_sample_size(), 512);

    // Verify V9 field count limit is effective: 3-field template should be rejected
    #[rustfmt::skip]
    let v9_3field_template: Vec<u8> = vec![
        0x00, 0x09,             // version 9
        0x00, 0x01,             // count
        0x00, 0x00, 0x00, 0x01, // sys_up_time
        0x00, 0x00, 0x00, 0x01, // unix_secs
        0x00, 0x00, 0x00, 0x01, // sequence
        0x00, 0x00, 0x00, 0x01, // source_id
        // Template flowset
        0x00, 0x00,             // flowset_id = 0
        0x00, 0x14,             // length = 20
        0x01, 0x00,             // template_id = 256
        0x00, 0x03,             // field_count = 3 (exceeds v9 limit of 2)
        0x00, 0x08, 0x00, 0x04,
        0x00, 0x0c, 0x00, 0x04,
        0x00, 0x07, 0x00, 0x02,
    ];
    let result = parser.parse_bytes(&v9_3field_template);
    assert!(
        !parser.has_v9_template(256),
        "V9 field count limit should reject 3-field template when max=2"
    );
    drop(result);
}
