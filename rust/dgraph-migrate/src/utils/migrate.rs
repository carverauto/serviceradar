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

//! The migration itself, as a library operation.
//!
//! Nothing here prints, and nothing here exits. Everything it learns is
//! returned as an [`Outcome`] or a [`MigrateError`].

use dgraph_client::DgraphClient;

use crate::errors::MigrateError;
use crate::types::{Environment, Mode, Outcome, SchemaSpec};
use crate::utils::endpoint;
use crate::utils::mode_env::{ENV_ENV, read};
use crate::utils::schema;

/// Resolve the environment's Dgraph, connect, and carry out `mode`.
///
/// # Errors
///
/// Returns [`MigrateError`] if the endpoint cannot be resolved, the cluster
/// cannot be reached, or the schema operation fails or does not take effect.
pub async fn run(spec: SchemaSpec, mode: Mode, env: Environment) -> Result<Outcome, MigrateError> {
    let target = endpoint::resolve(env)?;
    let client = connect(&target).await?;
    run_with_client(&client, spec, mode).await
}

/// Read `DGRAPH_ENV` / mode env vars, then [`run`].
///
/// # Errors
///
/// As [`run`], plus mode/environment selection failures.
pub async fn run_from_env(spec: SchemaSpec) -> Result<Outcome, MigrateError> {
    let env = Environment::parse(read(ENV_ENV).as_deref());
    let mode = Mode::from_env(env).map_err(MigrateError::Mode)?;
    let env = env.ok_or_else(|| {
        MigrateError::Endpoint(format!("{ENV_ENV} must be LOCAL, CI, or CLUSTER"))
    })?;
    run(spec, mode, env).await
}

/// As [`run`], against a client the caller already has.
///
/// # Errors
///
/// As [`run`], minus the endpoint and connection failures.
pub async fn run_with_client(
    client: &DgraphClient,
    spec: SchemaSpec,
    mode: Mode,
) -> Result<Outcome, MigrateError> {
    match mode {
        Mode::Status => Ok(Outcome::Status(schema::verify(client, spec).await?)),
        Mode::Migrate => migrate(client, spec).await,
        Mode::Deprovision => deprovision(client, spec).await,
    }
}

/// Connect to `target`.
///
/// # Errors
///
/// Returns [`MigrateError::Connect`] when the cluster is unreachable.
pub async fn connect(target: &str) -> Result<DgraphClient, MigrateError> {
    DgraphClient::connect(target)
        .await
        .map_err(|err| MigrateError::Connect(target.to_string(), err.to_string()))
}

async fn migrate(client: &DgraphClient, spec: SchemaSpec) -> Result<Outcome, MigrateError> {
    let before = schema::verify(client, spec).await?;
    if before.is_complete() {
        return Ok(Outcome::AlreadyCurrent);
    }

    schema::apply(client, spec).await?;

    let after = schema::verify(client, spec).await?;
    if after.is_complete() {
        Ok(Outcome::Migrated(before))
    } else {
        Err(MigrateError::StillIncomplete(after))
    }
}

async fn deprovision(client: &DgraphClient, spec: SchemaSpec) -> Result<Outcome, MigrateError> {
    schema::remove(client, spec).await?;

    let after = schema::verify(client, spec).await?;
    let fully_gone = after.missing_predicates().len() == spec.predicates().len()
        && after.missing_types().len() == spec.types().len();

    if fully_gone {
        Ok(Outcome::Deprovisioned)
    } else {
        Err(MigrateError::StillPresent(after))
    }
}
