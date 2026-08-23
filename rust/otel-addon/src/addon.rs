/*
 * Copyright 2026 Carver Automation Corporation.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

//! The [`Addon`] implementation: Configure builds (or rebuilds) the OTLP
//! collector around the agent-forward spool; RelayOtlp drains that spool to
//! the agent with cumulative-ack watermarking; StreamTelemetry carries the
//! spool monitor's OCSF usage events (native-telemetry:v1).

use std::net::SocketAddr;
use std::sync::{Arc, Mutex, MutexGuard};
use std::time::Duration;

use addon_sdk::{
    Addon, CAPABILITY_NATIVE_TELEMETRY_V1, CAPABILITY_OTLP_RELAY_V1, ConfigureResult, Health,
    HealthStatus, Info, OtlpRelayAckStream, OtlpRelayStream, TelemetryStream, pb,
};
use async_trait::async_trait;
use log::{debug, error, info, warn};
use sha2::{Digest as _, Sha256};
use tokio::sync::broadcast;
use tokio::task::JoinHandle;
use tokio_stream::StreamExt as _;
use tokio_stream::wrappers::errors::BroadcastStreamRecvError;
use tokio_stream::wrappers::{BroadcastStream, ReceiverStream};

use crate::spool_monitor::spawn_spool_monitor;

use otel::ServiceRadarCollector;
use otel::agent_forward::AgentForwardOutput;
use otel::agent_forward::spool::{Spool, SpoolConfig};
use otel::config::{Config as CollectorConfig, OutputBackend};

pub const ADDON_ID: &str = "otel-collector";
const ADDON_VERSION: &str = env!("CARGO_PKG_VERSION");

/// Spool fill ratio at which Health reports Degraded (90%).
const SPOOL_DEGRADED_NUM: u64 = 9;
const SPOOL_DEGRADED_DEN: u64 = 10;

/// A listener that fails to start is retried a few times (e.g. the previous
/// runtime's socket is still closing during a reconfigure) and then the task
/// exits, which Health surfaces as Degraded.
const LISTENER_START_ATTEMPTS: u32 = 5;
const LISTENER_RETRY_DELAY: Duration = Duration::from_millis(500);

/// Relay frames buffered between the spool reader task and the gRPC stream.
const RELAY_CHANNEL_DEPTH: usize = 16;

/// Spool-usage telemetry batches buffered for slow StreamTelemetry readers.
const TELEMETRY_CHANNEL_DEPTH: usize = 64;

pub struct OtelCollectorAddon {
    state: Mutex<State>,
    /// Fan-out for the spool monitor's OCSF usage events; StreamTelemetry
    /// subscribes here (native-telemetry:v1, lossy by contract).
    telemetry_tx: broadcast::Sender<pb::TelemetryBatch>,
}

impl Default for OtelCollectorAddon {
    fn default() -> Self {
        let (telemetry_tx, _) = broadcast::channel(TELEMETRY_CHANNEL_DEPTH);
        Self {
            state: Mutex::default(),
            telemetry_tx,
        }
    }
}

#[derive(Default)]
struct State {
    /// Hash of the currently-applied configuration (change detection).
    config_hash: String,
    /// Durable relay spool shared by the collector output and RelayOtlp.
    spool: Option<Arc<Spool>>,
    /// Spool settings backing `spool`, for reuse detection on reconfigure.
    spool_config: Option<SpoolConfig>,
    runtime: Option<Runtime>,
    /// Spool usage monitor task (one per open spool instance).
    monitor: Option<JoinHandle<()>>,
}

/// Listener tasks for the currently-applied configuration.
struct Runtime {
    grpc: JoinHandle<()>,
    http: Option<JoinHandle<()>>,
    metrics: Option<JoinHandle<()>>,
}

impl Runtime {
    fn shutdown(&self) {
        self.grpc.abort();
        if let Some(http) = &self.http {
            http.abort();
        }
        if let Some(metrics) = &self.metrics {
            metrics.abort();
        }
    }

    /// Name of the first listener whose task has exited, if any.
    fn down_listener(&self) -> Option<&'static str> {
        if self.grpc.is_finished() {
            return Some("OTLP/gRPC");
        }
        if self.http.as_ref().is_some_and(JoinHandle::is_finished) {
            return Some("OTLP/HTTP");
        }
        if self.metrics.as_ref().is_some_and(JoinHandle::is_finished) {
            return Some("metrics");
        }
        None
    }
}

/// Everything Configure validates *before* it tears down the previous
/// runtime, so a bad config never kills a working collector.
struct PreparedRuntime {
    collector: ServiceRadarCollector,
    grpc_addr: SocketAddr,
    grpc_tls: Option<tonic::transport::ServerTlsConfig>,
    max_request_bytes: usize,
    ingest_auth: Arc<otel::auth::IngestAuth>,
    http_options: Option<otel::http_server::HttpServerOptions>,
    metrics_addr: Option<SocketAddr>,
}

impl OtelCollectorAddon {
    fn lock_state(&self) -> MutexGuard<'_, State> {
        self.state
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
    }

    #[cfg(test)]
    fn spool_for_tests(&self) -> Option<Arc<Spool>> {
        self.lock_state().spool.clone()
    }
}

fn reject(config_hash: String, error: impl Into<String>) -> ConfigureResult {
    let error = error.into();
    warn!("rejecting configuration: {error}");
    ConfigureResult {
        config_hash,
        accepted: false,
        error,
    }
}

/// Parses the operator config (validated upstream against
/// `addons/otel-collector/config.schema.json`) into the collector config.
/// The required/default add-on shape omits `[output]` and relays through the
/// agent; explicit `output.backend = "jetstream"` is preserved for leaf-edge
/// deployments with a local NATS leaf.
fn parse_config(config_json: &[u8]) -> Result<CollectorConfig, String> {
    let trimmed: &[u8] = {
        let s = std::str::from_utf8(config_json).unwrap_or("");
        s.trim().as_bytes()
    };

    let (mut config, explicit_backend): (CollectorConfig, bool) = if trimmed.is_empty() {
        (CollectorConfig::default(), false)
    } else {
        let value: serde_json::Value = serde_json::from_slice(trimmed)
            .map_err(|e| format!("invalid configuration JSON: {e}"))?;
        let explicit_backend = value
            .get("output")
            .and_then(|output| output.get("backend"))
            .is_some();
        let config = serde_json::from_value(value)
            .map_err(|e| format!("invalid configuration JSON: {e}"))?;
        (config, explicit_backend)
    };

    if !explicit_backend {
        config.output.backend = OutputBackend::Agent;
    }

    if explicit_backend
        && config.output.backend == OutputBackend::Jetstream
        && config.nats.is_none()
    {
        return Err("direct JetStream output requires an explicit local NATS endpoint".to_string());
    }

    if explicit_backend
        && config.output.backend == OutputBackend::Jetstream
        && config
            .nats
            .as_ref()
            .and_then(|nats| nats.creds_file.as_deref())
            .is_some_and(|path| !path.trim().is_empty())
    {
        return Err(
            "direct JetStream output does not accept NATS .creds material; use assignment-scoped mTLS"
                .to_string(),
        );
    }

    Ok(config)
}

/// Validates the config and builds everything needed to start listeners.
fn prepare_runtime(
    config: &CollectorConfig,
    collector: ServiceRadarCollector,
) -> Result<PreparedRuntime, String> {
    let grpc_addr: SocketAddr = config
        .bind_address()
        .parse()
        .map_err(|e| format!("invalid OTLP/gRPC bind address: {e}"))?;

    let grpc_tls = otel::tls::setup_grpc_tls(config).map_err(|e| e.to_string())?;

    let ingest_auth = otel::auth::IngestAuth::from_config(&config.auth)
        .map_err(|e| format!("invalid [auth] configuration: {e}"))?;

    let http_options =
        otel::http_server::HttpServerOptions::from_config(config).map_err(|e| e.to_string())?;

    let metrics_addr = match config.metrics_address() {
        Some(addr) => Some(
            addr.parse::<SocketAddr>()
                .map_err(|e| format!("invalid metrics bind address: {e}"))?,
        ),
        None => None,
    };

    Ok(PreparedRuntime {
        collector,
        grpc_addr,
        grpc_tls,
        max_request_bytes: config.server.max_request_bytes,
        ingest_auth: Arc::new(ingest_auth),
        http_options,
        metrics_addr,
    })
}

fn prepare_agent_runtime(
    config: &CollectorConfig,
    spool: &Arc<Spool>,
) -> Result<PreparedRuntime, String> {
    let output = AgentForwardOutput::new(Arc::clone(spool));
    let collector = ServiceRadarCollector::with_output(Arc::new(output));
    prepare_runtime(config, collector)
}

async fn prepare_direct_runtime(config: &CollectorConfig) -> Result<PreparedRuntime, String> {
    let collector = match config.output.backend {
        OutputBackend::Jetstream => otel::server::create_collector_from_config(config)
            .await
            .map_err(|e| e.to_string())?,
        OutputBackend::Otlp => {
            return Err("output backend \"otlp\" is reserved and not implemented yet".to_string());
        }
        OutputBackend::Agent => {
            return Err("agent output must use the RelayOtlp spool runtime".to_string());
        }
    };

    prepare_runtime(config, collector)
}

/// Spawns the listener tasks. A listener retries startup a few times and
/// then gives up; the finished task is what Health reports as Degraded.
fn spawn_runtime(prepared: PreparedRuntime) -> Runtime {
    let PreparedRuntime {
        collector,
        grpc_addr,
        grpc_tls,
        max_request_bytes,
        ingest_auth,
        http_options,
        metrics_addr,
    } = prepared;

    let grpc_collector = collector.clone();
    let grpc = tokio::spawn(async move {
        for attempt in 1..=LISTENER_START_ATTEMPTS {
            let tls = grpc_tls.clone();
            // Errors are flattened to String immediately: the boxed listener
            // error is not Send and must not live across the retry sleep.
            let result = otel::server::start_server(
                grpc_addr,
                tls,
                grpc_collector.clone(),
                max_request_bytes,
                Arc::clone(&ingest_auth),
            )
            .await
            .map_err(|e| e.to_string());
            match result {
                Ok(()) => return,
                Err(e) => {
                    error!("OTLP/gRPC listener failed (attempt {attempt}): {e}");
                    tokio::time::sleep(LISTENER_RETRY_DELAY).await;
                }
            }
        }
        error!("OTLP/gRPC listener giving up after {LISTENER_START_ATTEMPTS} attempts");
    });

    let http = http_options.map(|options| {
        let http_collector = collector.clone();
        tokio::spawn(async move {
            for attempt in 1..=LISTENER_START_ATTEMPTS {
                let result =
                    otel::http_server::start_http_server(options.clone(), http_collector.clone())
                        .await
                        .map_err(|e| e.to_string());
                match result {
                    Ok(()) => return,
                    Err(e) => {
                        error!("OTLP/HTTP listener failed (attempt {attempt}): {e}");
                        tokio::time::sleep(LISTENER_RETRY_DELAY).await;
                    }
                }
            }
            error!("OTLP/HTTP listener giving up after {LISTENER_START_ATTEMPTS} attempts");
        })
    });

    let metrics = metrics_addr.map(|addr| {
        tokio::spawn(async move {
            let result = otel::server::start_metrics_server(addr)
                .await
                .map_err(|e| e.to_string());
            if let Err(e) = result {
                error!("metrics server failed: {e}");
            }
        })
    });

    Runtime {
        grpc,
        http,
        metrics,
    }
}

#[async_trait]
impl Addon for OtelCollectorAddon {
    async fn info(&self) -> anyhow::Result<Info> {
        Ok(Info {
            id: ADDON_ID.to_string(),
            version: ADDON_VERSION.to_string(),
            capabilities: vec![
                CAPABILITY_OTLP_RELAY_V1.to_string(),
                CAPABILITY_NATIVE_TELEMETRY_V1.to_string(),
            ],
        })
    }

    async fn configure(&self, config_json: &[u8]) -> anyhow::Result<ConfigureResult> {
        let mut hasher = Sha256::new();
        hasher.update(config_json);
        let config_hash = hex::encode(hasher.finalize());

        let config = match parse_config(config_json) {
            Ok(config) => config,
            Err(e) => return Ok(reject(config_hash, e)),
        };

        match config.output.backend {
            OutputBackend::Agent => {
                let agent_forward = config.agent_forward.clone().unwrap_or_default();
                let spool_config = agent_forward.spool_config();

                let mut state = self.lock_state();

                if state.config_hash == config_hash && state.runtime.is_some() {
                    debug!("configuration unchanged (hash {config_hash}); keeping current runtime");
                    return Ok(ConfigureResult {
                        config_hash,
                        accepted: true,
                        error: String::new(),
                    });
                }

                // Reuse the open spool when its settings are unchanged so the
                // relay reader, watermark, and relay_id sequence carry across
                // listener reconfigurations. Changed bounds at the same
                // location reconfigure the live spool in place; only a new
                // directory opens a new spool.
                let spool = match (&state.spool, &state.spool_config) {
                    (Some(spool), Some(existing)) if *existing == spool_config => Arc::clone(spool),
                    (Some(spool), Some(existing)) if existing.dir == spool_config.dir => {
                        if let Err(e) = spool.reconfigure(spool_config.clone()) {
                            return Ok(reject(
                                config_hash,
                                format!("failed to apply new spool bounds: {e:#}"),
                            ));
                        }
                        info!(
                            "applied new spool bounds in place: max {} bytes, free-disk floor {} bytes",
                            spool_config.max_bytes, spool_config.min_free_disk_bytes
                        );
                        Arc::clone(spool)
                    }
                    _ => match Spool::open(spool_config.clone()) {
                        Ok(spool) => Arc::new(spool),
                        Err(e) => {
                            return Ok(reject(
                                config_hash,
                                format!("failed to open relay spool: {e:#}"),
                            ));
                        }
                    },
                };

                // Validate everything before touching the running collector: a
                // bad config must never kill a working one.
                let prepared = match prepare_agent_runtime(&config, &spool) {
                    Ok(prepared) => prepared,
                    Err(e) => return Ok(reject(config_hash, e)),
                };

                if let Some(old) = state.runtime.take() {
                    info!("configuration changed; restarting OTLP listeners");
                    old.shutdown();
                }

                info!(
                    "starting OTEL collector add-on: grpc={}, http={}, output=agent, spool={} (max {} bytes)",
                    prepared.grpc_addr,
                    prepared
                        .http_options
                        .as_ref()
                        .map(|o| o.addr.to_string())
                        .unwrap_or_else(|| "disabled".to_string()),
                    agent_forward.spool_dir,
                    agent_forward.max_bytes,
                );

                // (Re)start the usage monitor when the spool instance changed
                // (or on first configure); a reused/reconfigured spool keeps
                // its monitor.
                let spool_replaced = state
                    .spool
                    .as_ref()
                    .is_none_or(|prev| !Arc::ptr_eq(prev, &spool));
                if spool_replaced || state.monitor.as_ref().is_none_or(JoinHandle::is_finished) {
                    if let Some(old) = state.monitor.take() {
                        old.abort();
                    }
                    state.monitor = Some(spawn_spool_monitor(
                        Arc::clone(&spool),
                        self.telemetry_tx.clone(),
                        ADDON_VERSION,
                    ));
                }

                state.runtime = Some(spawn_runtime(prepared));
                state.spool = Some(spool);
                state.spool_config = Some(spool_config);
                state.config_hash = config_hash.clone();
            }
            OutputBackend::Jetstream | OutputBackend::Otlp => {
                {
                    let state = self.lock_state();
                    if state.config_hash == config_hash && state.runtime.is_some() {
                        debug!(
                            "configuration unchanged (hash {config_hash}); keeping current runtime"
                        );
                        return Ok(ConfigureResult {
                            config_hash,
                            accepted: true,
                            error: String::new(),
                        });
                    }
                }

                let prepared = match prepare_direct_runtime(&config).await {
                    Ok(prepared) => prepared,
                    Err(e) => return Ok(reject(config_hash, e)),
                };

                let mut state = self.lock_state();

                if let Some(old) = state.runtime.take() {
                    info!("configuration changed; restarting OTLP listeners");
                    old.shutdown();
                }
                if let Some(old) = state.monitor.take() {
                    old.abort();
                }

                info!(
                    "starting OTEL collector add-on: grpc={}, http={}, output={:?}",
                    prepared.grpc_addr,
                    prepared
                        .http_options
                        .as_ref()
                        .map(|o| o.addr.to_string())
                        .unwrap_or_else(|| "disabled".to_string()),
                    config.output.backend,
                );

                state.runtime = Some(spawn_runtime(prepared));
                state.spool = None;
                state.spool_config = None;
                state.config_hash = config_hash.clone();
            }
        }

        Ok(ConfigureResult {
            config_hash,
            accepted: true,
            error: String::new(),
        })
    }

    async fn health(&self) -> anyhow::Result<Health> {
        let state = self.lock_state();

        let Some(runtime) = &state.runtime else {
            return Ok(Health {
                status: HealthStatus::Degraded,
                version: ADDON_VERSION.to_string(),
                degradation_reason: "awaiting configuration".to_string(),
                details: Default::default(),
            });
        };

        if let Some(listener) = runtime.down_listener() {
            return Ok(Health {
                status: HealthStatus::Degraded,
                version: ADDON_VERSION.to_string(),
                degradation_reason: format!("{listener} listener is down"),
                details: Default::default(),
            });
        }

        if let Some(spool) = &state.spool {
            let stats = spool.stats();
            let max_bytes = spool.max_bytes();
            if max_bytes > 0
                && stats.total_bytes * SPOOL_DEGRADED_DEN >= max_bytes * SPOOL_DEGRADED_NUM
            {
                return Ok(Health {
                    status: HealthStatus::Degraded,
                    version: ADDON_VERSION.to_string(),
                    degradation_reason: format!(
                        "relay spool >=90% full ({} of {} bytes; {} records evicted)",
                        stats.total_bytes,
                        max_bytes,
                        stats.evicted.total()
                    ),
                    details: Default::default(),
                });
            }
        }

        Ok(Health {
            status: HealthStatus::Healthy,
            version: ADDON_VERSION.to_string(),
            degradation_reason: String::new(),
            details: Default::default(),
        })
    }

    /// Streams spooled frames to the agent and consumes cumulative ack
    /// watermarks. The reader resumes from the persisted watermark, so every
    /// unacked frame is replayed (with its original relay_id) when the agent
    /// reopens the stream after a reconnect.
    #[allow(clippy::result_large_err)] // tonic::Status is the gRPC seam's error type
    fn relay_otlp(&self, acks: OtlpRelayAckStream) -> Result<OtlpRelayStream, tonic::Status> {
        let (spool, configured) = {
            let state = self.lock_state();
            (state.spool.clone(), state.runtime.is_some())
        };
        let spool = match (spool, configured) {
            (Some(spool), _) => spool,
            (None, true) => {
                return Err(tonic::Status::unavailable(
                    "collector is not configured for agent relay",
                ));
            }
            (None, false) => {
                return Err(tonic::Status::unavailable("collector not configured yet"));
            }
        };

        // Ack consumer: advance the durable watermark; the spool releases
        // fully-acked segments and wakes any reader.
        let ack_spool = Arc::clone(&spool);
        tokio::spawn(async move {
            let mut acks = acks;
            while let Some(item) = acks.next().await {
                match item {
                    Ok(ack) => {
                        if let Err(e) = ack_spool.advance_watermark(ack.acked_relay_id) {
                            error!(
                                "failed to advance relay watermark to {}: {e:#}",
                                ack.acked_relay_id
                            );
                            break;
                        }
                        debug!("relay watermark advanced to {}", ack.acked_relay_id);
                    }
                    Err(status) => {
                        debug!("relay ack stream closed: {status}");
                        break;
                    }
                }
            }
        });

        // Frame pump: drain the spool from the watermark, then follow new
        // appends until the agent drops the stream.
        let (tx, rx) = tokio::sync::mpsc::channel(RELAY_CHANNEL_DEPTH);
        let mut reader = spool.reader();
        tokio::spawn(async move {
            loop {
                match reader.try_next() {
                    Ok(Some(frame)) => {
                        if tx.send(Ok(frame)).await.is_err() {
                            debug!("relay stream dropped by agent; stopping pump");
                            return;
                        }
                    }
                    Ok(None) => {
                        let position = reader.position();
                        tokio::select! {
                            _ = tx.closed() => {
                                debug!("relay stream dropped by agent; stopping pump");
                                return;
                            }
                            _ = spool.wait_for_frame_after(position) => {}
                        }
                    }
                    Err(e) => {
                        error!("relay spool read failed: {e:#}");
                        let _ = tx
                            .send(Err(tonic::Status::internal(format!(
                                "relay spool read failed: {e}"
                            ))))
                            .await;
                        return;
                    }
                }
            }
        });

        Ok(Box::pin(ReceiverStream::new(rx)))
    }

    /// Native telemetry stream (native-telemetry:v1): OCSF spool-usage
    /// events from the monitor task. Lossy by contract — a lagging receiver
    /// gets a RESOURCE_EXHAUSTED marker, not back-pressure on the monitor.
    fn stream_telemetry(&self) -> TelemetryStream {
        let stream =
            BroadcastStream::new(self.telemetry_tx.subscribe()).filter_map(|item| match item {
                Ok(batch) => Some(Ok(batch)),
                Err(BroadcastStreamRecvError::Lagged(skipped)) => {
                    Some(Err(tonic::Status::resource_exhausted(format!(
                        "otel spool telemetry receiver lagged by {skipped} batches"
                    ))))
                }
            });
        Box::pin(stream)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use addon_sdk::pb::{
        OtlpRelayAck, TelemetryBatch, TelemetryPayloadKind, TelemetryRecord, TelemetrySource,
    };
    use std::time::Instant;

    fn config_json(spool_dir: &std::path::Path, max_bytes: u64) -> Vec<u8> {
        serde_json::json!({
            "server": {
                "bind_address": "127.0.0.1",
                "port": 0,
                "http": { "enabled": false }
            },
            "agent_forward": {
                "spool_dir": spool_dir.to_string_lossy(),
                "max_bytes": max_bytes,
                // Tests must not depend on the host volume's real free
                // space; the floor has dedicated unit tests in the otel
                // crate with an injected probe.
                "min_free_disk_bytes": 0
            }
        })
        .to_string()
        .into_bytes()
    }

    fn direct_leaf_config_json() -> Vec<u8> {
        serde_json::json!({
            "output": { "backend": "jetstream" },
            "nats": { "url": "tls://nats.edge.internal:4222" },
            "server": {
                "bind_address": "127.0.0.1",
                "port": 0,
                "http": { "enabled": false }
            }
        })
        .to_string()
        .into_bytes()
    }

    fn test_batch(payload: Vec<u8>) -> TelemetryBatch {
        TelemetryBatch {
            source: Some(TelemetrySource {
                source_type: ADDON_ID.to_string(),
                source_instance: "test".to_string(),
                metadata: Default::default(),
            }),
            records: vec![TelemetryRecord {
                event_id: "evt".to_string(),
                observed_time_unix_nano: 1,
                event_time_unix_nano: 0,
                payload_kind: TelemetryPayloadKind::OtlpTraces as i32,
                payload,
                metadata: Default::default(),
            }],
            counters: None,
        }
    }

    fn ack_stream() -> (
        tokio::sync::mpsc::Sender<Result<OtlpRelayAck, tonic::Status>>,
        OtlpRelayAckStream,
    ) {
        let (tx, rx) = tokio::sync::mpsc::channel(4);
        (tx, Box::pin(ReceiverStream::new(rx)))
    }

    #[tokio::test]
    async fn info_advertises_otlp_relay_and_native_telemetry_capabilities() {
        let addon = OtelCollectorAddon::default();
        let info = addon.info().await.unwrap();
        assert_eq!(info.id, "otel-collector");
        assert_eq!(
            info.capabilities,
            vec![
                "otlp-relay:v1".to_string(),
                "native-telemetry:v1".to_string()
            ]
        );
    }

    #[tokio::test]
    async fn configure_rejects_invalid_json() {
        let addon = OtelCollectorAddon::default();
        let result = addon.configure(b"{not json").await.unwrap();
        assert!(!result.accepted);
        assert!(result.error.contains("invalid configuration JSON"));
        assert!(!result.config_hash.is_empty());
    }

    #[test]
    fn parse_config_without_output_defaults_to_agent_relay() {
        let dir = tempfile::tempdir().unwrap();
        let config = parse_config(&config_json(dir.path(), 1024 * 1024)).unwrap();
        assert_eq!(config.output.backend, OutputBackend::Agent);
    }

    #[test]
    fn parse_config_with_explicit_jetstream_preserves_direct_leaf_backend() {
        let config = parse_config(&direct_leaf_config_json()).unwrap();
        assert_eq!(config.output.backend, OutputBackend::Jetstream);
    }

    #[test]
    fn parse_config_rejects_direct_jetstream_without_nats_endpoint() {
        let config = serde_json::json!({
            "output": { "backend": "jetstream" }
        });

        let error = parse_config(config.to_string().as_bytes()).unwrap_err();
        assert!(error.contains("requires an explicit local NATS endpoint"));
    }

    #[test]
    fn parse_config_rejects_direct_jetstream_creds_file() {
        let config = serde_json::json!({
            "output": { "backend": "jetstream" },
            "nats": {
                "url": "tls://leaf.example:4222",
                "creds_file": "/run/serviceradar/nats.creds"
            }
        });

        let error = parse_config(config.to_string().as_bytes()).unwrap_err();
        assert!(error.contains("does not accept NATS .creds"));
    }

    /// fj#4383 add-on config contract test: decodes the committed
    /// core-emitted `config_json` fixture with the REAL decoder entry point
    /// so core's delivery-path emitter and this config shape cannot drift
    /// apart. Regenerate the fixture with
    /// `cd elixir/serviceradar_core && mix serviceradar.gen.addon_contract_fixtures`.
    #[test]
    fn parse_config_decodes_core_emitted_contract_fixture() {
        const CORE_EMITTED_FIXTURE: &str =
            include_str!("../../../go/pkg/agent/testdata/addonconfig_contract/otel-collector.json");

        let config = parse_config(CORE_EMITTED_FIXTURE.as_bytes()).unwrap();

        // Explicit backend in the delivered config must be preserved.
        assert_eq!(config.output.backend, OutputBackend::Jetstream);

        let nats = config.nats.expect("nats section present");
        assert_eq!(nats.url, "tls://nats.demo.internal:4222");
        assert_eq!(nats.stream, "events");
        assert_eq!(nats.timeout_secs, 15);

        assert_eq!(config.server.bind_address, "0.0.0.0");
        assert_eq!(config.server.port, 4317);

        let forward = config.agent_forward.expect("agent_forward section present");
        assert_eq!(forward.spool_dir, "/var/lib/serviceradar/otel-spool");
    }

    #[tokio::test]
    async fn health_is_degraded_before_configuration() {
        let addon = OtelCollectorAddon::default();
        let health = addon.health().await.unwrap();
        assert_eq!(health.status, HealthStatus::Degraded);
        assert!(health.degradation_reason.contains("awaiting configuration"));
    }

    #[tokio::test]
    async fn relay_before_configuration_is_unavailable() {
        let addon = OtelCollectorAddon::default();
        let (_ack_tx, acks) = ack_stream();
        let err = addon.relay_otlp(acks).err().expect("must reject");
        assert_eq!(err.code(), tonic::Code::Unavailable);
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn configure_starts_runtime_and_reports_healthy() {
        let dir = tempfile::tempdir().unwrap();
        let addon = OtelCollectorAddon::default();

        let result = addon
            .configure(&config_json(dir.path(), 1024 * 1024))
            .await
            .unwrap();
        assert!(result.accepted, "error: {}", result.error);
        assert!(!result.config_hash.is_empty());

        // Give the gRPC listener a beat to bind (port 0 always succeeds).
        tokio::time::sleep(Duration::from_millis(200)).await;
        let health = addon.health().await.unwrap();
        assert_eq!(
            health.status,
            HealthStatus::Healthy,
            "reason: {}",
            health.degradation_reason
        );

        // Re-applying the identical config is a no-op with the same hash.
        let again = addon
            .configure(&config_json(dir.path(), 1024 * 1024))
            .await
            .unwrap();
        assert!(again.accepted);
        assert_eq!(again.config_hash, result.config_hash);
    }

    // Asserted against the parsed config rather than a live `configure`, deliberately.
    //
    // Direct JetStream now requires an explicit NATS endpoint, so this fixture has to name
    // one -- and `configure` reaches `prepare_direct_runtime`, which calls
    // `create_collector_from_config` and connects eagerly (`ConnectOptions::connect`, no
    // `retry_on_initial_connect`). That needs a live broker: in a hermetic sandbox the
    // hostname fails DNS resolution, and pointing it at loopback only trades that for
    // connection-refused. There is no URL that makes a `configure`-level assertion hermetic.
    //
    // The claim this test exists to make is still provable without connecting: a relay spool
    // is built ONLY under `OutputBackend::Agent` (see `configure`), so a config that parses to
    // `Jetstream` with no `[agent_forward]` section cannot reach the spool-creating arm at all.
    // Asserting that is stronger than asserting the spool happens to be absent afterwards,
    // because it holds regardless of runtime state.
    //
    // What is NOT covered here, and needs a broker to cover: the post-configure runtime
    // assertions (health reports Healthy, and relay_otlp refuses with Unavailable /
    // "not configured for agent relay"). Those belong in an integration test with a real NATS.
    #[test]
    fn direct_leaf_jetstream_config_cannot_build_a_relay_spool() {
        let config = parse_config(&direct_leaf_config_json()).expect("direct leaf config accepted");

        assert_eq!(config.output.backend, OutputBackend::Jetstream);
        assert!(
            config.agent_forward.is_none(),
            "a direct-leaf config must not carry [agent_forward]; a spool would be built for it"
        );
        assert!(
            config.nats.is_some(),
            "direct JetStream requires an explicit NATS endpoint"
        );
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn relay_streams_frames_and_acks_advance_watermark() {
        let dir = tempfile::tempdir().unwrap();
        let addon = OtelCollectorAddon::default();
        addon
            .configure(&config_json(dir.path(), 1024 * 1024))
            .await
            .unwrap();

        let spool = addon.spool_for_tests().expect("spool after configure");
        let relay_id = spool.append_batch(test_batch(vec![42; 64])).unwrap();

        let (ack_tx, acks) = ack_stream();
        let mut stream = addon.relay_otlp(acks).expect("relay stream");

        let frame = tokio::time::timeout(Duration::from_secs(5), stream.next())
            .await
            .expect("frame within timeout")
            .expect("stream open")
            .expect("frame ok");
        assert_eq!(frame.relay_id, relay_id);
        assert_eq!(
            frame.batch.unwrap().records[0].payload,
            vec![42u8; 64],
            "frame carries the spooled batch verbatim"
        );

        ack_tx
            .send(Ok(OtlpRelayAck {
                acked_relay_id: relay_id,
            }))
            .await
            .unwrap();

        let deadline = Instant::now() + Duration::from_secs(5);
        loop {
            if spool.stats().watermark == relay_id {
                break;
            }
            assert!(Instant::now() < deadline, "watermark never advanced");
            tokio::time::sleep(Duration::from_millis(20)).await;
        }

        // A frame appended while the stream is open must be delivered too.
        let second = spool.append_batch(test_batch(vec![7; 16])).unwrap();
        let frame = tokio::time::timeout(Duration::from_secs(5), stream.next())
            .await
            .expect("second frame within timeout")
            .expect("stream open")
            .expect("frame ok");
        assert_eq!(frame.relay_id, second);
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn health_degrades_when_spool_nears_capacity() {
        let dir = tempfile::tempdir().unwrap();
        let addon = OtelCollectorAddon::default();
        addon
            .configure(&config_json(dir.path(), 4096))
            .await
            .unwrap();
        tokio::time::sleep(Duration::from_millis(200)).await;

        let spool = addon.spool_for_tests().expect("spool after configure");
        // Fill past 90% of the 4096-byte budget (eviction does not kick in:
        // everything is still in the active segment).
        for _ in 0..40 {
            spool.append_batch(test_batch(vec![1; 64])).unwrap();
        }
        assert!(spool.stats().total_bytes * 10 >= 4096 * 9);

        let health = addon.health().await.unwrap();
        assert_eq!(health.status, HealthStatus::Degraded);
        assert!(
            health.degradation_reason.contains("spool"),
            "reason: {}",
            health.degradation_reason
        );
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn smaller_spool_bound_reconfigures_the_live_spool_in_place() {
        let dir = tempfile::tempdir().unwrap();
        let addon = OtelCollectorAddon::default();
        addon
            .configure(&config_json(dir.path(), 1024 * 1024))
            .await
            .unwrap();

        let spool = addon.spool_for_tests().expect("spool after configure");
        let relay_id = spool.append_batch(test_batch(vec![9; 64])).unwrap();

        // Deliver a smaller max_bytes: the SAME open spool must apply the
        // new bound immediately (no teardown — watermark, relay ids, and
        // spooled frames survive).
        let result = addon
            .configure(&config_json(dir.path(), 4096))
            .await
            .unwrap();
        assert!(result.accepted, "error: {}", result.error);

        let after = addon.spool_for_tests().expect("spool still open");
        assert!(
            Arc::ptr_eq(&spool, &after),
            "changed bounds must reuse the open spool, not reopen it"
        );
        assert_eq!(after.max_bytes(), 4096, "new bound is live immediately");
        assert!(
            after.stats().next_relay_id > relay_id,
            "relay id sequence carried across reconfigure"
        );

        // The monitor task survives a reuse (same spool instance).
        assert!(addon.lock_state().monitor.is_some());
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn configure_spawns_the_spool_usage_monitor() {
        let dir = tempfile::tempdir().unwrap();
        let addon = OtelCollectorAddon::default();
        assert!(addon.lock_state().monitor.is_none());
        addon
            .configure(&config_json(dir.path(), 1024 * 1024))
            .await
            .unwrap();
        let monitor_running = addon
            .lock_state()
            .monitor
            .as_ref()
            .is_some_and(|m| !m.is_finished());
        assert!(monitor_running, "monitor task must be running");
    }

    #[tokio::test]
    async fn stream_telemetry_forwards_monitor_batches() {
        let addon = OtelCollectorAddon::default();
        let mut stream = addon.stream_telemetry();

        // Simulate the monitor emitting one OCSF batch.
        addon
            .telemetry_tx
            .send(test_batch(vec![5; 8]))
            .expect("stream subscribed above");

        let batch = tokio::time::timeout(Duration::from_secs(5), stream.next())
            .await
            .expect("batch within timeout")
            .expect("stream open")
            .expect("batch ok");
        assert_eq!(batch.records[0].payload, vec![5u8; 8]);
    }
}
