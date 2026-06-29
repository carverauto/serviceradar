//! Engine configuration, loaded from the environment (`CORRELATION_ENGINE_*`),
//! mirroring `rust/srql`'s `envy`-based pattern.

use serde::Deserialize;

use crate::domain_model::DEFAULT_OPERATOR_RULE_TTL_MS;
use crate::error::{CorrelationEngineError, Result};

/// Runtime configuration for the fused engine.
#[derive(Debug, Clone, Deserialize)]
pub struct Config {
    /// CNPG host (consumed via `EmbeddedSrql` in task 1.2).
    #[serde(default = "default_cnpg_host")]
    pub cnpg_host: String,
    /// CNPG port.
    #[serde(default = "default_cnpg_port")]
    pub cnpg_port: u16,
    /// NATS URL (live `signals.state.>` deltas in; `signals.analytics.predictions` out).
    #[serde(default = "default_nats_url")]
    pub nats_url: String,
    /// Optional NATS mTLS root CA path.
    #[serde(default)]
    pub nats_ca_file: Option<String>,
    /// Optional NATS mTLS client certificate path.
    #[serde(default)]
    pub nats_cert_file: Option<String>,
    /// Optional NATS mTLS client key path.
    #[serde(default)]
    pub nats_key_file: Option<String>,
    /// Reasoning-tick cadence in milliseconds.
    #[serde(default = "default_tick_interval_ms")]
    pub tick_interval_ms: u64,
    /// Full SRQL re-snapshot cadence in milliseconds (reconciles + picks up new
    /// entities; live `signals.state.>` deltas keep the Context current between).
    #[serde(default = "default_refresh_interval_ms")]
    pub refresh_interval_ms: u64,
    /// On-disk Context snapshot path for fast restart (task 1.7).
    #[serde(default = "default_snapshot_path")]
    pub snapshot_path: String,
    /// Maximum age for live operator-rule evidence in milliseconds. Set to 0 to disable pruning.
    #[serde(default = "default_operator_rule_ttl_ms")]
    pub operator_rule_ttl_ms: u64,
}

fn default_cnpg_host() -> String {
    "localhost".to_string()
}

fn default_cnpg_port() -> u16 {
    5432
}

fn default_nats_url() -> String {
    "nats://localhost:4222".to_string()
}

fn default_tick_interval_ms() -> u64 {
    5_000
}

fn default_refresh_interval_ms() -> u64 {
    30_000
}

fn default_snapshot_path() -> String {
    "/var/lib/serviceradar/causal-engine/snapshot".to_string()
}

fn default_operator_rule_ttl_ms() -> u64 {
    DEFAULT_OPERATOR_RULE_TTL_MS as u64
}

impl Config {
    /// Load configuration from `CORRELATION_ENGINE_*` environment variables.
    pub fn from_env() -> Result<Self> {
        envy::prefixed("CORRELATION_ENGINE_")
            .from_env::<Config>()
            .map_err(|e| CorrelationEngineError::Config(e.to_string()))
    }
}
