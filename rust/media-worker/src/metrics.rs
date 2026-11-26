//! Prometheus metrics registry and JetStream operational telemetry snapshots (`5.2`).
//!
//! Exposes `/metrics` counters, gauges, and histograms and builds structured
//! operational telemetry payloads published to NATS JetStream (`telemetry.media_worker.metrics.v1`)
//! for `EventWriter` and `serviceradar-otel:4317` collection without direct DB writes.

use crate::errors::MediaWorkerError;
use chrono::Utc;
use prometheus::{
    Encoder, Histogram, HistogramOpts, IntCounter, IntCounterVec, IntGauge, Opts, Registry,
    TextEncoder,
};
use serde::{Deserialize, Serialize};
use std::sync::Arc;

/// NATS JetStream subject for media-worker operational telemetry (`5.2`).
pub const MEDIA_WORKER_TELEMETRY_SUBJECT: &str = "telemetry.media_worker.metrics.v1";

/// Per-instance Prometheus metrics registry for `serviceradar-media-worker`.
#[derive(Clone)]
pub struct WorkerMetrics {
    registry: Registry,
    keyframes_decoded_total: IntCounter,
    keyframes_undecodable_total: IntCounterVec,
    stage1_latency_seconds: Histogram,
    stage2_latency_seconds: Histogram,
    text_embed_latency_seconds: Histogram,
    jobs_completed_total: IntCounter,
    jobs_gone_total: IntCounter,
    jobs_failed_total: IntCounter,
    inflight_index_jobs: IntGauge,
    inflight_text_embeds: IntGauge,
    vantage_jobs_completed_total: IntCounter,
    vantage_jobs_gone_total: IntCounter,
    vantage_jobs_failed_total: IntCounter,
    vantage_crops_skipped_total: IntCounterVec,
    vantage_vlm_requests_total: IntCounterVec,
    vantage_vlm_latency_seconds: Histogram,
    inflight_vantage_jobs: IntGauge,
}

impl core::fmt::Debug for WorkerMetrics {
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        f.debug_struct("WorkerMetrics")
            .field("keyframes_decoded_total", &self.keyframes_decoded_count())
            .field("jobs_completed_total", &self.jobs_completed_count())
            .field("jobs_gone_total", &self.jobs_gone_count())
            .field("jobs_failed_total", &self.jobs_failed_count())
            .field("inflight_index_jobs", &self.inflight_index_jobs_value())
            .field("inflight_text_embeds", &self.inflight_text_embeds_value())
            .finish()
    }
}

impl Default for WorkerMetrics {
    fn default() -> Self {
        Self::new()
    }
}

impl WorkerMetrics {
    pub fn new() -> Self {
        let registry = Registry::new_custom(Some("serviceradar_media_worker".to_string()), None)
            .unwrap_or_else(|_| Registry::new());

        let keyframes_decoded_total = IntCounter::with_opts(Opts::new(
            "keyframes_decoded_total",
            "Total number of verified IDR keyframes decoded by the media worker",
        ))
        .expect("valid keyframes_decoded_total metric");

        let keyframes_undecodable_total = IntCounterVec::new(
            Opts::new(
                "keyframes_undecodable_total",
                "Sampled keyframes recorded as undecodable instead of indexed, by bounded reason",
            ),
            &["reason"],
        )
        .expect("valid keyframes_undecodable_total metric");

        let latency_buckets = vec![
            0.0005, 0.001, 0.0025, 0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1.0, 2.5,
        ];

        let stage1_latency_seconds = Histogram::with_opts(
            HistogramOpts::new(
                "stage1_latency_seconds",
                "Stage 1 localized subject detection latency in seconds",
            )
            .buckets(latency_buckets.clone()),
        )
        .expect("valid stage1_latency_seconds histogram");

        let stage2_latency_seconds = Histogram::with_opts(
            HistogramOpts::new(
                "stage2_latency_seconds",
                "Stage 2 batched vision-language embedding latency in seconds",
            )
            .buckets(latency_buckets.clone()),
        )
        .expect("valid stage2_latency_seconds histogram");

        let text_embed_latency_seconds = Histogram::with_opts(
            HistogramOpts::new(
                "text_embed_latency_seconds",
                "Interactive query text-embedding RPC latency in seconds",
            )
            .buckets(vec![
                0.00025, 0.0005, 0.001, 0.0025, 0.005, 0.01, 0.025, 0.05, 0.1, 0.25,
            ]),
        )
        .expect("valid text_embed_latency_seconds histogram");

        let jobs_completed_total = IntCounter::with_opts(Opts::new(
            "jobs_completed_total",
            "Total visual index jobs completed and confirmed on media.results.visual_index.v1",
        ))
        .expect("valid jobs_completed_total metric");

        let jobs_gone_total = IntCounter::with_opts(Opts::new(
            "jobs_gone_total",
            "Total visual index jobs cleanly skipped due to 410 Gone (deleted or quarantined block)",
        ))
        .expect("valid jobs_gone_total metric");

        let jobs_failed_total = IntCounter::with_opts(Opts::new(
            "jobs_failed_total",
            "Total visual index jobs failed due to integrity, grant, container, or inference errors",
        ))
        .expect("valid jobs_failed_total metric");

        let inflight_index_jobs = IntGauge::with_opts(Opts::new(
            "inflight_index_jobs",
            "Number of currently executing visual index jobs",
        ))
        .expect("valid inflight_index_jobs gauge");

        let inflight_text_embeds = IntGauge::with_opts(Opts::new(
            "inflight_text_embeds",
            "Number of currently executing interactive text-embedding RPC requests",
        ))
        .expect("valid inflight_text_embeds gauge");

        let vantage_jobs_completed_total = IntCounter::with_opts(Opts::new(
            "vantage_jobs_completed_total",
            "Total Vantage VLM jobs completed and confirmed on media.results.vantage.v1",
        ))
        .expect("valid vantage_jobs_completed_total metric");

        let vantage_jobs_gone_total = IntCounter::with_opts(Opts::new(
            "vantage_jobs_gone_total",
            "Total Vantage VLM jobs cleanly skipped due to 410 Gone",
        ))
        .expect("valid vantage_jobs_gone_total metric");

        let vantage_jobs_failed_total = IntCounter::with_opts(Opts::new(
            "vantage_jobs_failed_total",
            "Total Vantage VLM jobs failed due to integrity, grant, container, or VLM errors",
        ))
        .expect("valid vantage_jobs_failed_total metric");

        let vantage_crops_skipped_total = IntCounterVec::new(
            Opts::new(
                "vantage_crops_skipped_total",
                "Vantage detection/ROI crops skipped before VLM inference, by bounded reason",
            ),
            &["reason"],
        )
        .expect("valid vantage_crops_skipped_total metric");

        let vantage_vlm_requests_total = IntCounterVec::new(
            Opts::new(
                "vantage_vlm_requests_total",
                "Vantage VLM HTTP/parse outcomes, by bounded outcome",
            ),
            &["outcome"],
        )
        .expect("valid vantage_vlm_requests_total metric");

        let vantage_vlm_latency_seconds = Histogram::with_opts(
            HistogramOpts::new(
                "vantage_vlm_latency_seconds",
                "Vantage OpenAI-compatible VLM request latency in seconds",
            )
            .buckets(vec![0.05, 0.1, 0.25, 0.5, 1.0, 2.5, 5.0, 10.0, 30.0, 60.0]),
        )
        .expect("valid vantage_vlm_latency_seconds histogram");

        let inflight_vantage_jobs = IntGauge::with_opts(Opts::new(
            "inflight_vantage_jobs",
            "Number of currently executing Vantage VLM jobs",
        ))
        .expect("valid inflight_vantage_jobs gauge");

        let _ = registry.register(Box::new(keyframes_decoded_total.clone()));
        let _ = registry.register(Box::new(keyframes_undecodable_total.clone()));
        let _ = registry.register(Box::new(stage1_latency_seconds.clone()));
        let _ = registry.register(Box::new(stage2_latency_seconds.clone()));
        let _ = registry.register(Box::new(text_embed_latency_seconds.clone()));
        let _ = registry.register(Box::new(jobs_completed_total.clone()));
        let _ = registry.register(Box::new(jobs_gone_total.clone()));
        let _ = registry.register(Box::new(jobs_failed_total.clone()));
        let _ = registry.register(Box::new(inflight_index_jobs.clone()));
        let _ = registry.register(Box::new(inflight_text_embeds.clone()));
        let _ = registry.register(Box::new(vantage_jobs_completed_total.clone()));
        let _ = registry.register(Box::new(vantage_jobs_gone_total.clone()));
        let _ = registry.register(Box::new(vantage_jobs_failed_total.clone()));
        let _ = registry.register(Box::new(vantage_crops_skipped_total.clone()));
        let _ = registry.register(Box::new(vantage_vlm_requests_total.clone()));
        let _ = registry.register(Box::new(vantage_vlm_latency_seconds.clone()));
        let _ = registry.register(Box::new(inflight_vantage_jobs.clone()));

        Self {
            registry,
            keyframes_decoded_total,
            keyframes_undecodable_total,
            stage1_latency_seconds,
            stage2_latency_seconds,
            text_embed_latency_seconds,
            jobs_completed_total,
            jobs_gone_total,
            jobs_failed_total,
            inflight_index_jobs,
            inflight_text_embeds,
            vantage_jobs_completed_total,
            vantage_jobs_gone_total,
            vantage_jobs_failed_total,
            vantage_crops_skipped_total,
            vantage_vlm_requests_total,
            vantage_vlm_latency_seconds,
            inflight_vantage_jobs,
        }
    }

    pub fn inc_keyframes_decoded(&self, count: u64) {
        self.keyframes_decoded_total.inc_by(count);
    }

    /// Counts one sampled keyframe that was recorded as undecodable. `reason` is one of the
    /// bounded `UndecodableKeyframePayload` reasons, so the label set stays fixed.
    pub fn inc_keyframes_undecodable(&self, reason: &str) {
        self.keyframes_undecodable_total
            .with_label_values(&[reason])
            .inc();
    }

    pub fn observe_stage1_latency(&self, seconds: f64) {
        self.stage1_latency_seconds.observe(seconds);
    }

    pub fn observe_stage2_latency(&self, seconds: f64) {
        self.stage2_latency_seconds.observe(seconds);
    }

    pub fn observe_text_embed_latency(&self, seconds: f64) {
        self.text_embed_latency_seconds.observe(seconds);
    }

    pub fn inc_jobs_completed(&self) {
        self.jobs_completed_total.inc();
    }

    pub fn inc_jobs_gone(&self) {
        self.jobs_gone_total.inc();
    }

    pub fn inc_jobs_failed(&self) {
        self.jobs_failed_total.inc();
    }

    pub fn guard_inflight_index_job(self: &Arc<Self>) -> InflightGuard {
        self.inflight_index_jobs.inc();
        InflightGuard {
            gauge: self.inflight_index_jobs.clone(),
        }
    }

    pub fn guard_inflight_text_embed(self: &Arc<Self>) -> InflightGuard {
        self.inflight_text_embeds.inc();
        InflightGuard {
            gauge: self.inflight_text_embeds.clone(),
        }
    }

    pub fn inc_vantage_jobs_completed(&self) {
        self.vantage_jobs_completed_total.inc();
    }

    pub fn inc_vantage_jobs_gone(&self) {
        self.vantage_jobs_gone_total.inc();
    }

    pub fn inc_vantage_jobs_failed(&self) {
        self.vantage_jobs_failed_total.inc();
    }

    pub fn inc_vantage_crops_skipped(&self, reason: &str) {
        self.vantage_crops_skipped_total
            .with_label_values(&[reason])
            .inc();
    }

    pub fn inc_vantage_vlm_request(&self, outcome: &str) {
        self.vantage_vlm_requests_total
            .with_label_values(&[outcome])
            .inc();
    }

    pub fn observe_vantage_vlm_latency(&self, seconds: f64) {
        self.vantage_vlm_latency_seconds.observe(seconds);
    }

    pub fn guard_inflight_vantage_job(self: &Arc<Self>) -> InflightGuard {
        self.inflight_vantage_jobs.inc();
        InflightGuard {
            gauge: self.inflight_vantage_jobs.clone(),
        }
    }

    pub fn vantage_jobs_completed_count(&self) -> u64 {
        self.vantage_jobs_completed_total.get()
    }

    pub fn vantage_jobs_gone_count(&self) -> u64 {
        self.vantage_jobs_gone_total.get()
    }

    pub fn vantage_jobs_failed_count(&self) -> u64 {
        self.vantage_jobs_failed_total.get()
    }

    pub fn inflight_vantage_jobs_value(&self) -> i64 {
        self.inflight_vantage_jobs.get()
    }

    pub fn vantage_vlm_sample_count(&self) -> u64 {
        self.vantage_vlm_latency_seconds.get_sample_count()
    }

    pub fn keyframes_decoded_count(&self) -> u64 {
        self.keyframes_decoded_total.get()
    }

    pub fn jobs_completed_count(&self) -> u64 {
        self.jobs_completed_total.get()
    }

    pub fn jobs_gone_count(&self) -> u64 {
        self.jobs_gone_total.get()
    }

    pub fn jobs_failed_count(&self) -> u64 {
        self.jobs_failed_total.get()
    }

    pub fn inflight_index_jobs_value(&self) -> i64 {
        self.inflight_index_jobs.get()
    }

    pub fn inflight_text_embeds_value(&self) -> i64 {
        self.inflight_text_embeds.get()
    }

    pub fn stage1_sample_count(&self) -> u64 {
        self.stage1_latency_seconds.get_sample_count()
    }

    pub fn stage2_sample_count(&self) -> u64 {
        self.stage2_latency_seconds.get_sample_count()
    }

    pub fn text_embed_sample_count(&self) -> u64 {
        self.text_embed_latency_seconds.get_sample_count()
    }

    pub fn render_prometheus_text(&self) -> Result<String, MediaWorkerError> {
        let families = self.registry.gather();
        let encoder = TextEncoder::new();
        let mut buf = Vec::with_capacity(4096);
        encoder.encode(&families, &mut buf).map_err(|err| {
            MediaWorkerError::inference_failed(format!("failed encoding Prometheus metrics: {err}"))
        })?;
        String::from_utf8(buf).map_err(|err| {
            MediaWorkerError::inference_failed(format!("invalid UTF-8 in Prometheus output: {err}"))
        })
    }

    pub fn snapshot(
        &self,
        otel_endpoint: &str,
        model_id: &str,
        model_version: &str,
    ) -> TelemetrySnapshot {
        TelemetrySnapshot {
            schema: MEDIA_WORKER_TELEMETRY_SUBJECT.to_string(),
            schema_version: 1,
            observed_at: Utc::now().to_rfc3339(),
            otel_endpoint: otel_endpoint.to_string(),
            model_id: model_id.to_string(),
            model_version: model_version.to_string(),
            keyframes_decoded_total: self.keyframes_decoded_count(),
            jobs_completed_total: self.jobs_completed_count(),
            jobs_gone_total: self.jobs_gone_count(),
            jobs_failed_total: self.jobs_failed_count(),
            inflight_index_jobs: self.inflight_index_jobs_value(),
            inflight_text_embeds: self.inflight_text_embeds_value(),
            stage1_sample_count: self.stage1_sample_count(),
            stage1_sum_seconds: self.stage1_latency_seconds.get_sample_sum(),
            stage2_sample_count: self.stage2_sample_count(),
            stage2_sum_seconds: self.stage2_latency_seconds.get_sample_sum(),
            text_embed_sample_count: self.text_embed_sample_count(),
            text_embed_sum_seconds: self.text_embed_latency_seconds.get_sample_sum(),
            vantage_jobs_completed_total: self.vantage_jobs_completed_count(),
            vantage_jobs_gone_total: self.vantage_jobs_gone_count(),
            vantage_jobs_failed_total: self.vantage_jobs_failed_count(),
            inflight_vantage_jobs: self.inflight_vantage_jobs_value(),
            vantage_vlm_sample_count: self.vantage_vlm_sample_count(),
            vantage_vlm_sum_seconds: self.vantage_vlm_latency_seconds.get_sample_sum(),
        }
    }
}

/// RAII gauge decrement guard for inflight job and text-embed counters.
pub struct InflightGuard {
    gauge: IntGauge,
}

impl Drop for InflightGuard {
    fn drop(&mut self) {
        self.gauge.dec();
    }
}

/// JetStream operational metrics envelope emitted to `telemetry.media_worker.metrics.v1`.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct TelemetrySnapshot {
    schema: String,
    schema_version: u32,
    observed_at: String,
    otel_endpoint: String,
    model_id: String,
    model_version: String,
    keyframes_decoded_total: u64,
    jobs_completed_total: u64,
    jobs_gone_total: u64,
    jobs_failed_total: u64,
    inflight_index_jobs: i64,
    inflight_text_embeds: i64,
    stage1_sample_count: u64,
    stage1_sum_seconds: f64,
    stage2_sample_count: u64,
    stage2_sum_seconds: f64,
    text_embed_sample_count: u64,
    text_embed_sum_seconds: f64,
    #[serde(default)]
    vantage_jobs_completed_total: u64,
    #[serde(default)]
    vantage_jobs_gone_total: u64,
    #[serde(default)]
    vantage_jobs_failed_total: u64,
    #[serde(default)]
    inflight_vantage_jobs: i64,
    #[serde(default)]
    vantage_vlm_sample_count: u64,
    #[serde(default)]
    vantage_vlm_sum_seconds: f64,
}

impl TelemetrySnapshot {
    pub fn schema(&self) -> &str {
        &self.schema
    }

    pub fn otel_endpoint(&self) -> &str {
        &self.otel_endpoint
    }

    pub fn keyframes_decoded_total(&self) -> u64 {
        self.keyframes_decoded_total
    }

    pub fn jobs_completed_total(&self) -> u64 {
        self.jobs_completed_total
    }

    pub fn jobs_gone_total(&self) -> u64 {
        self.jobs_gone_total
    }
}
