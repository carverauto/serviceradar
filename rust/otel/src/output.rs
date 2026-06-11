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
//! - **Agent-forward** (planned) — edge add-on backend that hands encoded
//!   OTLP batches to the local serviceradar-agent, which relays them over
//!   its existing mTLS gateway channel; the gateway/core republishes onto
//!   the standard NATS subjects.
//! - **OTLP-exporter** (planned) — degenerate edge configuration that
//!   re-exports straight to a central OTLP endpoint for sites that prefer
//!   it.

use anyhow::Result;
use serde::Serialize;

use crate::opentelemetry::proto::collector::logs::v1::ExportLogsServiceRequest;
use crate::opentelemetry::proto::collector::metrics::v1::ExportMetricsServiceRequest;
use crate::opentelemetry::proto::collector::trace::v1::ExportTraceServiceRequest;

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
    /// that can never be published (oversize).
    async fn publish_traces(&self, traces: &ExportTraceServiceRequest) -> Result<PublishOutcome>;

    /// Publishes an OTLP logs export. `rejected` counts individual log
    /// records that can never be published (oversize).
    async fn publish_logs(&self, logs: &ExportLogsServiceRequest) -> Result<PublishOutcome>;

    /// Publishes a raw OTLP metrics export. `rejected` counts individual
    /// metric data points that can never be published (oversize).
    async fn publish_raw_metrics(
        &self,
        metrics: &ExportMetricsServiceRequest,
    ) -> Result<PublishOutcome>;

    /// Publishes collector-derived span performance metrics (best-effort;
    /// callers must not fail the originating OTLP export when this errors).
    async fn publish_derived_metrics(
        &self,
        metrics: &[PerformanceMetric],
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
