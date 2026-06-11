use prost::Message;
use serde_json::{json, Value};
use std::fmt::Write;

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
                include!(concat!(
                    env!("OUT_DIR"),
                    "/opentelemetry.proto.common.v1.rs"
                ));
            }
        }
        pub mod resource {
            pub mod v1 {
                include!(concat!(
                    env!("OUT_DIR"),
                    "/opentelemetry.proto.resource.v1.rs"
                ));
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

        let service_name = get_attr_string(&resource_attrs, "service.name");
        let service_version = get_attr_string(&resource_attrs, "service.version");
        let service_instance = get_attr_string(&resource_attrs, "service.instance.id");

        for scope_logs in resource_logs.scope_logs {
            let scope_name = scope_logs
                .scope
                .as_ref()
                .map(|s| s.name.clone())
                .unwrap_or_default();
            let scope_version = scope_logs
                .scope
                .as_ref()
                .map(|s| s.version.clone())
                .unwrap_or_default();
            let scope_attributes = scope_logs
                .scope
                .as_ref()
                .map(|s| attributes_to_json(&s.attributes))
                .unwrap_or_else(|| json!({}));

            for log_record in scope_logs.log_records {
                let timestamp = if log_record.time_unix_nano > 0 {
                    log_record.time_unix_nano
                } else {
                    log_record.observed_time_unix_nano
                };

                let mut log_json = json!({
                    "timestamp": timestamp,
                    "observed_time_unix_nano": log_record.observed_time_unix_nano,
                    "severity_number": log_record.severity_number,
                    "severity_text": log_record.severity_text,
                    "resource_attributes": resource_attrs.clone(),
                    "scope_attributes": scope_attributes.clone(),
                    "trace_flags": (log_record.flags & 0xFF),
                    "event_name": log_record.event_name,
                });

                log_json["resource"] = resource_attrs.clone();

                if !service_name.is_empty() {
                    log_json["service_name"] = json!(service_name);
                }
                if !service_version.is_empty() {
                    log_json["service_version"] = json!(service_version);
                }
                if !service_instance.is_empty() {
                    log_json["service_instance"] = json!(service_instance);
                }

                if !scope_name.is_empty() {
                    log_json["scope_name"] = json!(scope_name);
                    log_json["scope"] = json!(scope_name);
                }
                if !scope_version.is_empty() {
                    log_json["scope_version"] = json!(scope_version);
                }

                if let Some(trace_id) = normalize_id(&log_record.trace_id, TRACE_ID_LEN) {
                    log_json["trace_id"] = json!(trace_id);
                }
                if let Some(span_id) = normalize_id(&log_record.span_id, SPAN_ID_LEN) {
                    log_json["span_id"] = json!(span_id);
                }

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

fn get_attr_string(attrs: &Value, key: &str) -> String {
    match attrs {
        Value::Object(map) => map
            .get(key)
            .and_then(|value| value.as_str())
            .unwrap_or_default()
            .to_string(),
        _ => String::new(),
    }
}

/// Expected raw byte length of an OTLP trace id (canonical hex is 32 chars).
const TRACE_ID_LEN: usize = 16;
/// Expected raw byte length of an OTLP span id (canonical hex is 16 chars).
const SPAN_ID_LEN: usize = 8;

/// Normalize an OTLP id `bytes` field into canonical lowercase hex.
///
/// Producers are supposed to ship raw bytes (16 for trace ids, 8 for span
/// ids), but some exporters — notably the Erlang/Elixir OTLP logs exporter —
/// place the ASCII hex TEXT of the id in the protobuf bytes field. Naively
/// hexing those bytes produces double-hex ids that can never join back to
/// traces. This helper accepts:
///
/// - `expected_len` raw bytes        -> hex-encode (canonical)
/// - `2 * expected_len` ASCII hex    -> pass through, lowercased
/// - `4 * expected_len` ASCII hex    -> hex of ASCII hex; decode one layer,
///   then pass through, lowercased
///
/// Empty input, all-zero ids (invalid per the OTLP spec), and anything that
/// does not match one of the shapes above yield `None`.
fn normalize_id(bytes: &[u8], expected_len: usize) -> Option<String> {
    if bytes.is_empty() {
        return None;
    }

    let hex_id = if bytes.len() == expected_len {
        // Raw bytes (the spec-conformant shape): hex-encode.
        let mut out = String::with_capacity(bytes.len() * 2);
        for byte in bytes {
            let _ = write!(out, "{byte:02x}");
        }
        out
    } else if bytes.len() == 2 * expected_len && bytes.iter().all(u8::is_ascii_hexdigit) {
        // ASCII hex text shipped in the bytes field: pass through.
        String::from_utf8(bytes.to_vec()).ok()?.to_ascii_lowercase()
    } else if bytes.len() == 4 * expected_len && bytes.iter().all(u8::is_ascii_hexdigit) {
        // Hex of ASCII hex (already double-encoded upstream): decode one
        // layer, then require the result to be ASCII hex text.
        let decoded = decode_ascii_hex(bytes)?;
        if !decoded.iter().all(u8::is_ascii_hexdigit) {
            return None;
        }
        String::from_utf8(decoded).ok()?.to_ascii_lowercase()
    } else {
        return None;
    };

    // All-zero ids are "absent" per the OTLP/W3C trace-context specs.
    if hex_id.bytes().all(|b| b == b'0') {
        return None;
    }

    Some(hex_id)
}

/// Decode an even-length ASCII hex string into raw bytes.
fn decode_ascii_hex(bytes: &[u8]) -> Option<Vec<u8>> {
    fn nibble(b: u8) -> Option<u8> {
        (b as char).to_digit(16).map(|d| d as u8)
    }

    if !bytes.len().is_multiple_of(2) {
        return None;
    }

    let mut out = Vec::with_capacity(bytes.len() / 2);
    for pair in bytes.chunks_exact(2) {
        out.push((nibble(pair[0])? << 4) | nibble(pair[1])?);
    }
    Some(out)
}

fn any_value_to_json(value: &opentelemetry::proto::common::v1::AnyValue) -> Value {
    use opentelemetry::proto::common::v1::any_value::Value as AnyValueEnum;

    match &value.value {
        Some(AnyValueEnum::StringValue(s)) => json!(s),
        Some(AnyValueEnum::BoolValue(b)) => json!(b),
        Some(AnyValueEnum::IntValue(i)) => json!(i),
        Some(AnyValueEnum::DoubleValue(d)) => json!(d),
        Some(AnyValueEnum::ArrayValue(arr)) => {
            let values: Vec<Value> = arr.values.iter().map(any_value_to_json).collect();
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
        use opentelemetry::proto::common::v1::{
            any_value::Value as AnyValueEnum, AnyValue, KeyValue,
        };

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
        use opentelemetry::proto::common::v1::{
            any_value::Value as AnyValueEnum, AnyValue, InstrumentationScope, KeyValue,
        };
        use opentelemetry::proto::logs::v1::{ResourceLogs, ScopeLogs};
        use opentelemetry::proto::resource::v1::Resource;

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
        assert_eq!(result["scope_name"], "test-scope");
        assert_eq!(result["scope_version"], "1.0.0");
        assert_eq!(
            result["resource_attributes"]["service.name"],
            "test-service"
        );
        assert_eq!(result["service_name"], "test-service");
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

        logs_data.resource_logs[0].scope_logs[0]
            .log_records
            .push(second_log);

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
            value: Some(AnyValueEnum::DoubleValue(2.5)),
        };
        assert_eq!(any_value_to_json(&double_val), json!(2.5));

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
    fn test_normalize_id_raw_bytes() {
        let trace_bytes: Vec<u8> = (1..=16).collect();
        assert_eq!(
            normalize_id(&trace_bytes, 16).as_deref(),
            Some("0102030405060708090a0b0c0d0e0f10")
        );

        let span_bytes: Vec<u8> = (1..=8).collect();
        assert_eq!(
            normalize_id(&span_bytes, 8).as_deref(),
            Some("0102030405060708")
        );
    }

    #[test]
    fn test_normalize_id_ascii_hex_passthrough() {
        // The Erlang OTLP exporter ships the ASCII hex TEXT of the id in the
        // protobuf bytes field: 32 ASCII chars for a trace id.
        let ascii_hex = b"66353863AbCdEf001122334455667788";
        assert_eq!(
            normalize_id(ascii_hex, 16).as_deref(),
            Some("66353863abcdef001122334455667788")
        );

        let ascii_hex_span = b"AABBCCDD00112233";
        assert_eq!(
            normalize_id(ascii_hex_span, 8).as_deref(),
            Some("aabbccdd00112233")
        );
    }

    #[test]
    fn test_normalize_id_double_hex() {
        // Hex of the ASCII hex string: 64 bytes for a trace id. Decoding one
        // layer must recover the original 32-char id.
        let original = "66353863abcdef001122334455667788";
        let double_hex: Vec<u8> = original
            .bytes()
            .flat_map(|b| format!("{b:02x}").into_bytes())
            .collect();
        assert_eq!(double_hex.len(), 64);
        assert_eq!(normalize_id(&double_hex, 16).as_deref(), Some(original));

        let span_original = "aabbccdd00112233";
        let span_double_hex: Vec<u8> = span_original
            .bytes()
            .flat_map(|b| format!("{b:02x}").into_bytes())
            .collect();
        assert_eq!(span_double_hex.len(), 32);
        assert_eq!(
            normalize_id(&span_double_hex, 8).as_deref(),
            Some(span_original)
        );
    }

    #[test]
    fn test_normalize_id_zeros_rejected() {
        // Raw all-zero bytes.
        assert_eq!(normalize_id(&[0u8; 16], 16), None);
        assert_eq!(normalize_id(&[0u8; 8], 8), None);
        // ASCII hex all-zero text.
        assert_eq!(normalize_id(&[b'0'; 32], 16), None);
        // Double-hex of an all-zero ASCII id ("30" repeated 32 times).
        let double_zero: Vec<u8> = std::iter::repeat_n([b'3', b'0'], 32).flatten().collect();
        assert_eq!(double_zero.len(), 64);
        assert_eq!(normalize_id(&double_zero, 16), None);
    }

    #[test]
    fn test_normalize_id_empty_and_garbage() {
        // Empty.
        assert_eq!(normalize_id(&[], 16), None);
        // Wrong lengths.
        assert_eq!(normalize_id(&[1, 2, 3], 16), None);
        assert_eq!(normalize_id(&[1u8; 15], 16), None);
        assert_eq!(normalize_id(&[1u8; 33], 16), None);
        // 2x length but not ASCII hex.
        assert_eq!(normalize_id(&[b'z'; 32], 16), None);
        // 4x length but not ASCII hex.
        assert_eq!(normalize_id(&[b'!'; 64], 16), None);
        // 4x length ASCII hex that decodes to non-hex bytes (e.g. 0xff).
        assert_eq!(normalize_id(&[b'f'; 64], 16), None);
    }

    #[test]
    fn test_otel_logs_to_json_normalizes_ascii_hex_ids() {
        let mut logs_data = create_test_logs_data();
        let record = &mut logs_data.resource_logs[0].scope_logs[0].log_records[0];
        // Simulate the Erlang exporter: ASCII hex text in the bytes fields.
        record.trace_id = b"66353863ABCDEF001122334455667788".to_vec();
        record.span_id = b"AABBCCDD00112233".to_vec();

        let mut buf = Vec::new();
        logs_data.encode(&mut buf).unwrap();

        let result = otel_logs_to_json(&buf).unwrap();
        assert_eq!(result["trace_id"], "66353863abcdef001122334455667788");
        assert_eq!(result["span_id"], "aabbccdd00112233");
    }

    #[test]
    fn test_otel_logs_to_json_raw_byte_ids() {
        let mut logs_data = create_test_logs_data();
        let record = &mut logs_data.resource_logs[0].scope_logs[0].log_records[0];
        record.trace_id = (1..=16).collect();
        record.span_id = (1..=8).collect();

        let mut buf = Vec::new();
        logs_data.encode(&mut buf).unwrap();

        let result = otel_logs_to_json(&buf).unwrap();
        assert_eq!(result["trace_id"], "0102030405060708090a0b0c0d0e0f10");
        assert_eq!(result["span_id"], "0102030405060708");
    }

    #[test]
    fn test_otel_logs_to_json_omits_invalid_ids() {
        let mut logs_data = create_test_logs_data();
        let record = &mut logs_data.resource_logs[0].scope_logs[0].log_records[0];
        record.trace_id = vec![0u8; 16]; // all-zero = absent
        record.span_id = vec![1, 2, 3]; // garbage length

        let mut buf = Vec::new();
        logs_data.encode(&mut buf).unwrap();

        let result = otel_logs_to_json(&buf).unwrap();
        assert!(result.get("trace_id").is_none());
        assert!(result.get("span_id").is_none());
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
