use prost::Message;
use serde_json::{json, Value};

// Include the generated protobuf code
pub mod opentelemetry {
    pub mod proto {
        pub mod logs {
            pub mod v1 {
                include!(concat!(env!("OUT_DIR"), "/opentelemetry.proto.logs.v1.rs"));
            }
        }
        pub mod common {
            pub mod v1 {
                include!(concat!(env!("OUT_DIR"), "/opentelemetry.proto.common.v1.rs"));
            }
        }
        pub mod resource {
            pub mod v1 {
                include!(concat!(env!("OUT_DIR"), "/opentelemetry.proto.resource.v1.rs"));
            }
        }
    }
}

use opentelemetry::proto::logs::v1::LogsData;

/// Convert OTEL protobuf logs to JSON
pub fn otel_logs_to_json(data: &[u8]) -> anyhow::Result<Value> {
    let logs_data = LogsData::decode(data)?;
    
    let mut logs = Vec::new();
    
    for resource_logs in logs_data.resource_logs {
        let resource_attrs = resource_logs
            .resource
            .as_ref()
            .map(|r| attributes_to_json(&r.attributes))
            .unwrap_or_default();
            
        for scope_logs in resource_logs.scope_logs {
            let scope_name = scope_logs
                .scope
                .as_ref()
                .map(|s| s.name.clone())
                .unwrap_or_default();
                
            for log_record in scope_logs.log_records {
                let mut log_json = json!({
                    "timestamp": log_record.time_unix_nano,
                    "severity_number": log_record.severity_number,
                    "severity_text": log_record.severity_text,
                    "resource": resource_attrs.clone(),
                    "scope": scope_name.clone(),
                });
                
                if let Some(body) = log_record.body {
                    log_json["body"] = any_value_to_json(&body);
                }
                
                if !log_record.attributes.is_empty() {
                    log_json["attributes"] = attributes_to_json(&log_record.attributes);
                }
                
                logs.push(log_json);
            }
        }
    }
    
    // If there's only one log, return it directly, otherwise return array
    if logs.len() == 1 {
        Ok(logs.into_iter().next().unwrap())
    } else {
        Ok(json!(logs))
    }
}

fn attributes_to_json(attrs: &[opentelemetry::proto::common::v1::KeyValue]) -> Value {
    let mut map = serde_json::Map::new();
    for attr in attrs {
        if let Some(value) = &attr.value {
            map.insert(attr.key.clone(), any_value_to_json(value));
        }
    }
    Value::Object(map)
}

fn any_value_to_json(value: &opentelemetry::proto::common::v1::AnyValue) -> Value {
    use opentelemetry::proto::common::v1::any_value::Value as AnyValueEnum;
    
    match &value.value {
        Some(AnyValueEnum::StringValue(s)) => json!(s),
        Some(AnyValueEnum::BoolValue(b)) => json!(b),
        Some(AnyValueEnum::IntValue(i)) => json!(i),
        Some(AnyValueEnum::DoubleValue(d)) => json!(d),
        Some(AnyValueEnum::ArrayValue(arr)) => {
            let values: Vec<Value> = arr
                .values
                .iter()
                .map(any_value_to_json)
                .collect();
            json!(values)
        }
        Some(AnyValueEnum::KvlistValue(kv)) => attributes_to_json(&kv.values),
        Some(AnyValueEnum::BytesValue(bytes)) => {
            // Convert bytes to base64 string
            use base64::Engine;
            json!(base64::engine::general_purpose::STANDARD.encode(bytes))
        }
        None => Value::Null,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use prost::Message;
    use serde_json::json;

    fn create_test_log_record() -> opentelemetry::proto::logs::v1::LogRecord {
        use opentelemetry::proto::common::v1::{any_value::Value as AnyValueEnum, AnyValue, KeyValue};
        
        opentelemetry::proto::logs::v1::LogRecord {
            time_unix_nano: 1234567890000000000,
            observed_time_unix_nano: 1234567890000000000,
            severity_number: 9, // INFO level
            severity_text: "INFO".to_string(),
            body: Some(AnyValue {
                value: Some(AnyValueEnum::StringValue("Test log message".to_string())),
            }),
            attributes: vec![
                KeyValue {
                    key: "service.name".to_string(),
                    value: Some(AnyValue {
                        value: Some(AnyValueEnum::StringValue("test-service".to_string())),
                    }),
                },
                KeyValue {
                    key: "log.level".to_string(),
                    value: Some(AnyValue {
                        value: Some(AnyValueEnum::StringValue("info".to_string())),
                    }),
                },
            ],
            dropped_attributes_count: 0,
            flags: 0,
            trace_id: vec![],
            span_id: vec![],
            event_name: "".to_string(),
        }
    }

    fn create_test_logs_data() -> opentelemetry::proto::logs::v1::LogsData {
        use opentelemetry::proto::common::v1::{any_value::Value as AnyValueEnum, AnyValue, KeyValue, InstrumentationScope};
        use opentelemetry::proto::resource::v1::Resource;
        use opentelemetry::proto::logs::v1::{ResourceLogs, ScopeLogs};

        opentelemetry::proto::logs::v1::LogsData {
            resource_logs: vec![ResourceLogs {
                resource: Some(Resource {
                    attributes: vec![KeyValue {
                        key: "service.name".to_string(),
                        value: Some(AnyValue {
                            value: Some(AnyValueEnum::StringValue("test-service".to_string())),
                        }),
                    }],
                    dropped_attributes_count: 0,
                    entity_refs: vec![],
                }),
                scope_logs: vec![ScopeLogs {
                    scope: Some(InstrumentationScope {
                        name: "test-scope".to_string(),
                        version: "1.0.0".to_string(),
                        attributes: vec![],
                        dropped_attributes_count: 0,
                    }),
                    log_records: vec![create_test_log_record()],
                    schema_url: "".to_string(),
                }],
                schema_url: "".to_string(),
            }],
        }
    }

    #[test]
    fn test_otel_logs_to_json_single_log() {
        let logs_data = create_test_logs_data();
        let mut buf = Vec::new();
        logs_data.encode(&mut buf).unwrap();

        let result = otel_logs_to_json(&buf).unwrap();
        
        assert_eq!(result["timestamp"], 1234567890000000000u64);
        assert_eq!(result["severity_number"], 9);
        assert_eq!(result["severity_text"], "INFO");
        assert_eq!(result["body"], "Test log message");
        assert_eq!(result["scope"], "test-scope");
        assert_eq!(result["resource"]["service.name"], "test-service");
        assert_eq!(result["attributes"]["service.name"], "test-service");
        assert_eq!(result["attributes"]["log.level"], "info");
    }

    #[test]
    fn test_otel_logs_to_json_multiple_logs() {
        let mut logs_data = create_test_logs_data();
        
        // Add another log record
        let mut second_log = create_test_log_record();
        second_log.severity_text = "ERROR".to_string();
        second_log.severity_number = 17; // ERROR level
        
        logs_data.resource_logs[0].scope_logs[0].log_records.push(second_log);
        
        let mut buf = Vec::new();
        logs_data.encode(&mut buf).unwrap();

        let result = otel_logs_to_json(&buf).unwrap();
        
        // Should return an array when multiple logs
        assert!(result.is_array());
        let logs_array = result.as_array().unwrap();
        assert_eq!(logs_array.len(), 2);
        
        assert_eq!(logs_array[0]["severity_text"], "INFO");
        assert_eq!(logs_array[1]["severity_text"], "ERROR");
    }

    #[test]
    fn test_any_value_to_json_different_types() {
        use opentelemetry::proto::common::v1::{any_value::Value as AnyValueEnum, AnyValue};
        
        // String value
        let string_val = AnyValue {
            value: Some(AnyValueEnum::StringValue("test".to_string())),
        };
        assert_eq!(any_value_to_json(&string_val), json!("test"));
        
        // Boolean value
        let bool_val = AnyValue {
            value: Some(AnyValueEnum::BoolValue(true)),
        };
        assert_eq!(any_value_to_json(&bool_val), json!(true));
        
        // Integer value
        let int_val = AnyValue {
            value: Some(AnyValueEnum::IntValue(42)),
        };
        assert_eq!(any_value_to_json(&int_val), json!(42));
        
        // Double value
        let double_val = AnyValue {
            value: Some(AnyValueEnum::DoubleValue(3.14)),
        };
        assert_eq!(any_value_to_json(&double_val), json!(3.14));
        
        // Bytes value
        let bytes_val = AnyValue {
            value: Some(AnyValueEnum::BytesValue(vec![72, 101, 108, 108, 111])), // "Hello"
        };
        let result = any_value_to_json(&bytes_val);
        assert!(result.is_string());
        
        // Null value
        let null_val = AnyValue { value: None };
        assert_eq!(any_value_to_json(&null_val), Value::Null);
    }

    #[test]
    fn test_malformed_protobuf() {
        let invalid_data = vec![0xFF, 0xFE, 0xFD]; // Invalid protobuf data
        let result = otel_logs_to_json(&invalid_data);
        assert!(result.is_err());
    }

    #[test]
    fn test_empty_logs_data() {
        let logs_data = opentelemetry::proto::logs::v1::LogsData {
            resource_logs: vec![],
        };
        let mut buf = Vec::new();
        logs_data.encode(&mut buf).unwrap();

        let result = otel_logs_to_json(&buf).unwrap();
        assert_eq!(result, json!([]));
    }
}