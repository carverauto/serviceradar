//! JetStream-backed NATS output for OTLP telemetry.
//!
//! Module layout:
//! - [`chunker`]: splits OTLP exports into publishable chunks and accounts
//!   for per-record oversize rejections.
//! - `connection`: connection state and generation-counted recovery.
//! - `stream`: JetStream stream creation, `serviceradar.owner` claim and
//!   config reconciliation (discard-old).
//! - `publish`: chunk publishing with bounded in-flight fan-out, plus the
//!   [`crate::output::TelemetryOutput`] implementation.

pub mod chunker;
mod connection;
mod publish;
mod stream;

use std::path::PathBuf;
use std::sync::Arc;
use std::time::Duration;

use anyhow::{Result, anyhow};
use async_nats::jetstream;
use log::{debug, info};
use tempfile::TempDir;
use tokio::sync::{Mutex, RwLock, Semaphore};

use connection::ConnectionState;

// Re-exported for backwards compatibility; the type now lives with the
// output trait it belongs to.
pub use crate::output::PerformanceMetric;

/// Default bound on concurrently in-flight JetStream chunk publishes.
pub const DEFAULT_MAX_INFLIGHT_PUBLISHES: usize = 32;

#[derive(Clone, Debug)]
pub struct NATSConfig {
    pub url: String,
    pub subject: String,
    pub stream: String,
    pub logs_subject: Option<String>,
    pub timeout: Duration,
    pub max_bytes: i64,
    pub max_age: Duration,
    pub stream_replicas: usize,
    pub creds_file: Option<PathBuf>,
    pub tls_cert: Option<PathBuf>,
    pub tls_key: Option<PathBuf>,
    pub tls_ca: Option<PathBuf>,
    /// Holds control-plane-delivered PEM files alive for this runtime. The
    /// files are removed when the output is dropped and are never persisted
    /// as a NATS credentials file.
    pub tls_material_dir: Option<Arc<TempDir>>,
    /// Maximum number of concurrently in-flight chunk publishes across all
    /// export requests. Per-request chunk ordering stays sequential; this
    /// only bounds cross-request fan-out so a publish burst cannot overwhelm
    /// JetStream.
    pub max_inflight_publishes: usize,
}

impl Default for NATSConfig {
    fn default() -> Self {
        Self {
            url: "nats://localhost:4222".to_string(),
            subject: "otel".to_string(),
            stream: "events".to_string(),
            logs_subject: None,
            timeout: Duration::from_secs(30),
            max_bytes: 2 * 1024 * 1024 * 1024,
            max_age: Duration::from_secs(30 * 60),
            stream_replicas: 1,
            creds_file: None,
            tls_cert: None,
            tls_key: None,
            tls_ca: None,
            tls_material_dir: None,
            max_inflight_publishes: DEFAULT_MAX_INFLIGHT_PUBLISHES,
        }
    }
}

/// Suffix of the environment variable that overrides a stream's `max_bytes`.
pub const ENV_MAX_BYTES_SUFFIX: &str = "MAX_BYTES";
/// Suffix of the environment variable that overrides a stream's replica count.
pub const ENV_REPLICAS_SUFFIX: &str = "REPLICAS";

/// Name of the environment variable that overrides a size of `stream`:
/// `SERVICERADAR_JS_<STREAM>_<SUFFIX>`, where `<STREAM>` is the stream name
/// upper-cased with every non-alphanumeric character replaced by `_`. For the
/// default `events` stream this yields `SERVICERADAR_JS_EVENTS_MAX_BYTES` and
/// `SERVICERADAR_JS_EVENTS_REPLICAS`.
pub fn stream_env_var(stream: &str, suffix: &str) -> String {
    let stream: String = stream
        .chars()
        .map(|c| {
            if c.is_ascii_alphanumeric() {
                c.to_ascii_uppercase()
            } else {
                '_'
            }
        })
        .collect();
    format!("SERVICERADAR_JS_{stream}_{suffix}")
}

/// Reads an environment variable for [`NATSConfig::apply_env_overrides`].
///
/// A value that is not valid Unicode is returned lossily so it fails the
/// positive-integer parse instead of being treated as unset.
pub fn process_env(key: &str) -> Option<String> {
    std::env::var_os(key).map(|value| value.to_string_lossy().into_owned())
}

fn parse_positive_env<T>(key: &str, raw: &str) -> Result<T>
where
    T: std::str::FromStr + PartialOrd + Default,
{
    let trimmed = raw.trim();
    match trimmed.parse::<T>() {
        Ok(value) if value > T::default() => Ok(value),
        _ => Err(anyhow!(
            "invalid value {raw:?} for environment variable {key}: expected a positive integer"
        )),
    }
}

impl NATSConfig {
    /// Applies the `SERVICERADAR_JS_<STREAM>_MAX_BYTES` and
    /// `SERVICERADAR_JS_<STREAM>_REPLICAS` overrides to the stream size and
    /// replica count, so the precedence is environment, then the TOML value,
    /// then the compiled default. An empty or whitespace-only variable counts
    /// as unset; any other value that is not a positive integer is an error
    /// naming the variable, which fails startup.
    ///
    /// `lookup` resolves a variable name to its value; production passes
    /// [`process_env`].
    pub fn apply_env_overrides<F>(&mut self, lookup: F) -> Result<()>
    where
        F: Fn(&str) -> Option<String>,
    {
        let max_bytes_key = stream_env_var(&self.stream, ENV_MAX_BYTES_SUFFIX);
        if let Some(raw) = lookup(&max_bytes_key).filter(|raw| !raw.trim().is_empty()) {
            let max_bytes: i64 = parse_positive_env(&max_bytes_key, &raw)?;
            info!(
                "Stream '{}' max_bytes {} from {max_bytes_key} (config file value {})",
                self.stream, max_bytes, self.max_bytes
            );
            self.max_bytes = max_bytes;
        }

        let replicas_key = stream_env_var(&self.stream, ENV_REPLICAS_SUFFIX);
        if let Some(raw) = lookup(&replicas_key).filter(|raw| !raw.trim().is_empty()) {
            let replicas: usize = parse_positive_env(&replicas_key, &raw)?;
            info!(
                "Stream '{}' replicas {} from {replicas_key} (config file value {})",
                self.stream, replicas, self.stream_replicas
            );
            self.stream_replicas = replicas;
        }

        Ok(())
    }
}

/// JetStream-backed [`crate::output::TelemetryOutput`] (the
/// central-deployment backend).
///
/// Publishes hold no global lock: the `jetstream::Context` is `Clone` and
/// internally synchronized, so concurrent export requests publish
/// independently. Mutable state is confined to two narrow synchronization
/// points, neither held across a publish/ack await:
///
/// - `state` (`RwLock`): locked only long enough to clone out or swap the
///   current JetStream context.
/// - `recovery` (`Mutex`): serializes reconnect + ensure_stream so a publish
///   error storm triggers one reconnection instead of N.
pub struct NATSOutput {
    config: NATSConfig,
    state: RwLock<ConnectionState>,
    /// Serializes reconnect/stream-ensure only; never held during publishes.
    recovery: Mutex<()>,
    /// Bounds concurrently in-flight chunk publishes
    /// ([`NATSConfig::max_inflight_publishes`]).
    publish_permits: Semaphore,
    disabled: bool,
}

impl NATSOutput {
    pub async fn new(config: NATSConfig) -> Result<Self> {
        info!("Initializing NATS output");
        debug!("NATS config: {config:?}");

        let (_client, jetstream) = Self::connect(&config).await?;
        stream::ensure_stream(&jetstream, &config).await?;

        info!("NATS output initialized successfully");
        Ok(Self::from_parts(config, Some(jetstream), false))
    }

    pub fn disabled() -> Self {
        info!("NATS output disabled (no-op)");
        Self::from_parts(NATSConfig::default(), None, true)
    }

    fn from_parts(
        config: NATSConfig,
        jetstream: Option<jetstream::Context>,
        disabled: bool,
    ) -> Self {
        let permits = config.max_inflight_publishes.max(1);
        Self {
            state: RwLock::new(ConnectionState {
                jetstream,
                generation: 0,
            }),
            recovery: Mutex::new(()),
            publish_permits: Semaphore::new(permits),
            config,
            disabled,
        }
    }
}
