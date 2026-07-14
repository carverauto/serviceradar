//! Tests for concurrent parsing: shared parser behind Arc<Mutex<>> and
//! independent per-thread parsers.

use netflow_parser::{NetflowParser, RouterScopedParser};
use std::sync::{Arc, Mutex};
use std::thread;

/// A valid V5 packet for testing.
const V5_PACKET: [u8; 72] = [
    0, 5, 0, 1, 3, 0, 4, 0, 5, 0, 6, 7, 8, 9, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 0, 1, 2, 3, 4, 5,
    6, 7, 8, 9, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 0, 1, 2, 3, 4, 5,
    6, 7, 8, 9, 0, 1, 2, 3, 4, 5, 6, 7,
];

/// Verify that a RouterScopedParser behind Arc<Mutex<>> can be shared across threads.
#[test]
fn test_shared_scoped_parser_across_threads() {
    let parser = Arc::new(Mutex::new(RouterScopedParser::<String>::new()));

    let mut handles = Vec::new();
    for i in 0..4 {
        let parser = Arc::clone(&parser);
        handles.push(thread::spawn(move || {
            let source = format!("router-{}", i);
            for _ in 0..10 {
                let mut p = parser.lock().unwrap();
                let packets = p.parse_from_source(source.clone(), &V5_PACKET).packets;
                assert_eq!(packets.len(), 1);
            }
        }));
    }

    for h in handles {
        h.join().expect("thread panicked");
    }

    let p = parser.lock().unwrap();
    assert_eq!(p.source_count(), 4);
}

/// Verify that independent NetflowParser instances work correctly in parallel threads.
#[test]
fn test_independent_parsers_per_thread() {
    let mut handles = Vec::new();
    for _ in 0..4 {
        handles.push(thread::spawn(|| {
            let mut parser = NetflowParser::default();
            for _ in 0..20 {
                let result = parser.parse_bytes(&V5_PACKET);
                assert!(result.is_ok());
                assert_eq!(result.packets.len(), 1);
            }
        }));
    }

    for h in handles {
        h.join().expect("thread panicked");
    }
}

/// Verify concurrent V9 template caching and data parsing through a shared parser.
/// Each thread registers a unique template ID, then parses data against it.
#[test]
fn test_shared_parser_concurrent_v9_templates() {
    let parser = Arc::new(Mutex::new(NetflowParser::default()));

    let mut handles = Vec::new();
    for i in 0u16..4 {
        let parser = Arc::clone(&parser);
        handles.push(thread::spawn(move || {
            let template_id = 256 + i;
            let tid_bytes = template_id.to_be_bytes();

            // V9 template packet: template_id with 1 field (IN_BYTES=1, len=4)
            let template_packet: Vec<u8> = vec![
                0,
                9,
                0,
                1, // version=9, count=1
                0,
                0,
                0,
                0, // sys_up_time
                0,
                0,
                0,
                0, // unix_secs
                0,
                0,
                0,
                (i + 1) as u8, // sequence
                0,
                0,
                0,
                1, // source_id
                0,
                0, // flowset_id=0 (template)
                0,
                12, // length=12
                tid_bytes[0],
                tid_bytes[1], // template_id
                0,
                1, // field_count=1
                0,
                1, // field_type=IN_BYTES
                0,
                4, // field_length=4
            ];

            // V9 data packet using this template
            let data_packet: Vec<u8> = vec![
                0,
                9,
                0,
                1, // version=9, count=1
                0,
                0,
                0,
                0, // sys_up_time
                0,
                0,
                0,
                0, // unix_secs
                0,
                0,
                0,
                (i + 10) as u8, // sequence
                0,
                0,
                0,
                1, // source_id
                tid_bytes[0],
                tid_bytes[1], // flowset_id = template_id
                0,
                8, // length = 8 (4 header + 4 data)
                0,
                0,
                0,
                (i + 1) as u8, // IN_BYTES value
            ];

            // Register template
            {
                let mut p = parser.lock().unwrap();
                let result = p.parse_bytes(&template_packet);
                assert_eq!(
                    result.packets.len(),
                    1,
                    "Template parse should produce 1 packet"
                );
            }

            // Parse data (separate lock acquisition to allow interleaving)
            {
                let mut p = parser.lock().unwrap();
                let result = p.parse_bytes(&data_packet);
                assert_eq!(
                    result.packets.len(),
                    1,
                    "Data parse should produce 1 packet"
                );
                assert!(result.error.is_none(), "Data parse should not error");
            }
        }));
    }

    for h in handles {
        h.join().expect("thread panicked");
    }

    // Verify all 4 templates were cached
    let p = parser.lock().unwrap();
    for i in 0u16..4 {
        assert!(
            p.has_v9_template(256 + i),
            "Template {} should be cached",
            256 + i
        );
    }
}
