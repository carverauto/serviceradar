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

//! Applying, verifying and removing a [`crate::SchemaSpec`].
//!
//! Removal never uses `drop_all`. That would take unrelated predicates and
//! every node in the graph with it. [`remove`] drops exactly the predicates
//! and types named in the spec.

use dgraph_client::DgraphClient;
use serde::Deserialize;

use crate::errors::MigrateError;
use crate::types::{SchemaReport, SchemaSpec};

/// Apply the spec schema.
///
/// Idempotent: Dgraph's `alter` merges a schema rather than replacing it.
///
/// # Errors
///
/// Returns [`MigrateError::Schema`] if the cluster refuses the alteration.
pub async fn apply(client: &DgraphClient, spec: SchemaSpec) -> Result<(), MigrateError> {
    client
        .set_schema(spec.schema())
        .await
        .map_err(|err| MigrateError::Schema(err.to_string()))
}

/// Report which parts of the spec the cluster is missing.
///
/// # Errors
///
/// Returns an error only when the cluster cannot be queried. An incomplete
/// schema is a successful result.
pub async fn verify(client: &DgraphClient, spec: SchemaSpec) -> Result<SchemaReport, MigrateError> {
    let present_predicates = query_predicates(client, spec.predicates()).await?;
    let present_types = query_types(client, spec.types()).await?;

    let missing_predicates = spec
        .predicates()
        .iter()
        .filter(|name| !present_predicates.iter().any(|found| found == *name))
        .map(|name| (*name).to_string())
        .collect();

    let missing_types = spec
        .types()
        .iter()
        .filter(|name| !present_types.iter().any(|found| found == *name))
        .map(|name| (*name).to_string())
        .collect();

    Ok(SchemaReport::new(missing_predicates, missing_types))
}

/// Remove exactly the predicates and types the spec owns.
///
/// Data stored under those predicates goes with them; anything else in the
/// cluster is untouched. Dropping something already absent is not an error.
///
/// # Errors
///
/// Returns [`MigrateError::Schema`] on the first drop the cluster refuses.
pub async fn remove(client: &DgraphClient, spec: SchemaSpec) -> Result<(), MigrateError> {
    // Types first. A type definition only names predicates, so dropping it
    // first leaves no window in which a type refers to a predicate that has
    // already gone.
    for name in spec.types() {
        client
            .drop_type(*name)
            .await
            .map_err(|err| MigrateError::Schema(err.to_string()))?;
    }
    for name in spec.predicates() {
        client
            .drop_predicate(*name)
            .await
            .map_err(|err| MigrateError::Schema(err.to_string()))?;
    }
    Ok(())
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

#[derive(Debug, Deserialize)]
struct TypeRow {
    name: String,
}

#[derive(Debug, Deserialize)]
struct TypeResponse {
    #[serde(default)]
    types: Vec<TypeRow>,
}

async fn query_predicates(
    client: &DgraphClient,
    predicates: &[&str],
) -> Result<Vec<String>, MigrateError> {
    if predicates.is_empty() {
        return Ok(Vec::new());
    }
    let query = format!("schema(pred: [{}]) {{ type }}", predicates.join(", "));
    let response = client
        .run_dql(query)
        .await
        .map_err(|err| MigrateError::Schema(err.to_string()))?;
    let parsed: PredicateResponse = serde_json::from_slice(response.json())
        .map_err(|err| MigrateError::Schema(err.to_string()))?;
    Ok(parsed.schema.into_iter().map(|row| row.predicate).collect())
}

async fn query_types(client: &DgraphClient, types: &[&str]) -> Result<Vec<String>, MigrateError> {
    if types.is_empty() {
        return Ok(Vec::new());
    }
    let query = format!("schema(type: [{}]) {{}}", types.join(", "));
    let response = client
        .run_dql(query)
        .await
        .map_err(|err| MigrateError::Schema(err.to_string()))?;
    let parsed: TypeResponse = serde_json::from_slice(response.json())
        .map_err(|err| MigrateError::Schema(err.to_string()))?;
    Ok(parsed.types.into_iter().map(|row| row.name).collect())
}
