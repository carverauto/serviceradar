use anyhow::{Context, Result};
use serde::Deserialize;
use std::{
    env,
    net::{SocketAddr, ToSocketAddrs},
    time::Duration,
};

#[derive(Debug, Clone)]
pub struct AppConfig {
    pub listen_addr: SocketAddr,
    pub database_url: String,
    pub age_graph_name: String,
    pub max_pool_size: u32,
    /// PEM CONTENT, not paths. A path is meaningful only on the host that resolves it, and
    /// SecretManager yields content because the same secret is a Kubernetes secret, a Docker
    /// secret and a developer's file depending on the environment.
    pub database_ca_pem: Option<Vec<u8>>,
    pub database_client_cert_pem: Option<Vec<u8>>,
    pub database_client_key_pem: Option<Vec<u8>>,
    /// The name TLS verification is performed against -- `DatabaseConfig.tls_server_name`, not an
    /// environment variable. It reaches the connector, never the DSN.
    pub database_tls_server_name: Option<String>,
    pub api_key: Option<String>,
    pub api_key_kv_key: Option<String>,
    pub allowed_origins: Option<Vec<String>>,
    pub default_limit: i64,
    pub max_limit: i64,
    pub cursor_secret: String,
    pub max_cursor_offset: i64,
    pub request_timeout: Duration,
    pub db_statement_timeout: Duration,
    pub rate_limit_max_requests: u64,
    pub rate_limit_window: Duration,
}

#[derive(Debug, Deserialize)]
struct RawConfig {
    #[serde(default)]
    srql_listen_addr: Option<String>,
    #[serde(default)]
    srql_listen_host: Option<String>,
    #[serde(default)]
    srql_listen_port: Option<u16>,
    #[serde(default)]
    srql_database_url: Option<String>,
    #[serde(default)]
    database_url: Option<String>,
    #[serde(default)]
    srql_age_graph_name: Option<String>,
    #[serde(default = "default_pool_size")]
    srql_max_pool_size: u32,
    #[serde(default)]
    srql_api_key: Option<String>,
    #[serde(default)]
    srql_api_key_kv_key: Option<String>,
    #[serde(default)]
    srql_allowed_origins: Option<String>,
    #[serde(default = "default_limit")]
    srql_default_limit: i64,
    #[serde(default = "default_max_limit")]
    srql_max_limit: i64,
    #[serde(default)]
    srql_cursor_secret: Option<String>,
    #[serde(default = "default_max_cursor_offset")]
    srql_max_cursor_offset: i64,
    #[serde(default = "default_timeout_secs")]
    srql_request_timeout_secs: u64,
    #[serde(default = "default_db_statement_timeout_secs")]
    srql_db_statement_timeout_secs: u64,
    #[serde(default = "default_rate_limit_requests")]
    srql_rate_limit_max: u64,
    #[serde(default = "default_rate_limit_window_secs")]
    srql_rate_limit_window_secs: u64,
}

const fn default_pool_size() -> u32 {
    10
}

const fn default_limit() -> i64 {
    100
}

const fn default_max_limit() -> i64 {
    0
}

const fn default_max_cursor_offset() -> i64 {
    100_000
}

const fn default_timeout_secs() -> u64 {
    30
}

const fn default_db_statement_timeout_secs() -> u64 {
    30
}

const fn default_rate_limit_requests() -> u64 {
    120
}

const fn default_rate_limit_window_secs() -> u64 {
    60
}

impl AppConfig {
    pub fn from_env() -> Result<Self> {
        // Database TLS comes from the environment SERVICERADAR_ENV names: the posture and the
        // verification name from the committed instance, the PEMs from the provider that same
        // identity selects. It replaced PGSSLROOTCERT/PGSSLCERT/PGSSLKEY/PGSSLSERVERNAME/
        // PGSSLTARGETNAME -- five ambient variables that could each disagree with the others and
        // with the database actually being connected to.
        let tls = DatabaseTls::resolve()?;

        let raw: RawConfig =
            envy::from_env().context("failed to parse SRQL_* environment variables")?;

        let listen_addr = resolve_addr(
            raw.srql_listen_addr,
            raw.srql_listen_host,
            raw.srql_listen_port,
        )?;

        let database_url = raw
            .srql_database_url
            .or(raw.database_url)
            .or_else(|| env::var("DATABASE_URL").ok())
            .context("SRQL_DATABASE_URL or DATABASE_URL must be set")?;

        let age_graph_name = raw
            .srql_age_graph_name
            .or_else(|| env::var("AGE_GRAPH_NAME").ok())
            .unwrap_or_else(|| "platform_graph".to_string());

        let allowed_origins = raw.srql_allowed_origins.and_then(|csv| {
            let trimmed: Vec<_> = csv
                .split(',')
                .filter_map(|part| {
                    let entry = part.trim();
                    if entry.is_empty() {
                        None
                    } else {
                        Some(entry.to_string())
                    }
                })
                .collect();
            if trimmed.is_empty() {
                None
            } else {
                Some(trimmed)
            }
        });

        let api_key = raw.srql_api_key.and_then(non_empty_string);
        let cursor_secret = raw
            .srql_cursor_secret
            .and_then(non_empty_string)
            .context("SRQL_CURSOR_SECRET must be set")?;

        Ok(Self {
            listen_addr,
            database_url,
            age_graph_name,
            max_pool_size: raw.srql_max_pool_size,
            database_ca_pem: tls.ca_pem,
            database_client_cert_pem: tls.client_cert_pem,
            database_client_key_pem: tls.client_key_pem,
            database_tls_server_name: tls.server_name,
            api_key,
            api_key_kv_key: raw.srql_api_key_kv_key,
            allowed_origins,
            default_limit: raw.srql_default_limit.max(1),
            max_limit: if raw.srql_max_limit <= 0 {
                0
            } else {
                raw.srql_max_limit.max(raw.srql_default_limit)
            },
            cursor_secret,
            max_cursor_offset: raw.srql_max_cursor_offset.max(0),
            request_timeout: Duration::from_secs(raw.srql_request_timeout_secs.max(1)),
            db_statement_timeout: Duration::from_secs(raw.srql_db_statement_timeout_secs.max(1)),
            rate_limit_max_requests: raw.srql_rate_limit_max.max(1),
            rate_limit_window: Duration::from_secs(raw.srql_rate_limit_window_secs.max(1)),
        })
    }

    pub fn embedded(database_url: String) -> Self {
        Self {
            listen_addr: "127.0.0.1:0".parse().expect("valid socket addr"),
            database_url,
            age_graph_name: "platform_graph".to_string(),
            max_pool_size: default_pool_size(),
            database_ca_pem: None,
            database_client_cert_pem: None,
            database_client_key_pem: None,
            database_tls_server_name: None,
            api_key: None,
            api_key_kv_key: None,
            allowed_origins: None,
            default_limit: default_limit(),
            max_limit: default_max_limit(),
            cursor_secret: "embedded-srql-cursor-secret".to_string(),
            max_cursor_offset: default_max_cursor_offset(),
            request_timeout: Duration::from_secs(default_timeout_secs()),
            db_statement_timeout: Duration::from_secs(default_db_statement_timeout_secs()),
            rate_limit_max_requests: default_rate_limit_requests(),
            rate_limit_window: Duration::from_secs(default_rate_limit_window_secs()),
        }
    }
}

fn non_empty_string(value: String) -> Option<String> {
    let trimmed = value.trim();
    if trimmed.is_empty() {
        None
    } else {
        Some(trimmed.to_string())
    }
}

fn resolve_addr(
    addr: Option<String>,
    host: Option<String>,
    port: Option<u16>,
) -> Result<SocketAddr> {
    if let Some(addr) = addr {
        return addr
            .to_socket_addrs()
            .context("invalid SRQL_LISTEN_ADDR value")?
            .next()
            .context("SRQL_LISTEN_ADDR resolved to no addresses");
    }

    let host = host.unwrap_or_else(|| "0.0.0.0".to_string());
    let port = port.unwrap_or(8480);
    let combined = format!("{}:{}", host, port);
    combined
        .to_socket_addrs()
        .context("invalid SRQL listen host/port combination")?
        .next()
        .context("listen address resolved to no targets")
}

/// Database TLS material, resolved from the environment rather than from five variables.
///
/// `SERVICERADAR_ENV` names the environment; ConfigManager yields the posture and the
/// verification name from the committed instance, and SecretManager yields the PEMs from the
/// provider that same identity selects. Nothing here reads a per-setting variable, so there is no
/// combination of PGSSL* that can describe a server this process is not talking to.
pub struct DatabaseTls {
    pub ca_pem: Option<Vec<u8>>,
    pub client_cert_pem: Option<Vec<u8>>,
    pub client_key_pem: Option<Vec<u8>>,
    pub server_name: Option<String>,
}

impl DatabaseTls {
    pub fn resolve() -> Result<Self> {
        use serviceradar_config_manager::{
            built_ins, fetch_ca_bundle, ConfigManager, Filesystem, Identity, DATABASE_CA_CERT,
            DATABASE_CLIENT_CERT, DATABASE_CLIENT_KEY,
        };
        use serviceradar_config_schema::TlsMode;
        use serviceradar_secret_manager::{EnvironmentProvider, Manifest, SecretManager};

        let identity = Identity::from_env().map_err(|e| anyhow::anyhow!("{e}"))?;
        let manager = ConfigManager::load(&identity, built_ins(), &Filesystem)
            .map_err(|e| anyhow::anyhow!("{e}"))?;

        let database = manager
            .database()
            .context("the environment declares no database section")?;

        // The typed posture decides whether a CA is needed at all -- not the presence of a
        // variable, which is what let a verifying mode run without one.
        let verifies = matches!(
            TlsMode::try_from(database.tls_mode.unwrap_or_default()),
            Ok(TlsMode::VerifyCa) | Ok(TlsMode::VerifyFull)
        );

        if !verifies {
            return Ok(Self {
                ca_pem: None,
                client_cert_pem: None,
                client_key_pem: None,
                server_name: None,
            });
        }

        // A named bundle wins over a stored copy, the same order //rust/integration-db uses. A
        // cert-manager issuer rotates, so any copy is correct until it is not. Not consulting it
        // here is what failed the srql integration tests against the CI fixture while the fixture
        // lifecycle targets, which do consult it, connected fine.
        if let Some(url) = manager.ca_bundle_url() {
            return Ok(Self {
                ca_pem: Some(fetch_ca_bundle(url).map_err(|e| anyhow::anyhow!("{e}"))?),
                client_cert_pem: None,
                client_key_pem: None,
                server_name: database.tls_server_name.clone(),
            });
        }

        let secrets = SecretManager::new(
            EnvironmentProvider::for_kind(identity.kind()),
            Manifest::new([DATABASE_CA_CERT, DATABASE_CLIENT_CERT, DATABASE_CLIENT_KEY]),
        );

        let ca = secrets
            .resolve(DATABASE_CA_CERT)
            .map_err(|e| anyhow::anyhow!("database.tls_mode verifies the server, so {DATABASE_CA_CERT} is required: {e}"))?;

        // Client certificates are optional: a server that does not ask for one is the common
        // case. Both or neither -- srql::tls rejects half an identity rather than silently
        // connecting anonymously to a server that requires mTLS.
        let client_cert = secrets.resolve(DATABASE_CLIENT_CERT).ok();
        let client_key = secrets.resolve(DATABASE_CLIENT_KEY).ok();

        Ok(Self {
            ca_pem: Some(ca.expose().as_bytes().to_vec()),
            client_cert_pem: client_cert.map(|s| s.expose().as_bytes().to_vec()),
            client_key_pem: client_key.map(|s| s.expose().as_bytes().to_vec()),
            server_name: database.tls_server_name.clone(),
        })
    }
}

