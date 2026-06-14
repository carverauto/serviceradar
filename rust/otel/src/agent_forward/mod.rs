//! Agent-forward output backend (edge add-on deployment shape).
//!
//! [`AgentForwardOutput`] implements [`TelemetryOutput`] for the edge
//! collector running as a native agent add-on (edge-relay plan, step 1):
//! instead of publishing chunks to JetStream it wraps each chunk in a
//! [`TelemetryRecord`] with the OTLP relay payload kinds and appends it to
//! the durable [`spool::Spool`]. The `serviceradar-otel-addon` binary streams
//! spooled frames to the agent over `AddonService.RelayOtlp`
//! (`otlp-relay:v1`), which forwards them to the gateway and acks back after
//! the gateway publishes them onto the standard local NATS subjects.
//!
//! Invariants shared with the JetStream backend:
//! - exports are chunked ONCE here with the same <= 900 KiB chunker
//!   ([`crate::nats::chunker`]), so 1 record = 1 NATS message upstream;
//! - single records that can never fit are rejected identically
//!   ([`PublishOutcome::rejected`] + `otel_records_rejected_total`);
//! - `published` means *durably spooled* (the spool's fsync contract), not
//!   delivered — durability ownership transfers to NATS only after the
//!   gateway ack, which is the spool watermark's job, not this type's.
//!
//! Identity: the edge listener passes [`IngestContext::anonymous`]; identity
//! for edge data is stamped by the GATEWAY from the agent's mTLS certificate
//! and must never be asserted locally, so `ctx` is deliberately unused here.

pub mod spool;

use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{SystemTime, UNIX_EPOCH};

use addon_sdk::pb::{
    TelemetryBatch, TelemetryCounters, TelemetryPayloadKind, TelemetryRecord, TelemetrySource,
};
use anyhow::Result;
use log::{debug, warn};
use prost::Message;
use uuid::Uuid;

use crate::opentelemetry::proto::collector::logs::v1::ExportLogsServiceRequest;
use crate::opentelemetry::proto::collector::metrics::v1::ExportMetricsServiceRequest;
use crate::opentelemetry::proto::collector::trace::v1::ExportTraceServiceRequest;
use crate::output::{
    IngestContext, PerformanceMetric, PublishOutcome, TelemetryOutput, encode_derived_metric_batch,
};

use crate::nats::chunker::{
    MAX_PROTO_PUBLISH_BYTES, metric_request_data_points, split_logs_request, split_metrics_request,
    split_traces_request,
};
use spool::{Spool, SpoolFull};

/// `TelemetrySource.source_type` stamped on every relayed batch; matches the
/// add-on id in `addons/otel-collector/addon.yaml`.
pub const SOURCE_TYPE: &str = "otel-collector";

/// Minimum seconds between spool-cannot-grow warnings (further rejections
/// in the window are logged at debug, never silently).
const SPOOL_FULL_WARN_INTERVAL_SECS: u64 = 30;

/// Edge output backend that spools chunked OTLP exports for the acked
/// agent relay.
pub struct AgentForwardOutput {
    spool: Arc<Spool>,
    source_instance: String,
    /// Cumulative units received across all signals (spans/log records/data
    /// points/derived metrics), including rejected ones.
    received_total: AtomicU64,
    /// Cumulative records appended to the spool.
    emitted_total: AtomicU64,
    /// Unix seconds of the last spool-full warning (rate limiting).
    last_spool_full_warn_secs: AtomicU64,
}

impl AgentForwardOutput {
    pub fn new(spool: Arc<Spool>) -> Self {
        Self::with_instance(spool, "default")
    }

    pub fn with_instance(spool: Arc<Spool>, source_instance: impl Into<String>) -> Self {
        Self {
            spool,
            source_instance: source_instance.into(),
            received_total: AtomicU64::new(0),
            emitted_total: AtomicU64::new(0),
            last_spool_full_warn_secs: AtomicU64::new(0),
        }
    }

    /// The spool this output appends to (shared with the relay stream).
    pub fn spool(&self) -> &Arc<Spool> {
        &self.spool
    }

    fn make_record(&self, kind: TelemetryPayloadKind, payload: Vec<u8>) -> TelemetryRecord {
        TelemetryRecord {
            event_id: Uuid::new_v4().to_string(),
            observed_time_unix_nano: now_unix_nanos(),
            event_time_unix_nano: 0,
            payload_kind: kind as i32,
            payload,
            metadata: Default::default(),
        }
    }

    /// Builds the single-record batch for one chunk. `received`/`emitted`
    /// carry this output's cumulative totals; `dropped`/`queue_depth` are
    /// overwritten by the spool at append time (eviction accounting).
    fn make_batch(&self, record: TelemetryRecord) -> TelemetryBatch {
        TelemetryBatch {
            source: Some(TelemetrySource {
                source_type: SOURCE_TYPE.to_string(),
                source_instance: self.source_instance.clone(),
                metadata: Default::default(),
            }),
            records: vec![record],
            counters: Some(TelemetryCounters {
                received: self.received_total.load(Ordering::Relaxed),
                filtered: 0,
                emitted: self.emitted_total.load(Ordering::Relaxed),
                dropped: 0,     // stamped by the spool
                queue_depth: 0, // stamped by the spool
            }),
        }
    }

    /// Spools one chunk. Returns `Ok(true)` when spooled, `Ok(false)` when
    /// the spool refused to grow ([`SpoolFull`]: free-disk floor or ENOSPC
    /// even after evicting oldest segments) — callers count that as a
    /// per-signal rejection (OTLP `partial_success`), NOT a retryable
    /// transport failure, so a full disk can never become an error loop.
    /// Any other error propagates as a batch-level transport failure.
    fn spool_chunk(&self, kind: TelemetryPayloadKind, payload: Vec<u8>) -> Result<bool> {
        let record = self.make_record(kind, payload);
        match self.spool.append_batch(self.make_batch(record)) {
            Ok(relay_id) => {
                self.emitted_total.fetch_add(1, Ordering::Relaxed);
                debug!("spooled {kind:?} chunk as relay frame {relay_id}");
                Ok(true)
            }
            Err(err) if err.downcast_ref::<SpoolFull>().is_some() => {
                self.warn_spool_full(kind, &err);
                Ok(false)
            }
            Err(err) => Err(err),
        }
    }

    /// Rate-limited warning for spool-full rejections (at most one warn per
    /// [`SPOOL_FULL_WARN_INTERVAL_SECS`]; the rest log at debug).
    fn warn_spool_full(&self, kind: TelemetryPayloadKind, err: &anyhow::Error) {
        let now = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|d| d.as_secs())
            .unwrap_or(0);
        let last = self.last_spool_full_warn_secs.load(Ordering::Relaxed);
        let due = now.saturating_sub(last) >= SPOOL_FULL_WARN_INTERVAL_SECS;
        if due
            && self
                .last_spool_full_warn_secs
                .compare_exchange(last, now, Ordering::Relaxed, Ordering::Relaxed)
                .is_ok()
        {
            warn!("relay spool cannot grow; rejecting {kind:?} chunk(s): {err}");
        } else {
            debug!("relay spool cannot grow; rejecting {kind:?} chunk: {err}");
        }
    }
}

/// Spans in one (possibly chunked) trace export request.
fn trace_request_spans(request: &ExportTraceServiceRequest) -> usize {
    request
        .resource_spans
        .iter()
        .map(|rs| {
            rs.scope_spans
                .iter()
                .map(|ss| ss.spans.len())
                .sum::<usize>()
        })
        .sum()
}

/// Log records in one (possibly chunked) logs export request.
fn logs_request_records(request: &ExportLogsServiceRequest) -> usize {
    request
        .resource_logs
        .iter()
        .map(|rl| {
            rl.scope_logs
                .iter()
                .map(|sl| sl.log_records.len())
                .sum::<usize>()
        })
        .sum()
}

fn now_unix_nanos() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| i64::try_from(d.as_nanos()).unwrap_or(i64::MAX))
        .unwrap_or(0)
}

/// One spool-ready derived-metrics chunk: the encoded protobuf payload plus the
/// number of metrics inside it (for spool-rejection accounting).
type DerivedMetricChunk = (Vec<u8>, usize);

/// Splits derived span metrics into canonical `serviceradar.metric.v1`
/// protobuf payloads that fit the publish budget. Returns
/// `((payload, metric_count) chunks, rejected_metrics)` so spool-rejection
/// accounting knows each chunk's size.
fn derived_metric_payloads(
    metrics: &[PerformanceMetric],
    max_payload_bytes: usize,
) -> Result<(Vec<DerivedMetricChunk>, usize)> {
    if metrics.is_empty() {
        return Ok((Vec::new(), 0));
    }
    let payload = encode_derived_metric_batch(metrics);
    if payload.len() <= max_payload_bytes {
        return Ok((vec![(payload, metrics.len())], 0));
    }
    if metrics.len() == 1 {
        warn!(
            "Dropping oversized derived span metric: {} encoded bytes exceeds the {max_payload_bytes} byte publish budget",
            payload.len()
        );
        return Ok((Vec::new(), 1));
    }
    let mid = metrics.len() / 2;
    let (mut left, left_rejected) = derived_metric_payloads(&metrics[..mid], max_payload_bytes)?;
    let (right, right_rejected) = derived_metric_payloads(&metrics[mid..], max_payload_bytes)?;
    left.extend(right);
    Ok((left, left_rejected + right_rejected))
}

#[tonic::async_trait]
impl TelemetryOutput for AgentForwardOutput {
    /// Spools traces for the agent relay. `rejected` counts individual spans
    /// whose encoded size alone exceeds the publish budget — identical
    /// semantics (and chunker) to the JetStream backend so OTLP
    /// partial_success behavior does not depend on the deployment shape.
    async fn publish_traces(
        &self,
        traces: &ExportTraceServiceRequest,
        _ctx: &IngestContext,
    ) -> Result<PublishOutcome> {
        let span_count = trace_request_spans(traces);
        self.received_total
            .fetch_add(span_count as u64, Ordering::Relaxed);

        let (chunks, mut rejected) = split_traces_request(traces, MAX_PROTO_PUBLISH_BYTES);
        if rejected > 0 {
            crate::metrics::record_rejected("traces", "oversize", rejected);
        }

        let mut spool_rejected = 0usize;
        for chunk in &chunks {
            let mut payload = Vec::with_capacity(chunk.encoded_len());
            chunk.encode(&mut payload)?;
            if !self.spool_chunk(TelemetryPayloadKind::OtlpTraces, payload)? {
                spool_rejected += trace_request_spans(chunk);
            }
        }
        if spool_rejected > 0 {
            crate::metrics::record_rejected("traces", "spool_full", spool_rejected);
            rejected += spool_rejected;
        }

        debug!(
            "spooled {} span(s) in {} relay frame(s) ({} rejected)",
            span_count.saturating_sub(rejected),
            chunks.len(),
            rejected
        );
        Ok(PublishOutcome {
            published: span_count.saturating_sub(rejected),
            rejected,
        })
    }

    /// Spools logs for the agent relay; `rejected` mirrors the JetStream
    /// backend's per-record oversize rejection.
    async fn publish_logs(
        &self,
        logs: &ExportLogsServiceRequest,
        _ctx: &IngestContext,
    ) -> Result<PublishOutcome> {
        let logs_count = logs_request_records(logs);
        self.received_total
            .fetch_add(logs_count as u64, Ordering::Relaxed);

        let (chunks, mut rejected) = split_logs_request(logs, MAX_PROTO_PUBLISH_BYTES);
        if rejected > 0 {
            crate::metrics::record_rejected("logs", "oversize", rejected);
        }

        let mut spool_rejected = 0usize;
        for chunk in &chunks {
            let mut payload = Vec::with_capacity(chunk.encoded_len());
            chunk.encode(&mut payload)?;
            if !self.spool_chunk(TelemetryPayloadKind::OtlpLogs, payload)? {
                spool_rejected += logs_request_records(chunk);
            }
        }
        if spool_rejected > 0 {
            crate::metrics::record_rejected("logs", "spool_full", spool_rejected);
            rejected += spool_rejected;
        }

        Ok(PublishOutcome {
            published: logs_count.saturating_sub(rejected),
            rejected,
        })
    }

    /// Spools raw OTLP metrics; `rejected` counts metric data points (OTLP
    /// partial_success semantics), as in the JetStream backend.
    async fn publish_raw_metrics(
        &self,
        metrics: &ExportMetricsServiceRequest,
        _ctx: &IngestContext,
    ) -> Result<PublishOutcome> {
        let data_point_count = metric_request_data_points(metrics);
        self.received_total
            .fetch_add(data_point_count as u64, Ordering::Relaxed);

        let (chunks, mut rejected) = split_metrics_request(metrics, MAX_PROTO_PUBLISH_BYTES);
        if rejected > 0 {
            crate::metrics::record_rejected("metrics", "oversize", rejected);
        }

        let mut spool_rejected = 0usize;
        for chunk in &chunks {
            let mut payload = Vec::with_capacity(chunk.encoded_len());
            chunk.encode(&mut payload)?;
            if !self.spool_chunk(TelemetryPayloadKind::OtlpMetrics, payload)? {
                spool_rejected += metric_request_data_points(chunk);
            }
        }
        if spool_rejected > 0 {
            crate::metrics::record_rejected("metrics", "spool_full", spool_rejected);
            rejected += spool_rejected;
        }

        Ok(PublishOutcome {
            published: data_point_count.saturating_sub(rejected),
            rejected,
        })
    }

    /// Spools collector-derived span metrics as canonical
    /// `serviceradar.metric.v1` protobuf payloads with payload kind
    /// `OTLP_DERIVED_METRIC` so core routes them to the derived-metrics
    /// subject.
    async fn publish_derived_metrics(
        &self,
        metrics: &[PerformanceMetric],
        _ctx: &IngestContext,
    ) -> Result<PublishOutcome> {
        if metrics.is_empty() {
            return Ok(PublishOutcome::default());
        }
        self.received_total
            .fetch_add(metrics.len() as u64, Ordering::Relaxed);

        let (payloads, mut rejected) = derived_metric_payloads(metrics, MAX_PROTO_PUBLISH_BYTES)?;
        if rejected > 0 {
            crate::metrics::record_rejected("span_metrics", "oversize", rejected);
        }

        let mut spool_rejected = 0usize;
        for (payload, units) in payloads {
            if !self.spool_chunk(TelemetryPayloadKind::OtlpDerivedMetric, payload)? {
                spool_rejected += units;
            }
        }
        if spool_rejected > 0 {
            crate::metrics::record_rejected("span_metrics", "spool_full", spool_rejected);
            rejected += spool_rejected;
        }

        Ok(PublishOutcome {
            published: metrics.len().saturating_sub(rejected),
            rejected,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::spool::SpoolConfig;
    use super::*;
    use crate::opentelemetry::proto::common::v1::{AnyValue, KeyValue, any_value};
    use crate::opentelemetry::proto::logs::v1::{LogRecord, ResourceLogs, ScopeLogs};
    use crate::opentelemetry::proto::trace::v1::{ResourceSpans, ScopeSpans, Span};

    fn open_spool(dir: &std::path::Path) -> Arc<Spool> {
        Arc::new(Spool::open(SpoolConfig::new(dir)).unwrap())
    }

    fn span(name: &str, attr_value_len: usize) -> Span {
        Span {
            trace_id: vec![1; 16],
            span_id: vec![2; 8],
            name: name.to_string(),
            attributes: vec![KeyValue {
                key: "payload".to_string(),
                value: Some(AnyValue {
                    value: Some(any_value::Value::StringValue("x".repeat(attr_value_len))),
                }),
            }],
            ..Default::default()
        }
    }

    fn traces_request(spans: Vec<Span>) -> ExportTraceServiceRequest {
        ExportTraceServiceRequest {
            resource_spans: vec![ResourceSpans {
                resource: None,
                scope_spans: vec![ScopeSpans {
                    scope: None,
                    spans,
                    schema_url: String::new(),
                }],
                schema_url: String::new(),
            }],
        }
    }

    fn logs_request(body_lens: &[usize]) -> ExportLogsServiceRequest {
        ExportLogsServiceRequest {
            resource_logs: vec![ResourceLogs {
                resource: None,
                scope_logs: vec![ScopeLogs {
                    scope: None,
                    log_records: body_lens
                        .iter()
                        .map(|len| LogRecord {
                            body: Some(AnyValue {
                                value: Some(any_value::Value::StringValue("y".repeat(*len))),
                            }),
                            ..Default::default()
                        })
                        .collect(),
                    schema_url: String::new(),
                }],
                schema_url: String::new(),
            }],
        }
    }

    fn perf_metric(name: &str) -> PerformanceMetric {
        PerformanceMetric {
            timestamp: "2026-06-11T00:00:00Z".to_string(),
            trace_id: "ab".repeat(16),
            span_id: "cd".repeat(8),
            service_name: "svc".to_string(),
            span_name: name.to_string(),
            span_kind: "server".to_string(),
            duration_ms: 123.0,
            duration_seconds: 0.123,
            metric_type: "slow_span".to_string(),
            http_method: None,
            http_route: None,
            http_status_code: None,
            grpc_service: None,
            grpc_method: None,
            grpc_status_code: None,
            is_slow: true,
            component: "otel-collector".to_string(),
            level: "warn".to_string(),
        }
    }

    fn drain(spool: &Arc<Spool>) -> Vec<addon_sdk::pb::OtlpRelayFrame> {
        let mut reader = spool.reader();
        let mut frames = Vec::new();
        while let Some(frame) = reader.try_next().unwrap() {
            frames.push(frame);
        }
        frames
    }

    #[tokio::test]
    async fn traces_are_spooled_as_otlp_trace_records() {
        let dir = tempfile::tempdir().unwrap();
        let spool = open_spool(dir.path());
        let output = AgentForwardOutput::new(Arc::clone(&spool));

        let request = traces_request(vec![span("a", 10), span("b", 10)]);
        let outcome = output
            .publish_traces(&request, &IngestContext::anonymous())
            .await
            .unwrap();
        assert_eq!(outcome.published, 2);
        assert_eq!(outcome.rejected, 0);

        let frames = drain(&spool);
        assert_eq!(frames.len(), 1, "small export fits one chunk/frame");
        let batch = frames[0].batch.clone().unwrap();
        assert_eq!(batch.records.len(), 1, "1 record = 1 NATS message");
        let record = &batch.records[0];
        assert_eq!(record.payload_kind, TelemetryPayloadKind::OtlpTraces as i32);
        assert!(!record.event_id.is_empty());
        assert!(record.observed_time_unix_nano > 0);

        // The payload must be a decodable Export*ServiceRequest chunk
        // carrying exactly the original spans.
        let decoded = ExportTraceServiceRequest::decode(record.payload.as_slice()).unwrap();
        let names: Vec<_> = decoded.resource_spans[0].scope_spans[0]
            .spans
            .iter()
            .map(|s| s.name.clone())
            .collect();
        assert_eq!(names, vec!["a".to_string(), "b".to_string()]);

        assert_eq!(
            batch.source.unwrap().source_type,
            SOURCE_TYPE,
            "source matches the add-on id"
        );
    }

    #[tokio::test]
    async fn oversize_span_rejection_matches_jetstream_semantics() {
        let dir = tempfile::tempdir().unwrap();
        let spool = open_spool(dir.path());
        let output = AgentForwardOutput::new(Arc::clone(&spool));

        // One span larger than the 900 KiB budget on its own + one small
        // span: the oversize span is rejected, the small one is spooled.
        let request = traces_request(vec![
            span("oversize", MAX_PROTO_PUBLISH_BYTES + 1024),
            span("small", 16),
        ]);
        let outcome = output
            .publish_traces(&request, &IngestContext::anonymous())
            .await
            .unwrap();
        assert_eq!(outcome.rejected, 1);
        assert_eq!(outcome.published, 1);

        let frames = drain(&spool);
        assert_eq!(frames.len(), 1, "only the surviving span is spooled");
        for frame in &frames {
            for record in &frame.batch.as_ref().unwrap().records {
                assert!(
                    record.payload.len() <= MAX_PROTO_PUBLISH_BYTES,
                    "the <=900KiB invariant must hold for every spooled chunk"
                );
            }
        }
    }

    #[tokio::test]
    async fn large_log_export_is_chunked_into_multiple_frames() {
        let dir = tempfile::tempdir().unwrap();
        let spool = open_spool(dir.path());
        let output = AgentForwardOutput::new(Arc::clone(&spool));

        // Each record ~400 KiB: the export exceeds the budget and must split
        // into multiple <= 900 KiB chunks (one frame each).
        let request = logs_request(&[400 * 1024, 400 * 1024, 400 * 1024]);
        let outcome = output
            .publish_logs(&request, &IngestContext::anonymous())
            .await
            .unwrap();
        assert_eq!(outcome.published, 3);
        assert_eq!(outcome.rejected, 0);

        let frames = drain(&spool);
        assert!(frames.len() >= 2, "expected chunking, got {}", frames.len());
        for frame in &frames {
            let record = &frame.batch.as_ref().unwrap().records[0];
            assert_eq!(record.payload_kind, TelemetryPayloadKind::OtlpLogs as i32);
            assert!(record.payload.len() <= MAX_PROTO_PUBLISH_BYTES);
        }
    }

    #[tokio::test]
    async fn derived_metrics_use_metric_batch_protobuf_with_kind_6() {
        let dir = tempfile::tempdir().unwrap();
        let spool = open_spool(dir.path());
        let output = AgentForwardOutput::new(Arc::clone(&spool));

        let metrics = vec![perf_metric("m1"), perf_metric("m2")];
        let outcome = output
            .publish_derived_metrics(&metrics, &IngestContext::anonymous())
            .await
            .unwrap();
        assert_eq!(outcome.published, 2);

        let frames = drain(&spool);
        assert_eq!(frames.len(), 1);
        let record = &frames[0].batch.as_ref().unwrap().records[0];
        assert_eq!(
            record.payload_kind,
            TelemetryPayloadKind::OtlpDerivedMetric as i32
        );
        assert_eq!(record.payload_kind, 6, "wire contract value");

        let decoded = serviceradar_metric_proto::pb::MetricBatch::decode(record.payload.as_slice())
            .expect("derived metrics decode as MetricBatch");
        assert_eq!(decoded.schema_version, "serviceradar.metric.v1");
        assert_eq!(decoded.metrics.len(), 1);
        assert_eq!(decoded.metrics[0].points.len(), 2);
        let point = &decoded.metrics[0].points[0];
        assert_eq!(point.value, 123.0);
        assert_eq!(entry(&point.metadata, "trace_id"), Some("ab".repeat(16)));
        assert_eq!(
            entry(&point.metadata, "metric_type"),
            Some("slow_span".to_string())
        );
        assert_eq!(
            entry(&point.attributes, "service_name"),
            Some("svc".to_string())
        );
    }

    #[tokio::test]
    async fn empty_derived_metrics_publish_nothing() {
        let dir = tempfile::tempdir().unwrap();
        let spool = open_spool(dir.path());
        let output = AgentForwardOutput::new(Arc::clone(&spool));

        let outcome = output
            .publish_derived_metrics(&[], &IngestContext::anonymous())
            .await
            .unwrap();
        assert_eq!(outcome, PublishOutcome::default());
        assert!(drain(&spool).is_empty());
    }

    #[test]
    fn derived_metric_payloads_split_until_they_fit() {
        let metrics: Vec<PerformanceMetric> =
            (0..8).map(|i| perf_metric(&format!("m{i}"))).collect();
        let single = encode_derived_metric_batch(&metrics[..1]).len();

        // A budget that fits ~2 metrics forces recursive splitting.
        let (payloads, rejected) = derived_metric_payloads(&metrics, single * 2 + 16).unwrap();
        assert_eq!(rejected, 0);
        assert!(payloads.len() >= 4, "got {} payloads", payloads.len());
        let mut total = 0usize;
        for (payload, units) in &payloads {
            let decoded = serviceradar_metric_proto::pb::MetricBatch::decode(payload.as_slice())
                .expect("chunk decodes as MetricBatch");
            assert_eq!(
                decoded.metrics[0].points.len(),
                *units,
                "chunk unit count matches payload"
            );
            total += decoded.metrics[0].points.len();
        }
        assert_eq!(total, 8, "no metric lost in splitting");

        // A budget smaller than a single metric rejects it.
        let (payloads, rejected) = derived_metric_payloads(&metrics[..1], single - 1).unwrap();
        assert!(payloads.is_empty());
        assert_eq!(rejected, 1);
    }

    /// A spool that cannot grow (free-disk floor unsatisfiable, nothing to
    /// evict) turns into per-signal counted rejections, never an Err.
    struct NoSpace;

    impl super::spool::DiskFree for NoSpace {
        fn available_bytes(&self, _path: &std::path::Path) -> Option<u64> {
            Some(0)
        }
    }

    fn entry(
        entries: &[serviceradar_metric_proto::pb::StringMapEntry],
        key: &str,
    ) -> Option<String> {
        entries
            .iter()
            .find(|entry| entry.key == key)
            .map(|entry| entry.value.clone())
    }

    #[tokio::test]
    async fn spool_full_becomes_counted_rejection_not_transport_error() {
        let dir = tempfile::tempdir().unwrap();
        let mut config = SpoolConfig::new(dir.path());
        config.min_free_disk_bytes = 1024;
        let spool = Arc::new(Spool::open_with_disk_free(config, Arc::new(NoSpace)).unwrap());
        let output = AgentForwardOutput::new(Arc::clone(&spool));

        let request = traces_request(vec![span("a", 10), span("b", 10)]);
        let outcome = output
            .publish_traces(&request, &IngestContext::anonymous())
            .await
            .expect("rejection must not be a transport error");
        assert_eq!(outcome.published, 0);
        assert_eq!(outcome.rejected, 2, "every span in the chunk is counted");
        assert!(drain(&spool).is_empty(), "nothing was spooled");

        let logs = logs_request(&[16, 16, 16]);
        let outcome = output
            .publish_logs(&logs, &IngestContext::anonymous())
            .await
            .unwrap();
        assert_eq!(outcome.published, 0);
        assert_eq!(outcome.rejected, 3);

        let metrics = vec![perf_metric("m1")];
        let outcome = output
            .publish_derived_metrics(&metrics, &IngestContext::anonymous())
            .await
            .unwrap();
        assert_eq!(outcome.published, 0);
        assert_eq!(outcome.rejected, 1);
    }
}
