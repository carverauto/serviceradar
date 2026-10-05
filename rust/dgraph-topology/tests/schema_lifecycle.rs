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
use dgraph_topology::{DeviceWrite, EdgeWrite, PREDICATES, TYPES, TopologyClient, schema_spec};
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
