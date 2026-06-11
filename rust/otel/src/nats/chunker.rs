//! Splits OTLP export requests into chunks that fit the JetStream publish
//! budget, rejecting (and counting) individual records too large to ever
//! publish.

use log::warn;
use prost::Message;

use crate::opentelemetry::proto::collector::logs::v1::ExportLogsServiceRequest;
use crate::opentelemetry::proto::collector::metrics::v1::ExportMetricsServiceRequest;
use crate::opentelemetry::proto::collector::trace::v1::ExportTraceServiceRequest;
use crate::opentelemetry::proto::logs::v1::{ResourceLogs, ScopeLogs};
use crate::opentelemetry::proto::metrics::v1::{ResourceMetrics, ScopeMetrics};
use crate::opentelemetry::proto::trace::v1::{ResourceSpans, ScopeSpans};

/// Maximum encoded payload size for a single JetStream publish.
pub(crate) const MAX_PROTO_PUBLISH_BYTES: usize = 900 * 1024;

/// Splits an OTLP export into publishable chunks. The second tuple element is
/// the number of individual records dropped because a single record's encoded
/// size exceeds `max_publish_bytes`; such records can never be published, so
/// they are rejected (and reported via partial_success) instead of poisoning
/// the whole batch into an infinite client retry loop.
pub fn split_logs_request(
    logs: &ExportLogsServiceRequest,
    max_publish_bytes: usize,
) -> (Vec<ExportLogsServiceRequest>, usize) {
    if logs.encoded_len() <= max_publish_bytes {
        return (vec![logs.clone()], 0);
    }

    let mut units = Vec::new();
    for resource_log in &logs.resource_logs {
        for scope_log in &resource_log.scope_logs {
            for log_record in &scope_log.log_records {
                units.push(ExportLogsServiceRequest {
                    resource_logs: vec![ResourceLogs {
                        resource: resource_log.resource.clone(),
                        scope_logs: vec![ScopeLogs {
                            scope: scope_log.scope.clone(),
                            log_records: vec![log_record.clone()],
                            schema_url: scope_log.schema_url.clone(),
                        }],
                        schema_url: resource_log.schema_url.clone(),
                    }],
                });
            }
        }
    }

    pack_log_units(units, max_publish_bytes)
}

fn pack_log_units(
    units: Vec<ExportLogsServiceRequest>,
    max_publish_bytes: usize,
) -> (Vec<ExportLogsServiceRequest>, usize) {
    let mut chunks = Vec::new();
    let mut rejected = 0usize;
    let mut current = ExportLogsServiceRequest {
        resource_logs: Vec::new(),
    };

    for unit in units {
        let unit_size = unit.encoded_len();
        if unit_size > max_publish_bytes {
            rejected += 1;
            warn!(
                "Dropping oversized OTEL log record: {unit_size} encoded bytes exceeds the {max_publish_bytes} byte publish budget"
            );
            continue;
        }

        let mut candidate = current.clone();
        candidate.resource_logs.extend(unit.resource_logs.clone());

        if !current.resource_logs.is_empty() && candidate.encoded_len() > max_publish_bytes {
            chunks.push(current);
            current = unit;
        } else {
            current.resource_logs.extend(unit.resource_logs);
        }
    }

    if !current.resource_logs.is_empty() {
        chunks.push(current);
    }

    (chunks, rejected)
}

/// Splits an OTLP trace export into publishable chunks; the second tuple
/// element counts individual spans rejected for exceeding the budget alone.
pub fn split_traces_request(
    traces: &ExportTraceServiceRequest,
    max_publish_bytes: usize,
) -> (Vec<ExportTraceServiceRequest>, usize) {
    if traces.encoded_len() <= max_publish_bytes {
        return (vec![traces.clone()], 0);
    }

    let mut units = Vec::new();
    for resource_span in &traces.resource_spans {
        for scope_span in &resource_span.scope_spans {
            for span in &scope_span.spans {
                units.push(ExportTraceServiceRequest {
                    resource_spans: vec![ResourceSpans {
                        resource: resource_span.resource.clone(),
                        scope_spans: vec![ScopeSpans {
                            scope: scope_span.scope.clone(),
                            spans: vec![span.clone()],
                            schema_url: scope_span.schema_url.clone(),
                        }],
                        schema_url: resource_span.schema_url.clone(),
                    }],
                });
            }
        }
    }

    pack_trace_units(units, max_publish_bytes)
}

fn pack_trace_units(
    units: Vec<ExportTraceServiceRequest>,
    max_publish_bytes: usize,
) -> (Vec<ExportTraceServiceRequest>, usize) {
    let mut chunks = Vec::new();
    let mut rejected = 0usize;
    let mut current = ExportTraceServiceRequest {
        resource_spans: Vec::new(),
    };

    for unit in units {
        let unit_size = unit.encoded_len();
        if unit_size > max_publish_bytes {
            rejected += 1;
            warn!(
                "Dropping oversized OTEL span: {unit_size} encoded bytes exceeds the {max_publish_bytes} byte publish budget"
            );
            continue;
        }

        let mut candidate = current.clone();
        candidate.resource_spans.extend(unit.resource_spans.clone());

        if !current.resource_spans.is_empty() && candidate.encoded_len() > max_publish_bytes {
            chunks.push(current);
            current = unit;
        } else {
            current.resource_spans.extend(unit.resource_spans);
        }
    }

    if !current.resource_spans.is_empty() {
        chunks.push(current);
    }

    (chunks, rejected)
}

/// Splits an OTLP metrics export into publishable chunks; the second tuple
/// element counts rejected metric data points (not Metric containers), per
/// OTLP partial_success semantics.
pub fn split_metrics_request(
    metrics: &ExportMetricsServiceRequest,
    max_publish_bytes: usize,
) -> (Vec<ExportMetricsServiceRequest>, usize) {
    if metrics.encoded_len() <= max_publish_bytes {
        return (vec![metrics.clone()], 0);
    }

    let mut units = Vec::new();
    for resource_metrics in &metrics.resource_metrics {
        for scope_metrics in &resource_metrics.scope_metrics {
            for metric in &scope_metrics.metrics {
                units.push(ExportMetricsServiceRequest {
                    resource_metrics: vec![ResourceMetrics {
                        resource: resource_metrics.resource.clone(),
                        scope_metrics: vec![ScopeMetrics {
                            scope: scope_metrics.scope.clone(),
                            metrics: vec![metric.clone()],
                            schema_url: scope_metrics.schema_url.clone(),
                        }],
                        schema_url: resource_metrics.schema_url.clone(),
                    }],
                });
            }
        }
    }

    pack_metric_units(units, max_publish_bytes)
}

fn pack_metric_units(
    units: Vec<ExportMetricsServiceRequest>,
    max_publish_bytes: usize,
) -> (Vec<ExportMetricsServiceRequest>, usize) {
    let mut chunks = Vec::new();
    let mut rejected = 0usize;
    let mut current = ExportMetricsServiceRequest {
        resource_metrics: Vec::new(),
    };

    for unit in units {
        let unit_size = unit.encoded_len();
        if unit_size > max_publish_bytes {
            // OTLP metrics partial_success counts rejected data points, not
            // rejected Metric containers.
            rejected += metric_request_data_points(&unit);
            warn!(
                "Dropping oversized OTEL metric: {unit_size} encoded bytes exceeds the {max_publish_bytes} byte publish budget"
            );
            continue;
        }

        let mut candidate = current.clone();
        candidate
            .resource_metrics
            .extend(unit.resource_metrics.clone());

        if !current.resource_metrics.is_empty() && candidate.encoded_len() > max_publish_bytes {
            chunks.push(current);
            current = unit;
        } else {
            current.resource_metrics.extend(unit.resource_metrics);
        }
    }

    if !current.resource_metrics.is_empty() {
        chunks.push(current);
    }

    (chunks, rejected)
}

/// Counts the metric data points contained in an export request.
pub(crate) fn metric_request_data_points(request: &ExportMetricsServiceRequest) -> usize {
    use crate::opentelemetry::proto::metrics::v1::metric::Data;

    request
        .resource_metrics
        .iter()
        .flat_map(|rm| rm.scope_metrics.iter())
        .flat_map(|sm| sm.metrics.iter())
        .map(|metric| match metric.data {
            Some(Data::Gauge(ref gauge)) => gauge.data_points.len(),
            Some(Data::Sum(ref sum)) => sum.data_points.len(),
            Some(Data::Histogram(ref histogram)) => histogram.data_points.len(),
            Some(Data::ExponentialHistogram(ref histogram)) => histogram.data_points.len(),
            Some(Data::Summary(ref summary)) => summary.data_points.len(),
            None => 0,
        })
        .sum()
}
