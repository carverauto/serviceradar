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

//! Synthetic dual-write / rebuild / prune against a Dgraph fixture.
//!
//! Same acquire path as `schema_lifecycle`: Docker standalone locally,
//! `DGRAPH_TEST_STRATEGY=existing` against dgraph-ci in CI.

use dgraph_client::utils_test::fixtures::fetch_ca_bundle;
use dgraph_client::utils_test::{DEFAULT_GROOT_PASSWORD, DgraphInstance};
use dgraph_migrate::{Mode, connect, run_with_client};

use crate::{DeviceWrite, EdgeWrite, TopologyClient, schema_spec};

#[tokio::test]
async fn rebuild_is_idempotent_and_stale_mtr_prunes() {
    let client = connected_scratch().await;

    let edges = [EdgeWrite::canonical(
        "sr:host01.example.com",
        "sr:host02.example.com",
        "lldp",
        "direct-physical",
    )
    .with_interfaces("eth0", 1, "eth1", 2)];

    for endpoint in ["sr:host01.example.com", "sr:host02.example.com"] {
        client
            .upsert_device(&DeviceWrite::new(endpoint))
            .await
            .expect("device");
    }

    client
        .rebuild_canonical(&edges)
        .await
        .expect("first rebuild");
    let first = client
        .query_canonical_edges()
        .await
        .expect("query after first");
    assert_eq!(first.len(), 1, "synthetic canonical edge must land");
    assert_eq!(first[0].source(), "sr:host01.example.com");
    assert_eq!(first[0].target(), "sr:host02.example.com");

    client
        .rebuild_canonical(&edges)
        .await
        .expect("second rebuild");
    let second = client
        .query_canonical_edges()
        .await
        .expect("query after second");
    assert_eq!(
        second.len(),
        first.len(),
        "rebuild against unchanged evidence is a no-op on link_key cardinality"
    );

    let mtr = EdgeWrite::mtr_path(
        "sr:host01.example.com",
        "sr:host02.example.com",
        "agent-lab-1",
    )
    .with_last_seen("2000-01-01T00:00:00Z");
    client.upsert_mtr_path(&mtr).await.expect("mtr path");
    let pruned = client
        .prune_stale("2001-01-01T00:00:00Z", &["MTR_PATH".to_string()])
        .await
        .expect("prune");
    assert!(pruned >= 1, "stale MTR_PATH must prune, got {pruned}");
    let after_prune = client
        .query_canonical_edges()
        .await
        .expect("canonical after prune");
    assert_eq!(
        after_prune.len(),
        1,
        "canonical edges must survive MTR prune"
    );
}

async fn connected_scratch() -> TopologyClient {
    let instance = DgraphInstance::acquire().expect("dgraph fixture");
    eprintln!("{}", instance.describe());

    let ca_file = instance.ca_bundle_url().map(|url| {
        let pem = fetch_ca_bundle(url).expect("CA bundle");
        let path = std::env::temp_dir().join(format!(
            "dgraph-ca-cutover-{}.crt",
            instance.run_id().as_str()
        ));
        std::fs::write(&path, pem).expect("write CA");
        path
    });
    let sslroot = ca_file
        .as_ref()
        .map(|path| path.to_string_lossy().into_owned());
    let mut base_params: Vec<(&str, &str)> = Vec::new();
    if let Some(path) = sslroot.as_deref() {
        base_params.push(("sslrootcert", path));
    }

    let admin = instance
        .admin_password()
        .expect("groot password for namespace 0");
    let ns0 = connect(&instance.connection_string_as("groot", &admin, &base_params))
        .await
        .expect("connect namespace 0");
    let ns = ns0.create_namespace().await.expect("scratch namespace");
    let ns_id = ns.to_string();
    let mut ns_params = base_params.clone();
    ns_params.push(("namespace", ns_id.as_str()));
    let url = instance.connection_string_as("groot", DEFAULT_GROOT_PASSWORD, &ns_params);
    let client = TopologyClient::connect(&url)
        .await
        .unwrap_or_else(|err| panic!("connect scratch namespace {ns}: {err}"));
    run_with_client(client.dgraph(), schema_spec(), Mode::Migrate)
        .await
        .expect("apply topology schema");
    client
}
