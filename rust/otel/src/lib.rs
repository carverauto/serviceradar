use log::{debug, error, info, warn};
use tonic::{Request, Response, Status};

pub mod agent_forward;
pub mod auth;
pub mod cli;
pub mod config;
pub mod http_server;
pub mod metrics;
pub mod nats;
pub mod output;
pub mod server;
pub mod setup;
pub mod tls;

pub mod opentelemetry {
    #![allow(
        dead_code,
        clippy::doc_overindented_list_items,
        clippy::doc_lazy_continuation
    )]
    pub mod proto {
        pub mod collector {
            pub mod metrics {
                pub mod v1 {
                    tonic::include_proto!("opentelemetry.proto.collector.metrics.v1");
                }
            }
            pub mod trace {
                pub mod v1 {
                    tonic::include_proto!("opentelemetry.proto.collector.trace.v1");
                }
            }
            pub mod logs {
                pub mod v1 {
                    tonic::include_proto!("opentelemetry.proto.collector.logs.v1");
                }
            }
        }
        pub mod trace {
            pub mod v1 {
                tonic::include_proto!("opentelemetry.proto.trace.v1");
            }
        }
        pub mod logs {
            pub mod v1 {
                tonic::include_proto!("opentelemetry.proto.logs.v1");
            }
        }
        pub mod metrics {
            pub mod v1 {
                tonic::include_proto!("opentelemetry.proto.metrics.v1");
            }
        }
        pub mod resource {
            pub mod v1 {
                tonic::include_proto!("opentelemetry.proto.resource.v1");
            }
        }
        pub mod common {
            pub mod v1 {
                tonic::include_proto!("opentelemetry.proto.common.v1");
            }
        }
    }
}

use crate::output::{IngestContext, PerformanceMetric, TelemetryOutput};
use opentelemetry::proto::collector::logs::v1::logs_service_server::LogsService;
use opentelemetry::proto::collector::logs::v1::{
    ExportLogsPartialSuccess, ExportLogsServiceRequest, ExportLogsServiceResponse,
};
use opentelemetry::proto::collector::metrics::v1::metrics_service_server::MetricsService;
use opentelemetry::proto::collector::metrics::v1::{
    ExportMetricsPartialSuccess, ExportMetricsServiceRequest, ExportMetricsServiceResponse,
};
use opentelemetry::proto::collector::trace::v1::trace_service_server::TraceService;
use opentelemetry::proto::collector::trace::v1::{
    ExportTracePartialSuccess, ExportTraceServiceRequest, ExportTraceServiceResponse,
};
use opentelemetry::proto::metrics::v1::Metric;
use opentelemetry::proto::metrics::v1::metric::Data as MetricData;
use std::sync::{Arc, RwLock};

/// Backoff before the single NATS publish retry attempt.
const NATS_PUBLISH_RETRY_DELAY: std::time::Duration = std::time::Duration::from_millis(250);

/// Attempt a NATS publish, retrying once after a brief backoff on failure.
///
/// Returns the result of the retry if the first attempt fails. Callers decide
/// whether a final failure is fatal for the OTLP export (primary signals NACK
/// the request so SDK clients retransmit; derived data stays best-effort).
async fn publish_with_retry<T, F, Fut>(signal: &str, mut attempt: F) -> anyhow::Result<T>
where
    F: FnMut() -> Fut,
    Fut: std::future::Future<Output = anyhow::Result<T>>,
{
    match attempt().await {
        Ok(value) => Ok(value),
        Err(first_err) => {
            warn!(
                "Failed to publish {signal} to NATS (retrying once after {}ms): {first_err}",
                NATS_PUBLISH_RETRY_DELAY.as_millis()
            );
            tokio::time::sleep(NATS_PUBLISH_RETRY_DELAY).await;
            attempt().await
        }
    }
}

/// Error returned when an export could not be durably accepted (the NATS
/// publish failed even after a retry). The OTLP/gRPC surface maps this to
/// UNAVAILABLE and the OTLP/HTTP surface maps it to 503 so stock SDK
/// exporters retransmit the batch.
#[derive(Debug)]
pub struct ExportError {
    pub message: String,
}

impl std::fmt::Display for ExportError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.message)
    }
}

impl std::error::Error for ExportError {}

/// Builds the partial_success error message for records rejected because a
/// single record exceeded the maximum encoded size.
fn oversize_partial_message(rejected: usize) -> String {
    format!("{rejected} records exceeded max encoded size")
}

/// Extracts the `service.name` resource attribute from an OTLP resource,
/// returning `"unknown_service"` when it is absent or not a string value.
fn resource_service_name(resource: Option<&opentelemetry::proto::resource::v1::Resource>) -> &str {
    resource
        .and_then(|r| {
            r.attributes
                .iter()
                .find(|kv| kv.key == "service.name")
                .and_then(|kv| kv.value.as_ref())
                .and_then(|v| {
                    if let Some(opentelemetry::proto::common::v1::any_value::Value::StringValue(
                        s,
                    )) = &v.value
                    {
                        Some(s.as_str())
                    } else {
                        None
                    }
                })
        })
        .unwrap_or("unknown_service")
}

/// Hot-swappable handle to the active output backend.
///
/// The `RwLock` is only ever held long enough to clone the inner `Arc`
/// (per-export reads) or swap it (runtime reconfiguration) — never across a
/// publish await — so concurrent exports publish without any global
/// serialization (the old `Arc<Mutex<NATSOutput>>` head-of-line blocking).
type OutputSlot = RwLock<Arc<dyn TelemetryOutput>>;

#[derive(Clone)]
pub struct ServiceRadarCollector {
    output: Option<Arc<OutputSlot>>,
}

impl ServiceRadarCollector {
    pub async fn new(
        nats_config: Option<nats::NATSConfig>,
    ) -> Result<Self, Box<dyn std::error::Error>> {
        debug!("Creating ServiceRadarCollector");

        let output: Option<Arc<OutputSlot>> = if let Some(config) = nats_config {
            debug!("Initializing NATS output for collector");
            match nats::NATSOutput::new(config).await {
                Ok(output) => {
                    debug!("NATS output created successfully");
                    let output: Arc<dyn TelemetryOutput> = Arc::new(output);
                    Some(Arc::new(RwLock::new(output)))
                }
                Err(e) => {
                    error!("Failed to initialize NATS output: {e}");
                    return Err(e.into());
                }
            }
        } else {
            debug!("No NATS configuration provided, collector will not forward traces");
            None
        };

        debug!(
            "ServiceRadarCollector created with output backend: {}",
            output.is_some()
        );
        Ok(Self { output })
    }

    /// Builds a collector around an arbitrary output backend.
    ///
    /// This is the seam the planned agent-forward and OTLP-exporter edge
    /// backends (and tests) plug into; see [`crate::output`] for the backend
    /// roadmap.
    pub fn with_output(output: Arc<dyn TelemetryOutput>) -> Self {
        Self {
            output: Some(Arc::new(RwLock::new(output))),
        }
    }

    /// Clones the current output backend handle out of the slot. The lock is
    /// released before any publish await.
    fn output_handle(&self) -> Option<Arc<dyn TelemetryOutput>> {
        self.output.as_ref().map(|slot| match slot.read() {
            Ok(guard) => Arc::clone(&guard),
            Err(poisoned) => Arc::clone(&poisoned.into_inner()),
        })
    }

    fn swap_output(slot: &OutputSlot, new_output: Arc<dyn TelemetryOutput>) {
        match slot.write() {
            Ok(mut guard) => *guard = new_output,
            Err(poisoned) => *poisoned.into_inner() = new_output,
        }
    }

    /// Reconfigure NATS output at runtime. If None, disables output. If Some, rebuilds the output.
    pub async fn reconfigure_nats(&self, nats_config: Option<nats::NATSConfig>) {
        debug!("Reconfiguring NATS output for collector");
        match nats_config {
            Some(cfg) => match nats::NATSOutput::new(cfg).await {
                Ok(new_output) => {
                    if let Some(slot) = &self.output {
                        Self::swap_output(slot, Arc::new(new_output));
                        info!("NATS output reconfigured successfully");
                    } else {
                        warn!("NATS output not initialized; restart required to enable output");
                    }
                }
                Err(e) => {
                    error!("Failed to reconfigure NATS output: {e}");
                }
            },
            None => {
                if let Some(slot) = &self.output {
                    // Replace with a disabled output that drops
                    Self::swap_output(slot, Arc::new(nats::NATSOutput::disabled()));
                    info!("NATS output disabled via reconfiguration");
                } else {
                    debug!("NATS output already disabled");
                }
            }
        }
    }
}

impl std::fmt::Debug for ServiceRadarCollector {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("ServiceRadarCollector")
            .field("output", &self.output.is_some())
            .finish()
    }
}

impl ServiceRadarCollector {
    /// Shared OTLP traces export handler used by both the gRPC and HTTP
    /// transports.
    pub async fn handle_traces(
        &self,
        trace_data: ExportTraceServiceRequest,
        ctx: &IngestContext,
    ) -> Result<ExportTraceServiceResponse, ExportError> {
        let span_count = trace_data
            .resource_spans
            .iter()
            .map(|rs| {
                rs.scope_spans
                    .iter()
                    .map(|ss| ss.spans.len())
                    .sum::<usize>()
            })
            .sum::<usize>();

        info!(
            "Received OTEL export request: {} resource spans, {} total spans",
            trace_data.resource_spans.len(),
            span_count
        );
        metrics::record_received("traces", span_count);

        // Calculate durations and collect performance metrics for NATS publishing
        let mut performance_metrics = Vec::new();
        let current_time = chrono::Utc::now().to_rfc3339();

        for resource_span in &trace_data.resource_spans {
            // Extract service name from resource attributes
            let service_name = resource_service_name(resource_span.resource.as_ref());

            for scope_span in &resource_span.scope_spans {
                for span in &scope_span.spans {
                    // Calculate span duration
                    let duration_ns = span
                        .end_time_unix_nano
                        .saturating_sub(span.start_time_unix_nano);
                    let duration_ms = duration_ns as f64 / 1_000_000.0;
                    let duration_seconds = duration_ns as f64 / 1_000_000_000.0;

                    // Extract trace_id as hex string for easier correlation
                    let trace_id = hex::encode(&span.trace_id);
                    let span_id = hex::encode(&span.span_id);

                    // Extract additional context from span attributes
                    let mut span_attrs = std::collections::HashMap::new();
                    for attr in &span.attributes {
                        let Some(value) = &attr.value else {
                            continue;
                        };
                        let Some(opentelemetry::proto::common::v1::any_value::Value::StringValue(
                            s,
                        )) = &value.value
                        else {
                            continue;
                        };
                        span_attrs.insert(attr.key.as_str(), s.as_str());
                    }

                    // Record Prometheus metrics
                    let span_kind = metrics::span_kind_to_string(span.kind);
                    metrics::record_span_metrics(
                        service_name,
                        &span.name,
                        span_kind,
                        duration_seconds,
                        &span_attrs,
                    );

                    let is_slow = duration_ms > 100.0;

                    // Create base performance metric
                    let base_metric = PerformanceMetric {
                        timestamp: current_time.clone(),
                        trace_id: trace_id.clone(),
                        span_id: span_id.clone(),
                        service_name: service_name.to_string(),
                        span_name: span.name.clone(),
                        span_kind: span_kind.to_string(),
                        duration_ms,
                        duration_seconds,
                        metric_type: "span".to_string(),
                        http_method: None,
                        http_route: None,
                        http_status_code: None,
                        grpc_service: None,
                        grpc_method: None,
                        grpc_status_code: None,
                        is_slow,
                        component: "otel-collector".to_string(),
                        level: if is_slow {
                            "warn".to_string()
                        } else {
                            "info".to_string()
                        },
                    };

                    let should_export = is_slow;

                    if !should_export {
                        // Skip publishing metrics for spans that completed within the fast-path threshold
                        debug!(
                            "Skipping perf metric export for fast span '{}' (service: '{}', duration: {:.3}ms)",
                            span.name, service_name, duration_ms
                        );
                        continue;
                    }

                    // Add base span metric
                    performance_metrics.push(base_metric.clone());

                    // Add HTTP-specific metric if available
                    if let (Some(method), Some(route)) =
                        (span_attrs.get("http.method"), span_attrs.get("http.route"))
                    {
                        let mut http_metric = base_metric.clone();
                        http_metric.metric_type = "http".to_string();
                        http_metric.http_method = Some(method.to_string());
                        http_metric.http_route = Some(route.to_string());
                        http_metric.http_status_code =
                            span_attrs.get("http.status_code").map(|s| s.to_string());
                        performance_metrics.push(http_metric);
                    }

                    // Add gRPC-specific metric if available
                    if let Some(grpc_method) = span_attrs.get("rpc.method") {
                        let grpc_service = span_attrs.get("rpc.service").map_or("unknown", |v| *v);
                        let mut grpc_metric = base_metric.clone();
                        grpc_metric.metric_type = "grpc".to_string();
                        grpc_metric.grpc_service = Some(grpc_service.to_string());
                        grpc_metric.grpc_method = Some(grpc_method.to_string());
                        grpc_metric.grpc_status_code = span_attrs
                            .get("rpc.grpc.status_code")
                            .map(|s| s.to_string());
                        performance_metrics.push(grpc_metric);
                    }

                    // Add slow span metric if applicable
                    if is_slow {
                        let mut slow_metric = base_metric.clone();
                        slow_metric.metric_type = "slow_span".to_string();
                        slow_metric.level = "warn".to_string();
                        performance_metrics.push(slow_metric);
                    }

                    // Only log slow spans at warn level; otherwise emit debug-level breadcrumbs
                    if is_slow {
                        warn!(
                            "PERF METRIC - Service: '{}', Span: '{}', Duration: {:.3}ms, TraceID: {}, SpanID: {}",
                            service_name, span.name, duration_ms, trace_id, span_id
                        );
                    } else {
                        debug!(
                            "PERF METRIC - Service: '{}', Span: '{}', Duration: {:.3}ms, TraceID: {}, SpanID: {}",
                            service_name, span.name, duration_ms, trace_id, span_id
                        );
                    }
                }
            }
        }

        // Publish performance metrics to the output backend
        if performance_metrics.is_empty() {
            // Nothing to publish
        } else if let Some(output) = self.output_handle() {
            debug!(
                "Publishing {} performance metrics to NATS",
                performance_metrics.len()
            );
            metrics::record_received("span_metrics", performance_metrics.len());
            let publish_result = publish_with_retry("span_metrics", || async {
                output
                    .publish_derived_metrics(&performance_metrics, ctx)
                    .await
            })
            .await;
            match publish_result {
                Ok(outcome) => metrics::record_published("span_metrics", outcome.published),
                Err(e) => {
                    metrics::record_publish_failure("span_metrics", performance_metrics.len());
                    // Derived span metrics stay best-effort: losing them must
                    // not force SDK clients to retransmit the spans they are
                    // derived from. The primary span publish below is what
                    // decides the request outcome.
                    error!("Failed to publish performance metrics to NATS after retry: {e}");
                }
            }
        }

        // Log detailed debug information if enabled
        if log::log_enabled!(log::Level::Debug) {
            for (i, resource_span) in trace_data.resource_spans.iter().enumerate() {
                let resource_attrs = resource_span
                    .resource
                    .as_ref()
                    .map(|r| r.attributes.len())
                    .unwrap_or(0);
                debug!(
                    "Resource span {}: {} scope spans, {} resource attributes",
                    i,
                    resource_span.scope_spans.len(),
                    resource_attrs
                );

                for (j, scope_span) in resource_span.scope_spans.iter().enumerate() {
                    let scope_name = scope_span
                        .scope
                        .as_ref()
                        .map(|s| s.name.as_str())
                        .unwrap_or("unknown");
                    debug!(
                        "  Scope span {}: '{}' with {} spans",
                        j,
                        scope_name,
                        scope_span.spans.len()
                    );
                }
            }
        }

        // Send to NATS if configured. A publish failure (after one retry)
        // fails the export so SDK clients retransmit instead of silently
        // losing spans; downstream writers dedupe on primary key, so retries
        // are safe.
        let mut rejected_spans = 0usize;
        if let Some(output) = self.output_handle() {
            debug!("Forwarding traces to NATS");
            let publish_result = publish_with_retry("traces", || async {
                output.publish_traces(&trace_data, ctx).await
            })
            .await;
            match publish_result {
                Ok(outcome) => {
                    rejected_spans = outcome.rejected;
                    metrics::record_published("traces", outcome.published);
                }
                Err(e) => {
                    metrics::record_publish_failure("traces", span_count);
                    error!("Failed to publish traces to NATS after retry: {e}");
                    return Err(ExportError {
                        message: format!("failed to publish traces to NATS after retry: {e}"),
                    });
                }
            }
        } else {
            debug!("No NATS output configured, traces received but not forwarded");
        }

        debug!("OTEL export request completed successfully");
        // Per the OTLP spec, partial_success is unset on full success and
        // carries the rejected count when individual records were dropped
        // (e.g. a single span too large to ever publish).
        Ok(ExportTraceServiceResponse {
            partial_success: (rejected_spans > 0).then(|| ExportTracePartialSuccess {
                rejected_spans: rejected_spans as i64,
                error_message: oversize_partial_message(rejected_spans),
            }),
        })
    }
}

impl ServiceRadarCollector {
    /// Shared OTLP metrics export handler used by both the gRPC and HTTP
    /// transports.
    pub async fn handle_metrics(
        &self,
        metrics_data: ExportMetricsServiceRequest,
        ctx: &IngestContext,
    ) -> Result<ExportMetricsServiceResponse, ExportError> {
        let resource_metric_count = metrics_data.resource_metrics.len();
        let mut scope_metric_count = 0usize;
        let mut metric_count = 0usize;
        let mut data_point_count = 0usize;

        for resource_metrics in &metrics_data.resource_metrics {
            scope_metric_count += resource_metrics.scope_metrics.len();
            for scope_metrics in &resource_metrics.scope_metrics {
                metric_count += scope_metrics.metrics.len();
                for metric in &scope_metrics.metrics {
                    data_point_count += count_metric_data_points(metric);
                }
            }
        }

        info!(
            "Received OTEL metrics export request: {} resource sets, {} scope sets, {} metrics, {} data points",
            resource_metric_count, scope_metric_count, metric_count, data_point_count
        );
        metrics::record_received("metrics", data_point_count);

        if log::log_enabled!(log::Level::Debug) {
            for (index, resource_metrics) in metrics_data.resource_metrics.iter().enumerate() {
                let service_name = resource_service_name(resource_metrics.resource.as_ref());

                debug!(
                    "Resource metrics {}: service='{}', scope_metrics={}, total_metrics={}",
                    index,
                    service_name,
                    resource_metrics.scope_metrics.len(),
                    resource_metrics
                        .scope_metrics
                        .iter()
                        .map(|sm| sm.metrics.len())
                        .sum::<usize>()
                );
            }
        }

        // Send to NATS if configured. A publish failure (after one retry)
        // fails the export so SDK clients retransmit instead of silently
        // losing metric points.
        let mut rejected_data_points = 0usize;
        if let Some(output) = self.output_handle() {
            debug!("Forwarding raw OTLP metrics to NATS");
            let publish_result = publish_with_retry("metrics", || async {
                output.publish_raw_metrics(&metrics_data, ctx).await
            })
            .await;
            match publish_result {
                Ok(outcome) => {
                    rejected_data_points = outcome.rejected;
                    metrics::record_published("metrics", outcome.published);
                }
                Err(e) => {
                    metrics::record_publish_failure("metrics", data_point_count);
                    error!("Failed to publish raw OTLP metrics to NATS after retry: {e}");
                    return Err(ExportError {
                        message: format!("failed to publish metrics to NATS after retry: {e}"),
                    });
                }
            }
        } else {
            debug!("No NATS output configured, metrics received but not forwarded");
        }

        // partial_success stays unset on full success per the OTLP spec.
        Ok(ExportMetricsServiceResponse {
            partial_success: (rejected_data_points > 0).then(|| ExportMetricsPartialSuccess {
                rejected_data_points: rejected_data_points as i64,
                error_message: oversize_partial_message(rejected_data_points),
            }),
        })
    }
}

impl ServiceRadarCollector {
    /// Shared OTLP logs export handler used by both the gRPC and HTTP
    /// transports.
    pub async fn handle_logs(
        &self,
        logs_data: ExportLogsServiceRequest,
        ctx: &IngestContext,
    ) -> Result<ExportLogsServiceResponse, ExportError> {
        let logs_count = logs_data
            .resource_logs
            .iter()
            .map(|rl| {
                rl.scope_logs
                    .iter()
                    .map(|sl| sl.log_records.len())
                    .sum::<usize>()
            })
            .sum::<usize>();

        info!(
            "Received OTEL logs export request: {} resource logs, {} total log records",
            logs_data.resource_logs.len(),
            logs_count
        );
        metrics::record_received("logs", logs_count);

        // Log some debug details about the logs
        if log::log_enabled!(log::Level::Debug) {
            for (i, resource_log) in logs_data.resource_logs.iter().enumerate() {
                let resource_attrs = resource_log
                    .resource
                    .as_ref()
                    .map(|r| r.attributes.len())
                    .unwrap_or(0);
                debug!(
                    "Resource log {}: {} scope logs, {} resource attributes",
                    i,
                    resource_log.scope_logs.len(),
                    resource_attrs
                );

                for (j, scope_log) in resource_log.scope_logs.iter().enumerate() {
                    let scope_name = scope_log
                        .scope
                        .as_ref()
                        .map(|s| s.name.as_str())
                        .unwrap_or("unknown");
                    debug!(
                        "  Scope log {}: '{}' with {} log records",
                        j,
                        scope_name,
                        scope_log.log_records.len()
                    );
                }
            }
        }

        // Send to NATS if configured. A publish failure (after one retry)
        // fails the export so SDK clients retransmit instead of silently
        // losing log records.
        let mut rejected_log_records = 0usize;
        if let Some(output) = self.output_handle() {
            debug!("Forwarding logs to NATS");
            let publish_result = publish_with_retry("logs", || async {
                output.publish_logs(&logs_data, ctx).await
            })
            .await;
            match publish_result {
                Ok(outcome) => {
                    rejected_log_records = outcome.rejected;
                    metrics::record_published("logs", outcome.published);
                }
                Err(e) => {
                    metrics::record_publish_failure("logs", logs_count);
                    error!("Failed to publish logs to NATS after retry: {e}");
                    return Err(ExportError {
                        message: format!("failed to publish logs to NATS after retry: {e}"),
                    });
                }
            }
        } else {
            debug!("No NATS output configured, logs received but not forwarded");
        }

        debug!("OTEL logs export request completed successfully");
        // Per the OTLP spec, partial_success MUST be unset on full success;
        // it is only populated when log records were actually rejected.
        Ok(ExportLogsServiceResponse {
            partial_success: (rejected_log_records > 0).then(|| ExportLogsPartialSuccess {
                rejected_log_records: rejected_log_records as i64,
                error_message: oversize_partial_message(rejected_log_records),
            }),
        })
    }
}

/// Reads the identity established by the ingestion-auth interceptor
/// ([`crate::auth::grpc_auth_interceptor`]) back out of the gRPC request
/// extensions; absent extension (interceptor not installed) means anonymous.
fn grpc_ingest_context(extensions: &tonic::Extensions) -> IngestContext {
    IngestContext {
        identity: extensions
            .get::<crate::auth::AuthenticatedIdentity>()
            .and_then(|identity| identity.0.clone()),
    }
}

#[tonic::async_trait]
impl TraceService for ServiceRadarCollector {
    async fn export(
        &self,
        request: Request<ExportTraceServiceRequest>,
    ) -> Result<Response<ExportTraceServiceResponse>, Status> {
        let ctx = grpc_ingest_context(request.extensions());
        self.handle_traces(request.into_inner(), &ctx)
            .await
            .map(Response::new)
            .map_err(|e| Status::unavailable(e.message))
    }
}

#[tonic::async_trait]
impl MetricsService for ServiceRadarCollector {
    async fn export(
        &self,
        request: Request<ExportMetricsServiceRequest>,
    ) -> Result<Response<ExportMetricsServiceResponse>, Status> {
        let ctx = grpc_ingest_context(request.extensions());
        self.handle_metrics(request.into_inner(), &ctx)
            .await
            .map(Response::new)
            .map_err(|e| Status::unavailable(e.message))
    }
}

#[tonic::async_trait]
impl LogsService for ServiceRadarCollector {
    async fn export(
        &self,
        request: Request<ExportLogsServiceRequest>,
    ) -> Result<Response<ExportLogsServiceResponse>, Status> {
        let ctx = grpc_ingest_context(request.extensions());
        self.handle_logs(request.into_inner(), &ctx)
            .await
            .map(Response::new)
            .map_err(|e| Status::unavailable(e.message))
    }
}

fn count_metric_data_points(metric: &Metric) -> usize {
    match metric.data {
        Some(ref data) => match data {
            MetricData::Gauge(gauge) => gauge.data_points.len(),
            MetricData::Sum(sum) => sum.data_points.len(),
            MetricData::Histogram(histogram) => histogram.data_points.len(),
            MetricData::ExponentialHistogram(histogram) => histogram.data_points.len(),
            MetricData::Summary(summary) => summary.data_points.len(),
        },
        None => 0,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use opentelemetry::proto::common::v1::{AnyValue, KeyValue};
    use opentelemetry::proto::resource::v1::Resource;
    use opentelemetry::proto::trace::v1::{ResourceSpans, ScopeSpans, Span, Status as SpanStatus};

    fn create_test_trace_request() -> ExportTraceServiceRequest {
        ExportTraceServiceRequest {
            resource_spans: vec![ResourceSpans {
                resource: Some(Resource {
                    attributes: vec![
                        KeyValue {
                            key: "service.name".to_string(),
                            value: Some(AnyValue {
                                value: Some(
                                    opentelemetry::proto::common::v1::any_value::Value::StringValue(
                                        "test-service".to_string(),
                                    ),
                                ),
                            }),
                        },
                        KeyValue {
                            key: "service.version".to_string(),
                            value: Some(AnyValue {
                                value: Some(
                                    opentelemetry::proto::common::v1::any_value::Value::StringValue(
                                        "1.0.0".to_string(),
                                    ),
                                ),
                            }),
                        },
                    ],
                    dropped_attributes_count: 0,
                    entity_refs: vec![],
                }),
                scope_spans: vec![ScopeSpans {
                    scope: Some(opentelemetry::proto::common::v1::InstrumentationScope {
                        name: "test-instrumentation".to_string(),
                        version: "1.0.0".to_string(),
                        attributes: vec![],
                        dropped_attributes_count: 0,
                    }),
                    spans: vec![Span {
                        trace_id: vec![1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16],
                        span_id: vec![1, 2, 3, 4, 5, 6, 7, 8],
                        trace_state: "".to_string(),
                        parent_span_id: vec![],
                        flags: 1,
                        name: "test-span".to_string(),
                        kind: opentelemetry::proto::trace::v1::span::SpanKind::Server as i32,
                        start_time_unix_nano: 1640995200000000000, // 2022-01-01 00:00:00 UTC
                        end_time_unix_nano: 1640995201000000000,   // 2022-01-01 00:00:01 UTC
                        attributes: vec![KeyValue {
                            key: "http.method".to_string(),
                            value: Some(AnyValue {
                                value: Some(
                                    opentelemetry::proto::common::v1::any_value::Value::StringValue(
                                        "GET".to_string(),
                                    ),
                                ),
                            }),
                        }],
                        dropped_attributes_count: 0,
                        events: vec![],
                        dropped_events_count: 0,
                        links: vec![],
                        dropped_links_count: 0,
                        status: Some(SpanStatus {
                            message: "".to_string(),
                            code: opentelemetry::proto::trace::v1::status::StatusCode::Ok as i32,
                        }),
                    }],
                    schema_url: "".to_string(),
                }],
                schema_url: "https://opentelemetry.io/schemas/1.4.0".to_string(),
            }],
        }
    }

    #[tokio::test]
    async fn test_export_success() {
        let collector = ServiceRadarCollector::new(None).await.unwrap();
        let request = tonic::Request::new(create_test_trace_request());

        let response = TraceService::export(&collector, request).await;

        assert!(response.is_ok());
        let response = response.unwrap();
        let inner = response.into_inner();
        assert!(inner.partial_success.is_none());
    }

    #[tokio::test]
    async fn test_export_empty_request() {
        let collector = ServiceRadarCollector::new(None).await.unwrap();
        let request = tonic::Request::new(ExportTraceServiceRequest {
            resource_spans: vec![],
        });

        let response = TraceService::export(&collector, request).await;

        assert!(response.is_ok());
        let response = response.unwrap();
        let inner = response.into_inner();
        assert!(inner.partial_success.is_none());
    }

    #[tokio::test]
    async fn test_export_multiple_resource_spans() {
        let collector = ServiceRadarCollector::new(None).await.unwrap();
        let mut request_data = create_test_trace_request();

        // Add another resource span
        request_data.resource_spans.push(ResourceSpans {
            resource: Some(Resource {
                attributes: vec![KeyValue {
                    key: "service.name".to_string(),
                    value: Some(AnyValue {
                        value: Some(
                            opentelemetry::proto::common::v1::any_value::Value::StringValue(
                                "another-service".to_string(),
                            ),
                        ),
                    }),
                }],
                dropped_attributes_count: 0,
                entity_refs: vec![],
            }),
            scope_spans: vec![],
            schema_url: "".to_string(),
        });

        let request = tonic::Request::new(request_data);
        let response = TraceService::export(&collector, request).await;

        assert!(response.is_ok());
    }

    #[tokio::test]
    async fn test_publish_with_retry_first_attempt_succeeds() {
        let attempts = std::cell::Cell::new(0u32);
        let result = publish_with_retry("test", || {
            attempts.set(attempts.get() + 1);
            async { Ok(()) }
        })
        .await;

        assert!(result.is_ok());
        assert_eq!(attempts.get(), 1);
    }

    #[tokio::test]
    async fn test_publish_with_retry_recovers_on_second_attempt() {
        let attempts = std::cell::Cell::new(0u32);
        let result = publish_with_retry("test", || {
            let attempt = attempts.get() + 1;
            attempts.set(attempt);
            async move {
                if attempt == 1 {
                    Err(anyhow::anyhow!("transient NATS failure"))
                } else {
                    Ok(())
                }
            }
        })
        .await;

        assert!(result.is_ok());
        assert_eq!(attempts.get(), 2);
    }

    #[tokio::test]
    async fn test_publish_with_retry_fails_after_two_attempts() {
        let attempts = std::cell::Cell::new(0u32);
        let result = publish_with_retry("test", || {
            attempts.set(attempts.get() + 1);
            async { Err::<(), anyhow::Error>(anyhow::anyhow!("NATS still down")) }
        })
        .await;

        assert!(result.is_err());
        assert_eq!(attempts.get(), 2);
        assert!(result.unwrap_err().to_string().contains("NATS still down"));
    }

    #[tokio::test]
    async fn test_collector_debug_impl() {
        let collector = ServiceRadarCollector::new(None).await.unwrap();
        let debug_str = format!("{:?}", collector);
        assert!(debug_str.contains("ServiceRadarCollector"));
    }

    #[tokio::test]
    async fn test_trace_data_validation() {
        let collector = ServiceRadarCollector::new(None).await.unwrap();

        // Test with malformed trace data
        let malformed_request = ExportTraceServiceRequest {
            resource_spans: vec![ResourceSpans {
                resource: None, // Missing resource
                scope_spans: vec![ScopeSpans {
                    scope: None, // Missing scope
                    spans: vec![],
                    schema_url: "".to_string(),
                }],
                schema_url: "".to_string(),
            }],
        };

        let request = tonic::Request::new(malformed_request);
        let response = TraceService::export(&collector, request).await;

        // Should still succeed - collector accepts any valid protobuf
        assert!(response.is_ok());
    }

    #[tokio::test]
    async fn test_metrics_export_success() {
        let collector = ServiceRadarCollector::new(None).await.unwrap();
        let request = tonic::Request::new(ExportMetricsServiceRequest {
            resource_metrics: vec![],
        });

        let response = MetricsService::export(&collector, request).await;
        assert!(response.is_ok());
    }

    #[tokio::test]
    async fn test_logs_export_success() {
        let collector = ServiceRadarCollector::new(None).await.unwrap();
        let request = tonic::Request::new(create_test_logs_request());

        let response = LogsService::export(&collector, request).await;

        assert!(response.is_ok());
        let response = response.unwrap();
        let inner = response.into_inner();
        // OTLP spec: partial_success MUST be unset on full success.
        assert!(inner.partial_success.is_none());
    }

    fn create_test_logs_request() -> ExportLogsServiceRequest {
        ExportLogsServiceRequest {
            resource_logs: vec![opentelemetry::proto::logs::v1::ResourceLogs {
                resource: Some(opentelemetry::proto::resource::v1::Resource {
                    attributes: vec![opentelemetry::proto::common::v1::KeyValue {
                        key: "service.name".to_string(),
                        value: Some(opentelemetry::proto::common::v1::AnyValue {
                            value: Some(
                                opentelemetry::proto::common::v1::any_value::Value::StringValue(
                                    "test-service".to_string(),
                                ),
                            ),
                        }),
                    }],
                    dropped_attributes_count: 0,
                    entity_refs: vec![],
                }),
                scope_logs: vec![opentelemetry::proto::logs::v1::ScopeLogs {
                    scope: Some(opentelemetry::proto::common::v1::InstrumentationScope {
                        name: "test-logger".to_string(),
                        version: "1.0.0".to_string(),
                        attributes: vec![],
                        dropped_attributes_count: 0,
                    }),
                    log_records: vec![opentelemetry::proto::logs::v1::LogRecord {
                        time_unix_nano: 1640995200000000000, // 2022-01-01 00:00:00 UTC
                        observed_time_unix_nano: 1640995200000000000,
                        severity_number: opentelemetry::proto::logs::v1::SeverityNumber::Info
                            as i32,
                        severity_text: "INFO".to_string(),
                        body: Some(opentelemetry::proto::common::v1::AnyValue {
                            value: Some(
                                opentelemetry::proto::common::v1::any_value::Value::StringValue(
                                    "Test log message".to_string(),
                                ),
                            ),
                        }),
                        attributes: vec![],
                        dropped_attributes_count: 0,
                        flags: 0,
                        trace_id: vec![],
                        span_id: vec![],
                        event_name: "".to_string(),
                    }],
                    schema_url: "".to_string(),
                }],
                schema_url: "https://opentelemetry.io/schemas/1.4.0".to_string(),
            }],
        }
    }

    /// Test double for the output seam: counts calls, optionally fails or
    /// reports rejected records.
    #[derive(Default)]
    struct MockOutput {
        trace_calls: std::sync::atomic::AtomicUsize,
        log_calls: std::sync::atomic::AtomicUsize,
        metric_calls: std::sync::atomic::AtomicUsize,
        rejected: usize,
        fail: bool,
        /// Last [`IngestContext`] seen by any publish method, for asserting
        /// identity threading from the listeners into the output backend.
        last_ctx: std::sync::Mutex<Option<IngestContext>>,
    }

    impl MockOutput {
        fn record_ctx(&self, ctx: &IngestContext) {
            *self.last_ctx.lock().unwrap() = Some(ctx.clone());
        }

        fn last_identity(&self) -> Option<String> {
            self.last_ctx
                .lock()
                .unwrap()
                .as_ref()
                .and_then(|ctx| ctx.identity.clone())
        }
    }

    impl MockOutput {
        fn outcome(&self, total: usize) -> anyhow::Result<crate::output::PublishOutcome> {
            if self.fail {
                anyhow::bail!("mock output failure");
            }
            Ok(crate::output::PublishOutcome {
                published: total.saturating_sub(self.rejected),
                rejected: self.rejected,
            })
        }
    }

    #[tonic::async_trait]
    impl TelemetryOutput for MockOutput {
        async fn publish_traces(
            &self,
            traces: &ExportTraceServiceRequest,
            ctx: &IngestContext,
        ) -> anyhow::Result<crate::output::PublishOutcome> {
            self.record_ctx(ctx);
            self.trace_calls
                .fetch_add(1, std::sync::atomic::Ordering::SeqCst);
            let spans = traces
                .resource_spans
                .iter()
                .flat_map(|rs| rs.scope_spans.iter())
                .map(|ss| ss.spans.len())
                .sum();
            self.outcome(spans)
        }

        async fn publish_logs(
            &self,
            logs: &ExportLogsServiceRequest,
            ctx: &IngestContext,
        ) -> anyhow::Result<crate::output::PublishOutcome> {
            self.record_ctx(ctx);
            self.log_calls
                .fetch_add(1, std::sync::atomic::Ordering::SeqCst);
            let records = logs
                .resource_logs
                .iter()
                .flat_map(|rl| rl.scope_logs.iter())
                .map(|sl| sl.log_records.len())
                .sum();
            self.outcome(records)
        }

        async fn publish_raw_metrics(
            &self,
            _metrics: &ExportMetricsServiceRequest,
            ctx: &IngestContext,
        ) -> anyhow::Result<crate::output::PublishOutcome> {
            self.record_ctx(ctx);
            self.metric_calls
                .fetch_add(1, std::sync::atomic::Ordering::SeqCst);
            self.outcome(0)
        }

        async fn publish_derived_metrics(
            &self,
            metrics: &[PerformanceMetric],
            ctx: &IngestContext,
        ) -> anyhow::Result<crate::output::PublishOutcome> {
            self.record_ctx(ctx);
            self.outcome(metrics.len())
        }
    }

    #[tokio::test]
    async fn test_collector_publishes_through_output_trait() {
        let output = Arc::new(MockOutput::default());
        let collector = ServiceRadarCollector::with_output(output.clone());

        let response = collector
            .handle_traces(create_test_trace_request(), &IngestContext::anonymous())
            .await
            .unwrap();
        assert!(response.partial_success.is_none());
        assert_eq!(
            output.trace_calls.load(std::sync::atomic::Ordering::SeqCst),
            1
        );

        let response = collector
            .handle_logs(create_test_logs_request(), &IngestContext::anonymous())
            .await
            .unwrap();
        assert!(response.partial_success.is_none());
        assert_eq!(
            output.log_calls.load(std::sync::atomic::Ordering::SeqCst),
            1
        );
    }

    #[tokio::test]
    async fn test_collector_reports_partial_success_from_output_rejections() {
        let output = Arc::new(MockOutput {
            rejected: 1,
            ..MockOutput::default()
        });
        let collector = ServiceRadarCollector::with_output(output);

        let response = collector
            .handle_traces(create_test_trace_request(), &IngestContext::anonymous())
            .await
            .unwrap();
        let partial = response.partial_success.expect("partial_success expected");
        assert_eq!(partial.rejected_spans, 1);
        assert!(partial.error_message.contains("max encoded size"));
    }

    #[tokio::test]
    async fn test_collector_maps_output_failure_to_export_error_after_retry() {
        let output = Arc::new(MockOutput {
            fail: true,
            ..MockOutput::default()
        });
        let collector = ServiceRadarCollector::with_output(output.clone());

        let result = collector
            .handle_traces(create_test_trace_request(), &IngestContext::anonymous())
            .await;
        assert!(result.is_err());
        // publish_with_retry retries exactly once before failing the export.
        assert_eq!(
            output.trace_calls.load(std::sync::atomic::Ordering::SeqCst),
            2
        );
    }

    #[tokio::test]
    async fn test_authenticated_identity_threads_into_output_context() {
        let output = Arc::new(MockOutput::default());
        let collector = ServiceRadarCollector::with_output(output.clone());
        let ctx = IngestContext {
            identity: Some("tenant-a".to_string()),
        };

        collector
            .handle_traces(create_test_trace_request(), &ctx)
            .await
            .unwrap();
        assert_eq!(output.last_identity(), Some("tenant-a".to_string()));

        collector
            .handle_logs(create_test_logs_request(), &ctx)
            .await
            .unwrap();
        assert_eq!(output.last_identity(), Some("tenant-a".to_string()));

        collector
            .handle_metrics(
                ExportMetricsServiceRequest {
                    resource_metrics: vec![],
                },
                &ctx,
            )
            .await
            .unwrap();
        assert_eq!(output.last_identity(), Some("tenant-a".to_string()));
    }

    #[tokio::test]
    async fn test_anonymous_requests_publish_without_identity() {
        let output = Arc::new(MockOutput::default());
        let collector = ServiceRadarCollector::with_output(output.clone());

        collector
            .handle_traces(create_test_trace_request(), &IngestContext::anonymous())
            .await
            .unwrap();
        assert_eq!(output.last_identity(), None);
        assert!(output.last_ctx.lock().unwrap().is_some());
    }

    #[tokio::test]
    async fn test_grpc_export_reads_identity_from_interceptor_extensions() {
        let output = Arc::new(MockOutput::default());
        let collector = ServiceRadarCollector::with_output(output.clone());

        let mut request = tonic::Request::new(create_test_trace_request());
        request
            .extensions_mut()
            .insert(crate::auth::AuthenticatedIdentity(Some(
                "tenant-grpc".to_string(),
            )));

        let response = TraceService::export(&collector, request).await.unwrap();
        assert!(response.into_inner().partial_success.is_none());
        assert_eq!(output.last_identity(), Some("tenant-grpc".to_string()));
    }
}
