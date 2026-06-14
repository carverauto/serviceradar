//! Backend-agnostic output seam for the collector.
//!
//! The collector core (`ServiceRadarCollector` and its
//! `handle_traces`/`handle_logs`/`handle_metrics` export handlers) depends
//! only on [`TelemetryOutput`], never on a concrete backend, so the protocol
//! surface (gRPC/HTTP listeners, partial_success accounting, delivery
//! counters, auth modes) is shared by every deployment shape.
//!
//! Planned backends (see
//! `openspec/changes/refactor-otel-signal-correlation/design.md`, D8):
//!
//! - **JetStream** ([`crate::nats::NATSOutput`]) — the existing
//!   central-deployment backend; also the preferred edge transport when a
//!   site runs a NATS leaf node (pointed at the local leaf).
//! - **Agent-forward** — edge add-on backend that hands encoded OTLP batches
//!   to the local serviceradar-agent, which relays them over its existing
//!   mTLS gateway channel; the gateway publishes the chunks onto the standard
//!   local NATS subjects.
//! - **OTLP-exporter** (planned) — degenerate edge configuration that
//!   re-exports straight to a central OTLP endpoint for sites that prefer
//!   it.

use anyhow::Result;
use chrono::DateTime;
use prost::Message;
use serde::Serialize;
use serviceradar_metric_proto::pb::{
    IngestIdentity, Metric, MetricBatch, MetricKind, MetricPoint, MetricResource, MetricValueType,
    StringMapEntry,
};

use crate::opentelemetry::proto::collector::logs::v1::ExportLogsServiceRequest;
use crate::opentelemetry::proto::collector::metrics::v1::ExportMetricsServiceRequest;
use crate::opentelemetry::proto::collector::trace::v1::ExportTraceServiceRequest;

/// NATS message header carrying the authenticated sender identity for
/// downstream attribution. Stamped on every chunk published for a request
/// whose [`IngestContext::identity`] is set; consumers that do not know the
/// header ignore it.
pub const INGEST_IDENTITY_HEADER: &str = "Sr-Ingest-Identity";
pub const METRIC_ENVELOPE_SCHEMA_VERSION: &str = "serviceradar.metric.v1";
pub const DERIVED_METRIC_SOURCE: &str = "otel-metrics-derived";

/// Per-request ingestion context threaded from the listener (gRPC
/// interceptor / HTTP auth check) through the export handlers into the
/// output backend. `identity: None` means the request was anonymous
/// (token enforcement off on a trusted network).
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct IngestContext {
    /// Authenticated sender identity from the matched ingestion token.
    pub identity: Option<String>,
}

impl IngestContext {
    /// Context for an anonymous (unauthenticated) request.
    pub fn anonymous() -> Self {
        Self::default()
    }
}

/// Per-export delivery accounting returned by every output backend.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct PublishOutcome {
    /// Records the backend accepted (for the disabled no-op backend this
    /// counts records accepted-and-dropped, preserving the historical
    /// delivery-counter behavior).
    pub published: usize,
    /// Records permanently rejected (e.g. a single record whose encoded size
    /// exceeds the publish budget). Callers report these to OTLP clients via
    /// `partial_success` so SDKs do not retry them forever.
    pub rejected: usize,
}

/// Async sink for telemetry accepted by the collector.
///
/// Implementations must be safe to share across concurrent export requests
/// (`&self` methods, `Send + Sync`); the collector never serializes publishes
/// behind a global lock. An `Err` from a publish method means the batch was
/// not durably accepted — after a retry the caller fails the OTLP export so
/// SDK clients retransmit.
#[tonic::async_trait]
pub trait TelemetryOutput: Send + Sync {
    /// Publishes an OTLP trace export. `rejected` counts individual spans
    /// that can never be published (oversize). `ctx` carries the
    /// authenticated sender identity to stamp on the message envelope.
    async fn publish_traces(
        &self,
        traces: &ExportTraceServiceRequest,
        ctx: &IngestContext,
    ) -> Result<PublishOutcome>;

    /// Publishes an OTLP logs export. `rejected` counts individual log
    /// records that can never be published (oversize). `ctx` carries the
    /// authenticated sender identity to stamp on the message envelope.
    async fn publish_logs(
        &self,
        logs: &ExportLogsServiceRequest,
        ctx: &IngestContext,
    ) -> Result<PublishOutcome>;

    /// Publishes a raw OTLP metrics export. `rejected` counts individual
    /// metric data points that can never be published (oversize). `ctx`
    /// carries the authenticated sender identity to stamp on the envelope.
    async fn publish_raw_metrics(
        &self,
        metrics: &ExportMetricsServiceRequest,
        ctx: &IngestContext,
    ) -> Result<PublishOutcome>;

    /// Publishes collector-derived span performance metrics (best-effort;
    /// callers must not fail the originating OTLP export when this errors).
    async fn publish_derived_metrics(
        &self,
        metrics: &[PerformanceMetric],
        ctx: &IngestContext,
    ) -> Result<PublishOutcome>;
}

/// Span-derived performance metric emitted alongside the primary trace
/// publish (slow spans, HTTP/gRPC latency breakdowns).
#[derive(Debug, Clone, Serialize)]
pub struct PerformanceMetric {
    pub timestamp: String, // ISO 8601 timestamp
    pub trace_id: String,
    pub span_id: String,
    pub service_name: String,
    pub span_name: String,
    pub span_kind: String,
    pub duration_ms: f64,
    pub duration_seconds: f64,
    pub metric_type: String, // "span", "http", "grpc", "slow_span"

    // Optional HTTP fields
    pub http_method: Option<String>,
    pub http_route: Option<String>,
    pub http_status_code: Option<String>,

    // Optional gRPC fields
    pub grpc_service: Option<String>,
    pub grpc_method: Option<String>,
    pub grpc_status_code: Option<String>,

    // Performance flags
    pub is_slow: bool, // true if > 100ms

    // Additional metadata
    pub component: String, // "otel-collector"
    pub level: String,     // "info", "warn" for slow spans
}

pub fn encode_derived_metric_batch(metrics: &[PerformanceMetric]) -> Vec<u8> {
    derived_metric_batch(metrics).encode_to_vec()
}

fn derived_metric_batch(metrics: &[PerformanceMetric]) -> MetricBatch {
    MetricBatch {
        schema_version: METRIC_ENVELOPE_SCHEMA_VERSION.to_owned(),
        resource: Some(MetricResource {
            service_name: "otel-derived".to_owned(),
            service_type: "otel".to_owned(),
            ..Default::default()
        }),
        ingest_identity: Some(IngestIdentity {
            source: DERIVED_METRIC_SOURCE.to_owned(),
            payload_kind: METRIC_ENVELOPE_SCHEMA_VERSION.to_owned(),
            producer_id: "otel-collector".to_owned(),
            producer_kind: "otel-collector".to_owned(),
            ..Default::default()
        }),
        metrics: vec![Metric {
            name: "otel.span.duration_ms".to_owned(),
            metric_type: "otel_span_derived".to_owned(),
            kind: MetricKind::Gauge as i32,
            unit: "ms".to_owned(),
            points: metrics.iter().map(derived_metric_point).collect(),
            tags: string_entries([("metric_family", "otel_span_derived")]),
            ..Default::default()
        }],
        ..Default::default()
    }
}

fn derived_metric_point(metric: &PerformanceMetric) -> MetricPoint {
    let mut metadata = string_entries([
        ("timestamp", metric.timestamp.as_str()),
        ("trace_id", metric.trace_id.as_str()),
        ("span_id", metric.span_id.as_str()),
        ("metric_type", metric.metric_type.as_str()),
        ("is_slow", if metric.is_slow { "true" } else { "false" }),
        ("component", metric.component.as_str()),
        ("level", metric.level.as_str()),
    ]);
    metadata.push(StringMapEntry {
        key: "duration_seconds".to_owned(),
        value: metric.duration_seconds.to_string(),
    });

    MetricPoint {
        value: metric.duration_ms,
        raw_value: metric.duration_ms.to_string(),
        raw_value_type: MetricValueType::Double as i32,
        observed_at_unix_nano: timestamp_unix_nano(&metric.timestamp),
        attributes: string_entries([
            ("service_name", metric.service_name.as_str()),
            ("span_name", metric.span_name.as_str()),
            ("span_kind", metric.span_kind.as_str()),
            ("http_method", metric.http_method.as_deref().unwrap_or("")),
            ("http_route", metric.http_route.as_deref().unwrap_or("")),
            (
                "http_status_code",
                metric.http_status_code.as_deref().unwrap_or(""),
            ),
            ("grpc_service", metric.grpc_service.as_deref().unwrap_or("")),
            ("grpc_method", metric.grpc_method.as_deref().unwrap_or("")),
            (
                "grpc_status_code",
                metric.grpc_status_code.as_deref().unwrap_or(""),
            ),
        ]),
        metadata,
        ..Default::default()
    }
}

fn timestamp_unix_nano(timestamp: &str) -> u64 {
    DateTime::parse_from_rfc3339(timestamp)
        .ok()
        .and_then(|dt| dt.timestamp_nanos_opt())
        .and_then(|nanos| u64::try_from(nanos).ok())
        .unwrap_or(0)
}

fn string_entries<'a>(values: impl IntoIterator<Item = (&'a str, &'a str)>) -> Vec<StringMapEntry> {
    values
        .into_iter()
        .filter(|(_key, value)| !value.is_empty())
        .map(|(key, value)| StringMapEntry {
            key: key.to_owned(),
            value: value.to_owned(),
        })
        .collect()
}
