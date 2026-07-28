//! Integration tests for the [`TemplateStore`] extension point.
//!
//! These tests exercise the read-through / write-through protocol end-to-end
//! against real V9 and IPFIX template + data packets.

use netflow_parser::{
    AutoScopedParser, InMemoryTemplateStore, NetflowPacket, NetflowParser, TemplateEvent,
    TemplateKind, TemplateProtocol, TemplateStore, TemplateStoreError, TemplateStoreKey,
};
use std::net::SocketAddr;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};

// ---------------------------------------------------------------------------
// Packet builders (mirroring those in tests/template_cache.rs)
// ---------------------------------------------------------------------------

/// Build a V9 packet with a single template flowset.
/// `template_id` is the announced ID; `fields` is `(field_type, length)`.
fn v9_template_packet(template_id: u16, fields: &[(u16, u16)]) -> Vec<u8> {
    let template_record_len = 4 + fields.len() * 4;
    let flowset_len = 4 + template_record_len; // set header + record
    let mut pkt = Vec::new();
    // V9 header
    pkt.extend_from_slice(&9u16.to_be_bytes()); // version
    pkt.extend_from_slice(&1u16.to_be_bytes()); // count
    pkt.extend_from_slice(&0u32.to_be_bytes()); // sys_up_time
    pkt.extend_from_slice(&0u32.to_be_bytes()); // unix_secs
    pkt.extend_from_slice(&0u32.to_be_bytes()); // sequence
    pkt.extend_from_slice(&0u32.to_be_bytes()); // source_id
    // Template flowset
    pkt.extend_from_slice(&0u16.to_be_bytes()); // flowset_id = 0 (template)
    pkt.extend_from_slice(&(flowset_len as u16).to_be_bytes());
    pkt.extend_from_slice(&template_id.to_be_bytes());
    pkt.extend_from_slice(&(fields.len() as u16).to_be_bytes());
    for &(ft, fl) in fields {
        pkt.extend_from_slice(&ft.to_be_bytes());
        pkt.extend_from_slice(&fl.to_be_bytes());
    }
    pkt
}

/// Build a V9 data packet that references `template_id`. `payload` is the
/// raw record bytes that the template will decode against.
fn v9_data_packet(template_id: u16, payload: &[u8]) -> Vec<u8> {
    let flowset_len = 4 + payload.len();
    let mut pkt = Vec::new();
    pkt.extend_from_slice(&9u16.to_be_bytes());
    pkt.extend_from_slice(&1u16.to_be_bytes());
    pkt.extend_from_slice(&0u32.to_be_bytes());
    pkt.extend_from_slice(&0u32.to_be_bytes());
    pkt.extend_from_slice(&0u32.to_be_bytes());
    pkt.extend_from_slice(&0u32.to_be_bytes());
    pkt.extend_from_slice(&template_id.to_be_bytes());
    pkt.extend_from_slice(&(flowset_len as u16).to_be_bytes());
    pkt.extend_from_slice(payload);
    pkt
}

/// Build an IPFIX packet with a single template set.
fn ipfix_template_packet(template_id: u16, fields: &[(u16, u16)]) -> Vec<u8> {
    let template_record_len = 4 + fields.len() * 4;
    let set_len = (4 + template_record_len) as u16;
    let msg_len = 16 + set_len;
    let mut pkt = Vec::new();
    pkt.extend_from_slice(&0x000Au16.to_be_bytes());
    pkt.extend_from_slice(&msg_len.to_be_bytes());
    pkt.extend_from_slice(&1u32.to_be_bytes());
    pkt.extend_from_slice(&1u32.to_be_bytes());
    pkt.extend_from_slice(&1u32.to_be_bytes());
    pkt.extend_from_slice(&2u16.to_be_bytes());
    pkt.extend_from_slice(&set_len.to_be_bytes());
    pkt.extend_from_slice(&template_id.to_be_bytes());
    pkt.extend_from_slice(&(fields.len() as u16).to_be_bytes());
    for &(ft, fl) in fields {
        pkt.extend_from_slice(&ft.to_be_bytes());
        pkt.extend_from_slice(&fl.to_be_bytes());
    }
    pkt
}

/// Build an IPFIX data packet referencing `template_id`.
fn ipfix_data_packet(template_id: u16, payload: &[u8]) -> Vec<u8> {
    let set_len = (4 + payload.len()) as u16;
    let msg_len = 16 + set_len;
    let mut pkt = Vec::new();
    pkt.extend_from_slice(&0x000Au16.to_be_bytes());
    pkt.extend_from_slice(&msg_len.to_be_bytes());
    pkt.extend_from_slice(&1u32.to_be_bytes());
    pkt.extend_from_slice(&2u32.to_be_bytes());
    pkt.extend_from_slice(&1u32.to_be_bytes());
    pkt.extend_from_slice(&template_id.to_be_bytes());
    pkt.extend_from_slice(&set_len.to_be_bytes());
    pkt.extend_from_slice(payload);
    pkt
}

// ---------------------------------------------------------------------------
// V9 tests
// ---------------------------------------------------------------------------

#[test]
fn v9_template_is_written_through_on_learn() {
    let store = Arc::new(InMemoryTemplateStore::new());
    let mut parser = NetflowParser::builder()
        .with_template_store(store.clone())
        .build()
        .expect("build");

    // Template with a single 4-byte IN_BYTES field.
    let pkt = v9_template_packet(256, &[(1, 4)]);
    let result = parser.parse_bytes(&pkt);
    assert!(
        result.error.is_none(),
        "template parse error: {:?}",
        result.error
    );
    assert!(!result.packets.is_empty());

    // Store should now contain exactly one V9Data entry under the empty scope.
    let key = TemplateStoreKey::new("", TemplateKind::V9Data, 256);
    let bytes = store
        .get(&key)
        .expect("get")
        .expect("template should be persisted");
    assert!(!bytes.is_empty());
    assert_eq!(store.len(), 1);
}

#[test]
fn v9_data_record_is_decoded_via_read_through_after_replica_restart() {
    // Replica A learns a template into a shared store.
    let store = Arc::new(InMemoryTemplateStore::new());
    {
        let mut a = NetflowParser::builder()
            .with_template_store(store.clone())
            .build()
            .expect("build");
        let tmpl = v9_template_packet(256, &[(1, 4)]);
        assert!(a.parse_bytes(&tmpl).error.is_none());
    } // replica A goes away

    // Replica B starts fresh — no in-process templates — and receives a
    // data record for template 256. Without read-through this would land in
    // pending_flows / NoTemplate; with read-through it must decode.
    let mut b = NetflowParser::builder()
        .with_template_store(store.clone())
        .build()
        .expect("build");
    let data = v9_data_packet(256, &[0, 0, 0, 0x2A]); // IN_BYTES = 42
    let result = b.parse_bytes(&data);
    assert!(
        result.error.is_none(),
        "data parse error: {:?}",
        result.error
    );
    let pkt = result.packets.into_iter().next().expect("one packet");
    let v9 = match pkt {
        NetflowPacket::V9(v) => v,
        other => panic!("expected V9, got {:?}", other),
    };

    // The parser should have produced a Data flowset (not NoTemplate).
    let body = v9.flowsets.into_iter().next().expect("one flowset").body;
    let is_data = matches!(
        body,
        netflow_parser::variable_versions::v9::FlowSetBody::Data(_)
    );
    assert!(is_data, "expected Data flowset, got {:?}", body);

    // After read-through the in-process LRU should now contain template 256
    // so subsequent records served from the hot path.
    assert!(b.has_v9_template(256));
}

#[test]
fn v9_no_store_baseline_unchanged() {
    // Sanity check: with no store configured, behavior matches the
    // pre-existing path (no panics, no extra allocations of consequence,
    // template parses and is cached locally only).
    let mut parser = NetflowParser::default();
    let tmpl = v9_template_packet(256, &[(1, 4)]);
    let result = parser.parse_bytes(&tmpl);
    assert!(result.error.is_none());
    assert!(parser.has_v9_template(256));
}

#[test]
fn v9_clear_templates_propagates_to_store() {
    let store = Arc::new(InMemoryTemplateStore::new());
    let mut parser = NetflowParser::builder()
        .with_template_store(store.clone())
        .build()
        .expect("build");
    assert!(
        parser
            .parse_bytes(&v9_template_packet(256, &[(1, 4)]))
            .error
            .is_none()
    );
    assert_eq!(store.len(), 1);

    parser.clear_v9_templates();

    // The store must be drained as well, otherwise read-through would
    // immediately repopulate the cleared LRU, defeating the clear semantics.
    assert_eq!(store.len(), 0);
}

// ---------------------------------------------------------------------------
// IPFIX tests
// ---------------------------------------------------------------------------

#[test]
fn ipfix_template_is_written_through_on_learn() {
    let store = Arc::new(InMemoryTemplateStore::new());
    let mut parser = NetflowParser::builder()
        .with_template_store(store.clone())
        .build()
        .expect("build");

    let pkt = ipfix_template_packet(300, &[(1, 4), (2, 4)]);
    let result = parser.parse_bytes(&pkt);
    assert!(
        result.error.is_none(),
        "template parse error: {:?}",
        result.error
    );

    let key = TemplateStoreKey::new("", TemplateKind::IpfixData, 300);
    assert!(
        store.get(&key).expect("get").is_some(),
        "IPFIX template should be persisted"
    );
}

#[test]
fn ipfix_data_record_is_decoded_via_read_through() {
    // Seed the store via replica A.
    let store = Arc::new(InMemoryTemplateStore::new());
    {
        let mut a = NetflowParser::builder()
            .with_template_store(store.clone())
            .build()
            .expect("build");
        let tmpl = ipfix_template_packet(300, &[(1, 4)]);
        assert!(a.parse_bytes(&tmpl).error.is_none());
    }

    // Replica B starts cold.
    let mut b = NetflowParser::builder()
        .with_template_store(store.clone())
        .build()
        .expect("build");
    let data = ipfix_data_packet(300, &[0, 0, 0, 0x2A]);
    let result = b.parse_bytes(&data);
    assert!(
        result.error.is_none(),
        "data parse error: {:?}",
        result.error
    );

    let pkt = result.packets.into_iter().next().expect("one packet");
    let ipfix = match pkt {
        NetflowPacket::IPFix(v) => v,
        other => panic!("expected IPFIX, got {:?}", other),
    };
    let body = ipfix.flowsets.into_iter().next().expect("one set").body;
    let is_data = matches!(
        body,
        netflow_parser::variable_versions::ipfix::FlowSetBody::Data(_)
    );
    assert!(is_data, "expected Data set, got {:?}", body);
    assert!(b.has_ipfix_template(300));
}

#[test]
fn ipfix_template_withdrawal_evicts_from_store() {
    let store = Arc::new(InMemoryTemplateStore::new());
    let mut parser = NetflowParser::builder()
        .with_template_store(store.clone())
        .build()
        .expect("build");

    assert!(
        parser
            .parse_bytes(&ipfix_template_packet(300, &[(1, 4)]))
            .error
            .is_none()
    );
    let key = TemplateStoreKey::new("", TemplateKind::IpfixData, 300);
    assert!(store.get(&key).unwrap().is_some());

    // Withdrawal: same set ID = 2, template_id = 300, field_count = 0.
    let mut pkt = Vec::new();
    let set_len: u16 = 8;
    let msg_len: u16 = 16 + set_len;
    pkt.extend_from_slice(&0x000Au16.to_be_bytes());
    pkt.extend_from_slice(&msg_len.to_be_bytes());
    pkt.extend_from_slice(&1u32.to_be_bytes());
    pkt.extend_from_slice(&2u32.to_be_bytes());
    pkt.extend_from_slice(&1u32.to_be_bytes());
    pkt.extend_from_slice(&2u16.to_be_bytes());
    pkt.extend_from_slice(&set_len.to_be_bytes());
    pkt.extend_from_slice(&300u16.to_be_bytes());
    pkt.extend_from_slice(&0u16.to_be_bytes()); // field_count = 0
    let _ = parser.parse_bytes(&pkt);

    assert!(
        store.get(&key).unwrap().is_none(),
        "withdrawal should remove template from store"
    );
}

// ---------------------------------------------------------------------------
// AutoScopedParser tests
// ---------------------------------------------------------------------------

#[test]
fn auto_scoped_parser_uses_per_source_scope() {
    let store = Arc::new(InMemoryTemplateStore::new());
    let builder = NetflowParser::builder().with_template_store(store.clone());
    let mut scoped = AutoScopedParser::try_with_builder(builder).expect("valid");

    let src_a: SocketAddr = "10.0.0.1:2055".parse().unwrap();
    let src_b: SocketAddr = "10.0.0.2:2055".parse().unwrap();

    // Both sources announce the *same* template ID with *different* layouts.
    // Without per-source scoping in the store, B's write would clobber A's.
    let tmpl_a = v9_template_packet(256, &[(1, 4)]);
    let tmpl_b = v9_template_packet(256, &[(2, 4), (3, 4)]);
    let _ = scoped.parse_from_source(src_a, &tmpl_a);
    let _ = scoped.parse_from_source(src_b, &tmpl_b);

    // Two distinct entries should exist in the store, keyed by source.
    assert_eq!(store.len(), 2);

    // Verify each scope key resolves and the payloads differ (different
    // template layouts encode to different bytes).
    let mut found_payloads = Vec::new();
    {
        // V9 packets carry a source_id (0 here) so the AutoScopedParser
        // classifies them under the V9 scoping branch, not legacy.
        let scopes = ["v9:10.0.0.1:2055/0", "v9:10.0.0.2:2055/0"];
        for scope in scopes {
            let key = TemplateStoreKey::new(scope, TemplateKind::V9Data, 256);
            let bytes = store
                .get(&key)
                .unwrap()
                .unwrap_or_else(|| panic!("missing entry for scope {}", scope));
            found_payloads.push(bytes);
        }
    }
    assert_ne!(
        found_payloads[0], found_payloads[1],
        "scoped store entries must hold the distinct templates each source announced"
    );

    // Cross-replica read-through: a fresh AutoScopedParser sharing the same
    // store must resolve each source's template via its own scope key. Assert
    // each result contains a Data flowset (not NoTemplate) — read-through
    // miss or wrong-scope hit would yield NoTemplate without an error, so
    // checking for a V9 packet alone is not sufficient.
    let mut replica = AutoScopedParser::try_with_builder(
        NetflowParser::builder().with_template_store(store.clone()),
    )
    .expect("valid");

    fn assert_first_flowset_is_data(packets: &[NetflowPacket], who: &str) {
        let v9 = packets
            .iter()
            .find_map(|p| match p {
                NetflowPacket::V9(v) => Some(v),
                _ => None,
            })
            .unwrap_or_else(|| panic!("{who}: expected a V9 packet"));
        let body = &v9
            .flowsets
            .first()
            .unwrap_or_else(|| panic!("{who}: expected at least one flowset"))
            .body;
        assert!(
            matches!(
                body,
                netflow_parser::variable_versions::v9::FlowSetBody::Data(_)
            ),
            "{who}: expected Data flowset (read-through hit correct scope), got {:?}",
            body
        );
    }

    // Data record from src_a must decode against tmpl_a (1 field of 4 bytes).
    let r_a = replica.parse_from_source(src_a, &v9_data_packet(256, &[0, 0, 0, 0x2A]));
    assert!(r_a.error.is_none());
    assert_first_flowset_is_data(&r_a.packets, "src_a");
    // Data record from src_b must decode against tmpl_b (2 fields of 4 bytes each).
    let r_b = replica.parse_from_source(src_b, &v9_data_packet(256, &[0, 0, 0, 1, 0, 0, 0, 2]));
    assert!(r_b.error.is_none());
    assert_first_flowset_is_data(&r_b.packets, "src_b");
}

// ---------------------------------------------------------------------------
// Fault-injection store: makes get/put/remove return configurable Errs and
// lets tests seed deliberately corrupted payloads.
// ---------------------------------------------------------------------------

#[derive(Debug, Default)]
struct FaultStore {
    inner: Mutex<std::collections::HashMap<TemplateStoreKey, Vec<u8>>>,
    fail_get: AtomicUsize,
    fail_put: AtomicUsize,
    fail_remove: AtomicUsize,
    backend_errors: AtomicUsize,
}

impl FaultStore {
    fn new() -> Self {
        Self::default()
    }
    fn inject_get_failures(&self, n: usize) {
        self.fail_get.store(n, Ordering::SeqCst);
    }
    fn inject_put_failures(&self, n: usize) {
        self.fail_put.store(n, Ordering::SeqCst);
    }
    fn inject_remove_failures(&self, n: usize) {
        self.fail_remove.store(n, Ordering::SeqCst);
    }
    fn observed_errors(&self) -> usize {
        self.backend_errors.load(Ordering::SeqCst)
    }
}

impl TemplateStore for FaultStore {
    fn get(&self, key: &TemplateStoreKey) -> Result<Option<Vec<u8>>, TemplateStoreError> {
        if self.fail_get.load(Ordering::SeqCst) > 0 {
            self.fail_get.fetch_sub(1, Ordering::SeqCst);
            self.backend_errors.fetch_add(1, Ordering::SeqCst);
            return Err(TemplateStoreError::Backend("injected".into()));
        }
        Ok(self.inner.lock().unwrap().get(key).cloned())
    }
    fn put(&self, key: &TemplateStoreKey, value: &[u8]) -> Result<(), TemplateStoreError> {
        if self.fail_put.load(Ordering::SeqCst) > 0 {
            self.fail_put.fetch_sub(1, Ordering::SeqCst);
            self.backend_errors.fetch_add(1, Ordering::SeqCst);
            return Err(TemplateStoreError::Backend("injected".into()));
        }
        self.inner
            .lock()
            .unwrap()
            .insert(key.clone(), value.to_vec());
        Ok(())
    }
    fn remove(&self, key: &TemplateStoreKey) -> Result<(), TemplateStoreError> {
        if self.fail_remove.load(Ordering::SeqCst) > 0 {
            self.fail_remove.fetch_sub(1, Ordering::SeqCst);
            self.backend_errors.fetch_add(1, Ordering::SeqCst);
            return Err(TemplateStoreError::Backend("injected".into()));
        }
        self.inner.lock().unwrap().remove(key);
        Ok(())
    }
}

// ---------------------------------------------------------------------------
// Backend-error path
// ---------------------------------------------------------------------------

#[test]
fn put_backend_error_is_counted_and_does_not_abort_parsing() {
    let store = Arc::new(FaultStore::new());
    store.inject_put_failures(1);
    let mut parser = NetflowParser::builder()
        .with_template_store(store.clone())
        .build()
        .expect("build");

    // Template parse should succeed even though the put fails.
    let pkt = v9_template_packet(256, &[(1, 4)]);
    let result = parser.parse_bytes(&pkt);
    assert!(result.error.is_none());
    assert!(parser.has_v9_template(256));

    let metrics = parser.v9_cache_info().metrics;
    assert_eq!(
        metrics.template_store_backend_errors, 1,
        "backend error must be counted"
    );
    assert_eq!(store.observed_errors(), 1);
}

#[test]
fn get_backend_error_during_read_through_is_counted() {
    // Seed a valid entry, but make the next get() fail with a backend error.
    let store = Arc::new(FaultStore::new());
    {
        let mut seed = NetflowParser::builder()
            .with_template_store(store.clone())
            .build()
            .expect("build");
        let _ = seed.parse_bytes(&v9_template_packet(256, &[(1, 4)]));
    }
    store.inject_get_failures(1);

    let mut b = NetflowParser::builder()
        .with_template_store(store.clone())
        .build()
        .expect("build");
    let data = v9_data_packet(256, &[0, 0, 0, 0x2A]);
    let _ = b.parse_bytes(&data);

    let metrics = b.v9_cache_info().metrics;
    assert!(metrics.template_store_backend_errors >= 1);
}

// ---------------------------------------------------------------------------
// Codec-error cleanup path (review item #1)
// ---------------------------------------------------------------------------

#[test]
fn corrupted_payload_is_counted_and_removed_from_store() {
    let store = Arc::new(InMemoryTemplateStore::new());
    // Pre-seed the store with garbage bytes for template 256.
    let key = TemplateStoreKey::new("", TemplateKind::V9Data, 256);
    store
        .put(&key, &[0xff, 0xff, 0xff, 0xff, 0xff])
        .expect("seed");
    assert!(store.get(&key).unwrap().is_some());

    let mut parser = NetflowParser::builder()
        .with_template_store(store.clone())
        .build()
        .expect("build");
    let data = v9_data_packet(256, &[0, 0, 0, 0x2A]);
    let _ = parser.parse_bytes(&data);

    let metrics = parser.v9_cache_info().metrics;
    assert_eq!(
        metrics.template_store_codec_errors, 1,
        "codec error must be counted"
    );
    assert!(
        store.get(&key).unwrap().is_none(),
        "corrupted entry must be removed so a fresh announce can repopulate"
    );
}

// ---------------------------------------------------------------------------
// Eviction propagation on full cache (review item #3)
// ---------------------------------------------------------------------------

#[test]
fn lru_eviction_on_full_cache_propagates_to_store() {
    let store = Arc::new(InMemoryTemplateStore::new());
    // Cache size = 2: third template forces an eviction of the oldest.
    let mut parser = NetflowParser::builder()
        .with_template_store(store.clone())
        .with_cache_size(2)
        .build()
        .expect("build");

    for &(id, field_type) in &[(256u16, 1u16), (257, 2), (258, 3)] {
        assert!(
            parser
                .parse_bytes(&v9_template_packet(id, &[(field_type, 4)]))
                .error
                .is_none()
        );
    }

    // Template 256 was the oldest; it must be gone from both the LRU and the
    // store now that 258 forced an eviction.
    assert!(!parser.has_v9_template(256));
    let evicted = TemplateStoreKey::new("", TemplateKind::V9Data, 256);
    assert!(
        store.get(&evicted).unwrap().is_none(),
        "LRU eviction must remove the entry from the secondary store"
    );
    // 257 and 258 are still hot.
    assert!(store.len() == 2);
}

// ---------------------------------------------------------------------------
// IPFIX options-template read-through (was untested in the first pass)
// ---------------------------------------------------------------------------

/// Build an IPFIX options-template packet (set ID 3) with a single scope
/// field followed by a single option field, both 4 bytes.
fn ipfix_options_template_packet(template_id: u16) -> Vec<u8> {
    // record: template_id(2) + field_count(2) + scope_field_count(2) + 2*field(4) = 14
    let set_len: u16 = 4 + 14;
    let msg_len: u16 = 16 + set_len;
    let mut pkt = Vec::new();
    pkt.extend_from_slice(&0x000Au16.to_be_bytes());
    pkt.extend_from_slice(&msg_len.to_be_bytes());
    pkt.extend_from_slice(&1u32.to_be_bytes());
    pkt.extend_from_slice(&1u32.to_be_bytes());
    pkt.extend_from_slice(&1u32.to_be_bytes());
    pkt.extend_from_slice(&3u16.to_be_bytes()); // set ID = 3 (options template)
    pkt.extend_from_slice(&set_len.to_be_bytes());
    pkt.extend_from_slice(&template_id.to_be_bytes());
    pkt.extend_from_slice(&2u16.to_be_bytes()); // field_count = 2
    pkt.extend_from_slice(&1u16.to_be_bytes()); // scope_field_count = 1
    pkt.extend_from_slice(&1u16.to_be_bytes()); // scope field type
    pkt.extend_from_slice(&4u16.to_be_bytes()); // scope field length
    pkt.extend_from_slice(&3u16.to_be_bytes()); // option field type
    pkt.extend_from_slice(&4u16.to_be_bytes()); // option field length
    pkt
}

#[test]
fn ipfix_options_template_read_through_works() {
    let store = Arc::new(InMemoryTemplateStore::new());
    {
        let mut a = NetflowParser::builder()
            .with_template_store(store.clone())
            .build()
            .expect("build");
        let _ = a.parse_bytes(&ipfix_options_template_packet(400));
    }

    let mut b = NetflowParser::builder()
        .with_template_store(store.clone())
        .build()
        .expect("build");
    // Send an options-data packet referencing template 400.
    let data = ipfix_data_packet(400, &[0, 0, 0, 1, 0, 0, 0, 2]);
    let result = b.parse_bytes(&data);
    assert!(
        result.error.is_none(),
        "options-data parse: {:?}",
        result.error
    );
    assert!(b.has_ipfix_template(400));
}

// ---------------------------------------------------------------------------
// Restored event hook firing (review item #5)
// ---------------------------------------------------------------------------

#[test]
fn read_through_fires_restored_event() {
    let store = Arc::new(InMemoryTemplateStore::new());
    {
        let mut a = NetflowParser::builder()
            .with_template_store(store.clone())
            .build()
            .expect("build");
        let _ = a.parse_bytes(&v9_template_packet(256, &[(1, 4)]));
    }

    let restored: Arc<Mutex<Vec<(TemplateProtocol, u16)>>> = Arc::new(Mutex::new(Vec::new()));
    let restored_clone = Arc::clone(&restored);

    let mut b = NetflowParser::builder()
        .with_template_store(store.clone())
        .on_template_event(move |event| {
            if let TemplateEvent::Restored {
                template_id: Some(id),
                protocol,
            } = event
            {
                restored_clone.lock().unwrap().push((*protocol, *id));
            }
            Ok(())
        })
        .build()
        .expect("build");

    let _ = b.parse_bytes(&v9_data_packet(256, &[0, 0, 0, 0x2A]));

    let observed = restored.lock().unwrap().clone();
    assert_eq!(observed, vec![(TemplateProtocol::V9, 256)]);
}

// ---------------------------------------------------------------------------
// Pending-flow replay after read-through (review item #6)
// ---------------------------------------------------------------------------

#[test]
fn read_through_drives_pending_flow_replay() {
    use netflow_parser::PendingFlowsConfig;

    let store = Arc::new(InMemoryTemplateStore::new());

    // Replica B has pending-flow caching enabled and starts with an empty
    // in-process cache *and* an empty store.
    let mut b = NetflowParser::builder()
        .with_template_store(store.clone())
        .with_pending_flows(PendingFlowsConfig::default())
        .build()
        .expect("build");

    // Step 1: data record arrives before the template is known anywhere.
    // Pending-flow caching must queue it.
    let r1 = b.parse_bytes(&v9_data_packet(256, &[0, 0, 0, 0x2A]));
    assert!(r1.error.is_none());
    let m1 = b.v9_cache_info().metrics;
    assert_eq!(
        m1.pending_cached, 1,
        "data arriving before template must queue"
    );
    assert_eq!(m1.pending_replayed, 0);
    assert_eq!(m1.template_store_restored, 0);

    // Step 2: another replica learns the template and writes it to the
    // shared store.
    {
        let mut a = NetflowParser::builder()
            .with_template_store(store.clone())
            .build()
            .expect("build");
        let _ = a.parse_bytes(&v9_template_packet(256, &[(1, 4)]));
    }

    // Step 3: replica B receives another data record for template 256. The
    // read-through must (a) restore the template into B's in-process cache,
    // (b) decode the in-line record, AND (c) replay the previously-queued
    // pending entry against the freshly-restored template.
    let r2 = b.parse_bytes(&v9_data_packet(256, &[0, 0, 0, 0x99]));
    assert!(r2.error.is_none());
    let m2 = b.v9_cache_info().metrics;
    assert_eq!(
        m2.template_store_restored, 1,
        "read-through should restore the template"
    );
    assert_eq!(
        m2.pending_replayed, 1,
        "read-through must drive replay of the queued pending flow"
    );
    assert_eq!(m2.pending_replay_failed, 0);
}

// ---------------------------------------------------------------------------
// Duplicate-ID write-through (review item #8)
// ---------------------------------------------------------------------------

#[test]
fn duplicate_template_id_write_through_overwrites() {
    let store = Arc::new(InMemoryTemplateStore::new());
    let mut parser = NetflowParser::builder()
        .with_template_store(store.clone())
        .build()
        .expect("build");

    // Same ID, two different definitions in sequence.
    let _ = parser.parse_bytes(&v9_template_packet(256, &[(1, 4)]));
    let key = TemplateStoreKey::new("", TemplateKind::V9Data, 256);
    let bytes_v1 = store.get(&key).unwrap().expect("first write");

    let _ = parser.parse_bytes(&v9_template_packet(256, &[(2, 4), (3, 4)]));
    let bytes_v2 = store.get(&key).unwrap().expect("second write");

    assert_ne!(bytes_v1, bytes_v2, "store must reflect the new definition");
    assert_eq!(store.len(), 1, "still one entry under the same key");
}

// ---------------------------------------------------------------------------
// set_template_store_scope retrofit
// ---------------------------------------------------------------------------

#[test]
fn set_template_store_scope_retrofit_changes_keys() {
    let store = Arc::new(InMemoryTemplateStore::new());
    let mut parser = NetflowParser::builder()
        .with_template_store(store.clone())
        .build()
        .expect("build");

    // Default scope is empty.
    let _ = parser.parse_bytes(&v9_template_packet(256, &[(1, 4)]));
    assert!(
        store
            .get(&TemplateStoreKey::new("", TemplateKind::V9Data, 256))
            .unwrap()
            .is_some()
    );

    // Retrofit a scope; subsequent learns must land under it.
    parser.set_template_store_scope("collector-eu");
    let _ = parser.parse_bytes(&v9_template_packet(257, &[(2, 4)]));
    assert!(
        store
            .get(&TemplateStoreKey::new(
                "collector-eu",
                TemplateKind::V9Data,
                257
            ))
            .unwrap()
            .is_some()
    );
}

// ---------------------------------------------------------------------------
// clear_*_templates backend error reporting + remove-failure coverage
// ---------------------------------------------------------------------------

#[test]
fn clear_v9_templates_records_backend_errors_on_remove_failure() {
    let store = Arc::new(FaultStore::new());
    let mut parser = NetflowParser::builder()
        .with_template_store(store.clone())
        .build()
        .expect("build");

    // Learn two templates so clear_v9_templates issues two store.remove calls.
    let _ = parser.parse_bytes(&v9_template_packet(256, &[(1, 4)]));
    let _ = parser.parse_bytes(&v9_template_packet(257, &[(2, 4)]));
    let baseline = parser.v9_cache_info().metrics.template_store_backend_errors;

    // Inject two remove failures so both removes during clear() Err out.
    store.inject_remove_failures(2);
    parser.clear_v9_templates();

    let metrics = parser.v9_cache_info().metrics;
    assert_eq!(
        metrics.template_store_backend_errors - baseline,
        2,
        "clear_v9_templates must count backend errors on remove failure"
    );
    assert_eq!(store.observed_errors(), 2);
}

#[test]
fn clear_ipfix_templates_records_backend_errors_on_remove_failure() {
    let store = Arc::new(FaultStore::new());
    let mut parser = NetflowParser::builder()
        .with_template_store(store.clone())
        .build()
        .expect("build");

    let _ = parser.parse_bytes(&ipfix_template_packet(300, &[(1, 4)]));
    let baseline = parser
        .ipfix_cache_info()
        .metrics
        .template_store_backend_errors;

    store.inject_remove_failures(1);
    parser.clear_ipfix_templates();

    let metrics = parser.ipfix_cache_info().metrics;
    assert_eq!(
        metrics.template_store_backend_errors - baseline,
        1,
        "clear_ipfix_templates must count backend errors on remove failure"
    );
}

// ---------------------------------------------------------------------------
// AutoScopedParser source eviction cleans up store entries
// ---------------------------------------------------------------------------

#[test]
fn auto_scoped_parser_eviction_clears_evicted_source_from_store() {
    let store = Arc::new(InMemoryTemplateStore::new());
    let builder = NetflowParser::builder().with_template_store(store.clone());
    let mut scoped = AutoScopedParser::try_with_builder(builder)
        .expect("valid")
        .with_max_sources(2)
        .expect("valid");

    let src_a: SocketAddr = "10.0.0.1:2055".parse().unwrap();
    let src_b: SocketAddr = "10.0.0.2:2055".parse().unwrap();
    let src_c: SocketAddr = "10.0.0.3:2055".parse().unwrap();

    // Learn distinct templates from three different sources. Source A is
    // touched first, so it becomes the LRU when source C arrives.
    let _ = scoped.parse_from_source(src_a, &v9_template_packet(256, &[(1, 4)]));
    let _ = scoped.parse_from_source(src_b, &v9_template_packet(256, &[(2, 4)]));
    assert_eq!(store.len(), 2);

    // Touch B again to make A the unambiguously oldest entry.
    let _ = scoped.parse_from_source(src_b, &v9_template_packet(257, &[(3, 4)]));
    // Adding C must evict A. A's store entries (under "v9:10.0.0.1:2055/0")
    // must be removed — otherwise a later replica reading the store would
    // resurrect templates that no parser instance is responsible for.
    let _ = scoped.parse_from_source(src_c, &v9_template_packet(256, &[(4, 4)]));

    let key_a = TemplateStoreKey::new("v9:10.0.0.1:2055/0", TemplateKind::V9Data, 256);
    assert!(
        store.get(&key_a).unwrap().is_none(),
        "evicted source's templates must be cleared from the store"
    );
    // B and C entries should remain.
    let key_b_256 = TemplateStoreKey::new("v9:10.0.0.2:2055/0", TemplateKind::V9Data, 256);
    let key_b_257 = TemplateStoreKey::new("v9:10.0.0.2:2055/0", TemplateKind::V9Data, 257);
    let key_c = TemplateStoreKey::new("v9:10.0.0.3:2055/0", TemplateKind::V9Data, 256);
    assert!(store.get(&key_b_256).unwrap().is_some());
    assert!(store.get(&key_b_257).unwrap().is_some());
    assert!(store.get(&key_c).unwrap().is_some());
}

// ---------------------------------------------------------------------------
// Codec corruption coverage for non-V9Data kinds
// ---------------------------------------------------------------------------

#[test]
fn ipfix_corrupted_payload_is_counted_and_removed() {
    let store = Arc::new(InMemoryTemplateStore::new());
    let key = TemplateStoreKey::new("", TemplateKind::IpfixData, 300);
    store.put(&key, &[0xff; 6]).expect("seed");

    let mut parser = NetflowParser::builder()
        .with_template_store(store.clone())
        .build()
        .expect("build");
    let _ = parser.parse_bytes(&ipfix_data_packet(300, &[0, 0, 0, 0x2A]));

    let metrics = parser.ipfix_cache_info().metrics;
    assert_eq!(
        metrics.template_store_codec_errors, 1,
        "IPFIX codec error must be counted"
    );
    assert!(
        store.get(&key).unwrap().is_none(),
        "corrupted IPFIX entry must be removed"
    );
}

// ---------------------------------------------------------------------------
// LRU eviction propagates to store for IPFIX
// ---------------------------------------------------------------------------

#[test]
fn ipfix_lru_eviction_propagates_to_store() {
    let store = Arc::new(InMemoryTemplateStore::new());
    let mut parser = NetflowParser::builder()
        .with_template_store(store.clone())
        .with_cache_size(2)
        .build()
        .expect("build");

    let _ = parser.parse_bytes(&ipfix_template_packet(300, &[(1, 4)]));
    let _ = parser.parse_bytes(&ipfix_template_packet(301, &[(2, 4)]));
    let _ = parser.parse_bytes(&ipfix_template_packet(302, &[(3, 4)]));

    // Cache holds at most 2; the oldest (300) should have been evicted from
    // the in-process LRU and from the store.
    let key_300 = TemplateStoreKey::new("", TemplateKind::IpfixData, 300);
    assert!(
        store.get(&key_300).unwrap().is_none(),
        "evicted IPFIX template must be removed from store"
    );
    let key_301 = TemplateStoreKey::new("", TemplateKind::IpfixData, 301);
    let key_302 = TemplateStoreKey::new("", TemplateKind::IpfixData, 302);
    assert!(store.get(&key_301).unwrap().is_some());
    assert!(store.get(&key_302).unwrap().is_some());
}

// ---------------------------------------------------------------------------
// IPFIX Restored event firing
// ---------------------------------------------------------------------------

#[test]
fn ipfix_read_through_fires_restored_event() {
    let store = Arc::new(InMemoryTemplateStore::new());
    {
        let mut a = NetflowParser::builder()
            .with_template_store(store.clone())
            .build()
            .expect("build");
        let _ = a.parse_bytes(&ipfix_template_packet(300, &[(1, 4)]));
    }

    let restored: Arc<Mutex<Vec<(TemplateProtocol, u16)>>> = Arc::new(Mutex::new(Vec::new()));
    let restored_clone = Arc::clone(&restored);

    let mut b = NetflowParser::builder()
        .with_template_store(store.clone())
        .on_template_event(move |event| {
            if let TemplateEvent::Restored {
                template_id: Some(id),
                protocol,
            } = event
            {
                restored_clone.lock().unwrap().push((*protocol, *id));
            }
            Ok(())
        })
        .build()
        .expect("build");

    let _ = b.parse_bytes(&ipfix_data_packet(300, &[0, 0, 0, 0x2A]));

    let observed = restored.lock().unwrap().clone();
    assert_eq!(observed, vec![(TemplateProtocol::Ipfix, 300)]);
}
