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

use std::env;

use tokio_postgres::error::SqlState;
use tokio_postgres::{Client, NoTls};

use crate::evidence::{MapperLinkRow, canonical_link_key};
use crate::tls::postgres_connector;
use crate::{CanonicalEdgeRecord, CanonicalSnapshot, MigratorError, snapshot_from_edges};

pub struct PostgresSource {
    client: Client,
    graph_name: String,
}

impl PostgresSource {
    pub async fn connect() -> Result<Self, MigratorError> {
        let client = connect_client().await?;
        client
            .batch_execute(
                "SELECT set_config('search_path', 'ag_catalog, platform, public', false)",
            )
            .await
            .map_err(|err| MigratorError::Postgres(err.to_string()))?;
        let graph_name =
            env::var("AGE_GRAPH_NAME").unwrap_or_else(|_| "platform_graph".to_string());
        Ok(Self { client, graph_name })
    }

    /// Relational source of truth for both halves of the Job. AGE's canonical
    /// edges are the graph; `runtime_topology_links` is a row-capped God View
    /// cache and would silently truncate a large fleet into a destructive
    /// rebuild. Mapper evidence is the fallback for a deployment whose AGE
    /// graph holds no canonical edges yet.
    ///
    /// `rebuild` writes this set and `checksum` compares it, so the two must
    /// read it through the same call: a checksum that always read AGE would
    /// compare an empty AGE against a Dgraph the rebuild had just filled from
    /// mapper evidence, and fail the Helm hook in exactly the state the
    /// fallback exists for.
    ///
    /// Deduplicated on `topo.link_key` here rather than in either caller, so
    /// the rebuild upserts exactly what the checksum counts.
    pub async fn evidence_records(&self) -> Result<Vec<CanonicalEdgeRecord>, MigratorError> {
        let canonical = self.age_canonical_edges().await?;
        if !canonical.is_empty() {
            return Ok(crate::dedupe_by_link_key(&canonical));
        }
        let mapper = self.mapper_rows().await?;
        Ok(crate::dedupe_by_link_key(&crate::records_from_mapper_rows(
            &mapper,
        )))
    }

    pub async fn relational_snapshot(&self) -> Result<CanonicalSnapshot, MigratorError> {
        let edges = self.evidence_records().await?;
        Ok(snapshot_from_edges(&edges))
    }

    async fn mapper_rows(&self) -> Result<Vec<MapperLinkRow>, MigratorError> {
        let sql = "
            SELECT local_device_id, neighbor_device_id, protocol,
                   coalesce(local_if_name, ''), coalesce(neighbor_port_id, '')
            FROM platform.mapper_topology_links
            WHERE local_device_id LIKE 'sr:%'
              AND neighbor_device_id LIKE 'sr:%'
              AND local_device_id <> neighbor_device_id
        ";
        match self.client.query(sql, &[]).await {
            Ok(rows) => Ok(rows
                .into_iter()
                .map(|row| MapperLinkRow {
                    local_device_id: row.get(0),
                    neighbor_device_id: row.get(1),
                    protocol: row.get(2),
                    local_if_name: row.get(3),
                    neighbor_if_name: row.get(4),
                })
                .collect()),
            Err(err) if missing_relation(&err) => Ok(Vec::new()),
            Err(err) => Err(postgres_error(&err)),
        }
    }

    async fn age_canonical_edges(&self) -> Result<Vec<CanonicalEdgeRecord>, MigratorError> {
        let graph = self.graph_name.replace('\'', "''");
        // `r.link_key` is deliberately not read: AGE and Dgraph store
        // different native key formats, so identity is recomputed here in the
        // Dgraph format on both sides of the checksum.
        //
        // The WHERE clause is the canonical set, and must stay identical to
        // `RuntimeTopologyProjection.canonical_edge_predicate/3`. Rebuild is
        // destructive, so a wider or narrower set here deletes the edges core's
        // dual-write just copied in.
        let sql = format!(
            "
            SELECT src::text, dst::text, protocol::text,
                   evidence_class::text, if_ab::text, if_ba::text
            FROM ag_catalog.cypher('{graph}', $$
              MATCH (a:Device)-[r:CANONICAL_TOPOLOGY]->(b:Device)
              WHERE a.id IS NOT NULL
                AND b.id IS NOT NULL
                AND a.id STARTS WITH 'sr:'
                AND b.id STARTS WITH 'sr:'
                AND (
                  toUpper(coalesce(r.relation_type, '')) IN ['CONNECTS_TO', 'LOGICAL_PEER', 'HOSTED_ON']
                  OR (coalesce(r.relation_type, '') = '' AND toLower(coalesce(r.evidence_class, '')) IN ['direct', 'direct-physical', 'direct-logical', 'hosted-virtual'])
                )
              RETURN a.id, b.id,
                coalesce(r.protocol, ''),
                coalesce(r.evidence_class, ''),
                coalesce(r.local_if_name, coalesce(r.if_name_ab, '')),
                coalesce(r.neighbor_if_name, coalesce(r.if_name_ba, ''))
            $$) AS (src agtype, dst agtype, protocol agtype,
                    evidence_class agtype, if_ab agtype, if_ba agtype)
            "
        );
        match self.client.query(&sql, &[]).await {
            Ok(rows) => Ok(rows
                .into_iter()
                .filter_map(|row| {
                    let source = agtype_string(&row.get::<_, String>(0))?;
                    let target = agtype_string(&row.get::<_, String>(1))?;
                    let if_ab = agtype_string(&row.get::<_, String>(4)).unwrap_or_default();
                    let if_ba = agtype_string(&row.get::<_, String>(5)).unwrap_or_default();
                    Some(CanonicalEdgeRecord {
                        link_key: canonical_link_key(&source, &target, &if_ab, &if_ba),
                        protocol: agtype_string(&row.get::<_, String>(2))
                            .unwrap_or_else(|| "unknown".into()),
                        evidence_class: agtype_string(&row.get::<_, String>(3))
                            .unwrap_or_else(|| "direct".into()),
                        source,
                        target,
                        if_name_ab: if_ab,
                        if_name_ba: if_ba,
                    })
                })
                .collect()),
            Err(err) if missing_relation(&err) => Ok(Vec::new()),
            Err(err) => Err(postgres_error(&err)),
        }
    }
}

fn spawn_connection<F>(connection: F)
where
    F: std::future::Future<Output = Result<(), tokio_postgres::Error>> + Send + 'static,
{
    tokio::spawn(async move {
        if let Err(err) = connection.await {
            eprintln!("postgres connection error: {err}");
        }
    });
}

async fn connect_client() -> Result<Client, MigratorError> {
    let config = pg_config()?;
    let ssl_mode = env::var("CNPG_SSL_MODE")
        .or_else(|_| env::var("PGSSLMODE"))
        .unwrap_or_else(|_| "disable".to_string());
    if ssl_mode.eq_ignore_ascii_case("disable") {
        let (client, connection) = config
            .connect(NoTls)
            .await
            .map_err(|err| MigratorError::Postgres(err.to_string()))?;
        spawn_connection(connection);
        return Ok(client);
    }

    let ca_path =
        env::var("CNPG_CA_FILE").unwrap_or_else(|_| "/etc/serviceradar/certs/root.pem".into());
    let ca_pem = std::fs::read(&ca_path)
        .map_err(|err| MigratorError::Postgres(format!("read CNPG_CA_FILE {ca_path}: {err}")))?;
    let cert_path = env::var("CNPG_CERT_FILE").ok();
    let key_path = env::var("CNPG_KEY_FILE").ok();
    let client_cert = match (cert_path, key_path) {
        (Some(cert), Some(key)) => Some((
            std::fs::read(&cert).map_err(|err| MigratorError::Io(err.to_string()))?,
            std::fs::read(&key).map_err(|err| MigratorError::Io(err.to_string()))?,
        )),
        _ => None,
    };
    let server_name = env::var("CNPG_TLS_SERVER_NAME").ok();
    let tls = postgres_connector(
        &ca_pem,
        client_cert.as_ref().map(|(cert, _)| cert.as_slice()),
        client_cert.as_ref().map(|(_, key)| key.as_slice()),
        server_name.as_deref(),
    )?;
    let (client, connection) = config
        .connect(tls)
        .await
        .map_err(|err| MigratorError::Postgres(err.to_string()))?;
    spawn_connection(connection);
    Ok(client)
}

fn pg_config() -> Result<tokio_postgres::Config, MigratorError> {
    if let Ok(url) = env::var("DATABASE_URL") {
        return url
            .parse()
            .map_err(|err: tokio_postgres::Error| MigratorError::Postgres(err.to_string()));
    }
    let host = env::var("CNPG_HOST")
        .map_err(|_| MigratorError::MissingConfig("CNPG_HOST or DATABASE_URL".into()))?;
    let port = env::var("CNPG_PORT")
        .ok()
        .and_then(|value| value.parse().ok())
        .unwrap_or(5432);
    let database = env::var("CNPG_DATABASE").unwrap_or_else(|_| "serviceradar".into());
    let user = read_secret("CNPG_USERNAME", "CNPG_USERNAME_FILE")
        .or_else(|_| read_secret("CNPG_APP_USER", "CNPG_APP_USER_FILE"))?;
    let password = read_secret("CNPG_PASSWORD", "CNPG_PASSWORD_FILE")
        .or_else(|_| read_secret("CNPG_APP_PASSWORD", "CNPG_APP_PASSWORD_FILE"))
        .unwrap_or_default();
    let mut config = tokio_postgres::Config::new();
    config.host(&host);
    config.port(port);
    config.user(&user);
    config.password(&password);
    config.dbname(&database);
    Ok(config)
}

fn read_secret(value_env: &str, file_env: &str) -> Result<String, MigratorError> {
    if let Ok(value) = env::var(value_env)
        && !value.is_empty()
    {
        return Ok(value);
    }
    if let Ok(path) = env::var(file_env) {
        let value = std::fs::read_to_string(&path)
            .map_err(|err| MigratorError::Io(format!("{file_env} {path}: {err}")))?;
        return Ok(value.trim().to_string());
    }
    Err(MigratorError::MissingConfig(value_env.into()))
}

/// SQLSTATEs that mean "this evidence source is not in the database", which
/// both readers degrade to an empty set for.
///
/// `42P01` is a missing `platform.mapper_topology_links`. `3F000` covers both a
/// missing `ag_catalog` schema (AGE not installed) and the error AGE itself
/// raises for a graph that has not been created yet. Every other SQLSTATE is a
/// real failure and must fail the Job.
///
/// Classification reads the SQLSTATE rather than the error text because
/// tokio-postgres renders every server error as the literal `db error`, with
/// the server's own message reachable only through `DbError`. A match on the
/// rendered string can never fire.
#[must_use]
pub fn missing_relation_sqlstate(code: &SqlState) -> bool {
    *code == SqlState::UNDEFINED_TABLE || *code == SqlState::INVALID_SCHEMA_NAME
}

fn missing_relation(err: &tokio_postgres::Error) -> bool {
    err.code().is_some_and(missing_relation_sqlstate)
}

/// Carry the SQLSTATE and the server's message, so a failure an operator has to
/// act on does not surface as the bare `db error` tokio-postgres displays.
fn postgres_error(err: &tokio_postgres::Error) -> MigratorError {
    match err.as_db_error() {
        Some(db) => MigratorError::Postgres(format!("{}: {}", db.code().code(), db.message())),
        None => MigratorError::Postgres(err.to_string()),
    }
}

fn agtype_string(raw: &str) -> Option<String> {
    let trimmed = raw.trim().trim_matches('"').trim();
    if trimmed.is_empty() || trimmed == "null" {
        None
    } else {
        Some(trimmed.to_string())
    }
}
