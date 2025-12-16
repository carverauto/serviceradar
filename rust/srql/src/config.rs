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
    pub max_pool_size: u32,
    pub pg_ssl_root_cert: Option<String>,
    pub pg_ssl_cert: Option<String>,
    pub pg_ssl_key: Option<String>,
    pub api_key: Option<String>,
    pub api_key_kv_key: Option<String>,
    pub allowed_origins: Option<Vec<String>>,
    pub default_limit: i64,
    pub max_limit: i64,
    pub request_timeout: Duration,
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
    #[serde(default = "default_timeout_secs")]
    srql_request_timeout_secs: u64,
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
    500
}

const fn default_timeout_secs() -> u64 {
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

        Ok(Self {
            listen_addr,
            database_url,
            max_pool_size: raw.srql_max_pool_size,
            pg_ssl_root_cert: env::var("PGSSLROOTCERT").ok(),
            pg_ssl_cert: env::var("PGSSLCERT").ok(),
            pg_ssl_key: env::var("PGSSLKEY").ok(),
            api_key: raw.srql_api_key,
            api_key_kv_key: raw.srql_api_key_kv_key,
            allowed_origins,
            default_limit: raw.srql_default_limit.max(1),
            max_limit: raw.srql_max_limit.max(raw.srql_default_limit),
            request_timeout: Duration::from_secs(raw.srql_request_timeout_secs.max(1)),
            rate_limit_max_requests: raw.srql_rate_limit_max.max(1),
            rate_limit_window: Duration::from_secs(raw.srql_rate_limit_window_secs.max(1)),
        })
    }

    pub fn embedded(database_url: String) -> Self {
        Self {
            listen_addr: "127.0.0.1:0".parse().expect("valid socket addr"),
            database_url,
            max_pool_size: default_pool_size(),
            pg_ssl_root_cert: None,
            pg_ssl_cert: None,
            pg_ssl_key: None,
            api_key: None,
            api_key_kv_key: None,
            allowed_origins: None,
            default_limit: default_limit(),
            max_limit: default_max_limit(),
            request_timeout: Duration::from_secs(default_timeout_secs()),
            rate_limit_max_requests: default_rate_limit_requests(),
            rate_limit_window: Duration::from_secs(default_rate_limit_window_secs()),
        }
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
