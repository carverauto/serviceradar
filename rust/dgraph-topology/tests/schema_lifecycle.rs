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
use std::future::Future;
use std::io::Write;
use std::path::PathBuf;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{Duration, Instant};

use dgraph_client::DgraphClient;
use dgraph_migrate::{Mode, Outcome, run_with_client, verify};
use dgraph_topology::{DeviceWrite, EdgeWrite, PREDICATES, TYPES, TopologyClient, schema_spec};
use runfiles::Runfiles;
use serde::Deserialize;
use serviceradar_config_manager::{
    ConfigManager, DGRAPH_ADMIN_PASSWORD, Filesystem, Identity, fetch_ca_bundle,
};
use serviceradar_config_schema::DgraphTlsMode;
use serviceradar_secret_manager::{EnvironmentProvider, Manifest, Secret, SecretManager};

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
    let fixture = Fixture::ci();
    let mut ca_file = FixtureCa::create(&fixture.ca_bundle_url);
    let ca_path = ca_file.0.as_ref().expect("owned CA file");
    let admin_target = fixture.connection(0, fixture.admin_password.expose(), ca_path);
    // Upstream connection errors retain only parsed authority/structural
    // details. The migration connector's error also retains the full URL.
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
    // All fallible scratch setup and test assertions are inside the task. A
    // panic still returns control here for namespace deletion and verification.
    let ca_path = ca_path.clone();
    let mut task = tokio::spawn(async move {
        // Dgraph initializes each new namespace with this scratch credential.
        // The shared administrator credential is never changed.
        let target = fixture.connection(namespace, "password", &ca_path);
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

struct Fixture {
    authority: String,
    ca_bundle_url: String,
    admin_password: Secret,
}

impl Fixture {
    fn ci() -> Self {
        let identity = Identity::from_env().expect("typed fixture identity");
        assert_eq!(identity.to_string(), "ci", "only the CI fixture is allowed");
        let runfiles = Runfiles::create().expect("Bazel fixture runfiles");
        let path = runfiles
            .rlocation_from("serviceradar/config/environments/ci.binpb", "")
            .expect("declared CI config input");
        let bytes = std::fs::read(path).expect("read declared CI config");
        let manager = ConfigManager::load(&identity, &[("ci", &bytes)], &Filesystem)
            .expect("validated CI config");
        let config = manager.dgraph().expect("CI Dgraph config");
        assert_eq!(
            config
                .tls_mode
                .and_then(|mode| DgraphTlsMode::try_from(mode).ok()),
            Some(DgraphTlsMode::VerifyCa),
            "fixture connections must verify the Dgraph CA"
        );
        let host = config.host.as_deref().expect("CI Dgraph host");
        assert!(!host.contains(['@', '/', '?', '#']), "valid Dgraph host");
        let port = u16::try_from(config.port.expect("CI Dgraph port")).expect("valid Dgraph port");
        let authority = if host.parse::<std::net::Ipv6Addr>().is_ok() {
            format!("[{host}]:{port}")
        } else {
            format!("{host}:{port}")
        };
        let secrets = SecretManager::new(
            EnvironmentProvider::for_kind(identity.kind()),
            Manifest::new([DGRAPH_ADMIN_PASSWORD]),
        );
        Self {
            authority,
            ca_bundle_url: manager
                .dgraph_ca_bundle_url()
                .expect("CI Dgraph CA URL")
                .to_owned(),
            admin_password: secrets
                .resolve(DGRAPH_ADMIN_PASSWORD)
                .expect("typed CI Dgraph credential"),
        }
    }

    fn connection(&self, namespace: u64, password: &str, ca_path: &std::path::Path) -> String {
        format!(
            "dgraph://groot:{}@{}?sslmode=verify-ca&namespace={namespace}&sslrootcert={}",
            urlencoding::encode(password),
            self.authority,
            urlencoding::encode(ca_path.to_str().expect("CA path is UTF-8")),
        )
    }
}

struct FixtureCa(Option<PathBuf>);

impl FixtureCa {
    fn create(url: &str) -> Self {
        let pem = fetch_ca_bundle(url).expect("fixture CA bundle");
        static SEQUENCE: AtomicU64 = AtomicU64::new(0);
        let directory = std::env::var_os("TEST_TMPDIR")
            .map(PathBuf::from)
            .unwrap_or_else(std::env::temp_dir);
        let path = directory.join(format!(
            "dgraph-ca-{}-{}.crt",
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
        let written = file.write_all(&pem);
        drop(file);
        written.expect("write fixture CA");
        guard
    }

    fn remove(&mut self) -> std::io::Result<()> {
        if let Some(path) = &self.0 {
            std::fs::remove_file(path)?;
            if path.try_exists()? {
                return Err(std::io::Error::other("owned CA file remains after removal"));
            }
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
