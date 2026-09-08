//! JetStream-backed NATS output for OTLP telemetry.
//!
//! Module layout:
//! - [`chunker`]: splits OTLP exports into publishable chunks and accounts
//!   for per-record oversize rejections.
//! - `connection`: connection state and generation-counted recovery.
//! - `stream`: JetStream stream creation and config reconciliation.
//! - `publish`: chunk publishing with bounded in-flight fan-out, plus the
//!   [`crate::output::TelemetryOutput`] implementation.

pub mod chunker;
mod connection;
mod publish;
mod stream;

use std::path::PathBuf;
use std::sync::Arc;
use std::time::Duration;

use anyhow::Result;
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
