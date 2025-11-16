use crate::dual::DualRunConfig;
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
    pub api_key: Option<String>,
    pub allowed_origins: Option<Vec<String>>,
    pub default_limit: i64,
    pub max_limit: i64,
    pub request_timeout: Duration,
    pub dual_run: Option<DualRunConfig>,
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
    srql_allowed_origins: Option<String>,
    #[serde(default = "default_limit")]
    srql_default_limit: i64,
    #[serde(default = "default_max_limit")]
    srql_max_limit: i64,
    #[serde(default = "default_timeout_secs")]
    srql_request_timeout_secs: u64,
    #[serde(default)]
    srql_dual_run_url: Option<String>,
    #[serde(default)]
    srql_dual_run_timeout_ms: Option<u64>,
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

        let dual_run = raw.srql_dual_run_url.map(|url| DualRunConfig {
            url,
            timeout: Duration::from_millis(raw.srql_dual_run_timeout_ms.unwrap_or(2000)),
        });

        Ok(Self {
            listen_addr,
            database_url,
            max_pool_size: raw.srql_max_pool_size,
            api_key: raw.srql_api_key,
            allowed_origins,
            default_limit: raw.srql_default_limit.max(1),
            max_limit: raw.srql_max_limit.max(raw.srql_default_limit),
            request_timeout: Duration::from_secs(raw.srql_request_timeout_secs.max(1)),
            dual_run,
        })
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
