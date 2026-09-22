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
    dedupe_by_link_key, edge_writes_from_records, hash_canonical_edges, missing_relation_sqlstate,
    parse_dump, records_from_canonical_edges, records_from_mapper_rows, snapshot_from_edges,
};
use dgraph_topology::CanonicalEdge;
use tokio_postgres::error::SqlState;

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

/// What `query_canonical_edges` returns for an edge the rebuild just upserted.
fn readback_of(write: &dgraph_topology::EdgeWrite) -> CanonicalEdge {
    CanonicalEdge::new(
        write.source().to_string(),
        write.target().to_string(),
        0,
        0,
        0,
        0,
        0,
        false,
        write.protocol().to_string(),
        write.evidence_class().to_string(),
        write.confidence_tier().to_string(),
        0,
        write.if_name_ab().to_string(),
        0,
        write.if_name_ba().to_string(),
        write.link_key(),
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

/// `mapper_topology_links` is unique on a key that includes `protocol`, so one
/// Cisco link seen by both LLDP and CDP is two rows. Dgraph keys canonical
/// edges on `topo.link_key`, which does not carry protocol, so the rebuild
/// upserts both onto one node. Counting or hashing the two separately compares
/// a multiset against that set and fails the checksum on every helm upgrade.
#[test]
fn one_link_discovered_by_two_protocols_is_one_canonical_edge() {
    let rows = [
        MapperLinkRow {
            local_device_id: "sr:host01.example.com".into(),
            neighbor_device_id: "sr:host02.example.com".into(),
            protocol: "lldp".into(),
            local_if_name: "Gi1/0/1".into(),
            neighbor_if_name: "Gi1/0/2".into(),
        },
        MapperLinkRow {
            local_device_id: "sr:host01.example.com".into(),
            neighbor_device_id: "sr:host02.example.com".into(),
            protocol: "cdp".into(),
            local_if_name: "Gi1/0/1".into(),
            neighbor_if_name: "Gi1/0/2".into(),
        },
    ];
    let records = records_from_mapper_rows(&rows);
    assert_eq!(records.len(), 2, "premise: the two rows are distinct");
    assert_eq!(
        records[0].link_key, records[1].link_key,
        "premise: they collapse onto one Dgraph node"
    );

    let deduped = dedupe_by_link_key(&records);
    assert_eq!(deduped.len(), 1);

    // What the rebuild writes and what the checksum compares must be the same
    // set, or the post-upgrade hook fails in exactly this state.
    let writes = edge_writes_from_records(&deduped);
    assert_eq!(writes.len(), 1);
    let dgraph_readback = records_from_canonical_edges(&[readback_of(&writes[0])]);
    compare_snapshots(
        &snapshot_from_edges(&deduped),
        &snapshot_from_edges(&dgraph_readback),
    )
    .expect("the relational set and the Dgraph set must agree");
}

#[test]
fn dedupe_by_link_key_does_not_depend_on_row_order() {
    let a = synthetic_edge("sr:host01.example.com", "sr:host02.example.com", "a", "b");
    let mut b = a.clone();
    b.protocol = "cdp".to_string();

    assert_eq!(
        dedupe_by_link_key(&[a.clone(), b.clone()]),
        dedupe_by_link_key(&[b, a]),
        "the surviving record must not depend on the order the database returned"
    );
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

/// A fresh install runs the migrator Job before any AGE graph or mapper table
/// exists, and an absent evidence source has to degrade to an empty set rather
/// than fail the Helm release. The deciding signal is the SQLSTATE: every
/// server error tokio-postgres reports renders as the literal `db error`, so a
/// classifier keyed on the error text matches nothing and the degrade never
/// happens.
#[test]
fn absent_evidence_relations_are_classified_by_sqlstate() {
    // No platform.mapper_topology_links yet.
    assert!(missing_relation_sqlstate(&SqlState::from_code("42P01")));
    // No ag_catalog schema (AGE absent), and AGE's own "graph does not exist".
    assert!(missing_relation_sqlstate(&SqlState::from_code("3F000")));
}

/// The degrade is only for an absent relation. Anything else -- a renamed
/// column, a revoked grant, a rejected password -- is a real failure that must
/// fail the Job instead of rebuilding Dgraph from an empty evidence set.
#[test]
fn other_database_errors_still_fail_the_job() {
    for code in ["42703", "42501", "28P01", "57014", "53300"] {
        assert!(
            !missing_relation_sqlstate(&SqlState::from_code(code)),
            "SQLSTATE {code} must not degrade to an empty evidence set"
        );
    }
}
