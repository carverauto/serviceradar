use log::{debug, error, info, warn};
use tonic::{Request, Response, Status};

pub mod cli;
pub mod config;
pub mod metrics;
pub mod nats_output;
pub mod server;
pub mod setup;
pub mod tls;

pub mod opentelemetry {
    pub mod proto {
        pub mod collector {
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

use crate::nats_output::PerformanceMetric;
use opentelemetry::proto::collector::logs::v1::logs_service_server::LogsService;
use opentelemetry::proto::collector::logs::v1::{
    ExportLogsPartialSuccess, ExportLogsServiceRequest, ExportLogsServiceResponse,
};
use opentelemetry::proto::collector::trace::v1::trace_service_server::TraceService;
use opentelemetry::proto::collector::trace::v1::{
    ExportTraceServiceRequest, ExportTraceServiceResponse,
};
use std::sync::Arc;
use tokio::sync::Mutex;

#[derive(Clone)]
pub struct ServiceRadarCollector {
    nats_output: Option<Arc<Mutex<nats_output::NATSOutput>>>,
}

impl ServiceRadarCollector {
    pub async fn new(
        nats_config: Option<nats_output::NATSConfig>,
    ) -> Result<Self, Box<dyn std::error::Error>> {
        debug!("Creating ServiceRadarCollector");

        let nats_output = if let Some(config) = nats_config {
            debug!("Initializing NATS output for collector");
            match nats_output::NATSOutput::new(config).await {
                Ok(output) => {
                    debug!("NATS output created successfully");
                    Some(Arc::new(Mutex::new(output)))
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
            "ServiceRadarCollector created with NATS output: {}",
            nats_output.is_some()
        );
        Ok(Self { nats_output })
    }

    /// Reconfigure NATS output at runtime. If None, disables output. If Some, rebuilds the output.
    pub async fn reconfigure_nats(&self, nats_config: Option<nats_output::NATSConfig>) {
        debug!("Reconfiguring NATS output for collector");
        match nats_config {
            Some(cfg) => match nats_output::NATSOutput::new(cfg).await {
                Ok(new_output) => {
                    if let Some(arc) = &self.nats_output {
                        {
                            let mut guard = arc.lock().await;
                            *guard = new_output;
                            info!("NATS output reconfigured successfully");
                        }
                    } else {
                        warn!("NATS output not initialized; restart required to enable output");
                    }
                }
                Err(e) => {
                    error!("Failed to reconfigure NATS output: {e}");
                }
            },
            None => {
                if let Some(arc) = &self.nats_output {
                    {
                        let mut guard = arc.lock().await;
                        // Replace with a disabled output that drops
                        *guard = nats_output::NATSOutput::disabled();
                        info!("NATS output disabled via reconfiguration");
                    }
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
            .field("nats_output", &self.nats_output.is_some())
            .finish()
    }
}

#[tonic::async_trait]
impl TraceService for ServiceRadarCollector {
    async fn export(
        &self,
        request: Request<ExportTraceServiceRequest>,
    ) -> Result<Response<ExportTraceServiceResponse>, Status> {
        let trace_data = request.into_inner();

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

        // Calculate durations and collect performance metrics for NATS publishing
        let mut performance_metrics = Vec::new();
        let current_time = chrono::Utc::now().to_rfc3339();

        for resource_span in &trace_data.resource_spans {
            // Extract service name from resource attributes
            let service_name = resource_span
                .resource
                .as_ref()
                .and_then(|r| {
                    r.attributes
                        .iter()
                        .find(|kv| kv.key == "service.name")
                        .and_then(|kv| kv.value.as_ref())
                        .and_then(|v| {
                            if let Some(
                                opentelemetry::proto::common::v1::any_value::Value::StringValue(s),
                            ) = &v.value
                            {
                                Some(s.as_str())
                            } else {
                                None
                            }
                        })
                })
                .unwrap_or("unknown_service");

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
                        let Some(
                            opentelemetry::proto::common::v1::any_value::Value::StringValue(s),
                        ) = &value.value
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

                    // Still log for immediate visibility in logs
                    info!(
                        "PERF METRIC - Service: '{}', Span: '{}', Duration: {:.3}ms, TraceID: {}, SpanID: {}",
                        service_name, span.name, duration_ms, trace_id, span_id
                    );
                }
            }
        }

        // Publish performance metrics to NATS
        if performance_metrics.is_empty() {
            // Nothing to publish
        } else if let Some(nats) = &self.nats_output {
            debug!(
                "Publishing {} performance metrics to NATS",
                performance_metrics.len()
            );
            let nats_output = nats.lock().await;
            if let Err(e) = nats_output.publish_metrics(&performance_metrics).await {
                error!("Failed to publish performance metrics to NATS: {e}");
                // Don't fail the request, just log the error
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

        // Send to NATS if configured
        if let Some(nats) = &self.nats_output {
            debug!("Forwarding traces to NATS");
            let nats_output = nats.lock().await;
            if let Err(e) = nats_output.publish_traces(&trace_data).await {
                error!("Failed to publish traces to NATS: {e}");
                // Don't fail the request, just log the error
            }
        } else {
            debug!("No NATS output configured, traces received but not forwarded");
        }

        debug!("OTEL export request completed successfully");
        Ok(Response::new(ExportTraceServiceResponse {
            partial_success: None,
        }))
    }
}

#[tonic::async_trait]
impl LogsService for ServiceRadarCollector {
    async fn export(
        &self,
        request: Request<ExportLogsServiceRequest>,
    ) -> Result<Response<ExportLogsServiceResponse>, Status> {
        let logs_data = request.into_inner();

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

        // Send to NATS if configured
        if let Some(nats) = &self.nats_output {
            debug!("Forwarding logs to NATS");
            let nats_output = nats.lock().await;
            if let Err(e) = nats_output.publish_logs(&logs_data).await {
                error!("Failed to publish logs to NATS: {e}");
                // Don't fail the request, just log the error
            }
        } else {
            debug!("No NATS output configured, logs received but not forwarded");
        }

        debug!("OTEL logs export request completed successfully");
        Ok(Response::new(ExportLogsServiceResponse {
            partial_success: Some(ExportLogsPartialSuccess {
                rejected_log_records: 0,
                error_message: String::new(),
            }),
        }))
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
    async fn test_logs_export_success() {
        let collector = ServiceRadarCollector::new(None).await.unwrap();
        let request = tonic::Request::new(create_test_logs_request());

        let response = LogsService::export(&collector, request).await;

        assert!(response.is_ok());
        let response = response.unwrap();
        let inner = response.into_inner();
        assert!(inner.partial_success.is_some());
        let partial_success = inner.partial_success.unwrap();
        assert_eq!(partial_success.rejected_log_records, 0);
        assert!(partial_success.error_message.is_empty());
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
}
