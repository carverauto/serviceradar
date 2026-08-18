use runfiles::Runfiles;
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
use srql::{config::AppConfig, db::PgRustlsConnect, query::QueryRequest, server::Server};
use std::{
    borrow::Cow,
    env,
    fs::{self, File, OpenOptions},
    future::Future,
    io::{BufReader, Write},
    net::SocketAddr,
    path::{Path, PathBuf},
    process,
    sync::{
        atomic::{AtomicU64, Ordering},
        Once,
    },
    time::Duration,
    time::{SystemTime, UNIX_EPOCH},
};
use tokio::{
    task::JoinHandle,
    time::{sleep, Duration as TokioDuration},
};
use tokio_postgres::{config::Host, error::SqlState, Client, Config as PgConfig, NoTls};
use tower::ServiceExt;

const API_KEY: &str = "test-api-key";
const DB_CONNECT_RETRIES: usize = 240;
const DB_CONNECT_DELAY_MS: u64 = 250;
const DB_SEED_RETRIES: usize = 3;
const REMOTE_FIXTURE_LOCK_ID: i64 = 4_216_042;

static TRACING_INIT: Once = Once::new();
static TEMP_CA_SEQUENCE: AtomicU64 = AtomicU64::new(0);

fn ensure_rustls_crypto_provider() {
    let _ = rustls::crypto::ring::default_provider().install_default();
}

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
    let tls_config = FixtureTlsConfig::from_env().expect("failed to configure fixture TLS");

    log_connection_details("SRQL_TEST_DATABASE_URL", &config.database_url);
    log_connection_details("SRQL_TEST_ADMIN_URL", &config.admin_url);

    let guard = RemoteFixtureGuard::acquire(&config, &tls_config)
        .await
        .expect("failed to acquire remote fixture lock");
    guard
        .reset_database(&config, &tls_config)
        .await
        .expect("failed to reset remote fixture database");

    seed_fixture_database(&config.database_url, &tls_config)
        .await
        .expect("failed to seed fixture database");

    let app_config = test_config(config.database_url.clone(), &tls_config);
    let age_available = check_age_available(&config.database_url, &tls_config)
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

fn test_config(database_url: String, tls_config: &FixtureTlsConfig) -> AppConfig {
    AppConfig {
        listen_addr: SocketAddr::from(([127, 0, 0, 1], 0)),
        database_url,
        age_graph_name: "platform_graph".to_string(),
        max_pool_size: 5,
        pg_ssl_root_cert: tls_config.root_cert_path_string(),
        pg_ssl_cert: tls_config.client_cert.clone(),
        pg_ssl_key: tls_config.client_key.clone(),
        pg_ssl_server_name: tls_config.server_name.clone(),
        api_key: Some(API_KEY.to_string()),
        api_key_kv_key: None,
        allowed_origins: None,
        cursor_secret: "test-cursor-secret".to_string(),
        max_cursor_offset: 100_000,
        default_limit: 100,
        max_limit: 500,
        request_timeout: Duration::from_secs(30),
        db_statement_timeout: Duration::from_secs(30),
        rate_limit_max_requests: 120,
        rate_limit_window: Duration::from_secs(60),
    }
}

async fn seed_fixture_database(
    database_url: &str,
    tls_config: &FixtureTlsConfig,
) -> anyhow::Result<()> {
    let mut attempts = 0usize;
    loop {
        match seed_fixture_database_once(database_url, tls_config).await {
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

async fn seed_fixture_database_once(
    database_url: &str,
    tls_config: &FixtureTlsConfig,
) -> anyhow::Result<()> {
    let mut attempts = 0usize;
    let client = loop {
        let config: PgConfig = database_url.parse()?;
        match connect_with_tls(config, "fixture", tls_config).await {
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

        let (database_url, parsed) =
            parse_fixture_pg_config("SRQL_TEST_DATABASE_URL", &database_url)?;
        let (admin_url, _) = parse_fixture_pg_config("SRQL_TEST_ADMIN_URL", &admin_url)?;
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

fn parse_fixture_pg_config(
    env_name: &str,
    raw: &str,
) -> anyhow::Result<(String, tokio_postgres::Config)> {
    // Ecto/libpq use verify-ca/verify-full to turn peer/hostname verification on, but
    // tokio-postgres only parses disable/prefer/require. Keep the shared DSN verified for
    // every other client and map the mode to require only at this parser boundary; the
    // harness's rustls connector still verifies the CA and PGSSLSERVERNAME.
    let parser_input = normalize_sslmode_for_tokio_postgres(raw);
    let normalized = normalize_fixture_pg_connection_string(&parser_input)
        .map_err(|err| anyhow::anyhow!("{env_name} is invalid: {err}"))?;
    let parsed = normalized
        .parse()
        .map_err(|err| anyhow::anyhow!("{env_name} is invalid: {err}"))?;
    Ok((normalized, parsed))
}

fn normalize_sslmode_for_tokio_postgres(url: &str) -> Cow<'_, str> {
    let Some((base, query)) = url.split_once('?') else {
        return Cow::Borrowed(url);
    };

    let must_normalize = query.split('&').any(|parameter| {
        let Some((key, value)) = parameter.split_once('=') else {
            return false;
        };

        key.eq_ignore_ascii_case("sslmode")
            && (value.eq_ignore_ascii_case("verify-ca")
                || value.eq_ignore_ascii_case("verify-full"))
    });

    if !must_normalize {
        return Cow::Borrowed(url);
    }

    let normalized = query
        .split('&')
        .map(|parameter| {
            let Some((key, value)) = parameter.split_once('=') else {
                return Cow::Borrowed(parameter);
            };

            if key.eq_ignore_ascii_case("sslmode")
                && (value.eq_ignore_ascii_case("verify-ca")
                    || value.eq_ignore_ascii_case("verify-full"))
            {
                Cow::Owned(format!("{key}=require"))
            } else {
                Cow::Borrowed(parameter)
            }
        })
        .collect::<Vec<_>>()
        .join("&");

    Cow::Owned(format!("{base}?{normalized}"))
}

fn normalize_fixture_pg_connection_string(raw: &str) -> anyhow::Result<String> {
    if raw.parse::<PgConfig>().is_ok() {
        return Ok(raw.to_string());
    }

    normalize_postgres_url(raw)
}

fn normalize_postgres_url(raw: &str) -> anyhow::Result<String> {
    let (scheme, remainder) = raw
        .split_once("://")
        .ok_or_else(|| anyhow::anyhow!("invalid connection string"))?;
    if scheme != "postgres" && scheme != "postgresql" {
        anyhow::bail!("unsupported connection string scheme {scheme}");
    }

    let (authority, path_and_query) = remainder
        .split_once('/')
        .ok_or_else(|| anyhow::anyhow!("database URL must include a database name"))?;
    if authority.is_empty() {
        anyhow::bail!("database URL must include a host");
    }

    let (userinfo, host_port) = match authority.rsplit_once('@') {
        Some((userinfo, host_port)) => (Some(userinfo), host_port),
        None => (None, authority),
    };

    let (host, port) = parse_host_port(host_port)?;
    let (database_name, query) = match path_and_query.split_once('?') {
        Some((path, query)) => (path, Some(query)),
        None => (path_and_query, None),
    };
    let database_name = percent_decode(database_name.trim_start_matches('/'))?;
    if database_name.is_empty() {
        anyhow::bail!("database URL must include a database name");
    }

    let mut parts = vec![
        format!("host={}", quote_pg_keyword_value(&host)),
        format!("dbname={}", quote_pg_keyword_value(&database_name)),
    ];

    if let Some(port) = port {
        parts.push(format!("port={}", quote_pg_keyword_value(&port)));
    }

    if let Some(userinfo) = userinfo {
        let (user, password) = match userinfo.split_once(':') {
            Some((user, password)) => (user, Some(password)),
            None => (userinfo, None),
        };
        let user = percent_decode(user)?;
        if !user.is_empty() {
            parts.push(format!("user={}", quote_pg_keyword_value(&user)));
        }
        if let Some(password) = password {
            let password = percent_decode(password)?;
            parts.push(format!("password={}", quote_pg_keyword_value(&password)));
        }
    }

    if let Some(query) = query {
        for segment in query.split('&') {
            if segment.is_empty() {
                continue;
            }

            let (key, value) = match segment.split_once('=') {
                Some((key, value)) => (key, value),
                None => (segment, ""),
            };
            let key = percent_decode(key)?;
            if key.is_empty() {
                continue;
            }
            let value = percent_decode(value)?;
            parts.push(format!("{key}={}", quote_pg_keyword_value(&value)));
        }
    }

    Ok(parts.join(" "))
}

fn parse_host_port(value: &str) -> anyhow::Result<(String, Option<String>)> {
    if value.is_empty() {
        anyhow::bail!("database URL must include a host");
    }

    if let Some(rest) = value.strip_prefix('[') {
        let (host, remainder) = rest
            .split_once(']')
            .ok_or_else(|| anyhow::anyhow!("invalid IPv6 host"))?;
        let port = remainder
            .strip_prefix(':')
            .filter(|port| !port.is_empty())
            .map(str::to_string);
        return Ok((host.to_string(), port));
    }

    match value.rsplit_once(':') {
        Some((host, port))
            if !host.is_empty()
                && !port.is_empty()
                && port.bytes().all(|byte| byte.is_ascii_digit()) =>
        {
            Ok((host.to_string(), Some(port.to_string())))
        }
        _ => Ok((value.to_string(), None)),
    }
}

fn quote_pg_keyword_value(value: &str) -> String {
    let escaped = value.replace('\\', "\\\\").replace('\'', "\\'");
    format!("'{escaped}'")
}

fn percent_decode(value: &str) -> anyhow::Result<String> {
    let bytes = value.as_bytes();
    let mut decoded = Vec::with_capacity(bytes.len());
    let mut index = 0usize;

    while index < bytes.len() {
        if bytes[index] == b'%' {
            if index + 2 >= bytes.len() {
                anyhow::bail!("invalid percent-encoding");
            }
            let hi = decode_hex_digit(bytes[index + 1])?;
            let lo = decode_hex_digit(bytes[index + 2])?;
            decoded.push((hi << 4) | lo);
            index += 3;
            continue;
        }

        decoded.push(bytes[index]);
        index += 1;
    }

    String::from_utf8(decoded).map_err(|_| anyhow::anyhow!("invalid UTF-8 in connection string"))
}

fn decode_hex_digit(byte: u8) -> anyhow::Result<u8> {
    match byte {
        b'0'..=b'9' => Ok(byte - b'0'),
        b'a'..=b'f' => Ok(byte - b'a' + 10),
        b'A'..=b'F' => Ok(byte - b'A' + 10),
        _ => anyhow::bail!("invalid percent-encoding"),
    }
}

struct RemoteFixtureGuard {
    client: Client,
    _connection_task: JoinHandle<()>,
}

impl RemoteFixtureGuard {
    async fn acquire(
        config: &RemoteFixtureConfig,
        tls_config: &FixtureTlsConfig,
    ) -> anyhow::Result<Self> {
        let admin_config: PgConfig = config.admin_url.parse()?;
        let (client, task) = connect_with_tls(admin_config, "remote admin", tls_config).await?;
        client
            .execute("SELECT pg_advisory_lock($1)", &[&REMOTE_FIXTURE_LOCK_ID])
            .await?;
        Ok(Self {
            client,
            _connection_task: task,
        })
    }

    async fn reset_database(
        &self,
        config: &RemoteFixtureConfig,
        tls_config: &FixtureTlsConfig,
    ) -> anyhow::Result<()> {
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
        self.install_required_extensions(config, tls_config).await?;
        Ok(())
    }

    async fn install_required_extensions(
        &self,
        config: &RemoteFixtureConfig,
        tls_config: &FixtureTlsConfig,
    ) -> anyhow::Result<()> {
        let mut extension_config: PgConfig = config
            .admin_url
            .parse()
            .map_err(|err| anyhow::anyhow!("SRQL_TEST_ADMIN_URL is invalid: {err}"))?;
        extension_config.dbname(&config.database_name);
        let (client, task) =
            connect_with_tls(extension_config, "remote extension", tls_config).await?;
        client
            .batch_execute("CREATE EXTENSION IF NOT EXISTS timescaledb;")
            .await?;
        client
            .batch_execute("CREATE EXTENSION IF NOT EXISTS age;")
            .await?;
        client
            .batch_execute("CREATE EXTENSION IF NOT EXISTS postgis;")
            .await?;
        client
            .batch_execute("CREATE EXTENSION IF NOT EXISTS vector;")
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
            return Ok(None);
        }
        return Ok(Some(value));
    }
    let file_key = format!("{key}_FILE");
    if let Ok(path) = std::env::var(&file_key) {
        if path.trim().is_empty() {
            return Ok(None);
        }
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

/// Locates a declared build input through the Bazel ecosystem's reference lookup
/// (`@rules_rust//rust/runfiles`, published as the `runfiles` crate).
///
/// This replaced a hand-rolled search that tried, in order, the runfiles root itself,
/// `$TEST_WORKSPACE`, `__main` and `__main__`. None of those is `_main`, which is the canonical
/// name Bzlmod actually uses, so three of the four candidates could never match and the fourth
/// depended on a variable Bazel sets only for tests. The library consults the repo mapping the
/// build emitted, and finds the tree under `bazel run` and in manifest mode as well.
fn find_runfile(path: &str) -> Option<PathBuf> {
    let runfiles = Runfiles::create().ok()?;
    let resolved = runfiles.rlocation_from(format!("serviceradar/{path}"), "")?;
    resolved.exists().then_some(resolved)
}

fn load_fixture(name: &str) -> anyhow::Result<String> {
    let root = fixture_root();
    let path = root.join(name);
    fs::read_to_string(&path)
        .map_err(|err| anyhow::anyhow!("failed to read fixture {name} from {:?}: {err}", path))
}

fn fixture_root() -> PathBuf {
    // No environment override. Fixture data is a declared input, and a variable that can
    // repoint it lets a run read files nothing in the build graph knows about -- which is
    // the class of ambient override the configuration system exists to remove.
    const RELATIVE: &str = "integration_tests/srql/tests/fixtures";
    if let Some(path) = find_runfile(RELATIVE) {
        return path;
    }

    // std::env::var, not env!. The macro is evaluated at COMPILE time, so it bakes the
    // absolute path of the directory that built this crate into the test binary -- under
    // RBE that is /buildbuddy-execroot/..., which makes the artifact non-reproducible and
    // is rejected outright by rules_rs's process wrapper. Read at runtime instead: cargo
    // sets the variable when it runs the test, and Bazel never reaches this branch because
    // the runfiles lookup above already resolved.
    if let Ok(manifest_dir) = std::env::var("CARGO_MANIFEST_DIR") {
        return Path::new(&manifest_dir).join("tests").join("fixtures");
    }
    Path::new("tests").join("fixtures")
}

async fn check_age_available(
    database_url: &str,
    tls_config: &FixtureTlsConfig,
) -> anyhow::Result<bool> {
    let config: PgConfig = database_url.parse()?;
    let (client, _task) = connect_with_tls(config, "age-check", tls_config).await?;
    let result = client
        .query(
            "SELECT 1 FROM ag_catalog.cypher('platform_graph', 'RETURN 1') AS (result agtype) LIMIT 1",
            &[],
        )
        .await;
    Ok(result.is_ok())
}

async fn connect_with_tls(
    config: PgConfig,
    label: &str,
    tls_config: &FixtureTlsConfig,
) -> anyhow::Result<(Client, JoinHandle<()>)> {
    let label = label.to_string();
    if let Some(connector) = tls_config.connector()? {
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

struct FixtureTlsConfig {
    root_cert: Option<FixtureRootCert>,
    client_cert: Option<String>,
    client_key: Option<String>,
    server_name: Option<String>,
}

impl FixtureTlsConfig {
    fn from_env() -> anyhow::Result<Self> {
        Ok(Self {
            root_cert: resolve_pg_ssl_root_cert()?,
            client_cert: env::var("PGSSLCERT").ok(),
            client_key: env::var("PGSSLKEY").ok(),
            server_name: resolved_pg_ssl_server_name(),
        })
    }

    fn root_cert_path(&self) -> Option<&Path> {
        self.root_cert.as_ref().map(FixtureRootCert::path)
    }

    fn root_cert_path_string(&self) -> Option<String> {
        self.root_cert_path()
            .map(|path| path.to_string_lossy().into_owned())
    }

    fn connector(&self) -> anyhow::Result<Option<PgRustlsConnect>> {
        let Some(root_cert) = self.root_cert_path() else {
            return Ok(None);
        };

        Ok(Some(build_tls_connector(
            root_cert,
            self.client_cert.as_deref(),
            self.client_key.as_deref(),
            self.server_name.as_deref(),
        )?))
    }
}

fn resolved_pg_ssl_server_name() -> Option<String> {
    [
        "SRQL_TEST_DATABASE_SERVER_NAME",
        "SRQL_TEST_DATABASE_TLS_SERVER_NAME",
        "PGSSLSERVERNAME",
        "PGSSLTARGETNAME",
    ]
    .into_iter()
    .filter_map(|key| env::var(key).ok())
    .map(|value| value.trim().to_string())
    .find(|value| !value.is_empty())
}

enum FixtureRootCert {
    External(PathBuf),
    Temporary(TemporaryCaCert),
}

impl FixtureRootCert {
    fn path(&self) -> &Path {
        match self {
            Self::External(path) => path,
            Self::Temporary(cert) => cert.path(),
        }
    }
}

struct TemporaryCaCert {
    path: PathBuf,
    pending_file: Option<File>,
}

impl TemporaryCaCert {
    fn materialize(contents: &str) -> anyhow::Result<Self> {
        const CREATE_ATTEMPTS: usize = 16;

        for _ in 0..CREATE_ATTEMPTS {
            let nanos = SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap_or_default()
                .as_nanos();
            let sequence = TEMP_CA_SEQUENCE.fetch_add(1, Ordering::Relaxed);
            let path = env::temp_dir().join(format!(
                "srql-test-ca-{}-{nanos}-{sequence}.crt",
                process::id()
            ));

            let mut options = OpenOptions::new();
            options.write(true).create_new(true);
            #[cfg(unix)]
            {
                use std::os::unix::fs::OpenOptionsExt;
                options.mode(0o600);
            }

            let file = match options.open(&path) {
                Ok(file) => file,
                Err(err) if err.kind() == std::io::ErrorKind::AlreadyExists => continue,
                Err(err) => {
                    return Err(err).with_context(|| {
                        format!(
                            "failed to create temporary fixture CA in {}",
                            env::temp_dir().display()
                        )
                    });
                }
            };

            let mut cert = Self {
                path,
                pending_file: Some(file),
            };

            #[cfg(unix)]
            {
                use std::os::unix::fs::PermissionsExt;
                fs::set_permissions(&cert.path, fs::Permissions::from_mode(0o600))
                    .context("failed to restrict temporary fixture CA permissions")?;
            }

            cert.pending_file
                .as_mut()
                .expect("temporary fixture CA file should remain open during setup")
                .write_all(contents.as_bytes())
                .context("failed to write temporary fixture CA")?;
            drop(cert.pending_file.take());
            return Ok(cert);
        }

        anyhow::bail!("failed to allocate a unique temporary fixture CA path")
    }

    fn path(&self) -> &Path {
        &self.path
    }
}

impl Drop for TemporaryCaCert {
    fn drop(&mut self) {
        drop(self.pending_file.take());
        let _ = fs::remove_file(&self.path);
    }
}

fn resolve_pg_ssl_root_cert() -> anyhow::Result<Option<FixtureRootCert>> {
    if let Ok(path) = env::var("PGSSLROOTCERT") {
        let trimmed = path.trim();
        if !trimmed.is_empty() {
            let candidate = Path::new(trimmed);
            if candidate.is_file() {
                return Ok(Some(FixtureRootCert::External(candidate.to_path_buf())));
            }
        }
    }

    let raw_or_path = match env::var("SRQL_TEST_DATABASE_CA_CERT") {
        Ok(value) if !value.trim().is_empty() => value,
        _ => return Ok(None),
    };

    let trimmed = raw_or_path.trim();
    let candidate = Path::new(trimmed);
    if candidate.is_file() {
        return Ok(Some(FixtureRootCert::External(candidate.to_path_buf())));
    }

    if !trimmed.contains("BEGIN CERTIFICATE") {
        anyhow::bail!(
            "PGSSLROOTCERT was not readable and SRQL_TEST_DATABASE_CA_CERT did not contain a PEM certificate or a valid file path"
        );
    }

    Ok(Some(FixtureRootCert::Temporary(
        TemporaryCaCert::materialize(trimmed)?,
    )))
}

fn build_tls_connector(
    root_cert: &Path,
    client_cert: Option<&str>,
    client_key: Option<&str>,
    server_name: Option<&str>,
) -> anyhow::Result<PgRustlsConnect> {
    let mut reader = BufReader::new(File::open(root_cert).context("failed to open PGSSLROOTCERT")?);
    let mut root_store = RootCertStore::empty();
    for cert in certs(&mut reader) {
        let cert = cert.context("failed to parse PGSSLROOTCERT")?;
        root_store
            .add(cert)
            .map_err(|_| anyhow::anyhow!("invalid certificate in PGSSLROOTCERT"))?;
    }

    Ok(PgRustlsConnect::new(
        build_client_config(root_store, root_cert, client_cert, client_key)?,
        server_name.map(str::to_string),
    ))
}

fn build_client_config(
    root_store: RootCertStore,
    root_cert: &Path,
    client_cert: Option<&str>,
    client_key: Option<&str>,
) -> anyhow::Result<ClientConfig> {
    ensure_rustls_crypto_provider();
    let builder = ClientConfig::builder().with_root_certificates(root_store);

    match (client_cert, client_key) {
        (None, None) => Ok(builder.with_no_client_auth()),
        (Some(cert), Some(key)) => {
            let certs = load_client_certs(cert)?;
            let key = load_client_key(key)?;
            builder.with_client_auth_cert(certs, key).with_context(|| {
                format!(
                    "failed to build client TLS config for {}",
                    root_cert.display()
                )
            })
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn verified_fixture_ssl_modes_parse_at_the_tokio_boundary() {
        for mode in ["verify-ca", "verify-full", "VERIFY-FULL"] {
            let raw = format!(
                "postgres://fixture:p%40ss@192.0.2.10:30818/srql_fixture?\
                 application_name=srql-integration&sslmode={mode}"
            );
            let (normalized, config) =
                parse_fixture_pg_config("SRQL_TEST_DATABASE_URL", &raw).unwrap();

            assert!(normalized.contains("sslmode=require"));
            assert_eq!(config.get_user(), Some("fixture"));
            assert_eq!(config.get_dbname(), Some("srql_fixture"));
            assert_eq!(config.get_application_name(), Some("srql-integration"));
        }
    }

    #[test]
    fn non_verified_fixture_ssl_modes_are_unchanged() {
        let require = "postgres://u:p@host/db?sslmode=require&application_name=fixture";
        let disable = "postgres://u:p@host/db?sslmode=disable";

        assert!(matches!(
            normalize_sslmode_for_tokio_postgres(require),
            Cow::Borrowed(value) if value == require
        ));
        assert!(matches!(
            normalize_sslmode_for_tokio_postgres(disable),
            Cow::Borrowed(value) if value == disable
        ));
    }

    #[test]
    fn materialized_ca_is_private_and_removed_on_drop() {
        let cert = TemporaryCaCert::materialize(
            "-----BEGIN CERTIFICATE-----\nfixture\n-----END CERTIFICATE-----",
        )
        .unwrap();
        let path = cert.path().to_path_buf();

        assert_eq!(
            fs::read_to_string(&path).unwrap(),
            "-----BEGIN CERTIFICATE-----\nfixture\n-----END CERTIFICATE-----"
        );
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            assert_eq!(
                fs::metadata(&path).unwrap().permissions().mode() & 0o777,
                0o600
            );
        }

        drop(cert);
        assert!(!path.exists());
    }

    #[test]
    fn materialized_ca_is_removed_during_unwind() {
        let mut path = None;
        let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
            let cert = TemporaryCaCert::materialize(
                "-----BEGIN CERTIFICATE-----\nfixture\n-----END CERTIFICATE-----",
            )
            .unwrap();
            path = Some(cert.path().to_path_buf());
            panic!("exercise temporary CA cleanup during unwind");
        }));

        assert!(result.is_err());
        assert!(!path.unwrap().exists());
    }
}
