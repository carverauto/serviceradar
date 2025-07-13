use tonic::{Request, Response, Status};
use log::{debug, info, error};

pub mod cli;
pub mod config;
pub mod nats_output;
pub mod tls;
pub mod server;
pub mod setup;

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

use opentelemetry::proto::collector::trace::v1::trace_service_server::TraceService;
use opentelemetry::proto::collector::trace::v1::{ExportTraceServiceRequest, ExportTraceServiceResponse};
use opentelemetry::proto::collector::logs::v1::logs_service_server::LogsService;
use opentelemetry::proto::collector::logs::v1::{ExportLogsServiceRequest, ExportLogsServiceResponse, ExportLogsPartialSuccess};
use std::sync::Arc;
use tokio::sync::Mutex;

#[derive(Clone)]
pub struct ServiceRadarCollector {
    nats_output: Option<Arc<Mutex<nats_output::NATSOutput>>>,
}

impl ServiceRadarCollector {
    pub async fn new(nats_config: Option<nats_output::NATSConfig>) -> Result<Self, Box<dyn std::error::Error>> {
        debug!("Creating ServiceRadarCollector");
        
        let nats_output = if let Some(config) = nats_config {
            debug!("Initializing NATS output for collector");
            match nats_output::NATSOutput::new(config).await {
                Ok(output) => {
                    debug!("NATS output created successfully");
                    Some(Arc::new(Mutex::new(output)))
                },
                Err(e) => {
                    error!("Failed to initialize NATS output: {e}");
                    return Err(e.into());
                }
            }
        } else {
            debug!("No NATS configuration provided, collector will not forward traces");
            None
        };
        
        debug!("ServiceRadarCollector created with NATS output: {}", nats_output.is_some());
        Ok(Self { nats_output })
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
        
        let span_count = trace_data.resource_spans.iter()
            .map(|rs| rs.scope_spans.iter().map(|ss| ss.spans.len()).sum::<usize>())
            .sum::<usize>();
        
        info!("Received OTEL export request: {} resource spans, {} total spans", 
              trace_data.resource_spans.len(), span_count);
        
        // Log some debug details about the traces
        if log::log_enabled!(log::Level::Debug) {
            for (i, resource_span) in trace_data.resource_spans.iter().enumerate() {
                let resource_attrs = resource_span.resource.as_ref()
                    .map(|r| r.attributes.len()).unwrap_or(0);
                debug!("Resource span {}: {} scope spans, {} resource attributes", 
                       i, resource_span.scope_spans.len(), resource_attrs);
                
                for (j, scope_span) in resource_span.scope_spans.iter().enumerate() {
                    let scope_name = scope_span.scope.as_ref()
                        .map(|s| s.name.as_str()).unwrap_or("unknown");
                    debug!("  Scope span {}: '{}' with {} spans", 
                           j, scope_name, scope_span.spans.len());
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
        
        let logs_count = logs_data.resource_logs.iter()
            .map(|rl| rl.scope_logs.iter().map(|sl| sl.log_records.len()).sum::<usize>())
            .sum::<usize>();
        
        info!("Received OTEL logs export request: {} resource logs, {} total log records", 
              logs_data.resource_logs.len(), logs_count);
        
        // Log some debug details about the logs
        if log::log_enabled!(log::Level::Debug) {
            for (i, resource_log) in logs_data.resource_logs.iter().enumerate() {
                let resource_attrs = resource_log.resource.as_ref()
                    .map(|r| r.attributes.len()).unwrap_or(0);
                debug!("Resource log {}: {} scope logs, {} resource attributes", 
                       i, resource_log.scope_logs.len(), resource_attrs);
                
                for (j, scope_log) in resource_log.scope_logs.iter().enumerate() {
                    let scope_name = scope_log.scope.as_ref()
                        .map(|s| s.name.as_str()).unwrap_or("unknown");
                    debug!("  Scope log {}: '{}' with {} log records", 
                           j, scope_name, scope_log.log_records.len());
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
                                value: Some(opentelemetry::proto::common::v1::any_value::Value::StringValue(
                                    "test-service".to_string(),
                                )),
                            }),
                        },
                        KeyValue {
                            key: "service.version".to_string(),
                            value: Some(AnyValue {
                                value: Some(opentelemetry::proto::common::v1::any_value::Value::StringValue(
                                    "1.0.0".to_string(),
                                )),
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
                                value: Some(opentelemetry::proto::common::v1::any_value::Value::StringValue(
                                    "GET".to_string(),
                                )),
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
                        value: Some(opentelemetry::proto::common::v1::any_value::Value::StringValue(
                            "another-service".to_string(),
                        )),
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
                    attributes: vec![
                        opentelemetry::proto::common::v1::KeyValue {
                            key: "service.name".to_string(),
                            value: Some(opentelemetry::proto::common::v1::AnyValue {
                                value: Some(opentelemetry::proto::common::v1::any_value::Value::StringValue(
                                    "test-service".to_string(),
                                )),
                            }),
                        },
                    ],
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
                        severity_number: opentelemetry::proto::logs::v1::SeverityNumber::Info as i32,
                        severity_text: "INFO".to_string(),
                        body: Some(opentelemetry::proto::common::v1::AnyValue {
                            value: Some(opentelemetry::proto::common::v1::any_value::Value::StringValue(
                                "Test log message".to_string(),
                            )),
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