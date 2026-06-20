// Copyright 2026 Carver Automation Corporation.
//
// Licensed under the Apache License, Version 2.0 (the "License").
// SPDX-License-Identifier: Apache-2.0

//! The `AnomalyAddon`: consumes the agent's local metric feed
//! (`metric-feed:v1`), runs the shared detector per series, and emits anomaly
//! verdicts upstream over the native telemetry stream (`native-telemetry:v1`).

use std::fmt::Display;
use std::str::FromStr;
use std::sync::{Arc, Mutex, MutexGuard};

use addon_sdk::metric_pb::{
    Metric, MetricBatch, MetricKind, MetricPoint, MetricResource, MetricTemporality, StringMapEntry,
};
use addon_sdk::pb::{MetricFeedAck, MetricFeedFrame, TelemetryBatch, TelemetryRecord};
use addon_sdk::{
    Addon, CAPABILITY_METRIC_FEED_V1, CAPABILITY_NATIVE_TELEMETRY_V1, ConfigureResult, Health,
    HealthStatus, Info, MetricFeedAckStream, MetricFeedStream, SignalSchemaRef,
    TelemetryBatchBuilder, TelemetryStream, attach_signal_schema_ref, ocsf_event_record,
};
use async_trait::async_trait;
use prost::Message;
use serde::{Deserialize as _, de::Error as _};
use serviceradar_anomaly_core::{ReasonVerdict, SaturationGate};
use sha2::{Digest as _, Sha256};
use tokio::sync::{broadcast, mpsc};
use tokio::task::JoinHandle;
use tokio_stream::StreamExt as _;
use tokio_stream::wrappers::ReceiverStream;
use tonic::Status;

use std::path::{Path, PathBuf};

use crate::engine::{
    AnomalyTransition, DetectorEngine, EngineCheckpoint, EngineConfig, SeriesProfile,
};

const ADDON_ID: &str = "anomaly";
const ADDON_VERSION: &str = "0.1.17";
const VERDICT_CHANNEL_DEPTH: usize = 256;
const ACK_CHANNEL_DEPTH: usize = 64;
const OCSF_CLASS_EVENT_LOG_ACTIVITY: i64 = 1008;
const OCSF_CATEGORY_SYSTEM_ACTIVITY: i64 = 1;
const OCSF_ACTIVITY_CREATE: i64 = 1;
const OCSF_VERSION: &str = "1.7.0";

/// Default restart-checkpoint staleness bound (6h): a baseline whose last reading
/// is older than this is not reseeded on restart.
const DEFAULT_CHECKPOINT_MAX_AGE_NS: u64 = 6 * 60 * 60 * 1_000_000_000;
/// Default checkpoint cadence: persist after every N processed feed frames.
const DEFAULT_CHECKPOINT_WRITE_EVERY: u64 = 100;

/// Operator-supplied configuration (validated by the control plane against
/// `config.schema.json`). All fields optional; omitted ones keep the defaults.
#[derive(Debug, Default, serde::Deserialize)]
struct AddonConfig {
    #[serde(default, deserialize_with = "deserialize_optional_usize")]
    window_size: Option<usize>,
    #[serde(default, deserialize_with = "deserialize_optional_usize")]
    min_samples: Option<usize>,
    #[serde(default, deserialize_with = "deserialize_optional_f64")]
    n_sigma: Option<f64>,
    #[serde(default, deserialize_with = "deserialize_optional_usize")]
    confirm_slots: Option<usize>,
    #[serde(default, deserialize_with = "deserialize_optional_usize")]
    max_series: Option<usize>,
    /// Optional GLOBAL dispersion-floor overrides (fix #2). When set, these only
    /// ever RAISE a series' built-in per-class floor (max), letting an operator
    /// tighten the whole fleet without per-class tuning. Omitted leaves every
    /// series on its built-in default (0 for non-gauges, the gauge defaults for
    /// cpu/mem/disk). The central metric_class override channel remains a
    /// follow-up; this flat knob is the edge-only global override.
    #[serde(default, deserialize_with = "deserialize_optional_f64")]
    min_std_floor: Option<f64>,
    #[serde(default, deserialize_with = "deserialize_optional_f64")]
    min_cv: Option<f64>,
    /// Local path the add-on persists its per-series checkpoint to so a restart
    /// re-warms baselines instead of cold-starting. Unset disables checkpointing.
    checkpoint_path: Option<String>,
    /// Restart staleness bound in seconds (default 6h); series older than this
    /// are not reseeded.
    #[serde(default, deserialize_with = "deserialize_optional_u64")]
    checkpoint_max_age_secs: Option<u64>,
}

fn deserialize_optional_usize<'de, D>(deserializer: D) -> Result<Option<usize>, D::Error>
where
    D: serde::Deserializer<'de>,
{
    deserialize_optional_number(deserializer)
}

fn deserialize_optional_u64<'de, D>(deserializer: D) -> Result<Option<u64>, D::Error>
where
    D: serde::Deserializer<'de>,
{
    deserialize_optional_number(deserializer)
}

fn deserialize_optional_f64<'de, D>(deserializer: D) -> Result<Option<f64>, D::Error>
where
    D: serde::Deserializer<'de>,
{
    deserialize_optional_number(deserializer)
}

fn deserialize_optional_number<'de, D, T>(deserializer: D) -> Result<Option<T>, D::Error>
where
    D: serde::Deserializer<'de>,
    T: serde::de::DeserializeOwned + FromStr,
    T::Err: Display,
{
    let Some(value) = Option::<serde_json::Value>::deserialize(deserializer)? else {
        return Ok(None);
    };

    match value {
        serde_json::Value::Null => Ok(None),
        serde_json::Value::String(value) => {
            let trimmed = value.trim();
            if trimmed.is_empty() {
                Ok(None)
            } else {
                trimmed.parse::<T>().map(Some).map_err(D::Error::custom)
            }
        }
        value => serde_json::from_value::<T>(value)
            .map(Some)
            .map_err(D::Error::custom),
    }
}

/// Resolved checkpoint behavior derived from [`AddonConfig`]. `path` unset means
/// checkpointing is disabled (the add-on still runs, just cold-starts on restart).
#[derive(Clone)]
struct CheckpointSettings {
    path: Option<PathBuf>,
    max_age_ns: u64,
    write_every: u64,
}

impl Default for CheckpointSettings {
    fn default() -> Self {
        Self {
            path: None,
            max_age_ns: DEFAULT_CHECKPOINT_MAX_AGE_NS,
            write_every: DEFAULT_CHECKPOINT_WRITE_EVERY,
        }
    }
}

impl AddonConfig {
    fn into_engine_config(self) -> Result<EngineConfig, String> {
        let base = EngineConfig::default();
        let window_size = self.window_size.unwrap_or(base.window_size).max(1);
        let min_samples = self.min_samples.unwrap_or(base.min_samples).max(1);

        if min_samples > window_size {
            return Err(format!(
                "min_samples ({min_samples}) must be less than or equal to window_size ({window_size})"
            ));
        }

        Ok(EngineConfig {
            window_size,
            min_samples,
            n_sigma: self.n_sigma.unwrap_or(base.n_sigma),
            confirm_slots: self.confirm_slots.unwrap_or(base.confirm_slots).max(1),
            max_series: self.max_series.unwrap_or(base.max_series).max(1),
            // Only accept a finite, positive override; a 0/negative/NaN value is
            // treated as "unset" so it can never weaken a gauge's safe floor.
            min_std_floor: self.min_std_floor.filter(|v| v.is_finite() && *v > 0.0),
            min_cv: self.min_cv.filter(|v| v.is_finite() && *v > 0.0),
        })
    }
}

/// Edge anomaly add-on. Shared (`Arc`) across concurrent gRPC calls, so all
/// mutable state is behind a `Mutex`.
pub struct AnomalyAddon {
    engine: Arc<Mutex<DetectorEngine>>,
    verdict_tx: broadcast::Sender<TelemetryBatch>,
    scoring_health: Arc<Mutex<ScoringHealth>>,
    /// Resolved at `configure`; read when a feed stream opens.
    checkpoint: Mutex<CheckpointSettings>,
    /// The metric feed is single-owner: reconnecting replaces the prior scorer.
    feed_task: Mutex<Option<JoinHandle<()>>>,
}

impl Default for AnomalyAddon {
    fn default() -> Self {
        Self::new()
    }
}

impl AnomalyAddon {
    pub fn new() -> Self {
        let (verdict_tx, _) = broadcast::channel(VERDICT_CHANNEL_DEPTH);
        Self {
            engine: Arc::new(Mutex::new(DetectorEngine::new(EngineConfig::default()))),
            verdict_tx,
            scoring_health: Arc::new(Mutex::new(ScoringHealth::default())),
            checkpoint: Mutex::new(CheckpointSettings::default()),
            feed_task: Mutex::new(None),
        }
    }

    fn flush_checkpoint(&self) {
        let checkpoint = lock_checkpoint_settings(&self.checkpoint).clone();

        if let Some(path) = checkpoint.path.as_ref() {
            write_checkpoint(&self.engine, path);
        }
    }

    async fn stop_feed_task(&self) {
        let handle = lock_feed_task(&self.feed_task).take();

        if let Some(handle) = handle {
            self.flush_checkpoint();
            handle.abort();
            let _ = handle.await;
        }
    }
}

impl Drop for AnomalyAddon {
    fn drop(&mut self) {
        if let Ok(slot) = self.feed_task.get_mut()
            && let Some(handle) = slot.take()
        {
            handle.abort();
        }
    }
}

fn lock_engine(engine: &Arc<Mutex<DetectorEngine>>) -> MutexGuard<'_, DetectorEngine> {
    match engine.lock() {
        Ok(guard) => guard,
        Err(poisoned) => {
            let guard = poisoned.into_inner();
            // Preserve warmed detector state after poison recovery; at most the
            // series being mutated during the panic may be partially updated.
            engine.clear_poison();
            guard
        }
    }
}

fn lock_checkpoint_settings(
    checkpoint: &Mutex<CheckpointSettings>,
) -> MutexGuard<'_, CheckpointSettings> {
    match checkpoint.lock() {
        Ok(guard) => guard,
        Err(poisoned) => {
            let guard = poisoned.into_inner();
            checkpoint.clear_poison();
            guard
        }
    }
}

fn lock_feed_task(slot: &Mutex<Option<JoinHandle<()>>>) -> MutexGuard<'_, Option<JoinHandle<()>>> {
    match slot.lock() {
        Ok(guard) => guard,
        Err(poisoned) => {
            let guard = poisoned.into_inner();
            slot.clear_poison();
            guard
        }
    }
}

fn lock_scoring_health(health: &Arc<Mutex<ScoringHealth>>) -> MutexGuard<'_, ScoringHealth> {
    match health.lock() {
        Ok(guard) => guard,
        Err(poisoned) => {
            let guard = poisoned.into_inner();
            health.clear_poison();
            guard
        }
    }
}

#[async_trait]
impl Addon for AnomalyAddon {
    async fn info(&self) -> anyhow::Result<Info> {
        Ok(Info {
            id: ADDON_ID.to_string(),
            version: ADDON_VERSION.to_string(),
            capabilities: vec![
                CAPABILITY_METRIC_FEED_V1.to_string(),
                CAPABILITY_NATIVE_TELEMETRY_V1.to_string(),
            ],
        })
    }

    async fn configure(&self, config_json: &[u8]) -> anyhow::Result<ConfigureResult> {
        let config_hash = hex::encode(Sha256::digest(config_json));

        let parsed: AddonConfig = if config_json.is_empty() {
            AddonConfig::default()
        } else {
            match serde_json::from_slice(config_json) {
                Ok(cfg) => cfg,
                Err(err) => {
                    return Ok(ConfigureResult {
                        config_hash,
                        accepted: false,
                        error: format!("invalid anomaly add-on config: {err}"),
                    });
                }
            }
        };

        let settings = resolve_checkpoint_settings(&parsed);

        let engine_config = match parsed.into_engine_config() {
            Ok(config) => config,
            Err(err) => {
                return Ok(ConfigureResult {
                    config_hash,
                    accepted: false,
                    error: format!("invalid anomaly add-on config: {err}"),
                });
            }
        };

        lock_engine(&self.engine).set_config(engine_config);

        // Re-warm from the on-disk checkpoint before scoring resumes, so a
        // restart does not storm false positives while windows refill.
        if let Some(path) = settings.path.clone() {
            load_checkpoint(&self.engine, &path, settings.max_age_ns);
        }
        *lock_checkpoint_settings(&self.checkpoint) = settings;

        Ok(ConfigureResult {
            config_hash,
            accepted: true,
            error: String::new(),
        })
    }

    async fn health(&self) -> anyhow::Result<Health> {
        let engine = lock_engine(&self.engine);
        let engine_snapshot = EngineHealthSnapshot {
            tracked_series: engine.series_count(),
            tracked_counters: engine.counter_count(),
            max_series: engine.max_series(),
            dropped_total: engine.dropped_at_capacity,
        };
        drop(engine);

        let scoring = lock_scoring_health(&self.scoring_health).clone();
        let summary = scoring.health_summary(engine_snapshot);

        Ok(Health {
            status: summary.status,
            version: ADDON_VERSION.to_string(),
            degradation_reason: summary.detail,
        })
    }

    async fn shutdown(&self) -> anyhow::Result<()> {
        self.stop_feed_task().await;
        Ok(())
    }

    /// Hand the agent a verdict stream subscription. Every call gets a fresh
    /// receiver; lagging clients drop locally and reconnecting clients can
    /// subscribe without restarting the add-on.
    fn stream_telemetry(&self) -> TelemetryStream {
        telemetry_stream_from_receiver(self.verdict_tx.subscribe())
    }

    /// Consume the agent's local metric feed, score each sample, and ack frames.
    /// Verdicts are pushed onto the telemetry channel drained by
    /// [`Self::stream_telemetry`].
    fn stream_metric_feed(&self, frames: MetricFeedStream) -> Result<MetricFeedAckStream, Status> {
        let engine = self.engine.clone();
        let verdict_tx = self.verdict_tx.clone();
        let scoring_health = self.scoring_health.clone();
        let checkpoint = lock_checkpoint_settings(&self.checkpoint).clone();
        let (ack_tx, ack_rx) = mpsc::channel::<Result<MetricFeedAck, Status>>(ACK_CHANNEL_DEPTH);

        if let Some(prior) = lock_feed_task(&self.feed_task).take() {
            self.flush_checkpoint();
            prior.abort();
        }

        let handle = tokio::spawn(async move {
            let mut frames = frames;
            let mut frame_count: u64 = 0;
            while let Some(item) = frames.next().await {
                let frame = match item {
                    Ok(frame) => frame,
                    Err(_) => break,
                };
                process_frame(&engine, &verdict_tx, &scoring_health, &frame).await;

                // Persist the re-warm checkpoint on a frame cadence (best-effort;
                // a write failure never blocks or fails the feed).
                frame_count += 1;
                if let Some(path) = checkpoint.path.as_ref()
                    && frame_count.is_multiple_of(checkpoint.write_every)
                {
                    write_checkpoint(&engine, path);
                }

                // Cumulative ack: the agent uses this to bound in-flight frames.
                if ack_tx
                    .send(Ok(MetricFeedAck {
                        acked_feed_id: frame.feed_id,
                    }))
                    .await
                    .is_err()
                {
                    break;
                }
            }

            // Flush a final checkpoint on graceful stream end so the freshest
            // baselines survive an expected restart.
            if let Some(path) = checkpoint.path.as_ref() {
                write_checkpoint(&engine, path);
            }
        });
        *lock_feed_task(&self.feed_task) = Some(handle);

        Ok(Box::pin(ReceiverStream::new(ack_rx)))
    }
}

/// Decode one feed frame's `MetricBatch`, score every eligible point, and push a
/// verdict telemetry batch for any breaches.
async fn process_frame(
    engine: &Arc<Mutex<DetectorEngine>>,
    verdict_tx: &broadcast::Sender<TelemetryBatch>,
    scoring_health: &Arc<Mutex<ScoringHealth>>,
    frame: &MetricFeedFrame,
) {
    let batch = match MetricBatch::decode(frame.payload.as_slice()) {
        Ok(batch) => batch,
        Err(_) => return, // poison payload: drop the frame, never block the feed
    };
    let resource = batch.resource.unwrap_or_default();

    // Lock the engine only to score; never hold the std Mutex across an await.
    let mut records: Vec<TelemetryRecord> = Vec::new();
    let mut shed_report: Option<ShedReport> = None;
    let mut scored_samples = 0_u64;
    let mut last_scored_at_unix_nano = 0_u64;
    {
        let mut engine = lock_engine(engine);
        let dropped_before = engine.dropped_at_capacity;
        for metric in &batch.metrics {
            if is_process_metric(metric) {
                // Process/PID series are excluded from anomaly centrally
                // (sample_extractor) and at the edge for the same reason.
                continue;
            }

            // Monotonic cumulative counters (SNMP interface octets, etc.) cannot
            // be z-scored as raw values; rate-normalize each reading to a
            // per-second rate the same way central does before scoring.
            let counter = is_cumulative_counter(metric);

            // Per-series fidelity profile (dispersion floors + saturation gate).
            // A rate-normalized counter has NO saturation ceiling, so it stays
            // purely z-based (no gate) — a real flood must still fire. A
            // saturation gauge (cpu/mem/disk used_percent) gets the directional +
            // absolute-floor gate and the dispersion floors so a benign near-
            // constant level cannot explode into a Critical.
            let profile = if counter {
                SeriesProfile::default()
            } else {
                series_profile_for(metric)
            };

            for point in &metric.points {
                let series_key = series_key_for(&resource, metric, point);

                let value = if counter {
                    match engine.normalize_counter_with_max_rate(
                        &series_key,
                        counter_raw_value(point),
                        point.observed_at_unix_nano,
                        &counter_reset_anchor(point),
                        counter_width(metric, point),
                        max_counter_rate_per_second(metric, point),
                    ) {
                        Some(rate) => rate,
                        // Warmup / reset / gap / non-monotonic: no sample this point.
                        None => continue,
                    }
                } else {
                    point.value
                };

                scored_samples = scored_samples.saturating_add(1);
                last_scored_at_unix_nano =
                    last_scored_at_unix_nano.max(point.observed_at_unix_nano);

                if let Some(evaluated) = engine.evaluate_transition(
                    &series_key,
                    value,
                    point.observed_at_unix_nano,
                    profile,
                ) && matches!(
                    evaluated.transition,
                    AnomalyTransition::Open | AnomalyTransition::Clear
                ) {
                    records.push(verdict_record(
                        &resource,
                        metric,
                        point,
                        &series_key,
                        &evaluated.verdict,
                        evaluated.transition,
                    ));
                }
            }
        }

        let dropped_after = engine.dropped_at_capacity;
        if dropped_after > dropped_before {
            shed_report = Some(ShedReport {
                dropped_delta: dropped_after - dropped_before,
                dropped_total: dropped_after,
                tracked_series: engine.series_count(),
                tracked_counters: engine.counter_count(),
                max_series: engine.max_series(),
            });
        }
    }

    let emitted_records = records.len() as u64;

    if let Some(report) = shed_report {
        records.push(shed_record(&resource, frame.feed_id, report));
    }

    lock_scoring_health(scoring_health).record_frame(ScoringFrameUpdate {
        feed_id: frame.feed_id,
        scored_samples,
        emitted_verdicts: emitted_records,
        last_scored_at_unix_nano,
    });

    if records.is_empty() {
        return;
    }

    let mut builder = TelemetryBatchBuilder::new("anomaly-addon", resource.agent_id.clone());
    for record in records {
        builder = builder.push_record(record);
    }
    let _ = verdict_tx.send(builder.build());
}

fn telemetry_stream_from_receiver(mut rx: broadcast::Receiver<TelemetryBatch>) -> TelemetryStream {
    let (tx, out_rx) = mpsc::channel::<Result<TelemetryBatch, Status>>(VERDICT_CHANNEL_DEPTH);

    tokio::spawn(async move {
        loop {
            match rx.recv().await {
                Ok(batch) => match tx.try_send(Ok(batch)) {
                    Ok(()) | Err(mpsc::error::TrySendError::Full(_)) => {}
                    Err(mpsc::error::TrySendError::Closed(_)) => break,
                },
                Err(broadcast::error::RecvError::Lagged(_)) => continue,
                Err(broadcast::error::RecvError::Closed) => break,
            }
        }
    });

    Box::pin(ReceiverStream::new(out_rx))
}

#[derive(Clone, Debug, Default)]
struct ScoringHealth {
    frames_seen: u64,
    scored_samples: u64,
    emitted_verdicts: u64,
    last_feed_id: u64,
    last_scored_at_unix_nano: u64,
    last_frame_at_unix_nano: u64,
}

#[derive(Clone, Copy, Debug)]
struct ScoringFrameUpdate {
    feed_id: u64,
    scored_samples: u64,
    emitted_verdicts: u64,
    last_scored_at_unix_nano: u64,
}

#[derive(Clone, Copy, Debug)]
struct EngineHealthSnapshot {
    tracked_series: usize,
    tracked_counters: usize,
    max_series: usize,
    dropped_total: u64,
}

#[derive(Clone, Debug)]
struct HealthSummary {
    status: HealthStatus,
    detail: String,
}

impl ScoringHealth {
    fn record_frame(&mut self, update: ScoringFrameUpdate) {
        self.frames_seen = self.frames_seen.saturating_add(1);
        self.scored_samples = self.scored_samples.saturating_add(update.scored_samples);
        self.emitted_verdicts = self
            .emitted_verdicts
            .saturating_add(update.emitted_verdicts);
        self.last_feed_id = update.feed_id;
        self.last_frame_at_unix_nano = now_unix_nano();
        self.last_scored_at_unix_nano = self
            .last_scored_at_unix_nano
            .max(update.last_scored_at_unix_nano);
    }

    fn health_summary(&self, engine: EngineHealthSnapshot) -> HealthSummary {
        let cap_pressure = engine.max_series > 0
            && (engine.tracked_series >= engine.max_series
                || engine.tracked_counters >= engine.max_series);

        let (status, state) = if self.scored_samples == 0 {
            (HealthStatus::Degraded, "no_scored_samples")
        } else if engine.dropped_total > 0 {
            (HealthStatus::Degraded, "capacity_shed")
        } else if cap_pressure {
            (HealthStatus::Degraded, "at_capacity")
        } else {
            (HealthStatus::Healthy, "scoring_active")
        };

        HealthSummary {
            status,
            detail: format!(
                "state={state};frames_seen={};scored_samples={};emitted_verdicts={};last_feed_id={};last_frame_at_unix_nano={};last_scored_at_unix_nano={};tracked_series={};tracked_counters={};max_series={};dropped_total={}",
                self.frames_seen,
                self.scored_samples,
                self.emitted_verdicts,
                self.last_feed_id,
                self.last_frame_at_unix_nano,
                self.last_scored_at_unix_nano,
                engine.tracked_series,
                engine.tracked_counters,
                engine.max_series,
                engine.dropped_total
            ),
        }
    }
}

/// Resolve checkpoint behavior from the parsed config: a blank/absent path
/// disables checkpointing; `checkpoint_max_age_secs` overrides the staleness bound.
fn resolve_checkpoint_settings(config: &AddonConfig) -> CheckpointSettings {
    let mut settings = CheckpointSettings::default();

    if let Some(path) = config
        .checkpoint_path
        .as_ref()
        .map(|p| p.trim())
        .filter(|p| !p.is_empty())
    {
        settings.path = Some(PathBuf::from(path));
    }

    if let Some(secs) = config.checkpoint_max_age_secs {
        settings.max_age_ns = secs.saturating_mul(1_000_000_000);
    }

    settings
}

/// Atomically persist the engine's per-series checkpoint: write a sibling `.tmp`
/// then rename over the target so a crash mid-write never leaves a torn file.
/// Best-effort — any error is swallowed (the add-on keeps running, just without a
/// fresh checkpoint).
fn write_checkpoint(engine: &Arc<Mutex<DetectorEngine>>, path: &Path) {
    let checkpoint = {
        let engine = lock_engine(engine);
        engine.export_checkpoint()
    };

    let Ok(json) = serde_json::to_vec(&checkpoint) else {
        return;
    };

    let tmp = path.with_extension("tmp");
    if std::fs::write(&tmp, &json).is_ok() {
        let _ = std::fs::rename(&tmp, path);
    }
}

/// Re-warm the engine from an on-disk checkpoint. A missing file (first run) or a
/// corrupt/unparseable file is ignored — the add-on cold-starts rather than
/// failing — so checkpointing can never wedge startup.
fn load_checkpoint(engine: &Arc<Mutex<DetectorEngine>>, path: &Path, max_age_ns: u64) {
    let Ok(data) = std::fs::read(path) else {
        return;
    };
    let Ok(checkpoint) = serde_json::from_slice::<EngineCheckpoint>(&data) else {
        return;
    };

    let now = now_unix_nano();
    lock_engine(engine).restore_checkpoint(checkpoint, now, max_age_ns);
}

/// Wall-clock now in unix nanoseconds, for the restart staleness bound. Saturates
/// to 0 before the epoch (never panics).
fn now_unix_nano() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_nanos() as u64)
        .unwrap_or(0)
}

fn is_process_metric(metric: &Metric) -> bool {
    metric.metric_type == "process" || metric.name.starts_with("process.")
}

/// A cumulative-monotonic counter (SNMP interface octets/packets, etc.): a SUM
/// kind, cumulative temporality, monotonic. Mirrors central
/// `CounterNormalizer.cumulative_monotonic?` so the same series are rate-derived
/// at the edge and centrally. Such a metric's points are rate-normalized (not
/// dropped) before scoring.
fn is_cumulative_counter(metric: &Metric) -> bool {
    metric.is_monotonic
        && metric.temporality == MetricTemporality::Cumulative as i32
        && metric.kind == MetricKind::Sum as i32
}

/// The saturation-gauge class of a metric, derived from `metric_type` exactly as
/// central `series_config.metric_group/2` does (so edge and central agree on what
/// a gauge is). `None` means "not a saturation gauge" — the series stays purely
/// z-based with no dispersion floors (counters, interface rates, ICMP RTT, and
/// any unclassified metric). The class drives the fidelity defaults below.
#[derive(Clone, Copy, Debug, PartialEq)]
enum GaugeClass {
    Cpu,
    Mem,
    Disk,
}

/// Classify a metric's `metric_type` into a saturation-gauge class. Mirrors
/// central `metric_group/2`: `sysmon.cpu`/`cpu` -> CPU, `sysmon.memory`/`memory`
/// -> Mem, `sysmon.disk`/`disk` -> Disk. Everything else (snmp/icmp/flow/otel and
/// any unknown) is not a saturation gauge.
///
/// The `metric_type` match is necessary but NOT sufficient: the agent emits
/// non-percent series under these same types (e.g. `cpu.frequency_hz` /
/// `cpu.cluster.frequency_hz` are `sysmon.cpu`, unit Hz, ~GHz). Those are not
/// bounded 0-100% utilization gauges, so the directional saturation gate would
/// wrongly suppress a legitimate DOWNWARD excursion (CPU thermal throttling /
/// power-capping). We therefore additionally require the metric to be the
/// percent-utilization gauge — its `name` ends with `usage_percent` or
/// `used_percent` (matching `cpu.usage_percent`, `memory.used_percent`,
/// `disk.used_percent`). Frequency and any other non-percent series under these
/// types get `None` -> the default profile -> stay purely z-based (catching the
/// throttling excursion the symmetric z-score detects).
fn gauge_class(metric: &Metric) -> Option<GaugeClass> {
    if !is_utilization_percent_gauge(metric) {
        return None;
    }
    match metric.metric_type.as_str() {
        "sysmon.cpu" | "cpu" => Some(GaugeClass::Cpu),
        "sysmon.memory" | "memory" => Some(GaugeClass::Mem),
        "sysmon.disk" | "disk" => Some(GaugeClass::Disk),
        _ => None,
    }
}

/// True when the metric is the percent-utilization gauge of its group — its name
/// ends with `usage_percent` (cpu) or `used_percent` (mem/disk). This is the gate
/// that distinguishes a bounded 0-100% saturation gauge (`cpu.usage_percent`)
/// from a non-percent series riding the same `metric_type` (`cpu.frequency_hz`).
fn is_utilization_percent_gauge(metric: &Metric) -> bool {
    let name = metric.name.as_str();
    name.ends_with("usage_percent") || name.ends_with("used_percent")
}

/// Build the per-series fidelity [`SeriesProfile`] for a (non-counter) metric.
///
/// Saturation gauges (cpu/mem/disk `used_percent`) measure a bounded 0-100%
/// utilization with a meaningful direction: only *rising* utilization toward the
/// ceiling matters, and a low absolute value is benign no matter how the z-score
/// reads. So a gauge gets:
///   * a directional + absolute-floor saturation gate (fix #3) — only an upward
///     excursion ABOVE `min_breach_value` can breach; a benign low level (live:
///     disk 1.36%, mem 6.4%, a CPU core briefly at 18%) never alerts; and
///   * dispersion floors (fix #2) — `min_std_floor` in percentage points and a
///     relative `min_cv`, so a near-constant level with sub-point jitter cannot
///     manufacture a huge z-score.
///
/// Defaults are deliberately conservative (benign-suppressing, not alert-
/// suppressing): a disk genuinely climbing toward full, memory pressure, or a
/// CPU pinned high still clears the floor and fires. Per-core CPU is the most
/// volatile, so its floor is the highest (one core at 18%, or even a brief 100%
/// spike on a single core, must not page). These are the edge built-in defaults;
/// the central metric_class override channel (anomaly_addon_profile_seeder
/// projecting metric_class config into add-on params) is a documented FOLLOW-UP.
///
/// A non-gauge metric returns the default profile (no floors, no gate): purely
/// z-based, unchanged from prior behavior.
fn series_profile_for(metric: &Metric) -> SeriesProfile {
    match gauge_class(metric) {
        // Disk used_percent: very low variance normally; the live false-fire was
        // disk at ~1.36% with ~0.01 jitter. A 1-point absolute floor + 5% CV
        // tames the denominator; nothing under 80% full is worth a Critical.
        Some(GaugeClass::Disk) => SeriesProfile {
            min_std_floor: 1.0,
            min_cv: 0.05,
            saturation_gate: Some(SaturationGate {
                directional: true,
                min_value: 80.0,
            }),
        },
        // Memory used_percent: commonly runs 60-80% benignly (caches, buffers).
        // Same dispersion floors; only sustained pressure above 80% breaches.
        Some(GaugeClass::Mem) => SeriesProfile {
            min_std_floor: 1.0,
            min_cv: 0.05,
            saturation_gate: Some(SaturationGate {
                directional: true,
                min_value: 80.0,
            }),
        },
        // CPU used_percent (per-core): the noisiest gauge — individual cores spike
        // to 100% constantly and benignly. A higher absolute floor + std/CV floor
        // keep one core at 18% (or a brief single-core spike) from paging; only a
        // core sustained at/above 85% breaches.
        Some(GaugeClass::Cpu) => SeriesProfile {
            min_std_floor: 5.0,
            min_cv: 0.10,
            saturation_gate: Some(SaturationGate {
                directional: true,
                min_value: 85.0,
            }),
        },
        None => SeriesProfile::default(),
    }
}

/// The authoritative counter reading: the typed `raw_value` (the uint string SNMP
/// carries) when present, else the float `value`. Central prefers `raw_value`
/// for the same reason — the float can lose precision on a large u64.
fn counter_raw_value(point: &MetricPoint) -> f64 {
    let raw = point.raw_value.trim();
    if !raw.is_empty()
        && let Ok(parsed) = raw.parse::<f64>()
    {
        return parsed;
    }

    point.value
}

/// The reset-lineage anchor: the counter's start time when set, else the explicit
/// reset anchor. A change between readings means the counter restarted, so a rate
/// across it is dropped. Mirrors central's `reset_anchor` preference order.
fn counter_reset_anchor(point: &MetricPoint) -> String {
    if point.start_time_unix_nano > 0 {
        point.start_time_unix_nano.to_string()
    } else {
        point.reset_anchor.clone()
    }
}

/// Counter width can arrive as the typed metric field or as legacy metadata keys.
/// Preserve central's old metadata fallback so a zero proto field does not
/// silently suppress otherwise-corroborated 32-bit wrap handling.
fn counter_width(metric: &Metric, point: &MetricPoint) -> u32 {
    if metric.counter_width > 0 {
        return metric.counter_width;
    }

    metadata_u32_value(point, &["counter_width", "counter_bits", "pdu_width"])
        .or_else(|| metadata_u32_value(metric, &["counter_width", "counter_bits", "pdu_width"]))
        .unwrap_or(0)
}

fn max_counter_rate_per_second(metric: &Metric, point: &MetricPoint) -> Option<f64> {
    metadata_f64_value(point, &["max_counter_rate_per_second"])
        .or_else(|| metadata_f64_value(metric, &["max_counter_rate_per_second"]))
        .filter(|rate| rate.is_finite() && *rate > 0.0)
}

trait MetadataEntries {
    fn metadata_entries(&self) -> &[StringMapEntry];
}

impl MetadataEntries for Metric {
    fn metadata_entries(&self) -> &[StringMapEntry] {
        &self.metadata
    }
}

impl MetadataEntries for MetricPoint {
    fn metadata_entries(&self) -> &[StringMapEntry] {
        &self.metadata
    }
}

fn metadata_u32_value(source: &impl MetadataEntries, keys: &[&str]) -> Option<u32> {
    metadata_entry_value(source, keys).and_then(|value| value.parse::<u32>().ok())
}

fn metadata_f64_value(source: &impl MetadataEntries, keys: &[&str]) -> Option<f64> {
    metadata_entry_value(source, keys).and_then(|value| value.parse::<f64>().ok())
}

fn metadata_entry_value<'a>(source: &'a impl MetadataEntries, keys: &[&str]) -> Option<&'a str> {
    keys.iter().find_map(|key| {
        source
            .metadata_entries()
            .iter()
            .find(|entry| entry.key == *key)
            .map(|entry| entry.value.as_str())
    })
}

fn series_key_for(resource: &MetricResource, metric: &Metric, point: &MetricPoint) -> String {
    let partition = if resource.partition.is_empty() {
        "default"
    } else {
        resource.partition.as_str()
    };

    if !point.series_identity_hint.is_empty() {
        [
            "v2".to_string(),
            safe_component("partition", partition),
            safe_component("hint", &point.series_identity_hint),
        ]
        .join("|")
    } else {
        // Fallback when the producer did not stamp a hint: resource identity +
        // metric + interface keeps distinct series apart on one host. Remote
        // SNMP polls use the polled target, not the polling agent host.
        let resource_identity = series_resource_identity(resource, metric, point);
        let mut components = vec![
            "v2".to_string(),
            safe_component("partition", partition),
            safe_component("identity", &resource_identity),
            safe_component("metric", &metric.name),
        ];

        if !point.interface_uid.is_empty() {
            components.push(safe_component("interface_uid", &point.interface_uid));
        }

        if point.if_index > 0 {
            components.push(safe_component("if_index", &point.if_index.to_string()));
        }

        components.join("|")
    }
}

fn safe_component(name: &str, value: &str) -> String {
    format!("{name}={}", hex::encode(value.as_bytes()))
}

fn series_resource_identity(
    resource: &MetricResource,
    metric: &Metric,
    point: &MetricPoint,
) -> String {
    let metric_class = metric_class(metric);
    first_non_empty(&[
        resource.device_id.as_str(),
        snmp_target_identity(resource, metric_class, metric, point),
        resource.host_id.as_str(),
        resource.agent_id.as_str(),
        resource.host_ip.as_str(),
    ])
    .to_string()
}

fn anomaly_device_uid<'a>(
    resource: &'a MetricResource,
    metric_class: &str,
    metric: &'a Metric,
    point: &'a MetricPoint,
) -> &'a str {
    first_non_empty(&[
        resource.device_id.as_str(),
        snmp_target_identity(resource, metric_class, metric, point),
        resource.host_id.as_str(),
        resource.agent_id.as_str(),
        resource.host_ip.as_str(),
    ])
}

fn metric_class(metric: &Metric) -> &str {
    if metric.metric_type.is_empty() {
        "metric"
    } else {
        metric.metric_type.as_str()
    }
}

fn snmp_target_identity<'a>(
    resource: &'a MetricResource,
    metric_class: &str,
    metric: &'a Metric,
    point: &'a MetricPoint,
) -> &'a str {
    if !is_snmp_metric_class(metric_class) {
        return "";
    }

    first_non_empty(&[
        resource.target_device_ip.as_str(),
        metadata_entry_value(metric, &["target_device_ip"]).unwrap_or(""),
        metadata_entry_value(point, &["target_device_ip"]).unwrap_or(""),
        entry_value(&metric.tags, &["host"]).unwrap_or(""),
        entry_value(&point.attributes, &["host"]).unwrap_or(""),
        entry_value(&metric.tags, &["target"]).unwrap_or(""),
        entry_value(&point.attributes, &["target"]).unwrap_or(""),
    ])
}

fn is_snmp_metric_class(metric_class: &str) -> bool {
    metric_class == "snmp" || metric_class.starts_with("snmp.")
}

fn target_device_ip_for<'a>(
    resource: &'a MetricResource,
    metric_class: &str,
    metric: &'a Metric,
    point: &'a MetricPoint,
) -> &'a str {
    if !resource.target_device_ip.is_empty() {
        resource.target_device_ip.as_str()
    } else {
        snmp_target_identity(resource, metric_class, metric, point)
    }
}

fn entry_value<'a>(entries: &'a [StringMapEntry], keys: &[&str]) -> Option<&'a str> {
    keys.iter().find_map(|key| {
        entries
            .iter()
            .find(|entry| entry.key == *key)
            .map(|entry| entry.value.as_str())
    })
}

/// Merge the attested distinguishing tags into a JSON object for `source_identity`:
/// `metric.tags` first, then `point.attributes` (the per-point dimensions like
/// `core_id`/`mount_point`), point winning on a key collision. The raw attested
/// set is forwarded as-is; central applies its own identity/volatile-key
/// exclusions when it recomputes the canonical series_key.
fn attested_tags(
    metric: &Metric,
    point: &MetricPoint,
) -> serde_json::Map<String, serde_json::Value> {
    let mut tags = serde_json::Map::new();

    for entry in metric.tags.iter().chain(point.attributes.iter()) {
        if !entry.key.is_empty() {
            tags.insert(
                entry.key.clone(),
                serde_json::Value::String(entry.value.clone()),
            );
        }
    }

    tags
}

/// Build an OCSF Detection Finding (class_uid 2004) shaped to match the central
/// `VerdictEmitter` envelope, so core consumes an edge verdict identically. The
/// canonical `series_key` is computed CENTRALLY from gateway-attested fields, so
/// `source_identity` carries the raw resource identity for central re-keying;
/// the `series_key` here is the producer hint (provisional / for dedup).
/// `verdict_source: edge-spike` is the discriminator the edge<->central join uses.
fn verdict_record(
    resource: &MetricResource,
    metric: &Metric,
    point: &MetricPoint,
    series_key: &str,
    verdict: &ReasonVerdict,
    transition: AnomalyTransition,
) -> TelemetryRecord {
    let ts_nano = verdict
        .observed_at_unix_nano
        .unwrap_or(point.observed_at_unix_nano);
    let ts_ms = (ts_nano / 1_000_000) as i64;
    let severity_id = severity_id_from_score(verdict.score);
    let lifecycle_state = anomaly_lifecycle_state(transition);
    let status = anomaly_lifecycle_status(transition);
    let message = anomaly_lifecycle_message(transition, &verdict.reason);

    let metric_class = metric_class(metric);
    let device_uid = anomaly_device_uid(resource, metric_class, metric, point);
    let target_device_ip = target_device_ip_for(resource, metric_class, metric, point);

    let event_id = format!("anomaly:{series_key}:{ts_nano}:{lifecycle_state}");
    let finding_uid =
        format!("anomaly:finding:2004:anomaly_detection:{device_uid}:{series_key}:{metric_class}");

    let body = serde_json::json!({
        "event_id": &event_id,
        "id": &event_id,
        "signal_type": "causal",
        "event_type": "anomaly",
        "class_uid": 2004,
        "category_uid": 2,
        "type_uid": 200_401,
        "activity_id": 1,
        "finding_type": "detection",
        "provider": "anomaly_detection",
        "source": "serviceradar",
        "collector": "anomaly_addon",
        "verdict_source": "edge-spike",
        "status": status,
        "time": ts_ms,
        "severity_id": severity_id,
        "device_uid": device_uid,
        "device_id": device_uid,
        "target_device_ip": target_device_ip,
        "message": message,
        "finding_info": {
            "uid": finding_uid,
            "title": format!("{metric_class} anomaly on {device_uid}"),
            "type": "anomaly",
            "type_id": 99,
        },
        "source_identity": {
            "series_key": series_key,
            "metric_class": metric_class,
            "agent_id": &resource.agent_id,
            "host_id": &resource.host_id,
            "device_id": &resource.device_id,
            "host_ip": &resource.host_ip,
            "target_device_ip": target_device_ip,
            "partition": &resource.partition,
            "metric_name": &metric.name,
            "if_index": point.if_index,
            "interface_uid": &point.interface_uid,
            // Attested distinguishing tags (metric.tags ∪ point.attributes) so
            // central can reconstruct the exact per-core/per-mount/per-tag series
            // dimension; central applies its own identity/volatile-key exclusions.
            "tags": attested_tags(metric, point),
        },
        "anomaly": {
            "series_key": series_key,
            "metric_class": metric_class,
            "state": lifecycle_state,
            "target_device_ip": target_device_ip,
            "detector_state": &verdict.state,
            "reason": &verdict.reason,
            "score": verdict.score,
            "baseline_count": verdict.baseline_count,
            "value": verdict.sample_value,
            "sample_value": verdict.sample_value,
            "observed_at_unix_nano": ts_nano,
            "signals": [],
        },
    });

    let payload = serde_json::to_vec(&body).unwrap_or_default();
    let record = ocsf_event_record(event_id, ts_nano as i64, ts_nano as i64, payload);
    attach_signal_schema_ref(record, &anomaly_signal_schema_ref())
}

fn anomaly_lifecycle_state(transition: AnomalyTransition) -> &'static str {
    match transition {
        AnomalyTransition::Open => "anomaly_open",
        AnomalyTransition::Clear => "anomaly_clear",
        AnomalyTransition::None => "none",
    }
}

fn anomaly_lifecycle_status(transition: AnomalyTransition) -> &'static str {
    match transition {
        AnomalyTransition::Open => "open",
        AnomalyTransition::Clear => "inactive",
        AnomalyTransition::None => "suppressed",
    }
}

fn anomaly_lifecycle_message(transition: AnomalyTransition, reason: &str) -> String {
    match transition {
        AnomalyTransition::Open => reason.to_string(),
        AnomalyTransition::Clear => format!("anomaly cleared: {reason}"),
        AnomalyTransition::None => reason.to_string(),
    }
}

fn severity_id_from_score(score: f64) -> i64 {
    if score >= 6.0 {
        5
    } else if score >= 3.0 {
        4
    } else if score >= 2.0 {
        3
    } else {
        2
    }
}

fn first_non_empty<'a>(candidates: &[&'a str]) -> &'a str {
    candidates
        .iter()
        .copied()
        .find(|s| !s.is_empty())
        .unwrap_or("unknown")
}

fn anomaly_signal_schema_ref() -> SignalSchemaRef {
    SignalSchemaRef {
        producer_id: ADDON_ID.to_string(),
        producer_version: ADDON_VERSION.to_string(),
        schema_id: "com.carverauto.anomaly.detection_finding".to_string(),
        schema_version: "1.0.0".to_string(),
        display_contract_id: "com.carverauto.anomaly.detection_finding.display".to_string(),
        display_contract_version: "1.0.0".to_string(),
        display_contract: "display/detection_finding.display.json".to_string(),
        signal_type: "event".to_string(),
        payload_kind: "ocsf_event".to_string(),
    }
}

#[derive(Debug, Clone, Copy)]
struct ShedReport {
    dropped_delta: u64,
    dropped_total: u64,
    tracked_series: usize,
    tracked_counters: usize,
    max_series: usize,
}

/// Build a non-causal operational OCSF Event Log Activity for capacity shedding.
/// This is intentionally not an anomaly finding: it reports add-on pressure so
/// operators can tune `max_series` or targeting without polluting anomaly counts.
fn shed_record(resource: &MetricResource, feed_id: u64, report: ShedReport) -> TelemetryRecord {
    let ts_nano = now_unix_nano();
    let event_id = format!(
        "anomaly:shed:{}:{feed_id}:{}",
        first_non_empty(&[
            resource.agent_id.as_str(),
            resource.host_id.as_str(),
            resource.device_id.as_str(),
            "unknown",
        ]),
        report.dropped_total
    );

    let body = serde_json::json!({
        "id": &event_id,
        "time": ts_nano as i64,
        "class_uid": OCSF_CLASS_EVENT_LOG_ACTIVITY,
        "category_uid": OCSF_CATEGORY_SYSTEM_ACTIVITY,
        "type_uid": OCSF_CLASS_EVENT_LOG_ACTIVITY * 100 + OCSF_ACTIVITY_CREATE,
        "activity_id": OCSF_ACTIVITY_CREATE,
        "activity_name": "Create",
        "severity_id": 3,
        "severity": "Medium",
        "status_id": 1,
        "status": "Success",
        "status_code": "anomaly_capacity_shed",
        "message": format!(
            "Anomaly add-on shed {} new series at capacity ({} detector series, {} counters of max {})",
            report.dropped_delta, report.tracked_series, report.tracked_counters, report.max_series
        ),
        "log_name": "anomaly.capacity",
        "log_provider": ADDON_ID,
        "actor": { "app_name": "serviceradar-anomaly-addon" },
        "device": {
            "uid": first_non_empty(&[
                resource.device_id.as_str(),
                resource.host_id.as_str(),
                resource.agent_id.as_str(),
                resource.host_ip.as_str(),
            ])
        },
        "observables": [],
        "metadata": {
            "version": OCSF_VERSION,
            "product": {
                "name": "ServiceRadar Anomaly Add-on",
                "vendor_name": "Carver Automation"
            }
        },
        "unmapped": {
            "addon_id": ADDON_ID,
            "event_kind": "capacity_shed",
            "feed_id": feed_id,
            "agent_id": &resource.agent_id,
            "host_id": &resource.host_id,
            "device_id": &resource.device_id,
            "host_ip": &resource.host_ip,
            "partition": &resource.partition,
            "dropped_series_delta": report.dropped_delta,
            "dropped_series_total": report.dropped_total,
            "tracked_series": report.tracked_series,
            "tracked_counters": report.tracked_counters,
            "max_series": report.max_series
        }
    });

    let payload = serde_json::to_vec(&body).unwrap_or_default();
    let record = ocsf_event_record(event_id, ts_nano as i64, ts_nano as i64, payload);
    attach_signal_schema_ref(record, &shed_signal_schema_ref())
}

fn shed_signal_schema_ref() -> SignalSchemaRef {
    SignalSchemaRef {
        producer_id: ADDON_ID.to_string(),
        producer_version: ADDON_VERSION.to_string(),
        schema_id: "com.carverauto.anomaly.capacity_shed".to_string(),
        schema_version: "1.0.0".to_string(),
        display_contract_id: "com.carverauto.anomaly.capacity_shed.display".to_string(),
        display_contract_version: "1.0.0".to_string(),
        display_contract: "display/capacity_shed.display.json".to_string(),
        signal_type: "event".to_string(),
        payload_kind: "ocsf_event".to_string(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use addon_sdk::metric_pb::StringMapEntry;
    use broadcast::error::TryRecvError;
    use tokio::sync::mpsc;
    use tokio::time::{Duration, timeout};
    use tokio_stream::wrappers::ReceiverStream;

    fn entry(key: &str, value: &str) -> StringMapEntry {
        StringMapEntry {
            key: key.to_string(),
            value: value.to_string(),
        }
    }

    fn metric_of_type(metric_type: &str) -> Metric {
        Metric {
            name: format!("{metric_type}.used_percent"),
            metric_type: metric_type.to_string(),
            ..Default::default()
        }
    }

    fn metric_named(name: &str, metric_type: &str) -> Metric {
        Metric {
            name: name.to_string(),
            metric_type: metric_type.to_string(),
            ..Default::default()
        }
    }

    #[test]
    fn counter_width_prefers_typed_metric_field() {
        let metric = Metric {
            counter_width: 64,
            metadata: vec![entry("counter_width", "32")],
            ..Default::default()
        };

        assert_eq!(counter_width(&metric, &MetricPoint::default()), 64);
    }

    #[test]
    fn counter_width_falls_back_to_point_then_metric_metadata() {
        let metric = Metric {
            metadata: vec![entry("counter_bits", "64")],
            ..Default::default()
        };
        let point = MetricPoint {
            metadata: vec![entry("pdu_width", "32")],
            ..Default::default()
        };

        assert_eq!(counter_width(&metric, &point), 32);
        assert_eq!(counter_width(&metric, &MetricPoint::default()), 64);
    }

    #[test]
    fn max_counter_rate_uses_point_metadata_before_metric_metadata() {
        let metric = Metric {
            metadata: vec![entry("max_counter_rate_per_second", "1000")],
            ..Default::default()
        };
        let point = MetricPoint {
            metadata: vec![entry("max_counter_rate_per_second", "250")],
            ..Default::default()
        };

        assert_eq!(max_counter_rate_per_second(&metric, &point), Some(250.0));
        assert_eq!(
            max_counter_rate_per_second(&metric, &MetricPoint::default()),
            Some(1000.0)
        );
    }

    #[test]
    fn health_summary_reports_no_scored_samples() {
        let summary = ScoringHealth::default().health_summary(EngineHealthSnapshot {
            tracked_series: 0,
            tracked_counters: 0,
            max_series: 50_000,
            dropped_total: 0,
        });

        assert_eq!(summary.status, HealthStatus::Degraded);
        assert!(summary.detail.contains("state=no_scored_samples"));
        assert!(summary.detail.contains("scored_samples=0"));
        assert!(summary.detail.contains("tracked_series=0"));
    }

    #[test]
    fn health_summary_reports_active_scoring_and_capacity_pressure() {
        let mut scoring = ScoringHealth::default();
        scoring.record_frame(ScoringFrameUpdate {
            feed_id: 9,
            scored_samples: 3,
            emitted_verdicts: 1,
            last_scored_at_unix_nano: 123,
        });

        let active = scoring.health_summary(EngineHealthSnapshot {
            tracked_series: 2,
            tracked_counters: 1,
            max_series: 50_000,
            dropped_total: 0,
        });
        assert_eq!(active.status, HealthStatus::Healthy);
        assert!(active.detail.contains("state=scoring_active"));
        assert!(active.detail.contains("frames_seen=1"));
        assert!(active.detail.contains("scored_samples=3"));
        assert!(active.detail.contains("emitted_verdicts=1"));
        assert!(active.detail.contains("last_feed_id=9"));
        assert!(active.detail.contains("last_scored_at_unix_nano=123"));

        let shed = scoring.health_summary(EngineHealthSnapshot {
            tracked_series: 50_000,
            tracked_counters: 1,
            max_series: 50_000,
            dropped_total: 2,
        });
        assert_eq!(shed.status, HealthStatus::Degraded);
        assert!(shed.detail.contains("state=capacity_shed"));
        assert!(shed.detail.contains("dropped_total=2"));
    }

    fn anomaly_metric_batch(value: f64, observed_at_unix_nano: u64) -> MetricBatch {
        MetricBatch {
            resource: Some(MetricResource {
                agent_id: "agent-a".to_string(),
                host_id: "host-a".to_string(),
                device_id: "device-a".to_string(),
                partition: "demo".to_string(),
                ..Default::default()
            }),
            metrics: vec![Metric {
                name: "custom.value".to_string(),
                metric_type: "custom".to_string(),
                points: vec![MetricPoint {
                    value,
                    observed_at_unix_nano,
                    series_identity_hint: "series-a".to_string(),
                    ..Default::default()
                }],
                ..Default::default()
            }],
            ..Default::default()
        }
    }

    fn metric_feed_frame(feed_id: u64, value: f64) -> MetricFeedFrame {
        MetricFeedFrame {
            feed_id,
            source: None,
            payload: anomaly_metric_batch(value, feed_id).encode_to_vec(),
        }
    }

    fn metric_feed_stream() -> (
        mpsc::Sender<Result<MetricFeedFrame, Status>>,
        MetricFeedStream,
    ) {
        let (tx, rx) = mpsc::channel(4);
        (tx, Box::pin(ReceiverStream::new(rx)))
    }

    async fn process_anomaly_value(
        engine: &Arc<Mutex<DetectorEngine>>,
        tx: &broadcast::Sender<TelemetryBatch>,
        value: f64,
        observed_at_unix_nano: u64,
    ) {
        let scoring_health = Arc::new(Mutex::new(ScoringHealth::default()));
        let frame = MetricFeedFrame {
            feed_id: observed_at_unix_nano,
            source: None,
            payload: anomaly_metric_batch(value, observed_at_unix_nano).encode_to_vec(),
        };

        process_frame(engine, tx, &scoring_health, &frame).await;
    }

    fn assert_no_batch(rx: &mut broadcast::Receiver<TelemetryBatch>) {
        assert!(matches!(rx.try_recv(), Err(TryRecvError::Empty)));
    }

    fn recv_single_event(rx: &mut broadcast::Receiver<TelemetryBatch>) -> serde_json::Value {
        let batch = rx.try_recv().expect("telemetry batch");
        assert_eq!(batch.records.len(), 1);
        serde_json::from_slice(&batch.records[0].payload).expect("event json")
    }

    fn empty_telemetry_batch(source_instance: &str) -> TelemetryBatch {
        TelemetryBatchBuilder::new("test", source_instance).build()
    }

    #[test]
    fn config_empty_optional_numbers_fall_back_to_defaults() {
        let config: AddonConfig = serde_json::from_value(serde_json::json!({
            "window_size": "",
            "min_samples": "",
            "n_sigma": "",
            "confirm_slots": "",
            "max_series": "",
            "min_std_floor": "",
            "min_cv": "",
            "checkpoint_max_age_secs": ""
        }))
        .expect("empty strings should deserialize as unset optional knobs");

        let base = EngineConfig::default();
        let resolved = config.into_engine_config().expect("default config");
        assert_eq!(resolved.window_size, base.window_size);
        assert_eq!(resolved.min_samples, base.min_samples);
        assert_eq!(resolved.n_sigma, base.n_sigma);
        assert_eq!(resolved.confirm_slots, base.confirm_slots);
        assert_eq!(resolved.max_series, base.max_series);
        assert_eq!(resolved.min_std_floor, None);
        assert_eq!(resolved.min_cv, None);
    }

    #[test]
    fn config_accepts_numeric_strings_for_optional_numbers() {
        let config: AddonConfig = serde_json::from_value(serde_json::json!({
            "window_size": "42",
            "min_samples": "7",
            "n_sigma": "2.5",
            "confirm_slots": "3",
            "max_series": "1234",
            "min_std_floor": "0.25",
            "min_cv": "0.10",
            "checkpoint_max_age_secs": "60"
        }))
        .expect("numeric strings should deserialize");

        let checkpoint = resolve_checkpoint_settings(&config);
        assert_eq!(checkpoint.max_age_ns, 60_000_000_000);

        let resolved = config.into_engine_config().expect("valid config");
        assert_eq!(resolved.window_size, 42);
        assert_eq!(resolved.min_samples, 7);
        assert_eq!(resolved.n_sigma, 2.5);
        assert_eq!(resolved.confirm_slots, 3);
        assert_eq!(resolved.max_series, 1234);
        assert_eq!(resolved.min_std_floor, Some(0.25));
        assert_eq!(resolved.min_cv, Some(0.10));
    }

    #[test]
    fn config_rejects_min_samples_larger_than_window_size() {
        let config: AddonConfig = serde_json::from_value(serde_json::json!({
            "window_size": 5,
            "min_samples": 6
        }))
        .expect("shape is valid");

        let err = config
            .into_engine_config()
            .expect_err("must reject cold window");
        assert!(err.contains("min_samples (6)"));
        assert!(err.contains("window_size (5)"));
    }

    #[tokio::test]
    async fn configure_rejects_min_samples_larger_than_window_size() {
        let addon = AnomalyAddon::new();

        let result = addon
            .configure(br#"{"window_size":5,"min_samples":6}"#)
            .await
            .expect("configure returns result");

        assert!(!result.accepted);
        assert!(
            result
                .error
                .contains("min_samples (6) must be less than or equal to window_size (5)")
        );
    }

    #[test]
    fn gauge_classes_map_like_central_metric_group() {
        assert_eq!(
            gauge_class(&metric_of_type("sysmon.cpu")),
            Some(GaugeClass::Cpu)
        );
        assert_eq!(gauge_class(&metric_of_type("cpu")), Some(GaugeClass::Cpu));
        assert_eq!(
            gauge_class(&metric_of_type("sysmon.memory")),
            Some(GaugeClass::Mem)
        );
        assert_eq!(
            gauge_class(&metric_of_type("memory")),
            Some(GaugeClass::Mem)
        );
        assert_eq!(
            gauge_class(&metric_of_type("sysmon.disk")),
            Some(GaugeClass::Disk)
        );
        assert_eq!(gauge_class(&metric_of_type("disk")), Some(GaugeClass::Disk));
        // Non-gauges (snmp interface, icmp, flow, otel, unknown) are not gated.
        assert_eq!(gauge_class(&metric_of_type("snmp")), None);
        assert_eq!(gauge_class(&metric_of_type("icmp")), None);
        assert_eq!(gauge_class(&metric_of_type("flow")), None);
        assert_eq!(gauge_class(&metric_of_type("otel.metric_point")), None);
        assert_eq!(gauge_class(&metric_of_type("")), None);
    }

    #[test]
    fn gauge_profile_carries_directional_floor_gate() {
        // Disk/mem get the 80% floor; cpu gets the relaxed 85% floor. All are
        // directional, and all carry a nonzero dispersion floor.
        for (ty, floor) in [
            ("sysmon.disk", 80.0),
            ("sysmon.memory", 80.0),
            ("sysmon.cpu", 85.0),
        ] {
            let profile = series_profile_for(&metric_of_type(ty));
            let gate = profile.saturation_gate.expect("gauge must have a gate");
            assert!(gate.directional, "{ty} gate must be directional");
            assert_eq!(gate.min_value, floor, "{ty} absolute floor");
            assert!(profile.min_std_floor > 0.0, "{ty} must have a std floor");
            assert!(profile.min_cv > 0.0, "{ty} must have a cv floor");
        }
    }

    #[test]
    fn non_gauge_metric_gets_default_profile() {
        // An SNMP interface metric stays purely z-based (no gate, no floors).
        let profile = series_profile_for(&metric_of_type("snmp"));
        assert!(profile.saturation_gate.is_none());
        assert_eq!(profile.min_std_floor, 0.0);
        assert_eq!(profile.min_cv, 0.0);
    }

    #[test]
    fn cpu_frequency_under_sysmon_cpu_is_not_a_saturation_gauge() {
        // The agent emits `cpu.frequency_hz` / `cpu.cluster.frequency_hz` under
        // metric_type `sysmon.cpu` (unit Hz, ~GHz) — NOT a 0-100% utilization
        // gauge. The directional saturation gate would suppress a downward
        // frequency excursion (CPU thermal throttling / power-capping), a real
        // anomaly the symmetric z-score catches. So these must fall to the default
        // profile (no gate, no floors), staying purely z-based.
        for name in ["cpu.frequency_hz", "cpu.cluster.frequency_hz"] {
            let metric = metric_named(name, "sysmon.cpu");
            assert_eq!(
                gauge_class(&metric),
                None,
                "{name} must not be classified as a saturation gauge"
            );
            let profile = series_profile_for(&metric);
            assert!(
                profile.saturation_gate.is_none(),
                "{name} must have no saturation gate (allows downward throttling)"
            );
            assert_eq!(profile.min_std_floor, 0.0, "{name} must have no std floor");
            assert_eq!(profile.min_cv, 0.0, "{name} must have no cv floor");
        }
    }

    #[test]
    fn percent_utilization_gauges_keep_their_saturation_gate() {
        // The percent gauges the agent actually emits stay gated exactly as
        // before: cpu.usage_percent (Cpu, 85% floor), memory.used_percent (Mem,
        // 80%), disk.used_percent (Disk, 80%). The gate is what suppresses benign
        // low values; only the percent gauge gets it.
        for (name, ty, floor) in [
            ("cpu.usage_percent", "sysmon.cpu", 85.0),
            ("memory.used_percent", "sysmon.memory", 80.0),
            ("disk.used_percent", "sysmon.disk", 80.0),
        ] {
            let metric = metric_named(name, ty);
            assert!(
                gauge_class(&metric).is_some(),
                "{name} must remain a saturation gauge"
            );
            let profile = series_profile_for(&metric);
            let gate = profile
                .saturation_gate
                .unwrap_or_else(|| panic!("{name} must keep its saturation gate"));
            assert!(gate.directional, "{name} gate must be directional");
            assert_eq!(gate.min_value, floor, "{name} absolute floor");
            assert!(profile.min_std_floor > 0.0, "{name} must keep a std floor");
            assert!(profile.min_cv > 0.0, "{name} must keep a cv floor");
        }
    }

    #[test]
    fn attested_tags_merges_metric_and_point_with_point_winning() {
        let metric = Metric {
            tags: vec![
                entry("source_zone", "rack-a"),
                entry("sensor", "metric-default"),
            ],
            ..Default::default()
        };
        let point = MetricPoint {
            attributes: vec![entry("sensor", "cpu0"), entry("core_id", "0")],
            ..Default::default()
        };

        let tags = attested_tags(&metric, &point);

        assert_eq!(
            tags.get("source_zone").and_then(|v| v.as_str()),
            Some("rack-a")
        );
        assert_eq!(tags.get("core_id").and_then(|v| v.as_str()), Some("0"));
        // point.attributes wins on a key collision so the per-core/per-mount
        // dimension central reconstructs matches what the point carried.
        assert_eq!(tags.get("sensor").and_then(|v| v.as_str()), Some("cpu0"));
    }

    #[test]
    fn attested_tags_skips_empty_keys() {
        let metric = Metric {
            tags: vec![entry("", "ignored")],
            ..Default::default()
        };
        assert!(attested_tags(&metric, &MetricPoint::default()).is_empty());
    }

    #[test]
    fn snmp_remote_target_drives_edge_verdict_identity() {
        let resource = MetricResource {
            agent_id: "agent-ns03".to_string(),
            host_id: "ns03".to_string(),
            host_ip: "10.0.0.10".to_string(),
            target_device_ip: "10.0.0.20".to_string(),
            partition: "demo".to_string(),
            ..Default::default()
        };
        let metric = Metric {
            name: "ifHCInOctets".to_string(),
            metric_type: "snmp".to_string(),
            ..Default::default()
        };
        let point = MetricPoint {
            value: 1234.0,
            observed_at_unix_nano: 1_812_456_000_000_000_000,
            if_index: 7,
            interface_uid: "ifindex:7".to_string(),
            ..Default::default()
        };
        let series_key = series_key_for(&resource, &metric, &point);
        let verdict = ReasonVerdict {
            state: "anomalous".to_string(),
            anomalous: true,
            breached: true,
            include_in_baseline: false,
            next_consecutive_anomalous: 1,
            score: 4.2,
            reason: "test breach".to_string(),
            baseline_count: 30,
            next_rolling_acc: serviceradar_anomaly_core::WelfordAcc::default(),
            next_window_tail: Vec::new(),
            sample_value: 1234.0,
            observed_at_unix_nano: Some(1_812_456_000_000_000_000),
            signals: Vec::new(),
        };

        let record = verdict_record(
            &resource,
            &metric,
            &point,
            &series_key,
            &verdict,
            AnomalyTransition::Open,
        );
        let event: serde_json::Value = serde_json::from_slice(&record.payload).unwrap();

        assert_eq!(
            series_key,
            [
                "v2".to_string(),
                safe_component("partition", "demo"),
                safe_component("identity", "10.0.0.20"),
                safe_component("metric", "ifHCInOctets"),
                safe_component("interface_uid", "ifindex:7"),
                safe_component("if_index", "7"),
            ]
            .join("|")
        );
        assert_eq!(event["device_uid"], "10.0.0.20");
        assert_eq!(event["device_id"], "10.0.0.20");
        assert_eq!(event["target_device_ip"], "10.0.0.20");
        assert_eq!(event["anomaly"]["target_device_ip"], "10.0.0.20");
        assert_eq!(event["source_identity"]["target_device_ip"], "10.0.0.20");
        assert_eq!(event["source_identity"]["agent_id"], "agent-ns03");
    }

    #[test]
    fn snmp_tagged_target_drives_edge_verdict_identity_without_resource_target() {
        let resource = MetricResource {
            agent_id: "agent-ns03".to_string(),
            host_id: "ns03".to_string(),
            host_ip: "10.0.0.10".to_string(),
            partition: "demo".to_string(),
            ..Default::default()
        };
        let metric = Metric {
            name: "ifHCInOctets".to_string(),
            metric_type: "snmp".to_string(),
            tags: vec![entry("target", "router-a"), entry("host", "10.0.0.20")],
            ..Default::default()
        };
        let point = MetricPoint {
            value: 1234.0,
            observed_at_unix_nano: 1_812_456_000_000_000_000,
            if_index: 7,
            interface_uid: "ifindex:7".to_string(),
            attributes: vec![entry("target", "router-a"), entry("host", "10.0.0.20")],
            ..Default::default()
        };
        let series_key = series_key_for(&resource, &metric, &point);
        let verdict = ReasonVerdict {
            state: "anomalous".to_string(),
            anomalous: true,
            breached: true,
            include_in_baseline: false,
            next_consecutive_anomalous: 1,
            score: 4.2,
            reason: "test breach".to_string(),
            baseline_count: 30,
            next_rolling_acc: serviceradar_anomaly_core::WelfordAcc::default(),
            next_window_tail: Vec::new(),
            sample_value: 1234.0,
            observed_at_unix_nano: Some(1_812_456_000_000_000_000),
            signals: Vec::new(),
        };

        let record = verdict_record(
            &resource,
            &metric,
            &point,
            &series_key,
            &verdict,
            AnomalyTransition::Open,
        );
        let event: serde_json::Value = serde_json::from_slice(&record.payload).unwrap();

        assert_eq!(
            series_key,
            [
                "v2".to_string(),
                safe_component("partition", "demo"),
                safe_component("identity", "10.0.0.20"),
                safe_component("metric", "ifHCInOctets"),
                safe_component("interface_uid", "ifindex:7"),
                safe_component("if_index", "7"),
            ]
            .join("|")
        );
        assert_eq!(event["device_uid"], "10.0.0.20");
        assert_eq!(event["device_id"], "10.0.0.20");
        assert_eq!(event["target_device_ip"], "10.0.0.20");
        assert_eq!(event["anomaly"]["target_device_ip"], "10.0.0.20");
        assert_eq!(event["source_identity"]["target_device_ip"], "10.0.0.20");
        assert_eq!(event["source_identity"]["agent_id"], "agent-ns03");
    }

    #[test]
    fn edge_verdict_identity_uses_producer_sample_time() {
        let sample_time = 1_812_456_123_456_789_000_u64;
        let point_time = sample_time - 42_000_000;
        let resource = MetricResource {
            agent_id: "agent-a".to_string(),
            host_id: "host-a".to_string(),
            device_id: "device-a".to_string(),
            partition: "demo".to_string(),
            ..Default::default()
        };
        let metric = Metric {
            name: "cpu.usage_percent".to_string(),
            metric_type: "sysmon.cpu".to_string(),
            ..Default::default()
        };
        let point = MetricPoint {
            value: 99.0,
            observed_at_unix_nano: point_time,
            series_identity_hint: "device-a|cpu0".to_string(),
            ..Default::default()
        };
        let series_key = series_key_for(&resource, &metric, &point);
        let verdict = ReasonVerdict {
            state: "anomalous".to_string(),
            anomalous: true,
            breached: true,
            include_in_baseline: false,
            next_consecutive_anomalous: 5,
            score: 6.0,
            reason: "sample-time breach".to_string(),
            baseline_count: 30,
            next_rolling_acc: serviceradar_anomaly_core::WelfordAcc::default(),
            next_window_tail: Vec::new(),
            sample_value: 99.0,
            observed_at_unix_nano: Some(sample_time),
            signals: Vec::new(),
        };

        let first = verdict_record(
            &resource,
            &metric,
            &point,
            &series_key,
            &verdict,
            AnomalyTransition::Open,
        );
        let second = verdict_record(
            &resource,
            &metric,
            &point,
            &series_key,
            &verdict,
            AnomalyTransition::Open,
        );
        let event: serde_json::Value = serde_json::from_slice(&first.payload).unwrap();
        let expected_event_id = format!("anomaly:{series_key}:{sample_time}:anomaly_open");

        assert_eq!(first.event_id, expected_event_id);
        assert_eq!(second.event_id, expected_event_id);
        assert_eq!(first.event_time_unix_nano, sample_time as i64);
        assert_eq!(first.observed_time_unix_nano, sample_time as i64);
        assert_eq!(event["event_id"], expected_event_id);
        assert_eq!(event["id"], expected_event_id);
        assert_eq!(event["time"], (sample_time / 1_000_000) as i64);
        assert_eq!(event["anomaly"]["observed_at_unix_nano"], sample_time);
    }

    #[test]
    fn edge_series_key_encodes_partition_and_hint_boundaries() {
        let metric = Metric {
            name: "cpu.usage".to_string(),
            metric_type: "sysmon.cpu".to_string(),
            ..Default::default()
        };
        let point = MetricPoint {
            series_identity_hint: "host:a|core:0".to_string(),
            ..Default::default()
        };

        let first = MetricResource {
            partition: "prod:east".to_string(),
            ..Default::default()
        };
        let second = MetricResource {
            partition: "prod".to_string(),
            ..Default::default()
        };
        let second_point = MetricPoint {
            series_identity_hint: "east|host:a|core:0".to_string(),
            ..Default::default()
        };

        let first_key = series_key_for(&first, &metric, &point);
        let second_key = series_key_for(&second, &metric, &second_point);

        assert_ne!(first_key, second_key);
        assert!(first_key.contains(&safe_component("partition", "prod:east")));
        assert!(first_key.contains(&safe_component("hint", "host:a|core:0")));
        assert!(!first_key.contains("prod:east"));
        assert!(!first_key.contains("host:a|core:0"));
    }

    #[test]
    fn shed_record_is_operational_ocsf_event_not_an_anomaly() {
        let resource = MetricResource {
            agent_id: "agent-a".to_string(),
            host_id: "host-a".to_string(),
            partition: "demo".to_string(),
            ..Default::default()
        };
        let record = shed_record(
            &resource,
            42,
            ShedReport {
                dropped_delta: 3,
                dropped_total: 10,
                tracked_series: 1,
                tracked_counters: 2,
                max_series: 1,
            },
        );

        assert_eq!(
            record.payload_kind,
            addon_sdk::pb::TelemetryPayloadKind::OcsfEvent as i32
        );
        let event: serde_json::Value = serde_json::from_slice(&record.payload).unwrap();
        assert_eq!(event["class_uid"], OCSF_CLASS_EVENT_LOG_ACTIVITY);
        assert_eq!(event["status_code"], "anomaly_capacity_shed");
        assert_eq!(event["unmapped"]["dropped_series_delta"], 3);
        assert_eq!(event["unmapped"]["dropped_series_total"], 10);
        assert_eq!(event["unmapped"]["tracked_counters"], 2);
        assert!(event.get("anomaly").is_none());
        assert_ne!(
            event.get("event_type").and_then(|v| v.as_str()),
            Some("anomaly")
        );
        assert_eq!(
            record
                .metadata
                .get(addon_sdk::SIGNAL_SCHEMA_METADATA_SCHEMA_ID)
                .map(String::as_str),
            Some("com.carverauto.anomaly.capacity_shed")
        );
    }

    #[tokio::test]
    async fn process_frame_reports_capacity_shed_once_per_frame() {
        let engine = Arc::new(Mutex::new(DetectorEngine::new(EngineConfig {
            max_series: 1,
            min_samples: 1,
            confirm_slots: 1,
            ..EngineConfig::default()
        })));
        let (tx, mut rx) = broadcast::channel(4);
        let batch = MetricBatch {
            resource: Some(MetricResource {
                agent_id: "agent-a".to_string(),
                host_id: "host-a".to_string(),
                ..Default::default()
            }),
            metrics: vec![Metric {
                name: "cpu.usage_percent".to_string(),
                metric_type: "sysmon.cpu".to_string(),
                points: vec![
                    MetricPoint {
                        value: 10.0,
                        observed_at_unix_nano: 1,
                        series_identity_hint: "series-a".to_string(),
                        ..Default::default()
                    },
                    MetricPoint {
                        value: 20.0,
                        observed_at_unix_nano: 2,
                        series_identity_hint: "series-b".to_string(),
                        ..Default::default()
                    },
                    MetricPoint {
                        value: 30.0,
                        observed_at_unix_nano: 3,
                        series_identity_hint: "series-c".to_string(),
                        ..Default::default()
                    },
                ],
                ..Default::default()
            }],
            ..Default::default()
        };
        let frame = MetricFeedFrame {
            feed_id: 7,
            source: None,
            payload: batch.encode_to_vec(),
        };

        let scoring_health = Arc::new(Mutex::new(ScoringHealth::default()));
        process_frame(&engine, &tx, &scoring_health, &frame).await;

        let sent = rx.recv().await.expect("telemetry batch");
        assert_eq!(sent.records.len(), 1);
        let event: serde_json::Value = serde_json::from_slice(&sent.records[0].payload).unwrap();
        assert_eq!(event["status_code"], "anomaly_capacity_shed");
        assert_eq!(event["unmapped"]["dropped_series_delta"], 2);
        assert_eq!(event["unmapped"]["feed_id"], 7);
        let engine_snapshot = {
            let engine = engine.lock().expect("engine");
            EngineHealthSnapshot {
                tracked_series: engine.series_count(),
                tracked_counters: 0,
                max_series: 1,
                dropped_total: engine.dropped_at_capacity,
            }
        };
        let health = scoring_health
            .lock()
            .expect("health")
            .health_summary(engine_snapshot);
        assert_eq!(health.status, HealthStatus::Degraded);
        assert!(health.detail.contains("state=capacity_shed"));
        assert_eq!(event["unmapped"]["tracked_counters"], 0);
        assert_eq!(engine.lock().unwrap().dropped_at_capacity, 2);
    }

    #[tokio::test]
    async fn telemetry_stream_can_reconnect_and_survives_lag() {
        let (tx, rx) = broadcast::channel(1);
        let mut stream = telemetry_stream_from_receiver(rx);

        let _ = tx.send(empty_telemetry_batch("old-1"));
        let _ = tx.send(empty_telemetry_batch("old-2"));
        let _ = tx.send(empty_telemetry_batch("latest"));

        let received = stream
            .next()
            .await
            .expect("stream item after lag")
            .expect("batch ok");
        assert_eq!(
            received
                .source
                .as_ref()
                .map(|source| source.source_instance.as_str()),
            Some("latest")
        );

        let mut first = telemetry_stream_from_receiver(tx.subscribe());
        let mut second = telemetry_stream_from_receiver(tx.subscribe());
        let _ = tx.send(empty_telemetry_batch("after-reconnect"));

        for stream in [&mut first, &mut second] {
            let received = stream
                .next()
                .await
                .expect("reconnected stream item")
                .expect("batch ok");
            assert_eq!(
                received
                    .source
                    .as_ref()
                    .map(|source| source.source_instance.as_str()),
                Some("after-reconnect")
            );
        }
    }

    #[tokio::test]
    async fn metric_feed_reopen_aborts_prior_scorer() {
        let addon = AnomalyAddon::new();
        let (old_tx, old_frames) = metric_feed_stream();
        let mut old_acks = addon
            .stream_metric_feed(old_frames)
            .expect("old metric feed opens");

        old_tx
            .send(Ok(metric_feed_frame(1, 100.0)))
            .await
            .expect("old feed receiver");
        let old_ack = old_acks
            .next()
            .await
            .expect("old ack item")
            .expect("old ack ok");
        assert_eq!(old_ack.acked_feed_id, 1);

        let (new_tx, new_frames) = metric_feed_stream();
        let mut new_acks = addon
            .stream_metric_feed(new_frames)
            .expect("new metric feed opens");

        let old_end = timeout(Duration::from_secs(1), old_acks.next())
            .await
            .expect("old ack stream closes after feed replacement");
        assert!(old_end.is_none(), "old feed ack stream must close");
        assert!(
            old_tx.send(Ok(metric_feed_frame(2, 200.0))).await.is_err(),
            "old feed sender must observe the aborted receiver"
        );

        new_tx
            .send(Ok(metric_feed_frame(3, 300.0)))
            .await
            .expect("new feed receiver");
        let new_ack = new_acks
            .next()
            .await
            .expect("new ack item")
            .expect("new ack ok");
        assert_eq!(new_ack.acked_feed_id, 3);
    }

    #[tokio::test]
    async fn shutdown_aborts_open_metric_feed_promptly() {
        let addon = AnomalyAddon::new();
        let (feed_tx, frames) = metric_feed_stream();
        let mut acks = addon.stream_metric_feed(frames).expect("metric feed opens");

        feed_tx
            .send(Ok(metric_feed_frame(1, 100.0)))
            .await
            .expect("feed receiver");
        let ack = acks.next().await.expect("ack item").expect("ack ok");
        assert_eq!(ack.acked_feed_id, 1);

        timeout(Duration::from_millis(200), addon.shutdown())
            .await
            .expect("shutdown completes inside grace window")
            .expect("shutdown ok");

        let end = timeout(Duration::from_millis(200), acks.next())
            .await
            .expect("ack stream closes after shutdown");
        assert!(end.is_none(), "shutdown must close the ack stream");
        assert!(
            feed_tx.send(Ok(metric_feed_frame(2, 200.0))).await.is_err(),
            "shutdown must drop the feed receiver"
        );
    }

    #[tokio::test]
    async fn shutdown_flushes_final_metric_feed_checkpoint() {
        let path = std::env::temp_dir().join(format!(
            "sr-anomaly-shutdown-ckpt-{}-{}.json",
            std::process::id(),
            now_unix_nano()
        ));
        let _ = std::fs::remove_file(&path);

        let addon = AnomalyAddon::new();
        let config = serde_json::json!({
            "checkpoint_path": path.to_string_lossy()
        });
        let configured = addon
            .configure(config.to_string().as_bytes())
            .await
            .expect("configure ok");
        assert!(configured.accepted, "config accepted: {}", configured.error);

        let (feed_tx, frames) = metric_feed_stream();
        let mut acks = addon.stream_metric_feed(frames).expect("metric feed opens");

        feed_tx
            .send(Ok(metric_feed_frame(1, 100.0)))
            .await
            .expect("feed receiver");
        let ack = acks.next().await.expect("ack item").expect("ack ok");
        assert_eq!(ack.acked_feed_id, 1);
        assert!(
            !path.exists(),
            "write_every cadence should not have flushed yet"
        );

        addon.shutdown().await.expect("shutdown ok");

        assert!(path.exists(), "shutdown must write a final checkpoint");
        let restored = Arc::new(Mutex::new(DetectorEngine::new(EngineConfig::default())));
        load_checkpoint(&restored, &path, u64::MAX);
        assert_eq!(restored.lock().unwrap().series_count(), 1);

        let _ = std::fs::remove_file(&path);
    }

    #[tokio::test]
    async fn poisoned_engine_mutex_recovers_before_scoring() {
        let engine = Arc::new(Mutex::new(DetectorEngine::new(EngineConfig {
            max_series: 7,
            ..EngineConfig::default()
        })));
        {
            let mut guard = engine.lock().expect("warm engine");
            guard.evaluate("warm-series", 42.0, 1, SeriesProfile::default());
        }
        let poison_engine = engine.clone();

        let hook = std::panic::take_hook();
        std::panic::set_hook(Box::new(|_| {}));
        let result = std::panic::catch_unwind(move || {
            let _guard = poison_engine.lock().expect("lock before poison");
            panic!("poison engine mutex");
        });
        std::panic::set_hook(hook);
        assert!(result.is_err());
        assert!(engine.lock().is_err(), "test must poison the engine mutex");

        let (tx, _rx) = broadcast::channel(4);
        let scoring_health = Arc::new(Mutex::new(ScoringHealth::default()));
        process_frame(&engine, &tx, &scoring_health, &metric_feed_frame(1, 100.0)).await;

        let guard = engine.lock().expect("process_frame clears engine poison");
        let checkpoint = guard.export_checkpoint();
        assert!(
            checkpoint
                .series
                .iter()
                .any(|series| series.series_key == "warm-series"),
            "poison recovery should preserve warmed detector state"
        );
        assert_eq!(guard.series_count(), 2);
        assert_eq!(guard.max_series(), 7);
    }

    #[tokio::test]
    async fn process_frame_emits_only_anomaly_open_and_clear_transitions() {
        let engine = Arc::new(Mutex::new(DetectorEngine::new(EngineConfig {
            window_size: 50,
            min_samples: 5,
            n_sigma: 3.0,
            confirm_slots: 2,
            max_series: 10,
            ..EngineConfig::default()
        })));
        let (tx, mut rx) = broadcast::channel(8);

        for ts in 1..=20 {
            process_anomaly_value(&engine, &tx, 100.0, ts).await;
        }
        assert_no_batch(&mut rx);

        process_anomaly_value(&engine, &tx, 1_000.0, 21).await;
        assert_no_batch(&mut rx);

        process_anomaly_value(&engine, &tx, 1_000.0, 22).await;
        let open = recv_single_event(&mut rx);
        assert_eq!(open["status"], "open");
        assert_eq!(open["anomaly"]["state"], "anomaly_open");
        assert_eq!(open["anomaly"]["detector_state"], "anomalous");

        process_anomaly_value(&engine, &tx, 1_000.0, 23).await;
        assert_no_batch(&mut rx);

        process_anomaly_value(&engine, &tx, 100.0, 24).await;
        assert_no_batch(&mut rx);

        process_anomaly_value(&engine, &tx, 100.0, 25).await;
        let clear = recv_single_event(&mut rx);
        assert_eq!(clear["status"], "inactive");
        assert_eq!(clear["anomaly"]["state"], "anomaly_clear");
        assert_eq!(clear["anomaly"]["detector_state"], "clean");
        assert!(
            !clear["message"]
                .as_str()
                .unwrap_or_default()
                .contains("pending_anomaly")
        );
    }

    #[test]
    fn checkpoint_file_round_trip_atomic() {
        let path =
            std::env::temp_dir().join(format!("sr-anomaly-ckpt-{}.json", std::process::id()));
        let _ = std::fs::remove_file(&path);

        let engine = Arc::new(Mutex::new(DetectorEngine::new(EngineConfig::default())));
        {
            let mut e = engine.lock().unwrap();
            for i in 0..20 {
                e.evaluate(
                    "s",
                    100.0 + (i % 3) as f64,
                    i as u64,
                    SeriesProfile::default(),
                );
            }
        }

        write_checkpoint(&engine, &path);
        assert!(path.exists(), "checkpoint file must be written");
        // The atomic rename leaves no stray .tmp behind.
        assert!(!path.with_extension("tmp").exists());

        // A fresh engine re-warms from the file (huge max_age = nothing stale).
        let restored = Arc::new(Mutex::new(DetectorEngine::new(EngineConfig::default())));
        load_checkpoint(&restored, &path, u64::MAX);
        assert_eq!(restored.lock().unwrap().series_count(), 1);

        // A missing file is a no-op (cold start), never an error.
        let _ = std::fs::remove_file(&path);
        let cold = Arc::new(Mutex::new(DetectorEngine::new(EngineConfig::default())));
        load_checkpoint(&cold, &path, u64::MAX);
        assert_eq!(cold.lock().unwrap().series_count(), 0);
    }
}
