//! Horizontal scale-out via a shared `TemplateStore`.
//!
//! Demonstrates the use case the `TemplateStore` extension point exists for:
//! running multiple stateless parser replicas behind a UDP load balancer
//! without source-IP-affinity routing.
//!
//! Replica A learns a template, writes it through to a shared store, and
//! goes away. Replica B starts cold — its in-process template cache is
//! empty — and immediately receives a data record for that template.
//! With the store configured, replica B transparently restores the template
//! from the store and decodes the record. Without the store, the same data
//! record would queue in pending flows or fail to decode.
//!
//! In production you would back the `TemplateStore` with Redis, NATS KV,
//! or similar; the in-memory store used here keeps the example self
//! contained. The trait sees only opaque `Vec<u8>` payloads, so the
//! protocol is identical regardless of backend.
//!
//! Run with:
//! ```sh
//! cargo run --example horizontal_scale_out_template_store
//! ```

use netflow_parser::{
    InMemoryTemplateStore, NetflowPacket, NetflowParser, TemplateEvent, TemplateProtocol,
};
use std::sync::Arc;
use std::sync::Mutex;

fn main() {
    println!("=== Horizontal scale-out demo: two parsers sharing a TemplateStore ===\n");

    // The store any production deployment would back with Redis, NATS KV,
    // DynamoDB, etc. Implements the `TemplateStore` trait — get / put /
    // remove on opaque byte payloads.
    let store = Arc::new(InMemoryTemplateStore::new());

    // ------------------------------------------------------------------
    // Replica A: learns a template, persists it via write-through.
    // ------------------------------------------------------------------
    println!("[replica A] starting up, will learn one template");
    let mut replica_a = NetflowParser::builder()
        .with_template_store(Arc::clone(&store) as _)
        .build()
        .expect("build replica A");

    let template_packet = build_v9_template_packet(256, &[(8, 4), (12, 4), (1, 8)]);
    let result = replica_a.parse_bytes(&template_packet);
    if let Some(err) = result.error {
        panic!("template parse failed: {err}");
    }
    println!(
        "[replica A] learned template 256, store now has {} entr(ies)\n",
        store.len()
    );

    // Replica A goes away — drop it. The store is the only surviving
    // record of the template. A real deployment might drop replica A
    // because it crashed, scaled down, or rolled.
    drop(replica_a);

    // ------------------------------------------------------------------
    // Replica B: starts cold, no in-process templates. Receives a data
    // record for template 256 and must decode it via read-through.
    // ------------------------------------------------------------------
    println!("[replica B] starting cold (no in-process template cache)");

    // Wire up a hook so we can observe the Restored event. In production
    // this is how an observability system would distinguish "template
    // recovered from secondary tier" from "template freshly learned from
    // exporter announce" — both look like cache hits in the basic metric.
    let restored_log: Arc<Mutex<Vec<(TemplateProtocol, u16)>>> =
        Arc::new(Mutex::new(Vec::new()));
    let restored_log_for_hook = Arc::clone(&restored_log);

    let mut replica_b = NetflowParser::builder()
        .with_template_store(Arc::clone(&store) as _)
        .on_template_event(move |event| {
            if let TemplateEvent::Restored {
                template_id: Some(id),
                protocol,
            } = event
            {
                restored_log_for_hook
                    .lock()
                    .expect("poisoned")
                    .push((*protocol, *id));
            }
            Ok(())
        })
        .build()
        .expect("build replica B");

    // 16 bytes = three fields (4 + 4 + 8) matching the template above.
    let data_payload = [
        // src IP = 10.0.0.1
        0x0A, 0x00, 0x00, 0x01, // dst IP = 10.0.0.2
        0x0A, 0x00, 0x00, 0x02, // bytes = 4096
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x10, 0x00,
    ];
    let data_packet = build_v9_data_packet(256, &data_payload);

    let result = replica_b.parse_bytes(&data_packet);
    if let Some(err) = result.error {
        panic!("data parse on replica B failed: {err}");
    }

    let v9 = result
        .packets
        .into_iter()
        .find_map(|p| match p {
            NetflowPacket::V9(v) => Some(v),
            _ => None,
        })
        .expect("expected a V9 packet");
    let flowset_count = v9.flowsets.len();
    println!(
        "[replica B] decoded data packet against restored template ({} flowset(s))",
        flowset_count
    );

    // ------------------------------------------------------------------
    // Observability — what metrics and events fired?
    // ------------------------------------------------------------------
    let metrics = replica_b.v9_cache_info().metrics;
    println!("\n[replica B] cache metrics after read-through:");
    println!("    hits                     = {}", metrics.hits);
    println!("    misses                   = {}", metrics.misses);
    println!(
        "    template_store_restored  = {}",
        metrics.template_store_restored
    );
    println!(
        "    template_store_codec_err = {}",
        metrics.template_store_codec_errors
    );
    println!(
        "    template_store_backend_err = {}",
        metrics.template_store_backend_errors
    );

    let restored = restored_log.lock().expect("poisoned");
    println!("\n[replica B] TemplateEvent::Restored events:");
    for (protocol, id) in restored.iter() {
        println!("    {:?} template_id={}", protocol, id);
    }

    println!("\nDone. The same protocol works for IPFIX and IPFIX-options templates.");
    println!(
        "Hot-path overhead when no store is configured is a single Option::is_none branch."
    );
}

// --- packet builders --------------------------------------------------------
// Minimal V9 packet construction for the demo. In production these come from
// the wire — exporters announce templates, then send data records that
// reference them.

fn build_v9_template_packet(template_id: u16, fields: &[(u16, u16)]) -> Vec<u8> {
    let template_record_len = 4 + fields.len() * 4; // template header + fields
    let flowset_len = 4 + template_record_len; // set header + record
    let mut pkt = Vec::new();
    // V9 header (20 bytes)
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

fn build_v9_data_packet(template_id: u16, payload: &[u8]) -> Vec<u8> {
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
