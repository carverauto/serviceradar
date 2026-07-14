//! Tests for memory bounds: cache stats stay within configured limits and
//! error sample size is bounded.

use netflow_parser::NetflowParser;

/// Verify that V9 template cache stays within configured bounds when many
/// distinct templates are inserted.
#[test]
fn test_cache_info_stay_within_bounds() {
    let max_cache = 3;
    let mut parser = NetflowParser::builder()
        .with_cache_size(max_cache)
        .build()
        .expect("valid config");

    // Build V9 packets with distinct template IDs to actually fill the cache.
    // V9 template flowset: header(20) + flowset_header(4) + template(8) = 32 bytes
    for template_id in 256u16..266 {
        let tid = template_id.to_be_bytes();
        let v9_template_packet: Vec<u8> = vec![
            0, 9, // version
            0, 1, // count
            0, 0, 0, 0, // sys_uptime
            0, 0, 0, 0, // unix_secs
            0, 0, 0, 1, // sequence
            0, 0, 0, 0, // source_id
            // Template flowset
            0, 0, // flowset_id = 0 (template)
            0,
            12, // length = 12 (header(4) + template_id(2) + field_count(2) + 1 field(4))
            tid[0], tid[1], // template_id
            0, 1, // field_count = 1
            0, 1, // field_type = IN_BYTES
            0, 4, // field_length = 4
        ];
        assert!(
            !parser.parse_bytes(&v9_template_packet).packets.is_empty(),
            "Template packet for tid {} should parse successfully",
            template_id
        );
    }

    let v9_info = parser.v9_cache_info();
    assert_eq!(
        v9_info.current_size, max_cache,
        "V9 cache should be full at max capacity {}, got {}",
        max_cache, v9_info.current_size
    );
}

/// Verify that error samples respect the configured max_error_sample_size.
#[test]
fn test_error_sample_size_bounded() {
    let max_sample = 32;
    let mut parser = NetflowParser::builder()
        .with_max_error_sample_size(max_sample)
        .build()
        .expect("valid config");

    assert_eq!(parser.max_error_sample_size(), max_sample);

    // Feed garbage that triggers UnsupportedVersion error with a sample
    let garbage = vec![0xFFu8; 256];
    let result = parser.parse_bytes(&garbage);

    match result.error {
        Some(netflow_parser::NetflowError::UnsupportedVersion { sample, .. }) => {
            assert!(
                sample.len() <= max_sample,
                "error sample {} bytes exceeds max {}",
                sample.len(),
                max_sample
            );
        }
        other => panic!("expected UnsupportedVersion error, got {:?}", other),
    }
}

/// Verify that default max_error_sample_size is 256.
#[test]
fn test_default_error_sample_size() {
    let parser = NetflowParser::default();
    assert_eq!(parser.max_error_sample_size(), 256);
}
