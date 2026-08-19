use serviceradar_integration_db as db;
use runfiles::Runfiles;
use anyhow::Context;
use axum::{
    body::{self, Body},
    http::{self, Request, StatusCode},
    Router,
};
use serde::Serialize;
use serde_json::Value;
use srql::{config::AppConfig, db::PgRustlsConnect, query::QueryRequest, server::Server};
use std::{
    env,
    fs::{self, File, OpenOptions},
    future::Future,
    io::Write,
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
const REMOTE_FIXTURE_LOCK_ID: i64 = 4_216_042;

static TRACING_INIT: Once = Once::new();
static TEMP_CA_SEQUENCE: AtomicU64 = AtomicU64::new(0);

/// Runs a test closure against a fully bootstrapped SRQL instance backed by the seeded Postgres fixture.
pub async fn with_srql_harness<F, Fut>(test: F)
where
    F: FnOnce(SrqlTestHarness) -> Fut,
    Fut: Future<Output = ()>,
{
    TRACING_INIT.call_once(|| {
        let _ = tracing_subscriber::fmt::try_init();
    });

    // No skip arm. This returned early when the fixture was unresolvable, which is how three
    // targets stayed green while asserting nothing.
    let remote_config =
        RemoteFixtureConfig::from_env().expect("failed to resolve the fixture for this target");

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
    // Not unwrap_or(false): seeding already ran `CREATE EXTENSION IF NOT EXISTS age` and fails
    // if it cannot, so an Err here means the check itself broke. Defaulting it to false quietly
    // downgraded every AGE-gated assertion instead.
    let age_available = check_age_available(&config.database_url, &tls_config)
        .await
        .expect("failed to check whether AGE is available");
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
        database_ca_pem: tls_config.ca_pem.clone(),
        database_client_cert_pem: tls_config.client_cert_pem.clone(),
        database_client_key_pem: tls_config.client_key_pem.clone(),
        database_tls_server_name: tls_config.server_name.clone(),
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

/// Seeds once, and a failure is the answer.
///
/// This retried three times, which only ever helped when another target was resetting the same
/// database underneath it -- so it converted an isolation bug into an intermittent one. Each
/// target now owns its database, leaving nothing for a retry to win: a failure here means the
/// schema or seed is wrong.
async fn seed_fixture_database(
    database_url: &str,
    tls_config: &FixtureTlsConfig,
) -> anyhow::Result<()> {
    seed_fixture_database_once(database_url, tls_config).await
}

async fn seed_fixture_database_once(
    database_url: &str,
    tls_config: &FixtureTlsConfig,
) -> anyhow::Result<()> {
    let mut attempts = 0usize;
    let client = loop {
        // Through the shared parser: the assembled DSN carries `sslmode=verify-full`, which
    // tokio-postgres rejects outright -- it accepts only disable/prefer/require. The verifying
    // posture is a typed field that configures the connector, so the mode is stripped rather
    // than rewritten, and one implementation does it for both this harness and the lifecycle.
    let config = db::parse_pg_config(database_url, "database.url")?;
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
    /// The fixture's coordinates, typed.
    ///
    /// This replaced parsing two DSNs back apart to recover the owner and the database name --
    /// `get_user()` and `get_dbname()` on a re-parsed connection string. Those are schema
    /// fields, so there is nothing to recover: `database.owning_role` and `database.database`
    /// say what they are. The DSN is now assembled FROM them rather than mined for them, which
    /// also retires `parse_fixture_pg_config` and its sslmode rewriting -- the verifying modes
    /// tokio-postgres rejects never reach a parser, because the posture is a typed enum that
    /// configures the connector.
    fn from_env() -> anyhow::Result<Self> {
        // FAILS rather than skips. Reaching this code already means the caller passed
        // --//build:enable_integration_tests, because requires_shared_fixture() makes the target
        // incompatible otherwise -- so an unreachable fixture here is a broken run, not an
        // absent opt-in. Returning Ok(None) turned that into a green target asserting nothing.
        let fixture = db::config::Fixture::from_env().context(
            "the fixture did not resolve; this target opted in with \
             --//build:enable_integration_tests, so this is a failure and not a skip",
        )?;

        // This target's OWN database, not the shared fixture. Three targets that all reset
        // `database.database` delete each other's schema mid-run; //build/integration_shards.bzl
        // records the same lesson for the Elixir shards, measured as 40P01 deadlock_detected.
        // teardown_db drops everything matching this run id, so nothing new cleans up.
        let suffix = std::env::var("SRQL_TEST_DB_SUFFIX").context(
            "SRQL_TEST_DB_SUFFIX is set by this target's `env` in BUILD.bazel and names its \
             disposable database",
        )?;
        let database_name = db::shard_database_name(&suffix)?;
        let database_owner = fixture.owning_role()?.to_string();
        let admin_database = fixture.admin_database()?.to_string();

        Ok(Self {
            database_url: fixture.database_url(&database_name)?.expose().to_string(),
            // admin_url_for, not database_url: the latter resolves connecting_role (`srql`),
            // which ci.textproto deliberately denies CREATEDB, so every CREATE/DROP DATABASE
            // below would be refused.
            admin_url: fixture.admin_url_for(&admin_database)?.expose().to_string(),
            database_name,
            database_owner,
        })
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
        let admin_config = db::parse_pg_config(&config.admin_url, "database.admin_url")?;
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
        // The guard //rust/integration-db already owns: refuse anything outside the disposable
        // prefix. Without it this terminates backends on, and drops, whatever name it was handed
        // -- which was `database.database`, the fixture concurrent branches share.
        db::assert_disposable(&config.database_name)?;

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
        // db::parse_pg_config, not a bare parse: the assembled DSN carries sslmode=verify-full,
        // which tokio-postgres rejects outright. The shared parser strips it and the connector
        // re-establishes verification.
        let mut extension_config = db::parse_pg_config(&config.admin_url, "database.admin_url")?;
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

fn quote_ident(value: &str) -> String {
    format!("\"{}\"", value.replace('"', "\"\""))
}

fn quote_literal(value: &str) -> String {
    format!("'{}'", value.replace('\'', "''"))
}

fn log_connection_details(name: &str, url: &str) {
    match db::parse_pg_config(url, name) {
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
    // Through the shared parser: the assembled DSN carries `sslmode=verify-full`, which
    // tokio-postgres rejects outright -- it accepts only disable/prefer/require. The verifying
    // posture is a typed field that configures the connector, so the mode is stripped rather
    // than rewritten, and one implementation does it for both this harness and the lifecycle.
    let config = db::parse_pg_config(database_url, "database.url")?;
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

/// The fixture's TLS material, as PEM CONTENT.
///
/// It used to be paths, which is why this file carried machinery to turn a PEM into a temporary
/// file: `PGSSLROOTCERT` was a path, `SRQL_TEST_DATABASE_CA_CERT` was either a path or PEM, and
/// the consumer only accepted a path. srql now takes content, so all of that is gone -- along
/// with the four variables, which could each disagree about which server was being verified.
struct FixtureTlsConfig {
    ca_pem: Option<Vec<u8>>,
    client_cert_pem: Option<Vec<u8>>,
    client_key_pem: Option<Vec<u8>>,
    server_name: Option<String>,
}

impl FixtureTlsConfig {
    /// Resolved by srql's own code, not a second implementation. The harness must verify the
    /// fixture exactly as the service does, or it proves the wrong thing.
    fn from_env() -> anyhow::Result<Self> {
        let tls = srql::config::DatabaseTls::resolve()?;
        Ok(Self {
            ca_pem: tls.ca_pem,
            client_cert_pem: tls.client_cert_pem,
            client_key_pem: tls.client_key_pem,
            server_name: tls.server_name,
        })
    }

    /// Built by srql's shared builder, so the harness's connection verifies the fixture by
    /// exactly the code path the service uses.
    fn connector(&self) -> anyhow::Result<Option<PgRustlsConnect>> {
        let Some(ca) = self.ca_pem.as_deref() else {
            return Ok(None);
        };

        Ok(Some(srql::tls::postgres_connector(
            ca,
            self.client_cert_pem.as_deref(),
            self.client_key_pem.as_deref(),
            self.server_name.as_deref(),
        )?))
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

#[cfg(test)]
mod tests {
    use super::*;
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
