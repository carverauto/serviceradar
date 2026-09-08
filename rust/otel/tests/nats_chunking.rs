//! Integration tests for `otel::nats::chunker`: chunk-boundary packing and
//! per-record oversize rejection accounting for logs, traces, and metrics.

use prost::Message;

use otel::nats::chunker::{split_logs_request, split_metrics_request, split_traces_request};
use otel::opentelemetry::proto::collector::logs::v1::ExportLogsServiceRequest;
use otel::opentelemetry::proto::collector::metrics::v1::ExportMetricsServiceRequest;
use otel::opentelemetry::proto::collector::trace::v1::ExportTraceServiceRequest;
use otel::opentelemetry::proto::common::v1::{AnyValue, InstrumentationScope, KeyValue};
use otel::opentelemetry::proto::logs::v1::{LogRecord, ResourceLogs, ScopeLogs, SeverityNumber};
use otel::opentelemetry::proto::metrics::v1::{
    Gauge, Metric, NumberDataPoint, ResourceMetrics, ScopeMetrics,
};
use otel::opentelemetry::proto::resource::v1::Resource;
use otel::opentelemetry::proto::trace::v1::{
    ResourceSpans, ScopeSpans, Span, Status as SpanStatus, span::SpanKind,
};

fn test_resource(service_name: &str) -> Resource {
    Resource {
        attributes: vec![KeyValue {
            key: "service.name".to_string(),
            value: Some(AnyValue {
                value: Some(
                    otel::opentelemetry::proto::common::v1::any_value::Value::StringValue(
                        service_name.to_string(),
                    ),
                ),
            }),
        }],
        dropped_attributes_count: 0,
        entity_refs: vec![],
    }
}

#[test]
fn split_logs_request_chunks_oversized_exports() {
    let oversized_body = "x".repeat(2_000);
    let logs = ExportLogsServiceRequest {
        resource_logs: vec![ResourceLogs {
            resource: Some(test_resource("log-test")),
            scope_logs: vec![ScopeLogs {
                scope: Some(InstrumentationScope {
                    name: "logger".to_string(),
                    version: "1.0.0".to_string(),
                    attributes: vec![],
                    dropped_attributes_count: 0,
                }),
                log_records: (0..8)
                    .map(|idx| LogRecord {
                        time_unix_nano: idx,
                        observed_time_unix_nano: idx,
                        severity_number: SeverityNumber::Info as i32,
                        severity_text: "INFO".to_string(),
                        body: Some(AnyValue {
                            value: Some(otel::opentelemetry::proto::common::v1::any_value::Value::StringValue(
                                oversized_body.clone(),
                            )),
                        }),
                        attributes: vec![],
                        dropped_attributes_count: 0,
                        flags: 0,
                        trace_id: vec![],
                        span_id: vec![],
                        event_name: format!("log-{idx}"),
                    })
                    .collect(),
                schema_url: String::new(),
            }],
            schema_url: String::new(),
        }],
    };

    let (chunks, rejected) = split_logs_request(&logs, 5_000);
    assert_eq!(rejected, 0);
    assert!(chunks.len() > 1);
    assert!(chunks.iter().all(|chunk| chunk.encoded_len() <= 5_000));

    let total_logs = chunks
        .iter()
        .map(|chunk| {
            chunk
                .resource_logs
                .iter()
                .map(|rl| {
                    rl.scope_logs
                        .iter()
                        .map(|sl| sl.log_records.len())
                        .sum::<usize>()
                })
                .sum::<usize>()
        })
        .sum::<usize>();
    assert_eq!(total_logs, 8);
}

#[test]
fn split_traces_request_chunks_oversized_exports() {
    let oversized_name = "span".repeat(400);
    let traces = ExportTraceServiceRequest {
        resource_spans: vec![ResourceSpans {
            resource: Some(test_resource("trace-test")),
            scope_spans: vec![ScopeSpans {
                scope: Some(InstrumentationScope {
                    name: "scope".to_string(),
                    version: "1.0.0".to_string(),
                    attributes: vec![],
                    dropped_attributes_count: 0,
                }),
                spans: (0..12)
                    .map(|idx| Span {
                        trace_id: vec![1; 16],
                        span_id: vec![2; 8],
                        parent_span_id: vec![],
                        flags: 0,
                        name: format!("{oversized_name}-{idx}"),
                        kind: SpanKind::Internal as i32,
                        start_time_unix_nano: idx,
                        end_time_unix_nano: idx + 1,
                        attributes: vec![KeyValue {
                            key: "key".to_string(),
                            value: Some(AnyValue {
                                value: Some(otel::opentelemetry::proto::common::v1::any_value::Value::StringValue(
                                    "value".repeat(200),
                                )),
                            }),
                        }],
                        dropped_attributes_count: 0,
                        events: vec![],
                        dropped_events_count: 0,
                        links: vec![],
                        dropped_links_count: 0,
                        status: Some(SpanStatus {
                            message: String::new(),
                            code: 1,
                        }),
                        trace_state: String::new(),
                    })
                    .collect(),
                schema_url: String::new(),
            }],
            schema_url: String::new(),
        }],
    };

    let (chunks, rejected) = split_traces_request(&traces, 6_000);
    assert_eq!(rejected, 0);
    assert!(chunks.len() > 1);
    assert!(chunks.iter().all(|chunk| chunk.encoded_len() <= 6_000));

    let total_spans = chunks
        .iter()
        .map(|chunk| {
            chunk
                .resource_spans
                .iter()
                .map(|rs| {
                    rs.scope_spans
                        .iter()
                        .map(|ss| ss.spans.len())
                        .sum::<usize>()
                })
                .sum::<usize>()
        })
        .sum::<usize>();
    assert_eq!(total_spans, 12);
}

#[test]
fn split_metrics_request_chunks_oversized_exports() {
    let metrics = ExportMetricsServiceRequest {
        resource_metrics: vec![ResourceMetrics {
            resource: Some(test_resource("metric-test")),
            scope_metrics: vec![ScopeMetrics {
                scope: Some(InstrumentationScope {
                    name: "scope".to_string(),
                    version: "1.0.0".to_string(),
                    attributes: vec![],
                    dropped_attributes_count: 0,
                }),
                metrics: (0..10)
                    .map(|idx| Metric {
                        name: format!("metric-{idx}"),
                        description: "description".repeat(100),
                        unit: "1".to_string(),
                        metadata: vec![],
                        data: Some(otel::opentelemetry::proto::metrics::v1::metric::Data::Gauge(
                            Gauge {
                                data_points: vec![NumberDataPoint {
                                    attributes: vec![KeyValue {
                                        key: "attr".to_string(),
                                        value: Some(AnyValue {
                                            value: Some(otel::opentelemetry::proto::common::v1::any_value::Value::StringValue(
                                                "value".repeat(200),
                                            )),
                                        }),
                                    }],
                                    start_time_unix_nano: idx,
                                    time_unix_nano: idx + 1,
                                    exemplars: vec![],
                                    flags: 0,
                                    value: Some(
                                        otel::opentelemetry::proto::metrics::v1::number_data_point::Value::AsDouble(
                                            idx as f64,
                                        ),
                                    ),
                                }],
                            },
                        )),
                    })
                    .collect(),
                schema_url: String::new(),
            }],
            schema_url: String::new(),
        }],
    };

    let (chunks, rejected) = split_metrics_request(&metrics, 8_000);
    assert_eq!(rejected, 0);
    assert!(chunks.len() > 1);
    assert!(chunks.iter().all(|chunk| chunk.encoded_len() <= 8_000));

    let total_metrics = chunks
        .iter()
        .map(|chunk| {
            chunk
                .resource_metrics
                .iter()
                .map(|rm| {
                    rm.scope_metrics
                        .iter()
                        .map(|sm| sm.metrics.len())
                        .sum::<usize>()
                })
                .sum::<usize>()
        })
        .sum::<usize>();
    assert_eq!(total_metrics, 10);
}

fn small_span(idx: u64, name: &str) -> Span {
    Span {
        trace_id: vec![1; 16],
        span_id: vec![2; 8],
        parent_span_id: vec![],
        flags: 0,
        name: name.to_string(),
        kind: SpanKind::Internal as i32,
        start_time_unix_nano: idx,
        end_time_unix_nano: idx + 1,
        attributes: vec![],
        dropped_attributes_count: 0,
        events: vec![],
        dropped_events_count: 0,
        links: vec![],
        dropped_links_count: 0,
        status: Some(SpanStatus {
            message: String::new(),
            code: 1,
        }),
        trace_state: String::new(),
    }
}

#[test]
fn pack_trace_units_drops_oversized_single_span_and_keeps_rest() {
    let budget = 2_000usize;
    // One span whose encoded size alone exceeds the budget, plus small spans.
    let oversized = small_span(0, &"x".repeat(4_000));
    let traces = ExportTraceServiceRequest {
        resource_spans: vec![ResourceSpans {
            resource: Some(test_resource("trace-oversize")),
            scope_spans: vec![ScopeSpans {
                scope: Some(InstrumentationScope {
                    name: "scope".to_string(),
                    version: "1.0.0".to_string(),
                    attributes: vec![],
                    dropped_attributes_count: 0,
                }),
                spans: vec![
                    oversized,
                    small_span(1, "small-1"),
                    small_span(2, "small-2"),
                    small_span(3, "small-3"),
                ],
                schema_url: String::new(),
            }],
            schema_url: String::new(),
        }],
    };

    let (chunks, rejected) = split_traces_request(&traces, budget);
    assert_eq!(rejected, 1, "exactly the oversized span is rejected");
    assert!(!chunks.is_empty(), "remaining spans must still be packed");
    assert!(chunks.iter().all(|chunk| chunk.encoded_len() <= budget));

    let surviving_spans: usize = chunks
        .iter()
        .flat_map(|chunk| chunk.resource_spans.iter())
        .flat_map(|rs| rs.scope_spans.iter())
        .map(|ss| ss.spans.len())
        .sum();
    assert_eq!(surviving_spans, 3);
}

#[test]
fn pack_trace_units_all_oversized_yields_no_chunks() {
    let budget = 1_000usize;
    let traces = ExportTraceServiceRequest {
        resource_spans: vec![ResourceSpans {
            resource: Some(test_resource("trace-oversize-all")),
            scope_spans: vec![ScopeSpans {
                scope: None,
                spans: vec![
                    small_span(0, &"y".repeat(3_000)),
                    small_span(1, &"z".repeat(3_000)),
                ],
                schema_url: String::new(),
            }],
            schema_url: String::new(),
        }],
    };

    let (chunks, rejected) = split_traces_request(&traces, budget);
    assert_eq!(rejected, 2);
    assert!(chunks.is_empty());
}

#[test]
fn pack_log_units_drops_oversized_single_record_and_keeps_rest() {
    let budget = 2_000usize;
    let make_record = |idx: u64, body: String| LogRecord {
        time_unix_nano: idx,
        observed_time_unix_nano: idx,
        severity_number: SeverityNumber::Info as i32,
        severity_text: "INFO".to_string(),
        body: Some(AnyValue {
            value: Some(
                otel::opentelemetry::proto::common::v1::any_value::Value::StringValue(body),
            ),
        }),
        attributes: vec![],
        dropped_attributes_count: 0,
        flags: 0,
        trace_id: vec![],
        span_id: vec![],
        event_name: format!("log-{idx}"),
    };

    let logs = ExportLogsServiceRequest {
        resource_logs: vec![ResourceLogs {
            resource: Some(test_resource("log-oversize")),
            scope_logs: vec![ScopeLogs {
                scope: None,
                log_records: vec![
                    make_record(0, "x".repeat(5_000)),
                    make_record(1, "small".to_string()),
                    make_record(2, "small".to_string()),
                ],
                schema_url: String::new(),
            }],
            schema_url: String::new(),
        }],
    };

    let (chunks, rejected) = split_logs_request(&logs, budget);
    assert_eq!(rejected, 1);
    assert!(chunks.iter().all(|chunk| chunk.encoded_len() <= budget));

    let surviving_records: usize = chunks
        .iter()
        .flat_map(|chunk| chunk.resource_logs.iter())
        .flat_map(|rl| rl.scope_logs.iter())
        .map(|sl| sl.log_records.len())
        .sum();
    assert_eq!(surviving_records, 2);
}

#[test]
fn pack_metric_units_counts_rejected_data_points() {
    let budget = 2_000usize;
    let make_metric = |idx: u64, description: String, data_points: usize| {
        Metric {
        name: format!("metric-{idx}"),
        description,
        unit: "1".to_string(),
        metadata: vec![],
        data: Some(
            otel::opentelemetry::proto::metrics::v1::metric::Data::Gauge(Gauge {
                data_points: (0..data_points)
                    .map(|dp| NumberDataPoint {
                        attributes: vec![],
                        start_time_unix_nano: idx,
                        time_unix_nano: idx + dp as u64,
                        exemplars: vec![],
                        flags: 0,
                        value: Some(
                            otel::opentelemetry::proto::metrics::v1::number_data_point::Value::AsDouble(
                                dp as f64,
                            ),
                        ),
                    })
                    .collect(),
            }),
        ),
    }
    };

    let metrics = ExportMetricsServiceRequest {
        resource_metrics: vec![ResourceMetrics {
            resource: Some(test_resource("metric-oversize")),
            scope_metrics: vec![ScopeMetrics {
                scope: None,
                metrics: vec![
                    // Oversized metric carrying 3 data points.
                    make_metric(0, "d".repeat(5_000), 3),
                    make_metric(1, "small".to_string(), 1),
                    make_metric(2, "small".to_string(), 1),
                ],
                schema_url: String::new(),
            }],
            schema_url: String::new(),
        }],
    };

    let (chunks, rejected) = split_metrics_request(&metrics, budget);
    assert_eq!(rejected, 3, "all data points of the oversized metric count");
    assert!(chunks.iter().all(|chunk| chunk.encoded_len() <= budget));

    let surviving_metrics: usize = chunks
        .iter()
        .flat_map(|chunk| chunk.resource_metrics.iter())
        .flat_map(|rm| rm.scope_metrics.iter())
        .map(|sm| sm.metrics.len())
        .sum();
    assert_eq!(surviving_metrics, 2);
}
