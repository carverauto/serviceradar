use tonic::Request;

use otel::opentelemetry::proto::collector::trace::v1::{ExportTraceServiceRequest};
use otel::opentelemetry::proto::collector::trace::v1::trace_service_server::TraceService;
use otel::opentelemetry::proto::common::v1::{AnyValue, KeyValue};
use otel::opentelemetry::proto::resource::v1::Resource;
use otel::opentelemetry::proto::trace::v1::{ResourceSpans, ScopeSpans, Span, Status as SpanStatus};
use otel::ServiceRadarCollector;

fn create_test_trace_request() -> ExportTraceServiceRequest {
    ExportTraceServiceRequest {
        resource_spans: vec![ResourceSpans {
            resource: Some(Resource {
                attributes: vec![
                    KeyValue {
                        key: "service.name".to_string(),
                        value: Some(AnyValue {
                            value: Some(otel::opentelemetry::proto::common::v1::any_value::Value::StringValue(
                                "integration-test-service".to_string(),
                            )),
                        }),
                    },
                    KeyValue {
                        key: "service.version".to_string(),
                        value: Some(AnyValue {
                            value: Some(otel::opentelemetry::proto::common::v1::any_value::Value::StringValue(
                                "1.0.0".to_string(),
                            )),
                        }),
                    },
                ],
                dropped_attributes_count: 0,
                entity_refs: vec![],
            }),
            scope_spans: vec![ScopeSpans {
                scope: Some(otel::opentelemetry::proto::common::v1::InstrumentationScope {
                    name: "integration-test-instrumentation".to_string(),
                    version: "1.0.0".to_string(),
                    attributes: vec![],
                    dropped_attributes_count: 0,
                }),
                spans: vec![
                    Span {
                        trace_id: vec![1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16],
                        span_id: vec![1, 2, 3, 4, 5, 6, 7, 8],
                        trace_state: "".to_string(),
                        parent_span_id: vec![],
                        flags: 1,
                        name: "integration-test-span".to_string(),
                        kind: otel::opentelemetry::proto::trace::v1::span::SpanKind::Server as i32,
                        start_time_unix_nano: 1640995200000000000, // 2022-01-01 00:00:00 UTC
                        end_time_unix_nano: 1640995201000000000,   // 2022-01-01 00:00:01 UTC
                        attributes: vec![
                            KeyValue {
                                key: "http.method".to_string(),
                                value: Some(AnyValue {
                                    value: Some(otel::opentelemetry::proto::common::v1::any_value::Value::StringValue(
                                        "POST".to_string(),
                                    )),
                                }),
                            },
                            KeyValue {
                                key: "http.url".to_string(),
                                value: Some(AnyValue {
                                    value: Some(otel::opentelemetry::proto::common::v1::any_value::Value::StringValue(
                                        "https://api.example.com/test".to_string(),
                                    )),
                                }),
                            },
                        ],
                        dropped_attributes_count: 0,
                        events: vec![],
                        dropped_events_count: 0,
                        links: vec![],
                        dropped_links_count: 0,
                        status: Some(SpanStatus {
                            message: "".to_string(),
                            code: otel::opentelemetry::proto::trace::v1::status::StatusCode::Ok as i32,
                        }),
                    },
                    Span {
                        trace_id: vec![1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16],
                        span_id: vec![2, 3, 4, 5, 6, 7, 8, 9],
                        trace_state: "".to_string(),
                        parent_span_id: vec![1, 2, 3, 4, 5, 6, 7, 8],
                        flags: 1,
                        name: "child-span".to_string(),
                        kind: otel::opentelemetry::proto::trace::v1::span::SpanKind::Internal as i32,
                        start_time_unix_nano: 1640995200100000000,
                        end_time_unix_nano: 1640995200900000000,
                        attributes: vec![],
                        dropped_attributes_count: 0,
                        events: vec![],
                        dropped_events_count: 0,
                        links: vec![],
                        dropped_links_count: 0,
                        status: Some(SpanStatus {
                            message: "".to_string(),
                            code: otel::opentelemetry::proto::trace::v1::status::StatusCode::Ok as i32,
                        }),
                    },
                ],
                schema_url: "".to_string(),
            }],
            schema_url: "https://opentelemetry.io/schemas/1.4.0".to_string(),
        }],
    }
}

#[tokio::test]
async fn test_trace_service_export() {
    let collector = ServiceRadarCollector {};
    let request = Request::new(create_test_trace_request());
    
    let response = collector.export(request).await;
    
    assert!(response.is_ok());
    let response = response.unwrap();
    let inner = response.into_inner();
    assert!(inner.partial_success.is_none());
}

#[tokio::test]
async fn test_trace_service_export_empty() {
    let collector = ServiceRadarCollector {};
    let request = Request::new(ExportTraceServiceRequest {
        resource_spans: vec![],
    });
    
    let response = collector.export(request).await;
    
    assert!(response.is_ok());
    let response = response.unwrap();
    let inner = response.into_inner();
    assert!(inner.partial_success.is_none());
}

#[tokio::test]
async fn test_trace_service_export_multiple_batches() {
    let collector = ServiceRadarCollector {};
    
    // Send multiple batches
    for i in 0..5 {
        let mut request_data = create_test_trace_request();
        
        // Modify the trace ID to make each batch unique
        if let Some(resource_span) = request_data.resource_spans.first_mut() {
            if let Some(scope_span) = resource_span.scope_spans.first_mut() {
                if let Some(span) = scope_span.spans.first_mut() {
                    span.trace_id[0] = i as u8;
                    span.name = format!("batch-{}-span", i);
                }
            }
        }
        
        let request = Request::new(request_data);
        let response = collector.export(request).await;
        
        assert!(response.is_ok());
        let response = response.unwrap();
        let inner = response.into_inner();
        assert!(inner.partial_success.is_none());
    }
}

#[tokio::test]
async fn test_trace_service_concurrent_requests() {
    let mut handles = vec![];
    
    for i in 0..10 {
        let handle = tokio::spawn(async move {
            let collector = ServiceRadarCollector {};
            let mut request_data = create_test_trace_request();
            
            // Make each request unique
            if let Some(resource_span) = request_data.resource_spans.first_mut() {
                if let Some(scope_span) = resource_span.scope_spans.first_mut() {
                    if let Some(span) = scope_span.spans.first_mut() {
                        span.trace_id[0] = i as u8;
                        span.name = format!("concurrent-{}-span", i);
                    }
                }
            }
            
            let request = Request::new(request_data);
            let response = collector.export(request).await;
            
            assert!(response.is_ok());
            response.unwrap().into_inner()
        });
        
        handles.push(handle);
    }
    
    // Wait for all requests to complete
    for handle in handles {
        let result = handle.await.unwrap();
        assert!(result.partial_success.is_none());
    }
}