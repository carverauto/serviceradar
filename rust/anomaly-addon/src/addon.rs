// Copyright 2026 Carver Automation Corporation.
//
// Licensed under the Apache License, Version 2.0 (the "License").
// SPDX-License-Identifier: Apache-2.0

//! The `AnomalyAddon`: consumes the agent's local metric feed
//! (`metric-feed:v1`), runs the shared detector per series, and emits anomaly
//! verdicts upstream over the native telemetry stream (`native-telemetry:v1`).

use std::sync::{Arc, Mutex, MutexGuard};

use addon_sdk::metric_pb::{
    Metric, MetricBatch, MetricKind, MetricPoint, MetricResource, MetricTemporality,
};
use addon_sdk::pb::{MetricFeedAck, MetricFeedFrame, TelemetryBatch, TelemetryRecord};
use addon_sdk::{
    Addon, CAPABILITY_METRIC_FEED_V1, CAPABILITY_NATIVE_TELEMETRY_V1, ConfigureResult, Health,
    HealthStatus, Info, MetricFeedAckStream, MetricFeedStream, SignalSchemaRef,
    TelemetryBatchBuilder, TelemetryStream, attach_signal_schema_ref, ocsf_event_record,
};
use async_trait::async_trait;
use prost::Message;
use serde::de::{self, Deserializer};
use serde_json::Value;
use serviceradar_anomaly_core::{ReasonVerdict, SaturationGate};
use sha2::{Digest as _, Sha256};
use tokio::sync::{broadcast, mpsc};
use tokio::task::JoinHandle;
use tokio_stream::StreamExt as _;
use tokio_stream::wrappers::errors::BroadcastStreamRecvError;
use tokio_stream::wrappers::{BroadcastStream, ReceiverStream};
use tonic::Status;

use std::path::{Path, PathBuf};

use crate::engine::{
    AnomalyTransition, DetectorEngine, EngineCheckpoint, EngineConfig, SeriesProfile,
};

const ADDON_ID: &str = "anomaly";
const ADDON_VERSION: &str = "0.1.1";
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
    #[serde(default, deserialize_with = "optional_usize")]
    window_size: Option<usize>,
    #[serde(default, deserialize_with = "optional_usize")]
    min_samples: Option<usize>,
    #[serde(default, deserialize_with = "optional_f64")]
    n_sigma: Option<f64>,
    #[serde(default, deserialize_with = "optional_usize")]
    confirm_slots: Option<usize>,
    #[serde(default, deserialize_with = "optional_usize")]
    max_series: Option<usize>,
    /// Optional GLOBAL dispersion-floor overrides (fix #2). When set, these only
    /// ever RAISE a series' built-in per-class floor (max), letting an operator
    /// tighten the whole fleet without per-class tuning. Omitted leaves every
    /// series on its built-in default (0 for non-gauges, the gauge defaults for
    /// cpu/mem/disk). The central metric_class override channel remains a
    /// follow-up; this flat knob is the edge-only global override.
    #[serde(default, deserialize_with = "optional_f64")]
    min_std_floor: Option<f64>,
    #[serde(default, deserialize_with = "optional_f64")]
    min_cv: Option<f64>,
    /// Local path the add-on persists its per-series checkpoint to so a restart
    /// re-warms baselines instead of cold-starting. Unset disables checkpointing.
    #[serde(default, deserialize_with = "optional_string")]
    checkpoint_path: Option<String>,
    /// Restart staleness bound in seconds (default 6h); series older than this
    /// are not reseeded.
    #[serde(default, deserialize_with = "optional_u64")]
    checkpoint_max_age_secs: Option<u64>,
    /// Live-state staleness bound in seconds (default 6h); stale series/counters
    /// are evicted before rejecting new series at `max_series`.
    #[serde(default, deserialize_with = "optional_u64")]
    state_max_age_secs: Option<u64>,
}

fn optional_usize<'de, D>(deserializer: D) -> Result<Option<usize>, D::Error>
where
    D: Deserializer<'de>,
{
    match optional_value(deserializer)? {
        None => Ok(None),
        Some(Value::Number(number)) => number
            .as_u64()
            .and_then(|value| usize::try_from(value).ok())
            .map(Some)
            .ok_or_else(|| de::Error::custom("expected a non-negative integer")),
        Some(Value::String(value)) => parse_optional_integer(&value).and_then(|value| {
            value
                .map(|number| {
                    usize::try_from(number).map_err(|_| de::Error::custom("integer is too large"))
                })
                .transpose()
        }),
        Some(_) => Err(de::Error::custom("expected integer, string, or null")),
    }
}

fn optional_u64<'de, D>(deserializer: D) -> Result<Option<u64>, D::Error>
where
    D: Deserializer<'de>,
{
    match optional_value(deserializer)? {
        None => Ok(None),
        Some(Value::Number(number)) => number
            .as_u64()
            .map(Some)
            .ok_or_else(|| de::Error::custom("expected a non-negative integer")),
        Some(Value::String(value)) => parse_optional_integer(&value),
        Some(_) => Err(de::Error::custom("expected integer, string, or null")),
    }
}

fn optional_f64<'de, D>(deserializer: D) -> Result<Option<f64>, D::Error>
where
    D: Deserializer<'de>,
{
    match optional_value(deserializer)? {
        None => Ok(None),
        Some(Value::Number(number)) => number
            .as_f64()
            .map(Some)
            .ok_or_else(|| de::Error::custom("expected a finite number")),
        Some(Value::String(value)) => {
            let trimmed = value.trim();
            if trimmed.is_empty() {
                Ok(None)
            } else {
                trimmed
                    .parse::<f64>()
                    .map(Some)
                    .map_err(|_| de::Error::custom("expected a number"))
            }
        }
        Some(_) => Err(de::Error::custom("expected number, string, or null")),
    }
}

fn optional_string<'de, D>(deserializer: D) -> Result<Option<String>, D::Error>
where
    D: Deserializer<'de>,
{
    match optional_value(deserializer)? {
        None => Ok(None),
        Some(Value::String(value)) => {
            let trimmed = value.trim();
            if trimmed.is_empty() {
                Ok(None)
            } else {
                Ok(Some(value))
            }
        }
        Some(_) => Err(de::Error::custom("expected string or null")),
    }
}

fn optional_value<'de, D>(deserializer: D) -> Result<Option<Value>, D::Error>
where
    D: Deserializer<'de>,
{
    let value = <Option<Value> as serde::Deserialize>::deserialize(deserializer)?;

    Ok(value.filter(|value| !value.is_null()))
}

fn parse_optional_integer<E>(value: &str) -> Result<Option<u64>, E>
where
    E: de::Error,
{
    let trimmed = value.trim();
    if trimmed.is_empty() {
        Ok(None)
    } else {
        trimmed
            .parse::<u64>()
            .map(Some)
            .map_err(|_| de::Error::custom("expected a non-negative integer"))
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
    fn validation_error(&self) -> Option<String> {
        let base = EngineConfig::default();
        let window_size = self.window_size.unwrap_or(base.window_size).max(1);
        let min_samples = self.min_samples.unwrap_or(base.min_samples).max(1);

        if min_samples > window_size {
            Some(format!(
                "invalid anomaly add-on config: min_samples ({min_samples}) must be <= window_size ({window_size})"
            ))
        } else {
            None
        }
    }

    fn into_engine_config(self) -> EngineConfig {
        let base = EngineConfig::default();
        EngineConfig {
            window_size: self.window_size.unwrap_or(base.window_size).max(1),
            min_samples: self.min_samples.unwrap_or(base.min_samples).max(1),
            n_sigma: self.n_sigma.unwrap_or(base.n_sigma),
            confirm_slots: self.confirm_slots.unwrap_or(base.confirm_slots).max(1),
            max_series: self.max_series.unwrap_or(base.max_series).max(1),
            // Only accept a finite, positive override; a 0/negative/NaN value is
            // treated as "unset" so it can never weaken a gauge's safe floor.
            min_std_floor: self.min_std_floor.filter(|v| v.is_finite() && *v > 0.0),
            min_cv: self.min_cv.filter(|v| v.is_finite() && *v > 0.0),
            stale_series_max_age_ns: self
                .state_max_age_secs
                .map(|secs| secs.saturating_mul(1_000_000_000))
                .unwrap_or(base.stale_series_max_age_ns),
        }
    }
}

#[derive(Clone, Debug, Default)]
struct ScoringLiveness {
    frames_received: u64,
    samples_scored: u64,
    verdict_records_emitted: u64,
    capacity_dropped_total: u64,
    tracked_series: usize,
    tracked_counters: usize,
    max_series: usize,
    last_scored_unix_nano: Option<u64>,
}

#[derive(Clone, Copy, Debug, Default)]
struct FrameLiveness {
    samples_scored: u64,
    verdict_records_emitted: u64,
    capacity_dropped_total: u64,
    tracked_series: usize,
    tracked_counters: usize,
    max_series: usize,
    last_scored_unix_nano: Option<u64>,
}

fn scoring_liveness_json(liveness: &Arc<Mutex<ScoringLiveness>>) -> String {
    let snapshot = liveness.lock().expect("liveness mutex poisoned").clone();

    serde_json::json!({
        "kind": "anomaly_scoring_liveness",
        "frames_received": snapshot.frames_received,
        "samples_scored_total": snapshot.samples_scored,
        "verdict_records_emitted_total": snapshot.verdict_records_emitted,
        "tracked_series": snapshot.tracked_series,
        "tracked_counters": snapshot.tracked_counters,
        "max_series": snapshot.max_series,
        "capacity_dropped_total": snapshot.capacity_dropped_total,
        "last_scored_unix_nano": snapshot.last_scored_unix_nano
    })
    .to_string()
}

fn record_frame_received(liveness: &Arc<Mutex<ScoringLiveness>>) {
    let mut snapshot = liveness.lock().expect("liveness mutex poisoned");
    snapshot.frames_received = snapshot.frames_received.saturating_add(1);
}

fn record_frame_liveness(liveness: &Arc<Mutex<ScoringLiveness>>, frame: FrameLiveness) {
    let mut snapshot = liveness.lock().expect("liveness mutex poisoned");
    snapshot.samples_scored = snapshot.samples_scored.saturating_add(frame.samples_scored);
    snapshot.verdict_records_emitted = snapshot
        .verdict_records_emitted
        .saturating_add(frame.verdict_records_emitted);
    snapshot.capacity_dropped_total = frame.capacity_dropped_total;
    snapshot.tracked_series = frame.tracked_series;
    snapshot.tracked_counters = frame.tracked_counters;
    snapshot.max_series = frame.max_series;
    if let Some(ts) = frame.last_scored_unix_nano {
        snapshot.last_scored_unix_nano = Some(ts);
    }
}

/// Edge anomaly add-on. Shared (`Arc`) across concurrent gRPC calls, so all
/// mutable state is behind a `Mutex`.
pub struct AnomalyAddon {
    engine: Arc<Mutex<DetectorEngine>>,
    verdict_tx: broadcast::Sender<TelemetryBatch>,
    feed_task: Mutex<Option<JoinHandle<()>>>,
    liveness: Arc<Mutex<ScoringLiveness>>,
    /// Resolved at `configure`; read when a feed stream opens.
    checkpoint: Mutex<CheckpointSettings>,
}

impl Default for AnomalyAddon {
    fn default() -> Self {
        Self::new()
    }
}

impl AnomalyAddon {
    pub fn new() -> Self {
        let engine_config = EngineConfig::default();
        let (verdict_tx, _) = broadcast::channel(VERDICT_CHANNEL_DEPTH);
        Self {
            engine: Arc::new(Mutex::new(DetectorEngine::new(engine_config.clone()))),
            verdict_tx,
            feed_task: Mutex::new(None),
            liveness: Arc::new(Mutex::new(ScoringLiveness {
                max_series: engine_config.max_series,
                ..ScoringLiveness::default()
            })),
            checkpoint: Mutex::new(CheckpointSettings::default()),
        }
    }
}

impl Drop for AnomalyAddon {
    fn drop(&mut self) {
        if let Ok(mut feed_task) = self.feed_task.lock()
            && let Some(handle) = feed_task.take()
        {
            handle.abort();
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

        if let Some(error) = parsed.validation_error() {
            return Ok(ConfigureResult {
                config_hash,
                accepted: false,
                error,
            });
        }

        let settings = resolve_checkpoint_settings(&parsed);

        let engine_config = parsed.into_engine_config();
        lock_engine(&self.engine).set_config(engine_config.clone());
        self.liveness
            .lock()
            .expect("liveness mutex poisoned")
            .max_series = engine_config.max_series;

        // Re-warm from the on-disk checkpoint before scoring resumes, so a
        // restart does not storm false positives while windows refill.
        if let Some(path) = settings.path.clone() {
            load_checkpoint(&self.engine, &path, settings.max_age_ns);
        }
        *self.checkpoint.lock().expect("checkpoint mutex poisoned") = settings;

        Ok(ConfigureResult {
            config_hash,
            accepted: true,
            error: String::new(),
        })
    }

    async fn health(&self) -> anyhow::Result<Health> {
        Ok(Health {
            status: HealthStatus::Healthy,
            version: ADDON_VERSION.to_string(),
            degradation_reason: scoring_liveness_json(&self.liveness),
        })
    }

    /// Hand the agent a reconnect-safe verdict stream. Delivery is lossy by
    /// contract: a lagging receiver gets a RESOURCE_EXHAUSTED marker instead of
    /// back-pressure on scoring or metric-feed acknowledgement.
    fn stream_telemetry(&self) -> TelemetryStream {
        let stream =
            BroadcastStream::new(self.verdict_tx.subscribe()).filter_map(|item| match item {
                Ok(batch) => Some(Ok(batch)),
                Err(BroadcastStreamRecvError::Lagged(skipped)) => {
                    Some(Err(Status::resource_exhausted(format!(
                        "anomaly telemetry receiver lagged by {skipped} batches"
                    ))))
                }
            });
        Box::pin(stream)
    }

    /// Consume the agent's local metric feed, score each sample, and ack frames.
    /// Verdicts are pushed onto the telemetry channel drained by
    /// [`Self::stream_telemetry`].
    fn stream_metric_feed(&self, frames: MetricFeedStream) -> Result<MetricFeedAckStream, Status> {
        let engine = self.engine.clone();
        let verdict_tx = self.verdict_tx.clone();
        let liveness = self.liveness.clone();
        let checkpoint = self
            .checkpoint
            .lock()
            .expect("checkpoint mutex poisoned")
            .clone();
        let (ack_tx, ack_rx) = mpsc::channel::<Result<MetricFeedAck, Status>>(ACK_CHANNEL_DEPTH);

        let mut feed_task = self
            .feed_task
            .lock()
            .map_err(|_| Status::internal("metric-feed task mutex poisoned"))?;
        if let Some(handle) = feed_task.take() {
            handle.abort();
        }

        let handle = tokio::spawn(async move {
            let mut frames = frames;
            let mut frame_count: u64 = 0;
            while let Some(item) = frames.next().await {
                let frame = match item {
                    Ok(frame) => frame,
                    Err(_) => break,
                };
                process_frame(&engine, &verdict_tx, &liveness, &frame);

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
        *feed_task = Some(handle);

        Ok(Box::pin(ReceiverStream::new(ack_rx)))
    }
}

/// Decode one feed frame's `MetricBatch`, score every eligible point, and push a
/// verdict telemetry batch for any breaches.
fn process_frame(
    engine: &Arc<Mutex<DetectorEngine>>,
    verdict_tx: &broadcast::Sender<TelemetryBatch>,
    liveness: &Arc<Mutex<ScoringLiveness>>,
    frame: &MetricFeedFrame,
) {
    record_frame_received(liveness);

    let batch = match MetricBatch::decode(frame.payload.as_slice()) {
        Ok(batch) => batch,
        Err(_) => return, // poison payload: drop the frame, never block the feed
    };
    let resource = batch.resource.unwrap_or_default();

    // Lock the engine only to score; never hold the std Mutex across an await.
    let mut records: Vec<TelemetryRecord> = Vec::new();
    let mut shed_report: Option<ShedReport> = None;
    let mut frame_liveness = FrameLiveness::default();
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
                    match engine.normalize_counter(
                        &series_key,
                        counter_raw_value(point),
                        point.observed_at_unix_nano,
                        &counter_reset_anchor(point),
                        metric.counter_width,
                    ) {
                        Some(rate) => rate,
                        // Warmup / reset / gap / non-monotonic: no sample this point.
                        None => continue,
                    }
                } else {
                    point.value
                };

                if let Some(result) = engine.evaluate_transition(
                    &series_key,
                    value,
                    point.observed_at_unix_nano,
                    profile,
                ) {
                    frame_liveness.samples_scored = frame_liveness.samples_scored.saturating_add(1);
                    frame_liveness.last_scored_unix_nano = Some(
                        frame_liveness
                            .last_scored_unix_nano
                            .map_or(point.observed_at_unix_nano, |current| {
                                current.max(point.observed_at_unix_nano)
                            }),
                    );

                    if let Some(transition) = result.transition {
                        frame_liveness.verdict_records_emitted =
                            frame_liveness.verdict_records_emitted.saturating_add(1);
                        records.push(verdict_record(
                            &resource,
                            metric,
                            point,
                            &series_key,
                            &result.verdict,
                            transition,
                        ));
                    }
                }
            }
        }

        let dropped_after = engine.dropped_at_capacity;
        frame_liveness.capacity_dropped_total = dropped_after;
        frame_liveness.tracked_series = engine.series_count();
        frame_liveness.tracked_counters = engine.counter_count();
        frame_liveness.max_series = engine.max_series();
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
    record_frame_liveness(liveness, frame_liveness);

    if let Some(report) = shed_report {
        records.push(shed_record(&resource, frame.feed_id, report));
    }

    if records.is_empty() {
        return;
    }

    let mut builder = TelemetryBatchBuilder::new("anomaly-addon", resource.agent_id.clone());
    for record in records {
        builder = builder.push_record(record);
    }
    let _ = verdict_tx.send(builder.build());
}

fn lock_engine(engine: &Arc<Mutex<DetectorEngine>>) -> MutexGuard<'_, DetectorEngine> {
    match engine.lock() {
        Ok(guard) => guard,
        Err(poisoned) => {
            let mut guard = poisoned.into_inner();
            let config = guard.config();
            *guard = DetectorEngine::new(config);
            guard
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

fn series_key_for(resource: &MetricResource, metric: &Metric, point: &MetricPoint) -> String {
    if let Some(target_device_ip) = remote_snmp_target(resource, metric) {
        format!(
            "{}|{}|{}",
            series_key_component(target_device_ip),
            series_key_component(&metric.name),
            series_key_component(&point_interface_component(point))
        )
    } else if !point.series_identity_hint.is_empty() {
        point.series_identity_hint.clone()
    } else {
        // Fallback when the producer did not stamp a hint: agent + metric +
        // interface keeps distinct series apart on one host.
        format!(
            "{}|{}|{}",
            series_key_component(&resource.agent_id),
            series_key_component(&metric.name),
            series_key_component(&point_interface_component(point))
        )
    }
}

fn identity_anchor_for<'a>(resource: &'a MetricResource, metric: &Metric) -> &'a str {
    first_non_empty(&[
        remote_snmp_target(resource, metric).unwrap_or_default(),
        resource.device_id.as_str(),
        resource.host_id.as_str(),
        resource.agent_id.as_str(),
        resource.host_ip.as_str(),
    ])
}

fn remote_snmp_target<'a>(resource: &'a MetricResource, metric: &Metric) -> Option<&'a str> {
    let target = resource.target_device_ip.trim();

    if !snmp_metric(metric) || target.is_empty() {
        return None;
    }

    let is_self = [
        resource.host_ip.as_str(),
        resource.device_id.as_str(),
        resource.host_id.as_str(),
    ]
    .iter()
    .any(|candidate| !candidate.trim().is_empty() && candidate.trim() == target);

    if is_self { None } else { Some(target) }
}

fn snmp_metric(metric: &Metric) -> bool {
    metric.metric_type == "snmp" || metric.metric_type.starts_with("snmp.")
}

fn point_interface_component(point: &MetricPoint) -> String {
    if !point.interface_uid.trim().is_empty() {
        point.interface_uid.clone()
    } else if point.if_index > 0 {
        point.if_index.to_string()
    } else {
        String::new()
    }
}

fn series_key_component(value: &str) -> String {
    if safe_series_key_component(value) {
        value.to_string()
    } else {
        let digest = Sha256::digest(value.as_bytes());
        format!("h_{}", hex::encode(digest))
    }
}

fn safe_series_key_component(value: &str) -> bool {
    !value.is_empty()
        && !value.chars().any(|ch| {
            ch == '|'
                || ch == ':'
                || ch == '*'
                || ch == '>'
                || ch.is_whitespace()
                || ch.is_control()
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
    let severity_id = match transition {
        AnomalyTransition::Open => severity_id_from_score(verdict.score),
        AnomalyTransition::Clear => 1,
    };

    let metric_class = if metric.metric_type.is_empty() {
        "metric"
    } else {
        metric.metric_type.as_str()
    };
    let device_uid = identity_anchor_for(resource, metric);

    let transition_label = match transition {
        AnomalyTransition::Open => "open",
        AnomalyTransition::Clear => "clear",
    };
    let status = match transition {
        AnomalyTransition::Open => "open",
        AnomalyTransition::Clear => "closed",
    };
    let anomaly_state = match transition {
        AnomalyTransition::Open => verdict.state.as_str(),
        AnomalyTransition::Clear => "clear",
    };
    let event_id = format!("anomaly:{series_key}:{ts_nano}:{transition_label}");
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
        "target_device_ip": &resource.target_device_ip,
        "message": &verdict.reason,
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
            "target_device_ip": &resource.target_device_ip,
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
            "state": anomaly_state,
            "reason": &verdict.reason,
            "score": verdict.score,
            "baseline_count": verdict.baseline_count,
            "value": verdict.sample_value,
            "sample_value": verdict.sample_value,
            "target_device_ip": &resource.target_device_ip,
            "metadata": {
                "target_device_ip": &resource.target_device_ip,
            },
            "observed_at_unix_nano": ts_nano,
            "signals": [],
        },
    });

    let payload = serde_json::to_vec(&body).unwrap_or_default();
    let record = ocsf_event_record(event_id, ts_nano as i64, ts_nano as i64, payload);
    attach_signal_schema_ref(record, &anomaly_signal_schema_ref())
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
            "Anomaly add-on shed {} new series at capacity ({} detector series, {} counters tracked of max {})",
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

    #[tokio::test]
    async fn configure_rejects_min_samples_larger_than_window_size() {
        let addon = AnomalyAddon::new();
        let result = addon
            .configure(br#"{"window_size":5,"min_samples":6}"#)
            .await
            .expect("configure result");

        assert!(!result.accepted);
        assert!(result.error.contains("min_samples"));
        assert!(result.error.contains("window_size"));
    }

    #[tokio::test]
    async fn configure_treats_empty_optional_scalars_as_unset() {
        let addon = AnomalyAddon::new();
        let result = addon
            .configure(
                br#"{
                    "window_size":"",
                    "min_samples":"",
                    "n_sigma":"",
                    "confirm_slots":"",
                    "max_series":"",
                    "min_std_floor":"",
                    "min_cv":"",
                    "checkpoint_path":"",
                    "checkpoint_max_age_secs":"",
                    "state_max_age_secs":"",
                    "metric_feed":{"sources":["sysmon","snmp"]}
                }"#,
            )
            .await
            .expect("configure result");

        assert!(result.accepted, "unexpected error: {}", result.error);
        assert!(result.error.is_empty());
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
    fn fallback_series_key_hashes_unsafe_components_to_avoid_delimiter_collisions() {
        let left = series_key_for(
            &MetricResource {
                agent_id: "agent|a".to_string(),
                ..Default::default()
            },
            &Metric {
                name: "metric".to_string(),
                ..Default::default()
            },
            &MetricPoint {
                interface_uid: "if0".to_string(),
                ..Default::default()
            },
        );
        let right = series_key_for(
            &MetricResource {
                agent_id: "agent".to_string(),
                ..Default::default()
            },
            &Metric {
                name: "a|metric".to_string(),
                ..Default::default()
            },
            &MetricPoint {
                interface_uid: "if0".to_string(),
                ..Default::default()
            },
        );

        assert_ne!(left, right);
        assert!(left.contains("h_"));
        assert!(right.contains("h_"));
        assert!(!left.contains("agent|a"));
        assert!(!right.contains("a|metric"));
    }

    #[test]
    fn remote_snmp_target_overrides_agent_identity_and_hint() {
        let resource = MetricResource {
            agent_id: "agent-host".to_string(),
            host_id: "poller-host".to_string(),
            host_ip: "192.0.2.10".to_string(),
            device_id: "poller-device".to_string(),
            target_device_ip: "198.51.100.25".to_string(),
            partition: "demo".to_string(),
            ..Default::default()
        };
        let metric = Metric {
            name: "snmp.ifInOctets".to_string(),
            metric_type: "snmp.interface".to_string(),
            ..Default::default()
        };
        let point = MetricPoint {
            observed_at_unix_nano: 1_765_000_123_456_789_000,
            if_index: 7,
            series_identity_hint: "snmp:agent-host:7".to_string(),
            ..Default::default()
        };

        let series_key = series_key_for(&resource, &metric, &point);

        assert_eq!(series_key, "198.51.100.25|snmp.ifInOctets|7");
        assert_eq!(identity_anchor_for(&resource, &metric), "198.51.100.25");

        let verdict = ReasonVerdict {
            state: "confirmed_anomaly".to_string(),
            anomalous: true,
            breached: true,
            include_in_baseline: false,
            next_consecutive_anomalous: 3,
            score: 4.0,
            reason: "breach".to_string(),
            baseline_count: 30,
            next_rolling_acc: Default::default(),
            next_window_tail: vec![],
            sample_value: 99.0,
            observed_at_unix_nano: Some(point.observed_at_unix_nano),
            signals: vec![],
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

        assert_eq!(event["device_uid"], "198.51.100.25");
        assert_eq!(event["device_id"], "198.51.100.25");
        assert_eq!(event["target_device_ip"], "198.51.100.25");
        assert_eq!(event["anomaly"]["target_device_ip"], "198.51.100.25");
        assert_eq!(
            event["anomaly"]["metadata"]["target_device_ip"],
            "198.51.100.25"
        );
        assert_eq!(
            event["source_identity"]["target_device_ip"],
            "198.51.100.25"
        );
        assert_eq!(event["source_identity"]["agent_id"], "agent-host");
    }

    #[test]
    fn edge_verdict_identity_and_time_use_sample_timestamp() {
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
            observed_at_unix_nano: 1_765_000_123_456_789_000,
            ..Default::default()
        };
        let verdict = ReasonVerdict {
            state: "confirmed_anomaly".to_string(),
            anomalous: true,
            breached: true,
            include_in_baseline: false,
            next_consecutive_anomalous: 5,
            score: 4.0,
            reason: "breach".to_string(),
            baseline_count: 30,
            next_rolling_acc: Default::default(),
            next_window_tail: vec![],
            sample_value: 99.0,
            observed_at_unix_nano: Some(point.observed_at_unix_nano),
            signals: vec![],
        };

        let record = verdict_record(
            &resource,
            &metric,
            &point,
            "series-a",
            &verdict,
            AnomalyTransition::Open,
        );
        let event: serde_json::Value = serde_json::from_slice(&record.payload).unwrap();

        assert_eq!(
            record.event_time_unix_nano,
            point.observed_at_unix_nano as i64
        );
        assert_eq!(
            record.observed_time_unix_nano,
            point.observed_at_unix_nano as i64
        );
        assert_eq!(event["time"], 1_765_000_123_456_i64);
        assert_eq!(
            event["anomaly"]["observed_at_unix_nano"],
            point.observed_at_unix_nano
        );
        assert_eq!(
            event["event_id"],
            format!("anomaly:series-a:{}:open", point.observed_at_unix_nano)
        );
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
        let (tx, mut rx) = broadcast::channel(1);
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

        let liveness = Arc::new(Mutex::new(ScoringLiveness::default()));
        process_frame(&engine, &tx, &liveness, &frame);

        let sent = rx.recv().await.expect("telemetry batch");
        assert_eq!(sent.records.len(), 1);
        let event: serde_json::Value = serde_json::from_slice(&sent.records[0].payload).unwrap();
        assert_eq!(event["status_code"], "anomaly_capacity_shed");
        assert_eq!(event["unmapped"]["dropped_series_delta"], 2);
        assert_eq!(event["unmapped"]["feed_id"], 7);
        assert_eq!(engine.lock().unwrap().dropped_at_capacity, 2);
    }

    #[tokio::test]
    async fn process_frame_recovers_from_poisoned_engine_mutex() {
        let engine = Arc::new(Mutex::new(DetectorEngine::new(EngineConfig {
            max_series: 1,
            min_samples: 1,
            confirm_slots: 1,
            ..EngineConfig::default()
        })));
        let poisoned = Arc::clone(&engine);
        let _ = std::thread::spawn(move || {
            let _guard = poisoned.lock().expect("lock before panic");
            panic!("poison engine mutex for test");
        })
        .join();

        let (tx, mut rx) = broadcast::channel(1);
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
                ],
                ..Default::default()
            }],
            ..Default::default()
        };
        let frame = MetricFeedFrame {
            feed_id: 8,
            source: None,
            payload: batch.encode_to_vec(),
        };

        let liveness = Arc::new(Mutex::new(ScoringLiveness::default()));
        process_frame(&engine, &tx, &liveness, &frame);

        let sent = rx.recv().await.expect("telemetry batch after poison");
        assert_eq!(sent.records.len(), 1);
        let event: serde_json::Value = serde_json::from_slice(&sent.records[0].payload).unwrap();
        assert_eq!(event["status_code"], "anomaly_capacity_shed");
        assert_eq!(event["unmapped"]["feed_id"], 8);
    }

    #[tokio::test]
    async fn health_exposes_scoring_liveness_snapshot() {
        let addon = AnomalyAddon::new();
        {
            addon.engine.lock().unwrap().set_config(EngineConfig {
                min_samples: 1,
                confirm_slots: 1,
                max_series: 10,
                ..EngineConfig::default()
            });
            addon.liveness.lock().unwrap().max_series = 10;
        }

        let batch = MetricBatch {
            resource: Some(MetricResource {
                agent_id: "agent-a".to_string(),
                host_id: "host-a".to_string(),
                ..Default::default()
            }),
            metrics: vec![Metric {
                name: "cpu.usage_percent".to_string(),
                metric_type: "sysmon.cpu".to_string(),
                points: vec![MetricPoint {
                    value: 10.0,
                    observed_at_unix_nano: 123,
                    series_identity_hint: "series-a".to_string(),
                    ..Default::default()
                }],
                ..Default::default()
            }],
            ..Default::default()
        };
        let frame = MetricFeedFrame {
            feed_id: 9,
            source: None,
            payload: batch.encode_to_vec(),
        };

        process_frame(&addon.engine, &addon.verdict_tx, &addon.liveness, &frame);

        let health = addon.health().await.expect("health");
        assert_eq!(health.status, HealthStatus::Healthy);

        let liveness: serde_json::Value = serde_json::from_str(&health.degradation_reason).unwrap();
        assert_eq!(liveness["kind"], "anomaly_scoring_liveness");
        assert_eq!(liveness["frames_received"], 1);
        assert_eq!(liveness["samples_scored_total"], 1);
        assert_eq!(liveness["tracked_series"], 1);
        assert_eq!(liveness["max_series"], 10);
        assert_eq!(liveness["last_scored_unix_nano"], 123);
    }

    fn empty_feed_frame(feed_id: u64) -> MetricFeedFrame {
        MetricFeedFrame {
            feed_id,
            source: None,
            payload: MetricBatch::default().encode_to_vec(),
        }
    }

    #[tokio::test]
    async fn metric_feed_reopen_aborts_prior_scoring_task() {
        let addon = AnomalyAddon::new();

        let (old_tx, old_rx) = mpsc::channel(1);
        let mut old_acks = addon
            .stream_metric_feed(Box::pin(ReceiverStream::new(old_rx)))
            .expect("old metric feed stream");

        let (new_tx, new_rx) = mpsc::channel(1);
        let mut new_acks = addon
            .stream_metric_feed(Box::pin(ReceiverStream::new(new_rx)))
            .expect("new metric feed stream");

        let old_done = tokio::time::timeout(std::time::Duration::from_millis(250), old_acks.next())
            .await
            .expect("old ack stream should close after feed reopen");
        assert!(old_done.is_none());
        assert!(old_tx.send(Ok(empty_feed_frame(1))).await.is_err());

        new_tx
            .send(Ok(empty_feed_frame(2)))
            .await
            .expect("new metric feed receiver remains active");

        let ack = tokio::time::timeout(std::time::Duration::from_millis(250), new_acks.next())
            .await
            .expect("new ack stream should receive ack")
            .expect("new ack stream remains open")
            .expect("new ack should be ok");
        assert_eq!(ack.acked_feed_id, 2);
    }

    #[tokio::test]
    async fn metric_feed_closes_promptly_when_addon_is_dropped() {
        let addon = AnomalyAddon::new();

        let (tx, rx) = mpsc::channel(1);
        let mut acks = addon
            .stream_metric_feed(Box::pin(ReceiverStream::new(rx)))
            .expect("metric feed stream");

        drop(addon);

        let done = tokio::time::timeout(std::time::Duration::from_millis(250), acks.next())
            .await
            .expect("ack stream should close when addon drops");
        assert!(done.is_none());
        assert!(tx.send(Ok(empty_feed_frame(3))).await.is_err());
    }

    fn empty_telemetry_batch() -> TelemetryBatch {
        TelemetryBatch {
            source: None,
            records: Vec::new(),
            counters: None,
        }
    }

    #[tokio::test]
    async fn telemetry_stream_is_reconnect_safe() {
        let addon = AnomalyAddon::new();
        let mut first = addon.stream_telemetry();
        let mut second = addon.stream_telemetry();

        addon
            .verdict_tx
            .send(empty_telemetry_batch())
            .expect("broadcast to active subscribers");

        assert!(first.next().await.expect("first item").is_ok());
        assert!(second.next().await.expect("second item").is_ok());
    }

    #[tokio::test]
    async fn telemetry_stream_reports_lag_without_backpressure() {
        let addon = AnomalyAddon::new();
        let mut stream = addon.stream_telemetry();

        for _ in 0..(VERDICT_CHANNEL_DEPTH + 1) {
            addon
                .verdict_tx
                .send(empty_telemetry_batch())
                .expect("subscriber is active");
        }

        let err = stream
            .next()
            .await
            .expect("lag marker")
            .expect_err("lag should be reported as stream error");
        assert_eq!(err.code(), tonic::Code::ResourceExhausted);
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
