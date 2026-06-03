//! Engine configuration, loaded from the environment (`CAUSAL_ENGINE_*`),
//! mirroring `rust/srql`'s `envy`-based pattern.

use serde::Deserialize;

use crate::error::{CausalEngineError, Result};

/// Runtime configuration for the fused engine.
#[derive(Debug, Clone, Deserialize)]
pub struct Config {
    /// CNPG host (consumed via `EmbeddedSrql` in task 1.2).
    #[serde(default = "default_cnpg_host")]
    pub cnpg_host: String,
    /// CNPG port.
    #[serde(default = "default_cnpg_port")]
    pub cnpg_port: u16,
    /// NATS URL (JetStream deltas in 1.2; `signals.causal.predictions` emit in 1.6).
    #[serde(default = "default_nats_url")]
    pub nats_url: String,
    /// Reasoning-tick cadence in milliseconds (delta-driven ticks land in 1.2).
    #[serde(default = "default_tick_interval_ms")]
    pub tick_interval_ms: u64,
    /// On-disk Context snapshot path for fast restart (task 1.7).
    #[serde(default = "default_snapshot_path")]
    pub snapshot_path: String,
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

fn default_snapshot_path() -> String {
    "/var/lib/serviceradar/causal-engine/snapshot".to_string()
}

impl Config {
    /// Load configuration from `CAUSAL_ENGINE_*` environment variables.
    pub fn from_env() -> Result<Self> {
        envy::prefixed("CAUSAL_ENGINE_")
            .from_env::<Config>()
            .map_err(|e| CausalEngineError::Config(e.to_string()))
    }
}
