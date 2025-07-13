#[cfg(test)]
mod tests {
    use crate::config::{Config, MessageFormat};
    use crate::otel_logs;
    use prost::Message;
    use serde_json::json;

    #[test]
    fn test_config_with_protobuf_format() {
        let config_json = json!({
            "nats_url": "nats://localhost:4222",
            "stream_name": "test-stream",
            "consumer_name": "test-consumer", 
            "subjects": ["events.json", "events.protobuf"],
            "decision_groups": [
                {
                    "name": "json_events",
                    "subjects": ["events.json"],
                    "rules": [{"order": 1, "key": "rule1"}],
                    "format": "json"
                },
                {
                    "name": "protobuf_events", 
                    "subjects": ["events.protobuf"],
                    "rules": [{"order": 1, "key": "rule2"}],
                    "format": "protobuf"
                }
            ],
            "agent_id": "test-agent",
            "kv_bucket": "test-kv"
        });

        let config_str = serde_json::to_string(&config_json).unwrap();
        let cfg: Config = serde_json::from_str(&config_str).unwrap();
        
        assert!(cfg.validate().is_ok());
        assert_eq!(cfg.message_format_for_subject("events.json"), MessageFormat::Json);
        assert_eq!(cfg.message_format_for_subject("events.protobuf"), MessageFormat::Protobuf);
    }

    #[test]
    fn test_otel_logs_conversion_end_to_end() {
        use crate::otel_logs::opentelemetry::proto::{
            common::v1::{any_value::Value as AnyValueEnum, AnyValue, KeyValue, InstrumentationScope},
            logs::v1::{LogRecord, LogsData, ResourceLogs, ScopeLogs},
            resource::v1::Resource,
        };

        // Create a realistic OTEL log message
        let logs_data = LogsData {
            resource_logs: vec![ResourceLogs {
                resource: Some(Resource {
                    attributes: vec![
                        KeyValue {
                            key: "service.name".to_string(),
                            value: Some(AnyValue {
                                value: Some(AnyValueEnum::StringValue("my-service".to_string())),
                            }),
                        },
                        KeyValue {
                            key: "service.version".to_string(),
                            value: Some(AnyValue {
                                value: Some(AnyValueEnum::StringValue("1.0.0".to_string())),
                            }),
                        },
                    ],
                    dropped_attributes_count: 0,
                    entity_refs: vec![],
                }),
                scope_logs: vec![ScopeLogs {
                    scope: Some(InstrumentationScope {
                        name: "my-instrumentation".to_string(),
                        version: "1.0.0".to_string(),
                        attributes: vec![],
                        dropped_attributes_count: 0,
                    }),
                    log_records: vec![LogRecord {
                        time_unix_nano: 1640995200000000000, // 2022-01-01T00:00:00Z
                        observed_time_unix_nano: 1640995200000000000,
                        severity_number: 13, // WARN
                        severity_text: "WARN".to_string(),
                        body: Some(AnyValue {
                            value: Some(AnyValueEnum::StringValue(
                                "This is a warning message from OTEL".to_string()
                            )),
                        }),
                        attributes: vec![
                            KeyValue {
                                key: "http.method".to_string(),
                                value: Some(AnyValue {
                                    value: Some(AnyValueEnum::StringValue("GET".to_string())),
                                }),
                            },
                            KeyValue {
                                key: "http.status_code".to_string(),
                                value: Some(AnyValue {
                                    value: Some(AnyValueEnum::IntValue(404)),
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

        // Encode to protobuf
        let mut buf = Vec::new();
        logs_data.encode(&mut buf).unwrap();

        // Convert to JSON
        let result = otel_logs::otel_logs_to_json(&buf).unwrap();

        // Verify the conversion
        assert_eq!(result["timestamp"], 1640995200000000000u64);
        assert_eq!(result["severity_number"], 13);
        assert_eq!(result["severity_text"], "WARN");
        assert_eq!(result["body"], "This is a warning message from OTEL");
        assert_eq!(result["scope"], "my-instrumentation");
        
        // Check resource attributes
        assert_eq!(result["resource"]["service.name"], "my-service");
        assert_eq!(result["resource"]["service.version"], "1.0.0");
        
        // Check log attributes
        assert_eq!(result["attributes"]["http.method"], "GET");
        assert_eq!(result["attributes"]["http.status_code"], 404);
    }

    #[test]
    fn test_error_handling_invalid_protobuf() {
        let invalid_data = vec![0xFF, 0xFE, 0xFD, 0xFC]; // Invalid protobuf
        let result = otel_logs::otel_logs_to_json(&invalid_data);
        assert!(result.is_err());
        
        let error_msg = result.unwrap_err().to_string();
        assert!(error_msg.contains("failed to decode") || error_msg.contains("decode"));
    }

    #[test]
    fn test_complex_otel_log_with_nested_attributes() {
        use crate::otel_logs::opentelemetry::proto::{
            common::v1::{any_value::Value as AnyValueEnum, AnyValue, KeyValue, KeyValueList, ArrayValue},
            logs::v1::{LogRecord, LogsData, ResourceLogs, ScopeLogs},
            resource::v1::Resource,
        };

        let logs_data = LogsData {
            resource_logs: vec![ResourceLogs {
                resource: Some(Resource {
                    attributes: vec![],
                    dropped_attributes_count: 0,
                    entity_refs: vec![],
                }),
                scope_logs: vec![ScopeLogs {
                    scope: None,
                    log_records: vec![LogRecord {
                        time_unix_nano: 1640995200000000000,
                        observed_time_unix_nano: 1640995200000000000,
                        severity_number: 9,
                        severity_text: "INFO".to_string(),
                        body: Some(AnyValue {
                            value: Some(AnyValueEnum::StringValue("Complex log".to_string())),
                        }),
                        attributes: vec![
                            // Array attribute
                            KeyValue {
                                key: "tags".to_string(),
                                value: Some(AnyValue {
                                    value: Some(AnyValueEnum::ArrayValue(ArrayValue {
                                        values: vec![
                                            AnyValue {
                                                value: Some(AnyValueEnum::StringValue("tag1".to_string())),
                                            },
                                            AnyValue {
                                                value: Some(AnyValueEnum::StringValue("tag2".to_string())),
                                            },
                                        ],
                                    })),
                                }),
                            },
                            // Nested object attribute
                            KeyValue {
                                key: "metadata".to_string(),
                                value: Some(AnyValue {
                                    value: Some(AnyValueEnum::KvlistValue(KeyValueList {
                                        values: vec![
                                            KeyValue {
                                                key: "nested_key".to_string(),
                                                value: Some(AnyValue {
                                                    value: Some(AnyValueEnum::StringValue("nested_value".to_string())),
                                                }),
                                            },
                                            KeyValue {
                                                key: "number".to_string(),
                                                value: Some(AnyValue {
                                                    value: Some(AnyValueEnum::IntValue(42)),
                                                }),
                                            },
                                        ],
                                    })),
                                }),
                            },
                            // Binary data
                            KeyValue {
                                key: "binary_data".to_string(),
                                value: Some(AnyValue {
                                    value: Some(AnyValueEnum::BytesValue(vec![0x48, 0x65, 0x6c, 0x6c, 0x6f])), // "Hello"
                                }),
                            },
                        ],
                        dropped_attributes_count: 0,
                        flags: 0,
                        trace_id: vec![],
                        span_id: vec![],
                        event_name: "".to_string(),
                    }],
                    schema_url: "".to_string(),
                }],
                schema_url: "".to_string(),
            }],
        };

        let mut buf = Vec::new();
        logs_data.encode(&mut buf).unwrap();

        let result = otel_logs::otel_logs_to_json(&buf).unwrap();

        // Verify array conversion
        assert!(result["attributes"]["tags"].is_array());
        let tags = result["attributes"]["tags"].as_array().unwrap();
        assert_eq!(tags.len(), 2);
        assert_eq!(tags[0], "tag1");
        assert_eq!(tags[1], "tag2");

        // Verify nested object conversion
        assert!(result["attributes"]["metadata"].is_object());
        assert_eq!(result["attributes"]["metadata"]["nested_key"], "nested_value");
        assert_eq!(result["attributes"]["metadata"]["number"], 42);

        // Verify binary data conversion to base64
        assert!(result["attributes"]["binary_data"].is_string());
        let binary_str = result["attributes"]["binary_data"].as_str().unwrap();
        assert!(!binary_str.is_empty()); // Should be base64 encoded
    }
}