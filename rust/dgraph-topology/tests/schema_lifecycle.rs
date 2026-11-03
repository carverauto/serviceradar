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

//! Live schema lifecycle against a Dgraph fixture.
//!
//! Runs on the remote BuildBuddy runner against the typed CI Dgraph fixture.
//! The CI config is a declared Bazel input; credentials use SecretManager.
//! Compilation stays on RBE, while TestRunner runs beside the cluster fixture.
//!
//! Always uses a fresh Dgraph namespace so `remove` cannot touch another run's
//! predicates. `drop_all` is never called.

use std::collections::BTreeSet;
use std::time::{Duration, Instant};

use dgraph_migrate::{Mode, Outcome, run_with_client, verify};
use dgraph_topology::{
    DeviceWrite, EdgeKind, EdgeWrite, HopWrite, InterfaceWrite, MtrMetrics, PREDICATES, TYPES,
    TopologyClient, schema_spec,
};
use serde::Deserialize;

#[path = "support/fixture.rs"]
mod fixture;
use fixture::with_scratch;

#[tokio::test]
async fn apply_is_idempotent_remove_is_scoped_and_reapply_restores() {
    with_scratch(Duration::from_secs(300), |client, _target| async move {
        let spec = schema_spec();

        let before = verify(&client, spec).await.expect("verify empty");
        assert!(
            !before.is_complete(),
            "fresh namespace must not already have the topology schema"
        );
        assert_eq!(before.missing_predicates().len(), PREDICATES.len());
        assert_eq!(before.missing_types().len(), TYPES.len());

        let first = run_with_client(&client, spec, Mode::Migrate)
            .await
            .expect("first migrate");
        assert!(
            matches!(first, Outcome::Migrated(_)),
            "first migrate should apply, got {first:?}"
        );
        assert!(
            verify(&client, spec)
                .await
                .expect("verify after apply")
                .is_complete()
        );

        let second = run_with_client(&client, spec, Mode::Migrate)
            .await
            .expect("second migrate");
        assert_eq!(second, Outcome::AlreadyCurrent);

        client
            .set_schema("unrelated.foo: string .")
            .await
            .expect("foreign predicate");
        assert!(
            predicate_present(&client, "unrelated.foo")
                .await
                .expect("unrelated present"),
            "control predicate must exist before remove"
        );

        let removed = run_with_client(&client, spec, Mode::Deprovision)
            .await
            .expect("deprovision");
        assert_eq!(removed, Outcome::Deprovisioned);
        let after_remove = verify(&client, spec).await.expect("verify after remove");
        assert_eq!(after_remove.missing_predicates().len(), PREDICATES.len());
        assert_eq!(after_remove.missing_types().len(), TYPES.len());
        assert!(
            predicate_present(&client, "unrelated.foo")
                .await
                .expect("unrelated survived"),
            "remove must not drop predicates the spec does not own"
        );

        let restored = run_with_client(&client, spec, Mode::Migrate)
            .await
            .expect("restore");
        assert!(
            matches!(restored, Outcome::Migrated(_)),
            "re-apply after remove should migrate, got {restored:?}"
        );
        assert!(
            verify(&client, spec)
                .await
                .expect("verify restored")
                .is_complete()
        );
    })
    .await;
}

#[tokio::test]
async fn canonical_graph_pages_devices_and_edges_in_one_backend_snapshot() {
    with_scratch(Duration::from_secs(300), |client, _target| async move {
        run_with_client(&client, schema_spec(), Mode::Migrate)
            .await
            .expect("apply topology schema");
        let topology = TopologyClient::new(client);
        for index in 1..=258 {
            topology
                .upsert_device(
                    &DeviceWrite::new(format!("sr:host{index:04}.example.com"))
                        .with_hostname(format!("host{index:04}.example.com")),
                )
                .await
                .expect("write invented vertex");
        }
        topology
            .upsert_config_edge(&EdgeWrite::config_declared(
                "sr:host0001.example.com",
                "sr:host0002.example.com",
            ))
            .await
            .expect("write a noncanonical relation before the canonical pages");
        // The last vertex stays isolated. A ring among the others supplies
        // enough relations to cross the independent edge page boundary too.
        for index in 1..=257 {
            topology
                .upsert_canonical_edge(&EdgeWrite::canonical(
                    format!("sr:host{index:04}.example.com"),
                    format!("sr:host{:04}.example.com", index % 257 + 1),
                    "lldp",
                    "direct-physical",
                ))
                .await
                .expect("write invented canonical relation");
        }

        let started = Instant::now();
        let graph = topology
            .query_canonical_graph()
            .await
            .expect("read complete canonical graph from Dgraph");
        eprintln!(
            "canonical graph fixture: vertices={}, relations={}, query_elapsed_ms={}",
            graph.nodes().len(),
            graph.edges().len(),
            started.elapsed().as_millis()
        );
        assert_eq!(graph.nodes().len(), 258);
        assert_eq!(graph.edges().len(), 257);
        let expected_nodes: BTreeSet<_> = (1..=258)
            .map(|index| format!("sr:host{index:04}.example.com"))
            .collect();
        assert_eq!(
            graph
                .nodes()
                .iter()
                .map(|node| node.id().to_owned())
                .collect::<BTreeSet<_>>(),
            expected_nodes
        );
        let expected_edges: BTreeSet<_> = (1..=257)
            .map(|index| {
                (
                    format!("sr:host{index:04}.example.com"),
                    format!("sr:host{:04}.example.com", index % 257 + 1),
                )
            })
            .collect();
        assert_eq!(
            graph
                .edges()
                .iter()
                .map(|edge| (edge.source().to_owned(), edge.target().to_owned()))
                .collect::<BTreeSet<_>>(),
            expected_edges
        );
        let isolated = graph
            .nodes()
            .iter()
            .find(|node| node.id() == "sr:host0258.example.com")
            .expect("the isolated vertex must survive the canonical read");
        assert_eq!(isolated.hostname(), Some("host0258.example.com"));
        assert!(
            graph
                .edges()
                .iter()
                .all(|edge| { edge.source() != isolated.id() && edge.target() != isolated.id() })
        );
    })
    .await;
}

#[tokio::test]
async fn canonical_edges_are_rebuilt_in_batched_transactions() {
    with_scratch(Duration::from_secs(300), |client, _target| async move {
        run_with_client(&client, schema_spec(), Mode::Migrate)
            .await
            .expect("apply topology schema");
        let topology = TopologyClient::new(client);
        for index in 1..=451 {
            topology
                .upsert_device(&DeviceWrite::new(format!("sr:batch{index:04}.example.com")))
                .await
                .expect("write invented vertex");
        }
        let edges: Vec<EdgeWrite> = (1..=450)
            .map(|index| {
                EdgeWrite::canonical(
                    format!("sr:batch{index:04}.example.com"),
                    format!("sr:batch{:04}.example.com", index + 1),
                    "lldp",
                    "direct-physical",
                )
            })
            .collect();

        for chunk in edges.chunks(200) {
            topology
                .upsert_canonical_edges(chunk)
                .await
                .expect("upsert one batched chunk");
        }
        // A repeat of a chunk is harmless.
        topology
            .upsert_canonical_edges(&edges[..200])
            .await
            .expect("repeat a batched chunk");
        assert_eq!(
            topology.query_canonical_edges().await.expect("read").len(),
            450
        );

        let desired = &edges[..300];
        let stale = topology
            .stale_canonical_keys(desired)
            .await
            .expect("compute stale keys");
        assert_eq!(stale.len(), 150);
        for chunk in stale.chunks(64) {
            topology
                .delete_canonical_edges(chunk)
                .await
                .expect("delete one batched chunk");
        }
        // Deleting keys that are already gone is a no-op.
        topology
            .delete_canonical_edges(&stale[..10])
            .await
            .expect("repeat a delete chunk");

        let remaining: BTreeSet<String> = topology
            .query_canonical_edges()
            .await
            .expect("read")
            .iter()
            .map(|edge| edge.link_key().to_owned())
            .collect();
        let wanted: BTreeSet<String> = desired.iter().map(EdgeWrite::link_key).collect();
        assert_eq!(remaining, wanted);
        assert!(
            topology
                .stale_canonical_keys(desired)
                .await
                .expect("recompute stale keys")
                .is_empty()
        );
    })
    .await;
}

#[tokio::test]
async fn mtr_paths_return_their_measurements_newest_first() {
    with_scratch(Duration::from_secs(120), |client, _target| async move {
        run_with_client(&client, schema_spec(), Mode::Migrate)
            .await
            .expect("apply topology schema");
        let topology = TopologyClient::new(client);
        let agent = "sr:agent01.example.com";
        let far_hop = "198.51.100.7";
        topology
            .upsert_device(&DeviceWrite::new(agent))
            .await
            .expect("agent device");
        topology
            .upsert_hop(&HopWrite::new(far_hop))
            .await
            .expect("unresolved hop");
        topology
            .upsert_device(&DeviceWrite::new("sr:host02.example.com"))
            .await
            .expect("resolved hop device");

        let measured = MtrMetrics {
            avg_rtt_us: 4_250,
            loss_pct: 12.5,
            jitter_us: 310,
            from_hop: 1,
            to_hop: 2,
        };
        topology
            .upsert_mtr_path(
                &EdgeWrite::mtr_path(agent, far_hop, "agent-lab-1")
                    .with_last_seen("2030-01-02T00:00:00Z")
                    .with_mtr_metrics(measured),
            )
            .await
            .expect("newer path");
        topology
            .upsert_mtr_path(
                &EdgeWrite::mtr_path(agent, "sr:host02.example.com", "agent-lab-1")
                    .with_last_seen("2030-01-01T00:00:00Z"),
            )
            .await
            .expect("older path without measurements");
        topology
            .upsert_canonical_edge(&EdgeWrite::canonical(
                agent,
                "sr:host02.example.com",
                "lldp",
                "direct-physical",
            ))
            .await
            .expect("a canonical edge is not an MTR path");

        let paths = topology.query_mtr_paths(10).await.expect("read MTR paths");
        assert_eq!(paths.len(), 2, "only MTR_PATH edges: {paths:?}");
        let newest = &paths[0];
        assert_eq!(newest.source, agent);
        assert_eq!(newest.source_addr, "");
        assert_eq!(newest.target, format!("mtr:{far_hop}"));
        assert_eq!(newest.target_addr, far_hop);
        assert_eq!(newest.avg_rtt_us, 4_250);
        assert!((newest.loss_pct - 12.5).abs() < f64::EPSILON);
        assert_eq!(
            (newest.jitter_us, newest.from_hop, newest.to_hop),
            (310, 1, 2)
        );
        assert_eq!(newest.agent_id, "agent-lab-1");
        assert_eq!(paths[1].target, "sr:host02.example.com");
        assert_eq!(paths[1].avg_rtt_us, 0);

        assert_eq!(
            topology
                .query_mtr_paths(1)
                .await
                .expect("limited read")
                .len(),
            1
        );
    })
    .await;
}

#[tokio::test]
async fn device_neighborhood_resolves_peer_interfaces_from_connects_to() {
    with_scratch(Duration::from_secs(120), |client, _target| async move {
        run_with_client(&client, schema_spec(), Mode::Migrate)
            .await
            .expect("apply topology schema");
        let topology = TopologyClient::new(client);
        let switch = "sr:switch01.example.com";
        let router = "sr:router01.example.com";
        let server = "sr:server01.example.com";
        topology
            .upsert_device(
                &DeviceWrite::new(switch)
                    .with_hostname("switch01.example.com")
                    .with_ip("192.0.2.2"),
            )
            .await
            .expect("switch");
        topology
            .upsert_device(&DeviceWrite::new(router).with_hostname("router01.example.com"))
            .await
            .expect("router");
        topology
            .upsert_device(&DeviceWrite::new(server))
            .await
            .expect("server");
        for (key, device, name, index) in [
            ("sr:switch01.example.com/ge-0/0/1", switch, "ge-0/0/1", 1),
            ("sr:switch01.example.com/ge-0/0/2", switch, "ge-0/0/2", 2),
            ("sr:router01.example.com/xe-1/0/0", router, "xe-1/0/0", 7),
        ] {
            topology
                .upsert_interface(
                    &InterfaceWrite::new(key, device)
                        .with_name(name)
                        .with_if_index(index),
                )
                .await
                .expect("interface");
        }
        // Outbound evidence names the router's port; inbound evidence from the
        // server names the switch-facing port on the server, which has no
        // Interface vertex.
        topology
            .upsert_mapper_edge(
                &EdgeWrite::mapper_evidence(switch, router, EdgeKind::ConnectsTo, "lldp", "direct")
                    .with_interfaces("ge-0/0/1", 1, "xe-1/0/0", 0),
            )
            .await
            .expect("outbound evidence");
        topology
            .upsert_mapper_edge(
                &EdgeWrite::mapper_evidence(server, switch, EdgeKind::ConnectsTo, "lldp", "direct")
                    .with_interfaces("eth0", 2, "ge-0/0/2", 2),
            )
            .await
            .expect("inbound evidence");

        let graph = topology
            .query_device_neighborhood(switch, true)
            .await
            .expect("read neighborhood")
            .expect("the switch exists");
        assert_eq!(graph["device"]["id"], switch);
        assert_eq!(graph["device"]["hostname"], "switch01.example.com");
        let interface_ids: BTreeSet<_> = graph["interfaces"]
            .as_array()
            .expect("interfaces")
            .iter()
            .map(|iface| iface["id"].as_str().expect("id").to_owned())
            .collect();
        assert_eq!(
            interface_ids,
            BTreeSet::from([
                "sr:switch01.example.com/ge-0/0/1".to_owned(),
                "sr:switch01.example.com/ge-0/0/2".to_owned()
            ])
        );

        let peers = graph["peer_interfaces"].as_array().expect("peers");
        assert_eq!(peers.len(), 2, "{peers:?}");
        let router_port = peers
            .iter()
            .find(|peer| peer["owner_device_id"] == router)
            .expect("router peer");
        assert_eq!(router_port["id"], "sr:router01.example.com/xe-1/0/0");
        assert_eq!(router_port["ifindex"], 7);
        assert_eq!(
            router_port["owner_device"]["hostname"],
            "router01.example.com"
        );
        let server_port = peers
            .iter()
            .find(|peer| peer["owner_device_id"] == server)
            .expect("server peer");
        assert!(
            server_port["id"].is_null(),
            "no Interface vertex: {server_port}"
        );
        assert_eq!(server_port["name"], "eth0");
        for empty in ["collectors", "services", "targets", "device_capabilities"] {
            assert_eq!(graph[empty], serde_json::json!([]), "{empty}");
        }

        let without_topology = topology
            .query_device_neighborhood(switch, false)
            .await
            .expect("read without topology")
            .expect("the switch exists");
        assert_eq!(without_topology["interfaces"], serde_json::json!([]));
        assert_eq!(without_topology["peer_interfaces"], serde_json::json!([]));
        assert!(
            topology
                .query_device_neighborhood("sr:absent.example.com", true)
                .await
                .expect("read an absent device")
                .is_none()
        );
    })
    .await;
}

#[tokio::test]
async fn management_edges_are_stored_by_kind_and_stay_out_of_canonical_reads() {
    with_scratch(Duration::from_secs(120), |client, _target| async move {
        run_with_client(&client, schema_spec(), Mode::Migrate)
            .await
            .expect("apply topology schema");
        let topology = TopologyClient::new(client);
        let child = "sr:ap01.example.com";
        let controller = "sr:wlc01.example.com";
        for id in [child, controller] {
            topology
                .upsert_device(&DeviceWrite::new(id))
                .await
                .expect("device");
        }
        for (source, target, kind) in [
            (child, controller, EdgeKind::ManagedBy),
            (controller, child, EdgeKind::Manages),
        ] {
            topology
                .upsert_edge(&EdgeWrite::new(
                    source,
                    target,
                    kind,
                    "management",
                    "managed-by",
                    "management_device_v1",
                ))
                .await
                .expect("management edge");
        }
        topology
            .upsert_canonical_edge(&EdgeWrite::canonical(
                child,
                controller,
                "lldp",
                "direct-physical",
            ))
            .await
            .expect("canonical backbone between the same devices");

        let stored: BTreeSet<_> = topology
            .query_neighbourhood(child)
            .await
            .expect("read neighbourhood")
            .iter()
            .filter(|edge| edge.kind() != "CANONICAL_TOPOLOGY")
            .map(|edge| {
                (
                    edge.kind().to_owned(),
                    edge.edge().source().to_owned(),
                    edge.edge().target().to_owned(),
                )
            })
            .collect();
        assert_eq!(
            stored,
            BTreeSet::from([
                (
                    "MANAGED_BY".to_owned(),
                    child.to_owned(),
                    controller.to_owned()
                ),
                (
                    "MANAGES".to_owned(),
                    controller.to_owned(),
                    child.to_owned()
                ),
            ])
        );

        let graph = topology
            .query_canonical_graph()
            .await
            .expect("canonical graph");
        assert_eq!(
            graph
                .edges()
                .iter()
                .map(|edge| (edge.source().to_owned(), edge.target().to_owned()))
                .collect::<Vec<_>>(),
            vec![(child.to_owned(), controller.to_owned())],
            "only the canonical backbone is a canonical relation"
        );

        let view = topology
            .query_topology_view("2001-01-01T00:00:00Z")
            .await
            .expect("topology view");
        let view_kinds: BTreeSet<_> = view.edges().iter().map(|edge| edge.kind()).collect();
        assert_eq!(view_kinds, BTreeSet::from(["CANONICAL_TOPOLOGY"]));
    })
    .await;
}

#[derive(Debug, Deserialize)]
struct PredicateRow {
    predicate: String,
}

#[derive(Debug, Deserialize)]
struct PredicateResponse {
    #[serde(default)]
    schema: Vec<PredicateRow>,
}

async fn predicate_present(
    client: &dgraph_client::DgraphClient,
    name: &str,
) -> Result<bool, dgraph_migrate::MigrateError> {
    let query = format!("schema(pred: [{name}]) {{ type }}");
    let response = client
        .run_dql(query)
        .await
        .map_err(|err| dgraph_migrate::MigrateError::Schema(err.to_string()))?;
    let parsed: PredicateResponse = serde_json::from_slice(response.json())
        .map_err(|err| dgraph_migrate::MigrateError::Schema(err.to_string()))?;
    Ok(parsed.schema.iter().any(|row| row.predicate == name))
}
