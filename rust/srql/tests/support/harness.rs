use axum::{
    body::{self, Body},
    http::{self, Request, StatusCode},
    Router,
};
use serde::Serialize;
use serde_json::Value;
use srql::{config::AppConfig, query::QueryRequest, server::Server};
use std::sync::Once;
use std::{
    fs,
    future::Future,
    net::SocketAddr,
    path::{Path, PathBuf},
    process::{Command, Stdio},
    sync::{Mutex, OnceLock},
    time::Duration,
};
use testcontainers::{clients::Cli, GenericImage};
use tokio::{
    task::JoinHandle,
    time::{sleep, Duration as TokioDuration},
};
use tokio_postgres::{config::Host, error::SqlState, Client, Config as PgConfig, NoTls};
use tower::ServiceExt;

const API_KEY: &str = "test-api-key";
const CNPG_IMAGE: &str = "ghcr.io/carverauto/serviceradar-cnpg";
const CNPG_TAG: &str = "16.6.0-sr2";
const CNPG_IMAGE_REF: &str = "ghcr.io/carverauto/serviceradar-cnpg:16.6.0-sr2";
const CNPG_ARCHIVE: &str = "/opt/cnpg_image.tar";
const DB_CONNECT_RETRIES: usize = 240;
const DB_CONNECT_DELAY_MS: u64 = 250;
const REMOTE_FIXTURE_LOCK_ID: i64 = 4_216_042;

static CNPG_BUILD_STATE: OnceLock<Mutex<bool>> = OnceLock::new();
static TRACING_INIT: Once = Once::new();

const BOOTSTRAP_SCRIPT: &str = r#"set -euo pipefail
cat <<'EOS' >/tmp/bootstrap.sh
#!/bin/bash
set -euo pipefail
export PATH=/usr/lib/postgresql/16/bin:$PATH
initdb -D /tmp/pgdata >/tmp/initdb.log
cat <<'CONF' >> /tmp/pgdata/postgresql.conf
shared_preload_libraries = 'timescaledb,age'
listen_addresses = '*'
max_connections = 50
CONF
cat <<'HBA' > /tmp/pgdata/pg_hba.conf
host all all 0.0.0.0/0 trust
host all all ::/0 trust
HBA
exec postgres -D /tmp/pgdata -c logging_collector=off
EOS
chmod +x /tmp/bootstrap.sh
exec /tmp/bootstrap.sh
"#;

const AGE_GRAPH_BOOTSTRAP_SQL: &str = r#"
SET LOCAL search_path = ag_catalog, public, "$user";
DO $$
BEGIN
    BEGIN
        PERFORM ag_catalog.create_graph('serviceradar');
    EXCEPTION
        WHEN others THEN NULL;
    END;

    BEGIN
        EXECUTE format('GRANT USAGE ON SCHEMA %I TO PUBLIC', 'serviceradar');
        EXECUTE format('GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA %I TO PUBLIC', 'serviceradar');
    EXCEPTION
        WHEN insufficient_privilege THEN NULL;
        WHEN others THEN NULL;
    END;

    BEGIN
        GRANT USAGE ON SCHEMA ag_catalog TO PUBLIC;
        GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA ag_catalog TO PUBLIC;
    EXCEPTION
        WHEN insufficient_privilege THEN NULL;
        WHEN others THEN NULL;
    END;

    BEGIN
        PERFORM ag_catalog.create_vlabel('serviceradar', 'Device');
    EXCEPTION
        WHEN others THEN NULL;
    END;
    BEGIN
        PERFORM ag_catalog.create_vlabel('serviceradar', 'Collector');
    EXCEPTION
        WHEN others THEN NULL;
    END;
    BEGIN
        PERFORM ag_catalog.create_vlabel('serviceradar', 'Service');
    EXCEPTION
        WHEN others THEN NULL;
    END;
    BEGIN
        PERFORM ag_catalog.create_vlabel('serviceradar', 'Interface');
    EXCEPTION
        WHEN others THEN NULL;
    END;
    BEGIN
        PERFORM ag_catalog.create_vlabel('serviceradar', 'Capability');
    EXCEPTION
        WHEN others THEN NULL;
    END;

    BEGIN
        PERFORM ag_catalog.create_elabel('serviceradar', 'HOSTS_SERVICE');
    EXCEPTION
        WHEN others THEN NULL;
    END;
    BEGIN
        PERFORM ag_catalog.create_elabel('serviceradar', 'TARGETS');
    EXCEPTION
        WHEN others THEN NULL;
    END;
    BEGIN
        PERFORM ag_catalog.create_elabel('serviceradar', 'HAS_INTERFACE');
    EXCEPTION
        WHEN others THEN NULL;
    END;
    BEGIN
        PERFORM ag_catalog.create_elabel('serviceradar', 'REPORTED_BY');
    EXCEPTION
        WHEN others THEN NULL;
    END;
    BEGIN
        PERFORM ag_catalog.create_elabel('serviceradar', 'PROVIDES_CAPABILITY');
    EXCEPTION
        WHEN others THEN NULL;
    END;

    PERFORM * FROM ag_catalog.cypher('serviceradar', $_cypher$
        MERGE (d:Device {id: 'device-alpha', hostname: 'alpha-edge'})
        MERGE (c:Collector {id: 'serviceradar:agent:agent-1'})
        MERGE (svc:Service {id: 'serviceradar:service:ssh@agent-1', type: 'ssh'})
        MERGE (iface:Interface {id: 'device-alpha/eth0', name: 'eth0'})
        MERGE (cap:Capability {type: 'snmp'})
        MERGE (d)-[:HAS_INTERFACE]->(iface)
        MERGE (d)-[:PROVIDES_CAPABILITY]->(cap)
        MERGE (c)-[:HOSTS_SERVICE]->(svc)
        MERGE (svc)-[:TARGETS]->(d)
        MERGE (d)-[:REPORTED_BY]->(c)
    $_cypher$) AS (result agtype);
END $$;

CREATE OR REPLACE FUNCTION public.age_device_neighborhood(
    p_device_id text,
    p_collector_owned_only boolean DEFAULT false,
    p_include_topology boolean DEFAULT true
) RETURNS jsonb
LANGUAGE plpgsql
AS $$
DECLARE
    cypher_sql text;
    cypher_result ag_catalog.agtype;
    include_topology text := CASE WHEN coalesce(p_include_topology, true) THEN 'true' ELSE 'false' END;
    collector_only text := CASE WHEN coalesce(p_collector_owned_only, false) THEN 'true' ELSE 'false' END;
BEGIN
    PERFORM set_config('search_path', 'ag_catalog,pg_catalog,"$user",public', false);

    cypher_sql := format($cypher$
        WITH %s::boolean AS include_topology, %s::boolean AS collector_only
        MATCH (c:Collector {id: %L})
        OPTIONAL MATCH (c)-[:REPORTED_BY]->(parentCol:Collector)
        OPTIONAL MATCH (devAlias:Device {id: %L})-[:REPORTED_BY]->(parentFromAlias:Collector)
        OPTIONAL MATCH (childCol:Collector)-[:REPORTED_BY]->(c)
        OPTIONAL MATCH (childDev:Device)-[:REPORTED_BY]->(c)
            WHERE childDev.id STARTS WITH 'serviceradar:'
        WITH c, include_topology,
             collect(DISTINCT parentCol) + collect(DISTINCT parentFromAlias) AS parent_collectors,
             collect(DISTINCT childCol) AS child_collectors,
             collect(DISTINCT childDev.id) AS child_dev_ids
        WITH c, include_topology, parent_collectors, child_collectors,
             CASE WHEN size(child_dev_ids) = 0 THEN [NULL] ELSE child_dev_ids END AS child_dev_ids_safe
        UNWIND child_dev_ids_safe AS child_dev_id
        OPTIONAL MATCH (aliasCol:Collector {id: child_dev_id})
        WITH c, include_topology,
             parent_collectors,
             child_collectors,
             collect(DISTINCT aliasCol) AS alias_child_collectors
        WITH c, include_topology,
             [col IN parent_collectors WHERE col IS NOT NULL] AS parent_collectors,
             [col IN (child_collectors + alias_child_collectors) WHERE col IS NOT NULL] AS child_collectors,
             [c] + [col IN (child_collectors + alias_child_collectors) WHERE col IS NOT NULL | col] AS host_collectors
        UNWIND host_collectors AS host_col
        OPTIONAL MATCH (host_col)-[:HOSTS_SERVICE]->(svc:Service)
        OPTIONAL MATCH (svc)-[:TARGETS]->(t:Device)
        OPTIONAL MATCH (svc)-[:PROVIDES_CAPABILITY]->(svcCap:Capability)
        OPTIONAL MATCH (reported:Device)-[:REPORTED_BY]->(host_col)
        WITH c, include_topology, parent_collectors, child_collectors,
             collect(DISTINCT CASE WHEN svc IS NOT NULL THEN {service: properties(svc), collector_id: host_col.id, collector_owned: true} ELSE NULL END) AS services_output_raw,
             collect(DISTINCT t) AS service_targets,
             collect(DISTINCT svcCap) AS service_caps,
             collect(DISTINCT reported) AS reported_devices
        WITH c, include_topology, parent_collectors, child_collectors, services_output_raw, service_targets, service_caps, reported_devices,
             CASE WHEN size(service_targets + reported_devices) = 0 THEN [NULL] ELSE service_targets + reported_devices END AS combined_targets
        UNWIND combined_targets AS tgt
        WITH c, include_topology, parent_collectors, child_collectors, services_output_raw, service_caps,
             collect(DISTINCT tgt) AS all_targets
        RETURN {
            device: properties(c),
            collectors: [col IN (parent_collectors + child_collectors) WHERE col IS NOT NULL | properties(col)],
            services: [s IN services_output_raw WHERE s IS NOT NULL | s],
            targets: [tgt IN all_targets WHERE tgt IS NOT NULL | properties(tgt)],
            interfaces: [],
            peer_interfaces: [],
            device_capabilities: [],
            service_capabilities: [cap IN service_caps WHERE cap IS NOT NULL | properties(cap)]
        } AS result
    $cypher$, include_topology, collector_only, p_device_id, p_device_id);

    EXECUTE 'SELECT result FROM ag_catalog.cypher(''serviceradar'', ' ||
            chr(36) || chr(36) || cypher_sql || chr(36) || chr(36) ||
            ') AS (result ag_catalog.agtype)'
    INTO cypher_result;

    IF cypher_result IS NULL OR cypher_result::text = 'null' THEN
        cypher_sql := format($cypher$
            WITH %s::boolean AS include_topology, %s::boolean AS collector_only
            MATCH (d:Device {id: %L})
            OPTIONAL MATCH (d)-[:REPORTED_BY]->(col:Collector)
            OPTIONAL MATCH (col)-[:HOSTS_SERVICE]->(svc:Service)
            OPTIONAL MATCH (svc)-[:TARGETS]->(t:Device)
            OPTIONAL MATCH (svc)-[:PROVIDES_CAPABILITY]->(svcCap:Capability)
            OPTIONAL MATCH (d)-[:PROVIDES_CAPABILITY]->(dcap:Capability)
            OPTIONAL MATCH (d)-[:HAS_INTERFACE]->(iface:Interface)
            OPTIONAL MATCH (iface)-[:CONNECTS_TO]->(peer:Interface)
            WITH d, include_topology, collector_only,
                 collect(DISTINCT col) AS collectors,
                 collect(DISTINCT CASE WHEN svc IS NOT NULL AND t IS NOT NULL AND t.id = d.id AND col IS NOT NULL THEN {
                     service: properties(svc),
                     collector_id: col.id,
                     collector_owned: col IS NOT NULL
                 } ELSE NULL END) AS services_output_raw,
                 collect(DISTINCT CASE WHEN svc IS NOT NULL AND t IS NOT NULL AND t.id = d.id AND col IS NOT NULL THEN col ELSE NULL END) AS host_collectors_raw,
                 collect(DISTINCT CASE WHEN t IS NOT NULL AND t.id <> d.id THEN properties(t) ELSE NULL END) AS target_props_raw,
                 collect(DISTINCT iface) AS interfaces,
                 collect(DISTINCT peer) AS peers,
                 collect(DISTINCT dcap) AS device_caps,
                 collect(DISTINCT svcCap) AS service_caps
            WITH d, include_topology, collector_only, collectors, target_props_raw, interfaces, peers, device_caps, service_caps,
                 [c IN host_collectors_raw WHERE c IS NOT NULL] AS host_collectors,
                 [s IN services_output_raw WHERE s IS NOT NULL] AS services_output
            WITH d, include_topology, collector_only, collectors, services_output, target_props_raw, interfaces, peers, device_caps, service_caps, host_collectors,
                 CASE WHEN size(host_collectors) > 0 THEN host_collectors ELSE collectors END AS collector_list,
                 (size(host_collectors) > 0 OR size([c IN collectors WHERE c IS NOT NULL]) > 0) AS has_collector,
                 [tgt IN target_props_raw WHERE tgt IS NOT NULL | tgt] AS target_props
            WITH d, include_topology, collector_only, services_output, target_props, interfaces, peers, device_caps, service_caps, has_collector,
                 CASE WHEN size(collector_list) = 0 THEN [NULL] ELSE collector_list END AS collector_list_safe
            UNWIND collector_list_safe AS base_col
            OPTIONAL MATCH (parentCol:Collector)<-[:REPORTED_BY]-(base_col)
            WITH d, include_topology, collector_only, services_output, target_props, interfaces, peers, device_caps, service_caps, has_collector,
                 collect(DISTINCT base_col) AS collector_list_dedup,
                 collect(DISTINCT parentCol) AS parent_collectors
            WITH d, include_topology, collector_only, services_output, target_props, interfaces, peers, device_caps, service_caps,
                 collector_list_dedup + parent_collectors AS combined_collectors,
                 (has_collector OR size([p IN parent_collectors WHERE p IS NOT NULL]) > 0) AS has_any_collector
            WHERE NOT collector_only OR has_any_collector
            RETURN {
                device: properties(d),
                collectors: [c IN combined_collectors WHERE c IS NOT NULL | properties(c)],
                services: services_output,
                targets: target_props,
                interfaces: CASE WHEN include_topology THEN [i IN interfaces WHERE i IS NOT NULL | properties(i)] ELSE [] END,
                peer_interfaces: CASE WHEN include_topology THEN [p IN peers WHERE p IS NOT NULL | properties(p)] ELSE [] END,
                device_capabilities: [cap IN device_caps WHERE cap IS NOT NULL | properties(cap)],
                service_capabilities: [cap IN service_caps WHERE cap IS NOT NULL | properties(cap)]
            } AS result
        $cypher$, include_topology, collector_only, p_device_id);

        EXECUTE 'SELECT result FROM ag_catalog.cypher(''serviceradar'', ' ||
                chr(36) || chr(36) || cypher_sql || chr(36) || chr(36) ||
                ') AS (result ag_catalog.agtype)'
        INTO cypher_result;
    END IF;

    IF cypher_result IS NULL OR cypher_result::text = 'null' THEN
        cypher_sql := format($cypher$
            WITH %s::boolean AS include_topology, %s::boolean AS collector_only
            MATCH (svc:Service {id: %L})
            OPTIONAL MATCH (col:Collector)-[:HOSTS_SERVICE]->(svc)
            OPTIONAL MATCH (svc)-[:TARGETS]->(t:Device)
            OPTIONAL MATCH (svc)-[:PROVIDES_CAPABILITY]->(svcCap:Capability)
            WITH svc, include_topology, collector_only,
                 collect(DISTINCT col) AS collectors,
                 collect(DISTINCT t) AS targets,
                 collect(DISTINCT svcCap) AS service_caps
            WITH svc, include_topology, collector_only,
                 CASE WHEN size(collectors) = 0 THEN [NULL] ELSE collectors END AS collectors_list,
                 CASE WHEN size(targets) = 0 THEN [NULL] ELSE targets END AS targets_list,
                 service_caps
            UNWIND collectors_list AS base_col
            OPTIONAL MATCH (parentCol:Collector)<-[:REPORTED_BY]-(base_col)
            UNWIND targets_list AS tgt
            WITH svc, include_topology, collector_only, service_caps,
                 collect(DISTINCT base_col) AS collectors,
                 collect(DISTINCT parentCol) AS parent_collectors,
                 collect(DISTINCT tgt) AS targets_flat
            WITH svc, include_topology, collector_only,
                 collectors + parent_collectors AS combined_collectors,
                 targets_flat,
                 service_caps,
                 size([c IN (collectors + parent_collectors) WHERE c IS NOT NULL]) > 0 AS has_collector
            WHERE NOT collector_only OR has_collector
            RETURN {
                device: properties(svc),
                collectors: [c IN combined_collectors WHERE c IS NOT NULL | properties(c)],
                services: [{
                    service: properties(svc),
                    collector_id: CASE WHEN size([c IN combined_collectors WHERE c IS NOT NULL]) > 0 THEN (combined_collectors[0].id) ELSE NULL END,
                    collector_owned: size([c IN combined_collectors WHERE c IS NOT NULL]) > 0
                }],
                targets: [tgt IN targets_flat WHERE tgt IS NOT NULL | properties(tgt)],
                interfaces: [],
                peer_interfaces: [],
                device_capabilities: [],
                service_capabilities: [cap IN service_caps WHERE cap IS NOT NULL | properties(cap)]
            } AS result
        $cypher$, include_topology, collector_only, p_device_id);

        EXECUTE 'SELECT result FROM ag_catalog.cypher(''serviceradar'', ' ||
                chr(36) || chr(36) || cypher_sql || chr(36) || chr(36) ||
                ') AS (result ag_catalog.agtype)'
        INTO cypher_result;
    END IF;

    RETURN (cypher_result::text)::jsonb;
EXCEPTION
    WHEN undefined_function THEN
        RETURN NULL;
END;
$$;
"#;

/// Runs a test closure against a fully bootstrapped SRQL instance backed by the seeded Postgres fixture.
pub async fn with_srql_harness<F, Fut>(test: F)
where
    F: FnOnce(SrqlTestHarness) -> Fut,
    Fut: Future<Output = ()>,
{
    TRACING_INIT.call_once(|| {
        let _ = tracing_subscriber::fmt::try_init();
    });

    if let Some(remote_config) =
        RemoteFixtureConfig::from_env().expect("failed to read remote fixture config")
    {
        run_with_remote_fixture(remote_config, test).await;
        return;
    }

    run_with_local_fixture(test).await;
}

async fn run_with_local_fixture<F, Fut>(test: F)
where
    F: FnOnce(SrqlTestHarness) -> Fut,
    Fut: Future<Output = ()>,
{
    ensure_cnpg_image().expect("failed to prepare CNPG image for SRQL harness");

    let docker = Cli::default();
    let image = GenericImage::new(CNPG_IMAGE, CNPG_TAG)
        .with_exposed_port(5432)
        .with_entrypoint("bash");
    let container = docker.run((image, vec!["-lc".into(), BOOTSTRAP_SCRIPT.into()]));
    let port = container.get_host_port_ipv4(5432);
    let database_url = format!("postgres://postgres@127.0.0.1:{port}/postgres?sslmode=disable");

    seed_fixture_database(&database_url)
        .await
        .expect("failed to seed fixture database");

    let config = test_config(database_url);
    let age_available = check_age_available(&config.database_url)
        .await
        .unwrap_or(false);
    let server = Server::new(config)
        .await
        .expect("failed to boot SRQL server for harness");
    let router = server.router();

    let harness = SrqlTestHarness {
        router,
        api_key: API_KEY.to_string(),
        age_available,
    };

    test(harness).await;
}

async fn run_with_remote_fixture<F, Fut>(config: RemoteFixtureConfig, test: F)
where
    F: FnOnce(SrqlTestHarness) -> Fut,
    Fut: Future<Output = ()>,
{
    log_connection_details("SRQL_TEST_DATABASE_URL", &config.database_url);
    log_connection_details("SRQL_TEST_ADMIN_URL", &config.admin_url);

    let guard = RemoteFixtureGuard::acquire(&config)
        .await
        .expect("failed to acquire remote fixture lock");
    guard
        .reset_database(&config)
        .await
        .expect("failed to reset remote fixture database");

    seed_fixture_database(&config.database_url)
        .await
        .expect("failed to seed fixture database");

    let app_config = test_config(config.database_url.clone());
    let age_available = check_age_available(&config.database_url)
        .await
        .unwrap_or(false);
    let server = Server::new(app_config)
        .await
        .expect("failed to boot SRQL server for remote harness");
    let router = server.router();

    let harness = SrqlTestHarness {
        router,
        api_key: API_KEY.to_string(),
        age_available,
    };

    test(harness).await;

    drop(guard);
}

fn test_config(database_url: String) -> AppConfig {
    AppConfig {
        listen_addr: SocketAddr::from(([127, 0, 0, 1], 0)),
        database_url,
        max_pool_size: 5,
        pg_ssl_root_cert: None,
        api_key: Some(API_KEY.to_string()),
        api_key_kv_key: None,
        allowed_origins: None,
        default_limit: 100,
        max_limit: 500,
        request_timeout: Duration::from_secs(30),
        rate_limit_max_requests: 120,
        rate_limit_window: Duration::from_secs(60),
    }
}

async fn seed_fixture_database(database_url: &str) -> anyhow::Result<()> {
    let mut attempts = 0usize;
    let (client, connection) = loop {
        match tokio_postgres::connect(database_url, NoTls).await {
            Ok(parts) => break parts,
            Err(err) => {
                if attempts >= DB_CONNECT_RETRIES {
                    return Err(err.into());
                }
                attempts += 1;
                sleep(TokioDuration::from_millis(DB_CONNECT_DELAY_MS)).await;
            }
        }
    };
    tokio::spawn(async move {
        if let Err(err) = connection.await {
            eprintln!("fixture database connection closed with error: {err}");
        }
    });

    ensure_extension(&client, "timescaledb").await?;
    ensure_extension(&client, "age").await?;
    let schema_sql = load_fixture("schema.sql")?;
    let seed_sql = load_fixture("seed.sql")?;
    client.batch_execute(&schema_sql).await?;
    client.batch_execute(&seed_sql).await?;
    Ok(())
}

async fn ensure_extension(client: &Client, name: &str) -> anyhow::Result<()> {
    let create_sql = format!("CREATE EXTENSION IF NOT EXISTS {};", quote_ident(name));
    match client.batch_execute(&create_sql).await {
        Ok(_) => Ok(()),
        Err(err) => {
            if err.code() == Some(&SqlState::INSUFFICIENT_PRIVILEGE) {
                if extension_exists(client, name).await? {
                    eprintln!(
                        "[srql-test] skipping {} extension install due to insufficient privileges (already installed)",
                        name
                    );
                    Ok(())
                } else {
                    Err(err.into())
                }
            } else {
                Err(err.into())
            }
        }
    }
}

async fn extension_exists(client: &Client, name: &str) -> anyhow::Result<bool> {
    let row = client
        .query_opt("SELECT 1 FROM pg_extension WHERE extname = $1", &[&name])
        .await?;
    Ok(row.is_some())
}

#[derive(Clone)]
pub struct SrqlTestHarness {
    router: Router,
    api_key: String,
    age_available: bool,
}

impl SrqlTestHarness {
    pub async fn query(&self, request: QueryRequest) -> http::Response<Body> {
        self.request("/api/query", &request, true).await
    }

    #[allow(dead_code)]
    pub async fn query_without_api_key(&self, request: QueryRequest) -> http::Response<Body> {
        self.request("/api/query", &request, false).await
    }

    async fn request<T>(
        &self,
        path: &str,
        payload: &T,
        include_api_key: bool,
    ) -> http::Response<Body>
    where
        T: Serialize,
    {
        let mut builder = Request::builder()
            .method("POST")
            .uri(path)
            .header(http::header::CONTENT_TYPE, "application/json");

        if include_api_key {
            builder = builder.header("x-api-key", &self.api_key);
        }

        let body = serde_json::to_vec(payload).expect("request payload should serialize");
        let request = builder
            .body(Body::from(body))
            .expect("failed to build harness request");
        self.router
            .clone()
            .oneshot(request)
            .await
            .expect("router should handle harness request")
    }

    pub fn age_available(&self) -> bool {
        self.age_available
    }
}

pub async fn read_json(response: http::Response<Body>) -> (StatusCode, Value) {
    let status = response.status();
    let bytes = body::to_bytes(response.into_body(), 1024 * 1024)
        .await
        .expect("response body should deserialize");
    let value =
        serde_json::from_slice::<Value>(&bytes).expect("response body should be valid JSON");
    (status, value)
}

#[derive(Debug, Clone)]
struct RemoteFixtureConfig {
    database_url: String,
    admin_url: String,
    database_name: String,
    database_owner: String,
}

impl RemoteFixtureConfig {
    fn from_env() -> anyhow::Result<Option<Self>> {
        let database_url = match read_env_value("SRQL_TEST_DATABASE_URL")? {
            Some(value) => value,
            None => return Ok(None),
        };
        let admin_url = read_env_value("SRQL_TEST_ADMIN_URL")?.ok_or_else(|| {
            anyhow::anyhow!(
                "SRQL_TEST_ADMIN_URL must be set when SRQL_TEST_DATABASE_URL is provided"
            )
        })?;

        let parsed: tokio_postgres::Config = database_url
            .parse()
            .map_err(|err| anyhow::anyhow!("SRQL_TEST_DATABASE_URL is invalid: {err}"))?;
        let database_owner = parsed
            .get_user()
            .map(|value| value.to_string())
            .ok_or_else(|| {
                anyhow::anyhow!("SRQL_TEST_DATABASE_URL must include a username/owner")
            })?;
        let database_name = parsed
            .get_dbname()
            .map(|value| value.to_string())
            .ok_or_else(|| {
                anyhow::anyhow!("SRQL_TEST_DATABASE_URL must include a database name")
            })?;

        Ok(Some(Self {
            database_url,
            admin_url,
            database_name,
            database_owner,
        }))
    }
}

struct RemoteFixtureGuard {
    client: Client,
    _connection_task: JoinHandle<()>,
}

impl RemoteFixtureGuard {
    async fn acquire(config: &RemoteFixtureConfig) -> anyhow::Result<Self> {
        let (client, connection) = tokio_postgres::connect(&config.admin_url, NoTls).await?;
        let task = tokio::spawn(async move {
            if let Err(err) = connection.await {
                eprintln!("remote admin connection closed with error: {err}");
            }
        });
        client
            .execute("SELECT pg_advisory_lock($1)", &[&REMOTE_FIXTURE_LOCK_ID])
            .await?;
        Ok(Self {
            client,
            _connection_task: task,
        })
    }

    async fn reset_database(&self, config: &RemoteFixtureConfig) -> anyhow::Result<()> {
        let terminate_sql = format!(
            "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = {} AND pid <> pg_backend_pid();",
            quote_literal(&config.database_name)
        );
        self.client.batch_execute(&terminate_sql).await?;
        self.client
            .batch_execute(&format!(
                "DROP DATABASE IF EXISTS {};",
                quote_ident(&config.database_name)
            ))
            .await?;
        self.client
            .batch_execute(&format!(
                "CREATE DATABASE {} OWNER {};",
                quote_ident(&config.database_name),
                quote_ident(&config.database_owner)
            ))
            .await?;
        self.install_required_extensions(config).await?;
        Ok(())
    }

    async fn install_required_extensions(
        &self,
        config: &RemoteFixtureConfig,
    ) -> anyhow::Result<()> {
        let mut extension_config: PgConfig = config
            .admin_url
            .parse()
            .map_err(|err| anyhow::anyhow!("SRQL_TEST_ADMIN_URL is invalid: {err}"))?;
        extension_config.dbname(&config.database_name);
        let (client, connection) = extension_config.connect(NoTls).await?;
        let task = tokio::spawn(async move {
            if let Err(err) = connection.await {
                eprintln!("remote extension connection closed with error: {err}");
            }
        });
        client
            .batch_execute("CREATE EXTENSION IF NOT EXISTS timescaledb;")
            .await?;
        client
            .batch_execute("CREATE EXTENSION IF NOT EXISTS age;")
            .await?;
        client.batch_execute(AGE_GRAPH_BOOTSTRAP_SQL).await?;
        drop(client);
        let _ = task.await;
        Ok(())
    }
}

fn read_env_value(key: &str) -> anyhow::Result<Option<String>> {
    if let Ok(value) = std::env::var(key) {
        if value.trim().is_empty() {
            anyhow::bail!("{key} is set but empty");
        }
        return Ok(Some(value));
    }
    let file_key = format!("{key}_FILE");
    if let Ok(path) = std::env::var(&file_key) {
        let value = fs::read_to_string(&path)
            .map_err(|err| anyhow::anyhow!("failed to read {file_key} ({path}): {err}"))?
            .trim()
            .to_string();
        if value.is_empty() {
            anyhow::bail!("{file_key} pointed at an empty file");
        }
        return Ok(Some(value));
    }
    Ok(None)
}

fn quote_ident(value: &str) -> String {
    format!("\"{}\"", value.replace('"', "\"\""))
}

fn quote_literal(value: &str) -> String {
    format!("'{}'", value.replace('\'', "''"))
}

fn log_connection_details(name: &str, url: &str) {
    match url.parse::<PgConfig>() {
        Ok(cfg) => {
            let hosts: Vec<String> = cfg
                .get_hosts()
                .iter()
                .map(|host| match host {
                    Host::Tcp(host) => host.to_string(),
                    Host::Unix(path) => format!("unix:{}", path.display()),
                })
                .collect();
            let ports = cfg.get_ports();
            let port = ports.first().copied().unwrap_or_default();
            let user = cfg.get_user().unwrap_or("<unset>");
            let dbname = cfg.get_dbname().unwrap_or("<unset>");
            eprintln!(
                "[srql-test] {name}: user={user} db={dbname} hosts={:?} port={}",
                hosts, port
            );
        }
        Err(err) => {
            eprintln!("[srql-test] {name}: failed to parse connection string ({err})");
        }
    }
}

fn ensure_cnpg_image() -> anyhow::Result<()> {
    let state = CNPG_BUILD_STATE.get_or_init(|| Mutex::new(false));
    let mut fetched = state
        .lock()
        .expect("CNPG image build mutex poisoned by previous panic");
    if !*fetched {
        if !cnpg_image_present()? {
            fetch_cnpg_image()?;
        }
        *fetched = true;
    }
    Ok(())
}

fn cnpg_image_present() -> anyhow::Result<bool> {
    let status = Command::new("docker")
        .args(["image", "inspect", CNPG_IMAGE_REF])
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()?;
    Ok(status.success())
}

fn fetch_cnpg_image() -> anyhow::Result<()> {
    if load_cnpg_from_archive()? {
        return Ok(());
    }
    let status = Command::new("docker")
        .args(["pull", CNPG_IMAGE_REF])
        .status()?;
    if !status.success() {
        anyhow::bail!(
            "docker pull {CNPG_IMAGE_REF} failed with status {:?}",
            status.code()
        );
    }
    Ok(())
}

fn load_cnpg_from_archive() -> anyhow::Result<bool> {
    let archive = Path::new(CNPG_ARCHIVE);
    if !archive.exists() {
        return Ok(false);
    }
    let status = Command::new("docker")
        .args(["load", "--input", CNPG_ARCHIVE])
        .status()?;
    if !status.success() {
        anyhow::bail!(
            "docker load --input {CNPG_ARCHIVE} failed with status {:?}",
            status.code()
        );
    }
    Ok(true)
}

fn load_fixture(name: &str) -> anyhow::Result<String> {
    let root = fixture_root();
    let path = root.join(name);
    fs::read_to_string(&path)
        .map_err(|err| anyhow::anyhow!("failed to read fixture {name} from {:?}: {err}", path))
}

fn fixture_root() -> PathBuf {
    if let Ok(root) = std::env::var("SRQL_FIXTURE_ROOT") {
        let candidate = PathBuf::from(root);
        if candidate.exists() {
            return candidate;
        }
    }

    const RELATIVE: &str = "rust/srql/tests/fixtures";
    let runfile_rel = Path::new(RELATIVE);

    let find_in_base = |base: &Path| -> Option<PathBuf> {
        let mut candidates = vec![base.join(runfile_rel)];

        if let Ok(workspace) = std::env::var("TEST_WORKSPACE") {
            candidates.push(base.join(&workspace).join(runfile_rel));
        }

        candidates.push(base.join("__main").join(runfile_rel));
        candidates.push(base.join("__main__").join(runfile_rel));
        candidates.into_iter().find(|candidate| candidate.exists())
    };

    if let Ok(runfiles) = std::env::var("RUNFILES_DIR") {
        if let Some(path) = find_in_base(Path::new(&runfiles)) {
            return path;
        }
    }

    if let Ok(test_srcdir) = std::env::var("TEST_SRCDIR") {
        if let Some(path) = find_in_base(Path::new(&test_srcdir)) {
            return path;
        }
    }

    Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("tests")
        .join("fixtures")
}

async fn check_age_available(database_url: &str) -> anyhow::Result<bool> {
    let (client, connection) = tokio_postgres::connect(database_url, NoTls).await?;
    tokio::spawn(async move {
        let _ = connection.await;
    });
    let result = client
        .query(
            "SELECT 1 FROM ag_catalog.cypher('serviceradar', 'RETURN 1') AS (result agtype) LIMIT 1",
            &[],
        )
        .await;
    Ok(result.is_ok())
}
