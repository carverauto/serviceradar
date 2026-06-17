// Copyright 2026 Carver Automation Corporation.
//
// Licensed under the Apache License, Version 2.0 (the "License").
// SPDX-License-Identifier: Apache-2.0

//! The `AnomalyAddon`: consumes the agent's local metric feed
//! (`metric-feed:v1`), runs the shared detector per series, and emits anomaly
//! verdicts upstream over the native telemetry stream (`native-telemetry:v1`).

use std::sync::{Arc, Mutex};

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
use serviceradar_anomaly_core::ReasonVerdict;
use sha2::{Digest as _, Sha256};
use tokio::sync::mpsc;
use tokio_stream::StreamExt as _;
use tokio_stream::wrappers::ReceiverStream;
use tonic::Status;

use std::path::{Path, PathBuf};

use crate::engine::{DetectorEngine, EngineCheckpoint, EngineConfig};

const ADDON_ID: &str = "anomaly";
const ADDON_VERSION: &str = "0.1.0";
const VERDICT_CHANNEL_DEPTH: usize = 256;
const ACK_CHANNEL_DEPTH: usize = 64;

/// Default restart-checkpoint staleness bound (6h): a baseline whose last reading
/// is older than this is not reseeded on restart.
const DEFAULT_CHECKPOINT_MAX_AGE_NS: u64 = 6 * 60 * 60 * 1_000_000_000;
/// Default checkpoint cadence: persist after every N processed feed frames.
const DEFAULT_CHECKPOINT_WRITE_EVERY: u64 = 100;

/// Operator-supplied configuration (validated by the control plane against
/// `config.schema.json`). All fields optional; omitted ones keep the defaults.
#[derive(Debug, Default, serde::Deserialize)]
struct AddonConfig {
    window_size: Option<usize>,
    min_samples: Option<usize>,
    n_sigma: Option<f64>,
    confirm_slots: Option<usize>,
    max_series: Option<usize>,
    /// Local path the add-on persists its per-series checkpoint to so a restart
    /// re-warms baselines instead of cold-starting. Unset disables checkpointing.
    checkpoint_path: Option<String>,
    /// Restart staleness bound in seconds (default 6h); series older than this
    /// are not reseeded.
    checkpoint_max_age_secs: Option<u64>,
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
    fn into_engine_config(self) -> EngineConfig {
        let base = EngineConfig::default();
        EngineConfig {
            window_size: self.window_size.unwrap_or(base.window_size).max(1),
            min_samples: self.min_samples.unwrap_or(base.min_samples).max(1),
            n_sigma: self.n_sigma.unwrap_or(base.n_sigma),
            confirm_slots: self.confirm_slots.unwrap_or(base.confirm_slots).max(1),
            max_series: self.max_series.unwrap_or(base.max_series).max(1),
        }
    }
}

/// Edge anomaly add-on. Shared (`Arc`) across concurrent gRPC calls, so all
/// mutable state is behind a `Mutex`.
pub struct AnomalyAddon {
    engine: Arc<Mutex<DetectorEngine>>,
    verdict_tx: mpsc::Sender<Result<TelemetryBatch, Status>>,
    verdict_rx: Mutex<Option<mpsc::Receiver<Result<TelemetryBatch, Status>>>>,
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
        let (verdict_tx, verdict_rx) = mpsc::channel(VERDICT_CHANNEL_DEPTH);
        Self {
            engine: Arc::new(Mutex::new(DetectorEngine::new(EngineConfig::default()))),
            verdict_tx,
            verdict_rx: Mutex::new(Some(verdict_rx)),
            checkpoint: Mutex::new(CheckpointSettings::default()),
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

        self.engine
            .lock()
            .expect("engine mutex poisoned")
            .set_config(parsed.into_engine_config());

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
            degradation_reason: String::new(),
        })
    }

    /// Hand the agent the verdict stream. Called once when the agent opens the
    /// native telemetry stream; later calls get an empty stream.
    fn stream_telemetry(&self) -> TelemetryStream {
        match self
            .verdict_rx
            .lock()
            .expect("verdict_rx mutex poisoned")
            .take()
        {
            Some(rx) => Box::pin(ReceiverStream::new(rx)),
            None => Box::pin(tokio_stream::empty()),
        }
    }

    /// Consume the agent's local metric feed, score each sample, and ack frames.
    /// Verdicts are pushed onto the telemetry channel drained by
    /// [`Self::stream_telemetry`].
    fn stream_metric_feed(&self, frames: MetricFeedStream) -> Result<MetricFeedAckStream, Status> {
        let engine = self.engine.clone();
        let verdict_tx = self.verdict_tx.clone();
        let checkpoint = self
            .checkpoint
            .lock()
            .expect("checkpoint mutex poisoned")
            .clone();
        let (ack_tx, ack_rx) = mpsc::channel::<Result<MetricFeedAck, Status>>(ACK_CHANNEL_DEPTH);

        tokio::spawn(async move {
            let mut frames = frames;
            let mut frame_count: u64 = 0;
            while let Some(item) = frames.next().await {
                let frame = match item {
                    Ok(frame) => frame,
                    Err(_) => break,
                };
                process_frame(&engine, &verdict_tx, &frame).await;

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

        Ok(Box::pin(ReceiverStream::new(ack_rx)))
    }
}

/// Decode one feed frame's `MetricBatch`, score every eligible point, and push a
/// verdict telemetry batch for any breaches.
async fn process_frame(
    engine: &Arc<Mutex<DetectorEngine>>,
    verdict_tx: &mpsc::Sender<Result<TelemetryBatch, Status>>,
    frame: &MetricFeedFrame,
) {
    let batch = match MetricBatch::decode(frame.payload.as_slice()) {
        Ok(batch) => batch,
        Err(_) => return, // poison payload: drop the frame, never block the feed
    };
    let resource = batch.resource.unwrap_or_default();

    // Lock the engine only to score; never hold the std Mutex across an await.
    let mut records: Vec<TelemetryRecord> = Vec::new();
    {
        let mut engine = engine.lock().expect("engine mutex poisoned");
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

                if let Some(verdict) =
                    engine.evaluate(&series_key, value, point.observed_at_unix_nano)
                    && (verdict.breached || verdict.anomalous)
                {
                    records.push(verdict_record(
                        &resource,
                        metric,
                        point,
                        &series_key,
                        &verdict,
                    ));
                }
            }
        }
    }

    if records.is_empty() {
        return;
    }

    let mut builder = TelemetryBatchBuilder::new("anomaly-addon", resource.agent_id.clone());
    for record in records {
        builder = builder.push_record(record);
    }
    let _ = verdict_tx.send(Ok(builder.build())).await;
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
        let engine = engine.lock().expect("engine mutex poisoned");
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
    engine
        .lock()
        .expect("engine mutex poisoned")
        .restore_checkpoint(checkpoint, now, max_age_ns);
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
    if !point.series_identity_hint.is_empty() {
        point.series_identity_hint.clone()
    } else {
        // Fallback when the producer did not stamp a hint: agent + metric +
        // interface keeps distinct series apart on one host.
        format!(
            "{}|{}|{}",
            resource.agent_id, metric.name, point.interface_uid
        )
    }
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
) -> TelemetryRecord {
    let ts_nano = verdict
        .observed_at_unix_nano
        .unwrap_or(point.observed_at_unix_nano);
    let ts_ms = (ts_nano / 1_000_000) as i64;
    let severity_id = severity_id_from_score(verdict.score);

    let metric_class = if metric.metric_type.is_empty() {
        "metric"
    } else {
        metric.metric_type.as_str()
    };
    let device_uid = first_non_empty(&[
        resource.device_id.as_str(),
        resource.host_id.as_str(),
        resource.agent_id.as_str(),
        resource.host_ip.as_str(),
    ]);

    let event_id = format!("anomaly:{series_key}:{ts_nano}:{}", verdict.state);
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
        "status": "open",
        "time": ts_ms,
        "severity_id": severity_id,
        "device_uid": device_uid,
        "device_id": device_uid,
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
            "state": &verdict.state,
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
    fn checkpoint_file_round_trip_atomic() {
        let path =
            std::env::temp_dir().join(format!("sr-anomaly-ckpt-{}.json", std::process::id()));
        let _ = std::fs::remove_file(&path);

        let engine = Arc::new(Mutex::new(DetectorEngine::new(EngineConfig::default())));
        {
            let mut e = engine.lock().unwrap();
            for i in 0..20 {
                e.evaluate("s", 100.0 + (i % 3) as f64, i as u64);
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
