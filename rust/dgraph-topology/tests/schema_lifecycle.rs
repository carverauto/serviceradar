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

use dgraph_client::utils_test::fixtures::fetch_ca_bundle;
use dgraph_client::utils_test::{DEFAULT_GROOT_PASSWORD, DgraphInstance};
use dgraph_migrate::{Mode, Outcome, connect, run_with_client, verify};
use dgraph_topology::{PREDICATES, TYPES, schema_spec};
use serde::Deserialize;

#[tokio::test]
async fn apply_is_idempotent_remove_is_scoped_and_reapply_restores() {
    let instance = DgraphInstance::acquire().expect("dgraph fixture");
    eprintln!("{}", instance.describe());

    let ca_file = instance.ca_bundle_url().map(|url| {
        let pem = fetch_ca_bundle(url).expect("CA bundle");
        let path =
            std::env::temp_dir().join(format!("dgraph-ca-{}.crt", instance.run_id().as_str()));
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

    let ns = ns0
        .create_namespace()
        .await
        .expect("scratch namespace for this run");
    let ns_id = ns.to_string();
    let mut ns_params = base_params.clone();
    ns_params.push(("namespace", ns_id.as_str()));

    let client =
        connect(&instance.connection_string_as("groot", DEFAULT_GROOT_PASSWORD, &ns_params))
            .await
            .unwrap_or_else(|err| panic!("connect scratch namespace {ns}: {err}"));

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

    ns0.drop_namespace(ns)
        .await
        .expect("drop scratch namespace");
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
