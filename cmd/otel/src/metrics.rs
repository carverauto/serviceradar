use lazy_static::lazy_static;
use prometheus::{register_histogram_vec, register_counter_vec, HistogramVec, CounterVec, Encoder, TextEncoder};
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