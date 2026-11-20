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

use std::future::Future;
use std::time::Duration;

use dgraph_client::{DgraphClient, DgraphError, DgraphErrorEnum};
use serde::Deserialize;
use tokio::time::{Instant, sleep};

use crate::errors::MigrateError;
use crate::types::{SchemaReport, SchemaSpec};

/// Apply the spec schema.
///
/// Idempotent: Dgraph's `alter` merges a schema rather than replacing it.
///
/// # Errors
///
/// Returns [`MigrateError::Schema`] if the cluster refuses the alteration, or
/// is still building indexes after a bounded wait of one minute.
pub async fn apply(client: &DgraphClient, spec: SchemaSpec) -> Result<(), MigrateError> {
    alter_when_idle(|| client.set_schema(spec.schema())).await
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
/// Returns [`MigrateError::Schema`] on the first drop the cluster refuses, or
/// that is still refused for indexing after a bounded wait of one minute.
pub async fn remove(client: &DgraphClient, spec: SchemaSpec) -> Result<(), MigrateError> {
    // Types first. A type definition only names predicates, so dropping it
    // first leaves no window in which a type refers to a predicate that has
    // already gone.
    for name in spec.types() {
        alter_when_idle(|| client.drop_type(*name)).await?;
    }
    for name in spec.predicates() {
        alter_when_idle(|| client.drop_predicate(*name)).await?;
    }
    Ok(())
}

/// How long one schema operation waits for Dgraph to finish building indexes
/// before it fails.
const INDEXING_WAIT: Duration = Duration::from_secs(60);

/// First pause between attempts refused for indexing; it doubles up to
/// [`INDEXING_BACKOFF_MAX`].
const INDEXING_BACKOFF_FIRST: Duration = Duration::from_millis(250);

/// Longest pause between attempts refused for indexing.
const INDEXING_BACKOFF_MAX: Duration = Duration::from_secs(5);

/// Run one `alter`, repeating it while Dgraph refuses it for an index build.
///
/// An Alpha refuses every `alter`, schema change and drop alike, while an index
/// build is running on it, whichever namespace or earlier `alter` started that
/// build. The refused call changed nothing, so repeating it is safe. Every
/// other failure returns at once.
async fn alter_when_idle<F, Fut>(mut alter: F) -> Result<(), MigrateError>
where
    F: FnMut() -> Fut,
    Fut: Future<Output = Result<(), DgraphError>>,
{
    let deadline = Instant::now() + INDEXING_WAIT;
    let mut backoff = INDEXING_BACKOFF_FIRST;
    loop {
        match alter().await {
            Ok(()) => return Ok(()),
            Err(err) if indexing_in_progress(&err) => {
                let now = Instant::now();
                if now >= deadline {
                    return Err(MigrateError::Schema(format!(
                        "Dgraph was still building indexes after {}s: {err}",
                        INDEXING_WAIT.as_secs()
                    )));
                }
                // The last pause ends at the deadline, so the final attempt
                // runs there rather than giving up early.
                sleep(backoff.min(deadline - now)).await;
                backoff = (backoff * 2).min(INDEXING_BACKOFF_MAX);
            }
            Err(err) => return Err(MigrateError::Schema(err.to_string())),
        }
    }
}

/// Dgraph sends this refusal with gRPC code `Unknown`, so its sentinel text is
/// the only signal that tells it apart from a rejected schema.
fn indexing_in_progress(err: &DgraphError) -> bool {
    matches!(
        err.kind(),
        DgraphErrorEnum::Rpc { message, .. } if message.contains("errIndexingInProgress")
    )
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

#[cfg(test)]
mod tests {
    use std::cell::Cell;

    use dgraph_client::DgraphError;
    use tokio::time::Instant;

    use super::{INDEXING_WAIT, alter_when_idle};
    use crate::errors::MigrateErrorEnum;

    /// The refusal as Dgraph sends it. gRPC code 2 is `Unknown`.
    fn indexing() -> DgraphError {
        DgraphError::Rpc(2.into(), "errIndexingInProgress. Please retry".to_string())
    }

    #[tokio::test(start_paused = true)]
    async fn an_alter_refused_for_indexing_runs_again_once_indexing_ends() {
        let attempts = Cell::new(0_u32);
        let result = alter_when_idle(|| {
            attempts.set(attempts.get() + 1);
            let refused = attempts.get() <= 2;
            async move { if refused { Err(indexing()) } else { Ok(()) } }
        })
        .await;

        assert_eq!(result, Ok(()));
        assert_eq!(attempts.get(), 3);
    }

    #[tokio::test(start_paused = true)]
    async fn indexing_that_outlasts_the_wait_fails_and_says_why() {
        let started = Instant::now();
        let attempts = Cell::new(0_u32);
        let result = alter_when_idle(|| {
            attempts.set(attempts.get() + 1);
            async { Err(indexing()) }
        })
        .await;

        let err = result.expect_err("an alter refused for the whole wait must fail");
        match err.kind() {
            MigrateErrorEnum::Schema(reason) => {
                assert!(
                    reason.contains("still building indexes")
                        && reason.contains("errIndexingInProgress"),
                    "the failure must name the indexing wait, got {reason:?}"
                );
            }
            other => panic!("unexpected classification: {other:?}"),
        }
        assert!(started.elapsed() >= INDEXING_WAIT);
        assert!(attempts.get() > 1, "an indexing refusal must be retried");
    }

    #[tokio::test(start_paused = true)]
    async fn any_other_refusal_is_returned_without_another_attempt() {
        let attempts = Cell::new(0_u32);
        let result = alter_when_idle(|| {
            attempts.set(attempts.get() + 1);
            async { Err(DgraphError::Rpc(2.into(), "schema is invalid".to_string())) }
        })
        .await;

        assert!(matches!(
            result.expect_err("a rejected schema must fail").kind(),
            MigrateErrorEnum::Schema(reason) if reason.contains("schema is invalid")
        ));
        assert_eq!(attempts.get(), 1);
    }
}
