use anyhow::Context;
use axum::{
    body::{self, Body},
    http::{self, Request, StatusCode},
    Router,
};
use rustls::pki_types::{CertificateDer, PrivateKeyDer};
use rustls::{ClientConfig, RootCertStore};
use rustls_pemfile::certs;
use serde::Serialize;
use serde_json::Value;
use srql::{config::AppConfig, query::QueryRequest, server::Server};
use std::{
    env,
    fs::{self, File},
    future::Future,
    io::BufReader,
    net::SocketAddr,
    path::{Path, PathBuf},
    sync::Once,
    time::Duration,
};
use tokio::{
    task::JoinHandle,
    time::{sleep, Duration as TokioDuration},
};
use tokio_postgres::{config::Host, error::SqlState, Client, Config as PgConfig, NoTls};
use tokio_postgres_rustls::MakeRustlsConnect;
use tower::ServiceExt;

const API_KEY: &str = "test-api-key";
const DB_CONNECT_RETRIES: usize = 240;
const DB_CONNECT_DELAY_MS: u64 = 250;
const DB_SEED_RETRIES: usize = 3;
const REMOTE_FIXTURE_LOCK_ID: i64 = 4_216_042;

static TRACING_INIT: Once = Once::new();

/// Runs a test closure against a fully bootstrapped SRQL instance backed by the seeded Postgres fixture.
pub async fn with_srql_harness<F, Fut>(test: F)
where
    F: FnOnce(SrqlTestHarness) -> Fut,
    Fut: Future<Output = ()>,
{
    TRACING_INIT.call_once(|| {
        let _ = tracing_subscriber::fmt::try_init();
    });

    let remote_config = match RemoteFixtureConfig::from_env()
        .expect("failed to read remote fixture config")
    {
        Some(config) => config,
        None => {
            eprintln!(
                "[srql-test] skipping SRQL harness: SRQL_TEST_DATABASE_URL and SRQL_TEST_ADMIN_URL are not set"
            );
            return;
        }
    };

    run_with_remote_fixture(remote_config, test).await;
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
        pg_ssl_root_cert: env::var("PGSSLROOTCERT").ok(),
        pg_ssl_cert: env::var("PGSSLCERT").ok(),
        pg_ssl_key: env::var("PGSSLKEY").ok(),
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
    loop {
        match seed_fixture_database_once(database_url).await {
            Ok(()) => return Ok(()),
            Err(err) => {
                attempts += 1;
                if attempts >= DB_SEED_RETRIES {
                    return Err(err);
                }
                eprintln!(
                    "[srql-test] seeding attempt {attempts} failed: {err}; retrying fixture setup"
                );
                sleep(TokioDuration::from_millis(DB_CONNECT_DELAY_MS)).await;
            }
        }
    }
}

async fn seed_fixture_database_once(database_url: &str) -> anyhow::Result<()> {
    let mut attempts = 0usize;
    let client = loop {
        let config: PgConfig = database_url.parse()?;
        match connect_with_env_tls(config, "fixture").await {
            Ok((client, _task)) => break client,
            Err(err) => {
                if attempts >= DB_CONNECT_RETRIES {
                    return Err(err);
                }
                attempts += 1;
                sleep(TokioDuration::from_millis(DB_CONNECT_DELAY_MS)).await;
            }
        }
    };

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
    #[allow(dead_code)]
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

    #[allow(dead_code)]
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
        let db_env = read_env_value("SRQL_TEST_DATABASE_URL")?;
        let admin_env = read_env_value("SRQL_TEST_ADMIN_URL")?;

        let (database_url, admin_url) = match (db_env, admin_env) {
            (Some(db), Some(admin)) => (db, admin),
            (Some(_), None) => {
                anyhow::bail!(
                    "SRQL_TEST_ADMIN_URL must be set when SRQL_TEST_DATABASE_URL is provided"
                )
            }
            (None, Some(_)) => {
                anyhow::bail!(
                    "SRQL_TEST_DATABASE_URL must be set when SRQL_TEST_ADMIN_URL is provided"
                )
            }
            (None, None) => return Ok(None),
        };

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
        let admin_config: PgConfig = config.admin_url.parse()?;
        let (client, task) = connect_with_env_tls(admin_config, "remote admin").await?;
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
        let (client, task) = connect_with_env_tls(extension_config, "remote extension").await?;
        client
            .batch_execute("CREATE EXTENSION IF NOT EXISTS timescaledb;")
            .await?;
        client
            .batch_execute("CREATE EXTENSION IF NOT EXISTS age;")
            .await?;
        client
            .batch_execute(&format!(
                "GRANT USAGE ON SCHEMA ag_catalog TO {};",
                quote_ident(&config.database_owner)
            ))
            .await?;
        client
            .batch_execute(&format!(
                "GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA ag_catalog TO {};",
                quote_ident(&config.database_owner)
            ))
            .await?;
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

fn find_runfile(path: &str) -> Option<PathBuf> {
    let runfile_rel = Path::new(path);

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
            return Some(path);
        }
    }

    if let Ok(test_srcdir) = std::env::var("TEST_SRCDIR") {
        if let Some(path) = find_in_base(Path::new(&test_srcdir)) {
            return Some(path);
        }
    }

    None
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
    if let Some(path) = find_runfile(RELATIVE) {
        return path;
    }

    Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("tests")
        .join("fixtures")
}

async fn check_age_available(database_url: &str) -> anyhow::Result<bool> {
    let config: PgConfig = database_url.parse()?;
    let (client, _task) = connect_with_env_tls(config, "age-check").await?;
    let result = client
        .query(
            "SELECT 1 FROM ag_catalog.cypher('serviceradar', 'RETURN 1') AS (result agtype) LIMIT 1",
            &[],
        )
        .await;
    Ok(result.is_ok())
}

async fn connect_with_env_tls(
    config: PgConfig,
    label: &str,
) -> anyhow::Result<(Client, JoinHandle<()>)> {
    let label = label.to_string();
    if let Some(connector) = tls_connector_from_env()? {
        let (client, connection) = config.connect(connector).await?;
        let task = tokio::spawn(async move {
            if let Err(err) = connection.await {
                eprintln!("{label} connection closed with error: {err}");
            }
        });
        Ok((client, task))
    } else {
        let (client, connection) = config.connect(NoTls).await?;
        let task = tokio::spawn(async move {
            if let Err(err) = connection.await {
                eprintln!("{label} connection closed with error: {err}");
            }
        });
        Ok((client, task))
    }
}

fn tls_connector_from_env() -> anyhow::Result<Option<MakeRustlsConnect>> {
    let root_cert = match env::var("PGSSLROOTCERT") {
        Ok(value) if !value.trim().is_empty() => value,
        _ => return Ok(None),
    };
    let client_cert = env::var("PGSSLCERT").ok();
    let client_key = env::var("PGSSLKEY").ok();

    Ok(Some(build_tls_connector(
        &root_cert,
        client_cert.as_deref(),
        client_key.as_deref(),
    )?))
}

fn build_tls_connector(
    root_cert: &str,
    client_cert: Option<&str>,
    client_key: Option<&str>,
) -> anyhow::Result<MakeRustlsConnect> {
    let mut reader =
        BufReader::new(File::open(root_cert).context("failed to open PGSSLROOTCERT")?);
    let mut root_store = RootCertStore::empty();
    for cert in certs(&mut reader) {
        let cert = cert.context("failed to parse PGSSLROOTCERT")?;
        root_store
            .add(cert)
            .map_err(|_| anyhow::anyhow!("invalid certificate in PGSSLROOTCERT"))?;
    }

    Ok(MakeRustlsConnect::new(build_client_config(
        root_store,
        root_cert,
        client_cert,
        client_key,
    )?))
}

fn build_client_config(
    root_store: RootCertStore,
    root_cert: &str,
    client_cert: Option<&str>,
    client_key: Option<&str>,
) -> anyhow::Result<ClientConfig> {
    let builder = ClientConfig::builder().with_root_certificates(root_store);

    match (client_cert, client_key) {
        (None, None) => Ok(builder.with_no_client_auth()),
        (Some(cert), Some(key)) => {
            let certs = load_client_certs(cert)?;
            let key = load_client_key(key)?;
            builder
                .with_client_auth_cert(certs, key)
                .with_context(|| format!("failed to build client TLS config for {root_cert}"))
        }
        _ => anyhow::bail!("PGSSLCERT and PGSSLKEY must both be set (or neither)"),
    }
}

fn load_client_certs(path: &str) -> anyhow::Result<Vec<CertificateDer<'static>>> {
    let mut reader = BufReader::new(
        File::open(path).with_context(|| format!("failed to open PGSSLCERT file '{path}'"))?,
    );

    let mut chain = Vec::new();
    for cert in certs(&mut reader) {
        chain.push(cert.context("failed to parse PGSSLCERT")?);
    }

    if chain.is_empty() {
        anyhow::bail!("PGSSLCERT contained no certificates");
    }

    Ok(chain)
}

fn load_client_key(path: &str) -> anyhow::Result<PrivateKeyDer<'static>> {
    let mut reader = BufReader::new(
        File::open(path).with_context(|| format!("failed to open PGSSLKEY file '{path}'"))?,
    );

    let key = rustls_pemfile::private_key(&mut reader)
        .context("failed to parse PGSSLKEY")?
        .context("PGSSLKEY contained no private keys")?;

    Ok(key)
}
