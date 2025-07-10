use tonic::{Request, Response, Status};

pub mod opentelemetry {
    pub mod proto {
        pub mod collector {
            pub mod trace {
                pub mod v1 {
                    tonic::include_proto!("opentelemetry.proto.collector.trace.v1");
                }
            }
        }
        pub mod trace {
            pub mod v1 {
                tonic::include_proto!("opentelemetry.proto.trace.v1");
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

#[derive(Debug)]
pub struct MyCollector {}

#[tonic::async_trait]
impl TraceService for MyCollector {
    async fn export(
        &self,
        request: Request<ExportTraceServiceRequest>,
    ) -> Result<Response<ExportTraceServiceResponse>, Status> {
        let trace_data = request.into_inner();
        println!("Received traces: {:#?}", trace_data);
        Ok(Response::new(ExportTraceServiceResponse {
            partial_success: None,
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
        let collector = MyCollector {};
        let request = tonic::Request::new(create_test_trace_request());
        
        let response = collector.export(request).await;
        
        assert!(response.is_ok());
        let response = response.unwrap();
        let inner = response.into_inner();
        assert!(inner.partial_success.is_none());
    }

    #[tokio::test]
    async fn test_export_empty_request() {
        let collector = MyCollector {};
        let request = tonic::Request::new(ExportTraceServiceRequest {
            resource_spans: vec![],
        });
        
        let response = collector.export(request).await;
        
        assert!(response.is_ok());
        let response = response.unwrap();
        let inner = response.into_inner();
        assert!(inner.partial_success.is_none());
    }

    #[tokio::test]
    async fn test_export_multiple_resource_spans() {
        let collector = MyCollector {};
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
        let response = collector.export(request).await;
        
        assert!(response.is_ok());
    }

    #[tokio::test]
    async fn test_collector_debug_impl() {
        let collector = MyCollector {};
        let debug_str = format!("{:?}", collector);
        assert_eq!(debug_str, "MyCollector");
    }

    #[tokio::test]
    async fn test_trace_data_validation() {
        let collector = MyCollector {};
        
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
        let response = collector.export(request).await;
        
        // Should still succeed - collector accepts any valid protobuf
        assert!(response.is_ok());
    }
}