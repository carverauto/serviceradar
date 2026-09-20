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

//! Resolving which Dgraph to talk to from the detected environment.
//!
//! Only LOCAL has a default. CI and CLUSTER must be told their host. A
//! default of localhost is harmless on a workstation and dangerous anywhere
//! else: a cluster migration that silently fell back to `127.0.0.1` would
//! report success having migrated nothing.

use crate::errors::MigrateError;
use crate::types::Environment;
use crate::utils::mode_env::read;

/// Host used for LOCAL when [`HOST_ENV`] is unset.
pub const LOCAL_HOST_DEFAULT: &str = "127.0.0.1";

/// Dgraph's gRPC port, used when [`PORT_ENV`] is unset.
pub const PORT_DEFAULT: &str = "9080";

/// Full `dgraph://` URL. Wins over host/port when set.
pub const URL_ENV: &str = "DGRAPH_URL";

/// Host used to assemble `dgraph://host:port`.
pub const HOST_ENV: &str = "DGRAPH_HOST";

/// Port used to assemble `dgraph://host:port`.
pub const PORT_ENV: &str = "DGRAPH_PORT";

/// Resolve the `dgraph://` connection string, reading the process environment.
///
/// # Errors
///
/// Returns [`MigrateError`] when a non-local environment has not been told
/// its host, or when the configured port is not a number.
pub fn resolve(env: Environment) -> Result<String, MigrateError> {
    resolve_from(env, read(URL_ENV), read(HOST_ENV), read(PORT_ENV))
}

/// The whole resolution rule, as a pure function.
///
/// # Errors
///
/// As [`resolve`].
pub fn resolve_from(
    env: Environment,
    url: Option<String>,
    host: Option<String>,
    port: Option<String>,
) -> Result<String, MigrateError> {
    if let Some(url) = url.filter(|value| !value.is_empty()) {
        return Ok(url);
    }

    let host = resolve_host(env, host)?;
    let port = resolve_port(port)?;
    Ok(format!("dgraph://{host}:{port}"))
}

fn resolve_host(env: Environment, configured: Option<String>) -> Result<String, MigrateError> {
    let configured = configured.filter(|value| !value.is_empty());
    match configured {
        Some(host) => Ok(host),
        None if env.allows_localhost_default() => Ok(LOCAL_HOST_DEFAULT.to_string()),
        None => Err(MigrateError::Endpoint(format!(
            "{HOST_ENV} is required in {env:?}"
        ))),
    }
}

fn resolve_port(configured: Option<String>) -> Result<u16, MigrateError> {
    let raw = configured
        .filter(|value| !value.is_empty())
        .unwrap_or_else(|| PORT_DEFAULT.to_string());
    raw.parse::<u16>()
        .map_err(|_| MigrateError::Endpoint(format!("invalid {PORT_ENV}: {raw}")))
}
