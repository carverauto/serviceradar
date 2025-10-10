use anyhow::Result;
use async_nats::jetstream::{self, Message};
use cloudevents::{EventBuilder, EventBuilderV10};
use log::debug;
use serde_json::Value;
use url::Url;
use uuid::Uuid;

use crate::config::{Config, MessageFormat};
use crate::engine::SharedEngine;
use crate::{otel_logs, otel_metrics};

pub async fn process_message(
    engine: &SharedEngine,
    cfg: &Config,
    js: &jetstream::Context,
    msg: &Message,
) -> Result<()> {
    debug!("processing message on subject {}", msg.subject);

    // Determine message format and parse accordingly
    let format = cfg.message_format_for_subject(&msg.subject);
    let mut context: serde_json::Value = match format {
        MessageFormat::Json => serde_json::from_slice(&msg.payload)?,
        MessageFormat::Protobuf => otel_logs::otel_logs_to_json(&msg.payload)?,
        MessageFormat::OtelMetrics => otel_metrics::otel_metrics_to_json(&msg.payload)?,
    };

    let rules = cfg.ordered_rules_for_subject(&msg.subject);
    let event_type = rules.last().map(String::as_str).unwrap_or("processed");

    for key in &rules {
        let dkey = format!("{}/{}/{}", cfg.stream_name, msg.subject, key);
        let resp = match engine.evaluate(&dkey, context.clone().into()).await {
            Ok(r) => r,
            Err(e) => {
                if let zen_engine::EvaluationError::LoaderError(le) = e.as_ref() {
                    if let zen_engine::loader::LoaderError::NotFound(_) = le.as_ref() {
                        debug!("rule {dkey} not found, skipping");
                        continue;
                    }
                }
                return Err(anyhow::anyhow!(e.to_string()));
            }
        };
        debug!("decision {dkey} evaluated");
        context = Value::from(resp.result);
    }

    if !rules.is_empty() {
        let ce = EventBuilderV10::new()
            .id(Uuid::new_v4().to_string())
            .source(Url::parse(&format!(
                "nats://{}/{}",
                cfg.stream_name, msg.subject
            ))?)
            .ty(event_type.to_string())
            .data("application/json", context)
            .build()?;

        let data = serde_json::to_vec(&ce)?;
        if let Some(suffix) = &cfg.result_subject_suffix {
            let result_subject = format!("{}.{}", msg.subject, suffix.trim_start_matches('.'));
            debug!("published result to {result_subject}");
            js.publish(result_subject, data.into()).await?.await?;
        } else if let Some(subject) = &cfg.result_subject {
            debug!("published result to {subject}");
            js.publish(subject.clone(), data.into()).await?.await?;
        }
    }

    Ok(())
}

#[cfg(test)]
mod tests {
    use crate::config::{Config, DecisionGroupConfig, MessageFormat, RuleEntry};
    use prost::Message;
    use serde_json::json;

    fn create_test_config() -> Config {
        Config {
            nats_url: "nats://localhost:4222".to_string(),
            domain: None,
            stream_name: "test-stream".to_string(),
            consumer_name: "test-consumer".to_string(),
            subjects: vec![
                "events.json".to_string(),
                "events.protobuf".to_string(),
                "events.metrics".to_string(),
            ],
            result_subject: None,
            result_subject_suffix: Some(".processed".to_string()),
            decision_keys: vec![],
            decision_groups: vec![
                DecisionGroupConfig {
                    name: "json_group".to_string(),
                    subjects: vec!["events.json".to_string()],
                    rules: vec![RuleEntry {
                        order: 1,
                        key: "test_rule".to_string(),
                    }],
                    format: MessageFormat::Json,
                },
                DecisionGroupConfig {
                    name: "protobuf_group".to_string(),
                    subjects: vec!["events.protobuf".to_string()],
                    rules: vec![RuleEntry {
                        order: 1,
                        key: "test_rule".to_string(),
                    }],
                    format: MessageFormat::Protobuf,
                },
                DecisionGroupConfig {
                    name: "metrics_group".to_string(),
                    subjects: vec!["events.metrics".to_string()],
                    rules: vec![RuleEntry {
                        order: 1,
                        key: "test_rule".to_string(),
                    }],
                    format: MessageFormat::OtelMetrics,
                },
            ],
            kv_bucket: "test-kv".to_string(),
            agent_id: "test-agent".to_string(),
            listen_addr: "0.0.0.0:50055".to_string(),
            security: None,
            grpc_security: None,
        }
    }

    fn create_otel_protobuf_data() -> Vec<u8> {
        use crate::otel_logs::opentelemetry::proto::{
            common::v1::{
                any_value::Value as AnyValueEnum, AnyValue, InstrumentationScope, KeyValue,
            },
            logs::v1::{LogRecord, LogsData, ResourceLogs, ScopeLogs},
            resource::v1::Resource,
        };

        let logs_data = LogsData {
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
                    log_records: vec![LogRecord {
                        time_unix_nano: 1234567890000000000,
                        observed_time_unix_nano: 1234567890000000000,
                        severity_number: 9,
                        severity_text: "INFO".to_string(),
                        body: Some(AnyValue {
                            value: Some(AnyValueEnum::StringValue(
                                "Test protobuf message".to_string(),
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
                schema_url: "".to_string(),
            }],
        };

        let mut buf = Vec::new();
        logs_data.encode(&mut buf).unwrap();
        buf
    }

    #[test]
    fn test_message_format_detection() {
        let cfg = create_test_config();

        assert_eq!(
            cfg.message_format_for_subject("events.json"),
            MessageFormat::Json
        );
        assert_eq!(
            cfg.message_format_for_subject("events.protobuf"),
            MessageFormat::Protobuf
        );
        assert_eq!(
            cfg.message_format_for_subject("events.metrics"),
            MessageFormat::OtelMetrics
        );
        assert_eq!(
            cfg.message_format_for_subject("events.unknown"),
            MessageFormat::Json
        );
    }

    #[test]
    fn test_json_message_parsing() {
        let json_data = json!({
            "message": "test json message",
            "level": "info"
        });
        let json_bytes = serde_json::to_vec(&json_data).unwrap();

        let parsed: serde_json::Value = serde_json::from_slice(&json_bytes).unwrap();
        assert_eq!(parsed["message"], "test json message");
        assert_eq!(parsed["level"], "info");
    }

    #[test]
    fn test_protobuf_message_parsing() {
        let protobuf_data = create_otel_protobuf_data();
        let result = crate::otel_logs::otel_logs_to_json(&protobuf_data).unwrap();

        assert_eq!(result["severity_text"], "INFO");
        assert_eq!(result["body"], "Test protobuf message");
        assert_eq!(result["timestamp"], 1234567890000000000u64);
    }

    #[test]
    fn test_metrics_message_parsing() {
        let protobuf_data = create_otel_metrics_data();
        let result = crate::otel_metrics::otel_metrics_to_json(&protobuf_data).unwrap();

        assert_eq!(result["resource_metric_count"], 1);
        let summaries = result["resource_summaries"].as_array().unwrap();
        assert_eq!(summaries.len(), 1);
        assert_eq!(summaries[0]["service_name"], "test-service");
        let scope_metrics = summaries[0]["scope_metrics"].as_array().unwrap();
        assert_eq!(scope_metrics.len(), 1);
        let metrics = scope_metrics[0]["metrics"].as_array().unwrap();
        assert_eq!(metrics.len(), 1);
        assert_eq!(metrics[0]["name"], "cpu.usage");
        assert_eq!(metrics[0]["data_type"], "gauge");
    }

    #[test]
    fn test_ordered_rules_for_subject() {
        let cfg = create_test_config();

        let json_rules = cfg.ordered_rules_for_subject("events.json");
        assert_eq!(json_rules, vec!["test_rule"]);

        let protobuf_rules = cfg.ordered_rules_for_subject("events.protobuf");
        assert_eq!(protobuf_rules, vec!["test_rule"]);

        let metrics_rules = cfg.ordered_rules_for_subject("events.metrics");
        assert_eq!(metrics_rules, vec!["test_rule"]);
    }

    fn create_otel_metrics_data() -> Vec<u8> {
        use crate::otel_metrics::opentelemetry::proto::{
            collector::metrics::v1::ExportMetricsServiceRequest,
            common::v1::{
                any_value::Value as AnyValueEnum, AnyValue, InstrumentationScope, KeyValue,
            },
            metrics::v1::{
                metric::Data as MetricData, number_data_point::Value as NumberValue, Gauge, Metric,
                NumberDataPoint, ResourceMetrics, ScopeMetrics,
            },
            resource::v1::Resource,
        };

        let request = ExportMetricsServiceRequest {
            resource_metrics: vec![ResourceMetrics {
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
                scope_metrics: vec![ScopeMetrics {
                    scope: Some(InstrumentationScope {
                        name: "test-scope".to_string(),
                        version: "1.0.0".to_string(),
                        attributes: vec![],
                        dropped_attributes_count: 0,
                    }),
                    metrics: vec![Metric {
                        name: "cpu.usage".to_string(),
                        description: "CPU usage".to_string(),
                        unit: "%".to_string(),
                        data: Some(MetricData::Gauge(Gauge {
                            data_points: vec![NumberDataPoint {
                                attributes: vec![],
                                start_time_unix_nano: 0,
                                time_unix_nano: 1,
                                exemplars: vec![],
                                flags: 0,
                                value: Some(NumberValue::AsDouble(19.5)),
                            }],
                        })),
                        metadata: vec![],
                    }],
                    schema_url: "".to_string(),
                }],
                schema_url: "".to_string(),
            }],
        };

        let mut buf = Vec::new();
        request.encode(&mut buf).unwrap();
        buf
    }
}
