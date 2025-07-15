use prost::Message;

// This example demonstrates how to create and convert OTEL protobuf logs to JSON
fn main() -> Result<(), Box<dyn std::error::Error>> {
    // Include the protobuf definitions
    use serviceradar_zen::otel_logs::opentelemetry::proto::{
        common::v1::{any_value::Value as AnyValueEnum, AnyValue, KeyValue, InstrumentationScope},
        logs::v1::{LogRecord, LogsData, ResourceLogs, ScopeLogs},
        resource::v1::Resource,
    };

    // Create a sample OTEL log message
    let logs_data = LogsData {
        resource_logs: vec![ResourceLogs {
            resource: Some(Resource {
                attributes: vec![
                    KeyValue {
                        key: "service.name".to_string(),
                        value: Some(AnyValue {
                            value: Some(AnyValueEnum::StringValue("example-service".to_string())),
                        }),
                    },
                    KeyValue {
                        key: "service.version".to_string(),
                        value: Some(AnyValue {
                            value: Some(AnyValueEnum::StringValue("1.2.3".to_string())),
                        }),
                    },
                ],
                dropped_attributes_count: 0,
                entity_refs: vec![],
            }),
            scope_logs: vec![ScopeLogs {
                scope: Some(InstrumentationScope {
                    name: "example-instrumentation".to_string(),
                    version: "1.0.0".to_string(),
                    attributes: vec![],
                    dropped_attributes_count: 0,
                }),
                log_records: vec![LogRecord {
                    time_unix_nano: 1640995200000000000, // 2022-01-01T00:00:00Z
                    observed_time_unix_nano: 1640995200000000000,
                    severity_number: 9, // INFO
                    severity_text: "INFO".to_string(),
                    body: Some(AnyValue {
                        value: Some(AnyValueEnum::StringValue(
                            "This is an example OTEL log message".to_string()
                        )),
                    }),
                    attributes: vec![
                        KeyValue {
                            key: "user.id".to_string(),
                            value: Some(AnyValue {
                                value: Some(AnyValueEnum::StringValue("12345".to_string())),
                            }),
                        },
                        KeyValue {
                            key: "request.duration_ms".to_string(),
                            value: Some(AnyValue {
                                value: Some(AnyValueEnum::IntValue(250)),
                            }),
                        },
                    ],
                    dropped_attributes_count: 0,
                    flags: 0,
                    trace_id: vec![1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16],
                    span_id: vec![1, 2, 3, 4, 5, 6, 7, 8],
                    event_name: "".to_string(),
                }],
                schema_url: "https://opentelemetry.io/schemas/1.9.0".to_string(),
            }],
            schema_url: "https://opentelemetry.io/schemas/1.9.0".to_string(),
        }],
    };

    // Encode to protobuf binary
    let mut protobuf_data = Vec::new();
    logs_data.encode(&mut protobuf_data)?;
    println!("Protobuf data size: {} bytes", protobuf_data.len());

    // Convert to JSON using our conversion function
    let json_value = serviceradar_zen::otel_logs::otel_logs_to_json(&protobuf_data)?;
    let json_pretty = serde_json::to_string_pretty(&json_value)?;
    
    println!("Converted JSON:");
    println!("{}", json_pretty);

    Ok(())
}