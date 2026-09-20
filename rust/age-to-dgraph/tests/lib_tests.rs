/*
 * Copyright 2026 Carver Automation Corporation.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

use age_to_dgraph::{
    CanonicalEdgeRecord, MapperLinkRow, Mode, canonical_link_key, compare_snapshots,
    edge_writes_from_records, hash_canonical_edges, parse_dump, records_from_canonical_edges,
    records_from_mapper_rows, snapshot_from_edges,
};
use dgraph_topology::CanonicalEdge;

fn synthetic_edge(src: &str, dst: &str, if_ab: &str, if_ba: &str) -> CanonicalEdgeRecord {
    CanonicalEdgeRecord {
        link_key: canonical_link_key(src, dst, if_ab, if_ba),
        source: src.to_string(),
        target: dst.to_string(),
        protocol: "lldp".to_string(),
        evidence_class: "direct-physical".to_string(),
        if_name_ab: if_ab.to_string(),
        if_name_ba: if_ba.to_string(),
    }
}

/// A Dgraph read carries whatever `topo.link_key` the store happens to hold.
fn stored_dgraph_edge(
    src: &str,
    dst: &str,
    if_ab: &str,
    if_ba: &str,
    stored_link_key: &str,
) -> CanonicalEdge {
    CanonicalEdge::new(
        src.to_string(),
        dst.to_string(),
        0,
        0,
        0,
        0,
        0,
        false,
        "lldp".to_string(),
        "direct-physical".to_string(),
        "high".to_string(),
        0,
        if_ab.to_string(),
        0,
        if_ba.to_string(),
        stored_link_key.to_string(),
        String::new(),
    )
}

#[test]
fn default_mode_is_rebuild() {
    assert_eq!(Mode::parse(None).unwrap(), Mode::Rebuild);
    assert_eq!(Mode::parse(Some("")).unwrap(), Mode::Rebuild);
    assert_eq!(Mode::parse(Some("rebuild")).unwrap(), Mode::Rebuild);
    assert_eq!(Mode::parse(Some("checksum")).unwrap(), Mode::Checksum);
    assert_eq!(Mode::parse(Some("dump-load")).unwrap(), Mode::DumpLoad);
    assert!(Mode::parse(Some("drop_all")).is_err());
}

#[test]
fn content_hash_is_order_independent_and_stable() {
    let a = synthetic_edge(
        "sr:host01.example.com",
        "sr:host02.example.com",
        "eth0",
        "eth1",
    );
    let b = synthetic_edge(
        "sr:host02.example.com",
        "sr:host03.example.com",
        "eth2",
        "eth3",
    );
    let forward = hash_canonical_edges(&[a.clone(), b.clone()]);
    let reverse = hash_canonical_edges(&[b, a]);
    assert_eq!(forward, reverse);
    assert_eq!(forward.len(), 64);
}

#[test]
fn matching_snapshots_pass() {
    let edges = [synthetic_edge(
        "sr:host01.example.com",
        "sr:host02.example.com",
        "eth0",
        "eth1",
    )];
    let age = snapshot_from_edges(&edges);
    let dgraph = snapshot_from_edges(&edges);
    let report = compare_snapshots(&age, &dgraph).expect("match");
    assert_eq!(report.age.edge_count, 1);
    assert_eq!(
        report.age.node_count, 2,
        "node count is the endpoints of canonical edges"
    );
}

#[test]
fn checksum_ignores_the_store_native_link_key() {
    // AGE stores `<local_interface_key>|<neighbor_interface_key>`; a Dgraph
    // node written before the key format changed carries the 4-part form.
    // Neither may reach the hash, or the checksum can never pass.
    let age_edges = [synthetic_edge(
        "sr:host01.example.com",
        "sr:host02.example.com",
        "eth0",
        "eth1",
    )];
    let dgraph_edges = records_from_canonical_edges(&[stored_dgraph_edge(
        "sr:host01.example.com",
        "sr:host02.example.com",
        "eth0",
        "eth1",
        "sr:host01.example.com|sr:host02.example.com|eth0|eth1",
    )]);
    assert_eq!(dgraph_edges[0].link_key, age_edges[0].link_key);
    compare_snapshots(
        &snapshot_from_edges(&age_edges),
        &snapshot_from_edges(&dgraph_edges),
    )
    .expect("identity is recomputed on both sides");
}

#[test]
fn missing_dgraph_edge_fails_checksum() {
    let age_edges = [
        synthetic_edge(
            "sr:host01.example.com",
            "sr:host02.example.com",
            "eth0",
            "eth1",
        ),
        synthetic_edge(
            "sr:host02.example.com",
            "sr:host03.example.com",
            "eth2",
            "eth3",
        ),
    ];
    let dgraph_edges = [synthetic_edge(
        "sr:host01.example.com",
        "sr:host02.example.com",
        "eth0",
        "eth1",
    )];
    let err = compare_snapshots(
        &snapshot_from_edges(&age_edges),
        &snapshot_from_edges(&dgraph_edges),
    )
    .expect_err("divergence");
    let message = err.to_string();
    assert!(message.contains("node_count"), "{message}");
    assert!(message.contains("edge_count"), "{message}");
    assert!(message.contains("content_hash"), "{message}");
}

#[test]
fn mapper_rows_are_a_fallback_evidence_source() {
    let rows = [
        MapperLinkRow {
            local_device_id: "sr:host01.example.com".into(),
            neighbor_device_id: "sr:host02.example.com".into(),
            protocol: "cdp".into(),
            local_if_name: "Gi1/0/1".into(),
            neighbor_if_name: "Gi1/0/2".into(),
        },
        MapperLinkRow {
            local_device_id: "switch.internal".into(),
            neighbor_device_id: "sr:host02.example.com".into(),
            protocol: "cdp".into(),
            local_if_name: String::new(),
            neighbor_if_name: String::new(),
        },
    ];
    let records = records_from_mapper_rows(&rows);
    assert_eq!(records.len(), 1, "only sr: <-> sr: pairs are canonical");
    assert_eq!(records[0].source, "sr:host01.example.com");
    assert_eq!(records[0].protocol, "cdp");
    assert_eq!(records[0].evidence_class, "direct");
    let writes = edge_writes_from_records(&records);
    assert_eq!(writes.len(), 1);
    assert_eq!(writes[0].link_key(), records[0].link_key);
}

#[test]
fn synthetic_lab_dump_parses() {
    let dump = parse_dump(
        br#"{
  "nodes": 2,
  "edges": [{
    "link_key": "sr:host01.example.com|sr:host02.example.com|eth0|eth1",
    "source": "sr:host01.example.com",
    "target": "sr:host02.example.com",
    "protocol": "lldp",
    "evidence_class": "direct-physical",
    "if_name_ab": "eth0",
    "if_name_ba": "eth1"
  }]
}"#,
    )
    .expect("dump");
    assert_eq!(dump.nodes, 2);
    assert_eq!(dump.edges.len(), 1);
    assert!(dump.edges[0].source.starts_with("sr:"));
}

#[test]
fn dump_load_is_refused_without_lab_flag() {
    let err = Mode::require_lab_dump_allowed().expect_err("refused");
    assert!(err.to_string().contains("lab-only"));
}
