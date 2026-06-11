use lazy_static::lazy_static;
use prometheus::{
    CounterVec, Encoder, HistogramVec, TextEncoder, register_counter_vec, register_histogram_vec,
};
use std::collections::HashMap;

lazy_static! {
    // Histogram for span durations - allows percentile calculations
    pub static ref SPAN_DURATION_HISTOGRAM: HistogramVec = register_histogram_vec!(
        "serviceradar_span_duration_seconds",
        "Duration of spans in seconds",
        &["service_name", "span_name", "span_kind"],
        // Buckets from 1ms to 10s - adjust based on your typical latencies
        vec![0.001, 0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1.0, 2.5, 5.0, 10.0]
    ).unwrap();

    // Counter for total spans processed
    pub static ref SPAN_TOTAL_COUNTER: CounterVec = register_counter_vec!(
        "serviceradar_spans_total",
        "Total number of spans processed",
        &["service_name", "span_name", "span_kind"]
    ).unwrap();

    // Histogram for HTTP request durations (when HTTP attributes are present)
    pub static ref HTTP_REQUEST_DURATION_HISTOGRAM: HistogramVec = register_histogram_vec!(
        "serviceradar_http_request_duration_seconds",
        "Duration of HTTP requests in seconds",
        &["service_name", "method", "route", "status_code"],
        vec![0.001, 0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1.0, 2.5, 5.0, 10.0]
    ).unwrap();

    // Histogram for gRPC request durations (when gRPC attributes are present)
    pub static ref GRPC_REQUEST_DURATION_HISTOGRAM: HistogramVec = register_histogram_vec!(
        "serviceradar_grpc_request_duration_seconds",
        "Duration of gRPC requests in seconds",
        &["service_name", "grpc_service", "grpc_method", "status_code"],
        vec![0.001, 0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1.0, 2.5, 5.0, 10.0]
    ).unwrap();

    // Counter for slow spans (over 100ms)
    pub static ref SLOW_SPAN_COUNTER: CounterVec = register_counter_vec!(
        "serviceradar_slow_spans_total",
        "Total number of slow spans (>100ms)",
        &["service_name", "span_name"]
    ).unwrap();

    // Per-signal delivery accounting: items received via OTLP export requests.
    pub static ref OTEL_RECEIVED_TOTAL: CounterVec = register_counter_vec!(
        "otel_received_total",
        "Total OTLP items received by the collector, by signal (spans, log records, metric data points)",
        &["signal"]
    ).unwrap();

    // Per-signal delivery accounting: items successfully published to NATS.
    pub static ref OTEL_PUBLISHED_TOTAL: CounterVec = register_counter_vec!(
        "otel_published_total",
        "Total OTLP items successfully published to NATS, by signal",
        &["signal"]
    ).unwrap();

    // Per-signal delivery accounting: items that failed to publish to NATS
    // after retry. received == published + publish_failures (modulo in-flight).
    pub static ref OTEL_PUBLISH_FAILURES_TOTAL: CounterVec = register_counter_vec!(
        "otel_publish_failures_total",
        "Total OTLP items that failed to publish to NATS after retry, by signal",
        &["signal"]
    ).unwrap();

    // Per-signal accounting of individual records dropped at ingest (e.g. a
    // single span/log/metric whose encoded size exceeds the NATS payload
    // budget). These drops are reported back to OTLP clients via
    // partial_success so SDKs do not retry them forever.
    pub static ref OTEL_RECORDS_REJECTED_TOTAL: CounterVec = register_counter_vec!(
        "otel_records_rejected_total",
        "Total OTLP records rejected by the collector, by signal and reason",
        &["signal", "reason"]
    ).unwrap();

    // Agent-forward backend: records evicted from the durable relay spool
    // before the agent acked them (oldest-first overflow / age eviction).
    // These are real data loss at the edge; the same totals ride upstream in
    // TelemetryCounters.dropped on outgoing relay batches.
    pub static ref OTEL_RELAY_SPOOL_EVICTED_TOTAL: CounterVec = register_counter_vec!(
        "otel_relay_spool_evicted_records_total",
        "Total OTLP records evicted unacknowledged from the agent-forward relay spool, by signal",
        &["signal"]
    ).unwrap();
}

/// Record items received for a signal ("traces", "metrics", "logs", "span_metrics").
pub fn record_received(signal: &str, count: usize) {
    if count > 0 {
        OTEL_RECEIVED_TOTAL
            .with_label_values(&[signal])
            .inc_by(count as f64);
    }
}

/// Record items successfully published to NATS for a signal.
pub fn record_published(signal: &str, count: usize) {
    if count > 0 {
        OTEL_PUBLISHED_TOTAL
            .with_label_values(&[signal])
            .inc_by(count as f64);
    }
}

/// Record items that failed to publish to NATS (after retry) for a signal.
pub fn record_publish_failure(signal: &str, count: usize) {
    if count > 0 {
        OTEL_PUBLISH_FAILURES_TOTAL
            .with_label_values(&[signal])
            .inc_by(count as f64);
    }
}

/// Record individual records rejected at ingest for a signal (e.g. reason
/// "oversize" when a single encoded record exceeds the publish budget).
pub fn record_rejected(signal: &str, reason: &str, count: usize) {
    if count > 0 {
        OTEL_RECORDS_REJECTED_TOTAL
            .with_label_values(&[signal, reason])
            .inc_by(count as f64);
    }
}

/// Record records evicted unacked from the agent-forward relay spool for a
/// signal ("traces", "logs", "metrics", "derived_metrics", "other").
pub fn record_spool_evicted(signal: &str, count: u64) {
    if count > 0 {
        OTEL_RELAY_SPOOL_EVICTED_TOTAL
            .with_label_values(&[signal])
            .inc_by(count as f64);
    }
}

pub fn record_span_metrics(
    service_name: &str,
    span_name: &str,
    span_kind: &str,
    duration_seconds: f64,
    span_attributes: &HashMap<&str, &str>,
) {
    // Record basic span metrics
    SPAN_DURATION_HISTOGRAM
        .with_label_values(&[service_name, span_name, span_kind])
        .observe(duration_seconds);

    SPAN_TOTAL_COUNTER
        .with_label_values(&[service_name, span_name, span_kind])
        .inc();

    // Record HTTP-specific metrics if HTTP attributes are present
    if let (Some(method), Some(route)) = (
        span_attributes.get("http.method"),
        span_attributes.get("http.route"),
    ) {
        let status_code = span_attributes
            .get("http.status_code")
            .map_or("unknown", |v| *v);

        HTTP_REQUEST_DURATION_HISTOGRAM
            .with_label_values(&[service_name, method, route, status_code])
            .observe(duration_seconds);
    }

    // Record gRPC-specific metrics if gRPC attributes are present
    if let Some(grpc_method) = span_attributes.get("rpc.method") {
        let grpc_service = span_attributes.get("rpc.service").map_or("unknown", |v| *v);
        let status_code = span_attributes
            .get("rpc.grpc.status_code")
            .map_or("unknown", |v| *v);

        GRPC_REQUEST_DURATION_HISTOGRAM
            .with_label_values(&[service_name, grpc_service, grpc_method, status_code])
            .observe(duration_seconds);
    }

    // Record slow spans
    if duration_seconds > 0.1 {
        // 100ms threshold
        SLOW_SPAN_COUNTER
            .with_label_values(&[service_name, span_name])
            .inc();
    }
}

pub fn get_metrics_text() -> Result<String, Box<dyn std::error::Error>> {
    let encoder = TextEncoder::new();
    let metric_families = prometheus::gather();
    let mut buffer = Vec::new();
    encoder.encode(&metric_families, &mut buffer)?;
    Ok(String::from_utf8(buffer)?)
}

/// Convert span kind enum to string for metrics labels
pub fn span_kind_to_string(kind: i32) -> &'static str {
    match kind {
        0 => "unspecified",
        1 => "internal",
        2 => "server",
        3 => "client",
        4 => "producer",
        5 => "consumer",
        _ => "unknown",
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    // The prometheus registry is process-global, so each test uses unique
    // signal label values to stay independent of other tests.

    #[test]
    fn test_record_received_increments_counter() {
        let signal = "test_received_signal";
        record_received(signal, 3);
        record_received(signal, 2);
        assert_eq!(OTEL_RECEIVED_TOTAL.with_label_values(&[signal]).get(), 5.0);
    }

    #[test]
    fn test_record_published_increments_counter() {
        let signal = "test_published_signal";
        record_published(signal, 7);
        assert_eq!(OTEL_PUBLISHED_TOTAL.with_label_values(&[signal]).get(), 7.0);
    }

    #[test]
    fn test_record_publish_failure_increments_counter() {
        let signal = "test_failure_signal";
        record_publish_failure(signal, 4);
        assert_eq!(
            OTEL_PUBLISH_FAILURES_TOTAL
                .with_label_values(&[signal])
                .get(),
            4.0
        );
    }

    #[test]
    fn test_zero_count_does_not_create_series() {
        let signal = "test_zero_signal";
        record_received(signal, 0);
        record_published(signal, 0);
        record_publish_failure(signal, 0);
        assert_eq!(OTEL_RECEIVED_TOTAL.with_label_values(&[signal]).get(), 0.0);
        assert_eq!(OTEL_PUBLISHED_TOTAL.with_label_values(&[signal]).get(), 0.0);
        assert_eq!(
            OTEL_PUBLISH_FAILURES_TOTAL
                .with_label_values(&[signal])
                .get(),
            0.0
        );
    }

    #[test]
    fn test_record_spool_evicted_increments_counter() {
        let signal = "test_spool_evicted_signal";
        record_spool_evicted(signal, 3);
        record_spool_evicted(signal, 2);
        assert_eq!(
            OTEL_RELAY_SPOOL_EVICTED_TOTAL
                .with_label_values(&[signal])
                .get(),
            5.0
        );
        // Zero counts must not create a series.
        record_spool_evicted("test_spool_evicted_zero_signal", 0);
        assert_eq!(
            OTEL_RELAY_SPOOL_EVICTED_TOTAL
                .with_label_values(&["test_spool_evicted_zero_signal"])
                .get(),
            0.0
        );
    }

    #[test]
    fn test_record_rejected_increments_counter() {
        let signal = "test_rejected_signal";
        record_rejected(signal, "oversize", 2);
        record_rejected(signal, "oversize", 3);
        assert_eq!(
            OTEL_RECORDS_REJECTED_TOTAL
                .with_label_values(&[signal, "oversize"])
                .get(),
            5.0
        );
        // Zero counts must not create a series.
        record_rejected("test_rejected_zero_signal", "oversize", 0);
        assert_eq!(
            OTEL_RECORDS_REJECTED_TOTAL
                .with_label_values(&["test_rejected_zero_signal", "oversize"])
                .get(),
            0.0
        );
    }

    #[test]
    fn test_counters_appear_in_metrics_text() {
        record_received("test_text_signal", 1);
        record_published("test_text_signal", 1);
        record_publish_failure("test_text_signal", 1);
        let text = get_metrics_text().unwrap();
        assert!(text.contains("otel_received_total"));
        assert!(text.contains("otel_published_total"));
        assert!(text.contains("otel_publish_failures_total"));
    }
}
