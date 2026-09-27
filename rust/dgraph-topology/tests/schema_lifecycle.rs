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
//! Local default: `DgraphInstance::acquire()` starts `dgraph/standalone:v25.4.0`.
//! CI: `DGRAPH_TEST_STRATEGY=existing` plus host/port/sslmode/password pointing at
//! `dgraph-ci`. Never `demo`: product Helm embed is a later task.
//!
//! Always uses a fresh Dgraph namespace so `remove` cannot touch another run's
//! predicates. `drop_all` is never called.

use std::collections::BTreeSet;
use std::future::Future;
use std::io::Write;
use std::path::PathBuf;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{Duration, Instant};

use dgraph_client::DgraphClient;
use dgraph_client::utils_test::fixtures::fetch_ca_bundle;
use dgraph_client::utils_test::{DEFAULT_GROOT_PASSWORD, DgraphInstance};
use dgraph_migrate::{Mode, Outcome, run_with_client, verify};
use dgraph_topology::{DeviceWrite, EdgeWrite, PREDICATES, TYPES, TopologyClient, schema_spec};
use serde::Deserialize;

#[tokio::test]
async fn apply_is_idempotent_remove_is_scoped_and_reapply_restores() {
    with_scratch(|client| async move {
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
    with_scratch(|client| async move {
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

async fn with_scratch<F, Fut>(test: F)
where
    F: FnOnce(DgraphClient) -> Fut + Send + 'static,
    Fut: Future<Output = ()> + Send + 'static,
{
    let instance = DgraphInstance::acquire().expect("Dgraph fixture");
    eprintln!("{}", instance.describe());
    let mut ca_file = FixtureCa::create(&instance);
    let sslroot = ca_file
        .0
        .as_ref()
        .map(|path| path.to_string_lossy().into_owned());
    let mut base_params = Vec::new();
    if let Some(path) = sslroot.as_deref() {
        base_params.push(("sslrootcert", path));
    }
    let password = instance.admin_password().expect("fixture admin credential");
    // Upstream connection errors retain only parsed authority/structural
    // details. The migration connector's error also retains the full URL.
    let admin_target = instance.connection_string_as("groot", &password, &base_params);
    let admin = tokio::time::timeout(
        Duration::from_secs(30),
        DgraphClient::connect(&admin_target),
    )
    .await
    .expect("fixture administrator connection timed out")
    .expect("connect fixture administrator");
    let namespace = tokio::time::timeout(Duration::from_secs(30), admin.create_namespace())
        .await
        .expect("namespace allocation timed out; server ownership is unknown")
        .expect("allocate owned scratch namespace");
    assert_ne!(
        namespace, 0,
        "never use the shared admin namespace as scratch"
    );
    let namespace_id = namespace.to_string();
    let mut params = base_params;
    params.push(("namespace", namespace_id.as_str()));
    let target = instance.connection_string_as("groot", DEFAULT_GROOT_PASSWORD, &params);

    // All fallible scratch setup and test assertions are inside the task. A
    // panic still returns control here for namespace deletion and verification.
    let mut task = tokio::spawn(async move {
        let client = DgraphClient::connect(&target)
            .await
            .expect("connect owned scratch namespace");
        test(client).await;
    });
    let outcome = match tokio::time::timeout(Duration::from_secs(300), &mut task).await {
        Ok(result) => Some(result),
        Err(_) => {
            task.abort();
            let _ = task.await;
            None
        }
    };

    let mut cleanup_errors = Vec::new();
    match tokio::time::timeout(Duration::from_secs(30), admin.drop_namespace(namespace)).await {
        Ok(Ok(())) => {}
        Ok(Err(error)) => cleanup_errors.push(format!("drop owned namespace: {error}")),
        Err(_) => cleanup_errors.push("drop owned namespace timed out".into()),
    }
    match tokio::time::timeout(Duration::from_secs(30), admin.list_namespaces()).await {
        Ok(Ok(namespaces)) if namespaces.contains_key(&namespace) => {
            cleanup_errors.push("owned namespace remains after deletion".into());
        }
        Ok(Ok(_)) => eprintln!("owned Dgraph namespace absence verified"),
        Ok(Err(error)) => cleanup_errors.push(format!("verify namespace absence: {error}")),
        Err(_) => cleanup_errors.push("verify namespace absence timed out".into()),
    }
    if let Err(error) = ca_file.remove() {
        cleanup_errors.push(format!("remove owned CA file: {error}"));
    }
    if !cleanup_errors.is_empty() {
        eprintln!(
            "Dgraph fixture cleanup failed for owned namespace {namespace}: {}",
            cleanup_errors.join("; ")
        );
    }
    match outcome {
        Some(Ok(())) => assert!(cleanup_errors.is_empty(), "scratch cleanup failed"),
        Some(Err(error)) if error.is_panic() => std::panic::resume_unwind(error.into_panic()),
        Some(Err(error)) => panic!("scratch test task failed: {error}"),
        None => panic!("scratch test exceeded its five-minute deadline"),
    }
}

struct FixtureCa(Option<PathBuf>);

impl FixtureCa {
    fn create(instance: &DgraphInstance) -> Self {
        let Some(url) = instance.ca_bundle_url() else {
            return Self(None);
        };
        let pem = fetch_ca_bundle(url).expect("fixture CA bundle");
        static SEQUENCE: AtomicU64 = AtomicU64::new(0);
        let path = std::env::temp_dir().join(format!(
            "dgraph-ca-{}-{}-{}.crt",
            instance.run_id().as_str(),
            std::process::id(),
            SEQUENCE.fetch_add(1, Ordering::Relaxed),
        ));
        let mut options = std::fs::OpenOptions::new();
        options.create_new(true).write(true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            options.mode(0o600);
        }
        let mut file = options.open(&path).expect("create owned CA file");
        let guard = Self(Some(path));
        file.write_all(pem.as_bytes()).expect("write fixture CA");
        guard
    }

    fn remove(&mut self) -> std::io::Result<()> {
        if let Some(path) = &self.0 {
            std::fs::remove_file(path)?;
            self.0 = None;
        }
        Ok(())
    }
}

impl Drop for FixtureCa {
    fn drop(&mut self) {
        let _ = self.remove();
    }
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
