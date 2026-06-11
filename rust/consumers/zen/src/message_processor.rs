use anyhow::Result;
use async_nats::jetstream::{self, Message};
use async_nats::HeaderMap;
use log::debug;
use serde_json::Value;

use crate::config::{Config, MessageFormat};
use crate::engine::SharedEngine;
use crate::rule_discovery;
use crate::telemetry;
use crate::{flow_proto, otel_logs, otel_metrics};

pub async fn process_message(
    engine: &SharedEngine,
    cfg: &Config,
    js: &jetstream::Context,
    msg: &Message,
) -> Result<()> {
    debug!("processing message on subject {}", msg.subject);

    // Determine message format and parse accordingly
    let format = cfg.message_format_for_subject(&msg.subject);
    let counters = telemetry::counters_for_format(&format);

    // Count each message once, on its first delivery, so NAK-driven
    // redeliveries do not inflate the received counter.
    let first_delivery = msg.info().map(|info| info.delivered <= 1).unwrap_or(true);
    if first_delivery {
        if let Some(counters) = counters {
            counters.record_received();
        }
    }

    let mut context: serde_json::Value = match format {
        MessageFormat::Json => serde_json::from_slice(&msg.payload)?,
        MessageFormat::Protobuf => otel_logs::otel_logs_to_json(&msg.payload)?,
        MessageFormat::OtelMetrics => otel_metrics::otel_metrics_to_json(&msg.payload)?,
        MessageFormat::FlowProtobuf => flow_proto::flow_to_json(&msg.payload)?,
    };

    let rule_subject = cfg.subject_for_rule_lookup(&msg.subject);
    let rules = rule_discovery::ordered_rules_for_subject(cfg, js, &msg.subject).await?;
    for key in &rules {
        let dkey = format!("{}/{}/{}", cfg.stream_name, rule_subject, key);
        let previous_context = context.clone();
        let resp = match engine
            .evaluate(&dkey, previous_context.clone().into())
            .await
        {
            Ok(r) => r,
            Err(e) => {
                if matches!(
                    e.as_ref(),
                    zen_engine::EvaluationError::LoaderError(le)
                        if matches!(le, zen_engine::loader::LoaderError::NotFound(_))
                ) {
                    debug!("rule {dkey} not found, skipping");
                    continue;
                }

                let message = match e.as_ref() {
                    zen_engine::EvaluationError::LoaderError(le) => {
                        format!("failed to load rule {dkey}: {le}")
                    }
                    _ => format!("failed to evaluate rule {dkey}: {e}"),
                };

                return Err(anyhow::anyhow!(message));
            }
        };
        debug!("decision {dkey} evaluated");
        context = merge_rule_result(previous_context, Value::from(resp.result));
    }

    // Passthrough-by-default: an OTEL log message with NO decision rules at
    // all (none configured, none discovered in KV) used to be
    // consumed-and-ACKed without republishing — a silent drop that made
    // fresh installs depend on a KV bootstrap rule. Republish the converted
    // JSON unchanged instead, unless strict mode is configured
    // (`passthrough_when_unmatched: false`).
    let passthrough = passthrough_applies(cfg, &format, &rules);

    if !rules.is_empty() || passthrough {
        let data = serde_json::to_vec(&context)?;

        // Copy attribution (Sr-*) and trace-context headers from the consumed
        // message onto the republished one. The central collector and edge
        // relay stamp those headers on the original message; downstream
        // consumers (e.g. the db-event-writer) read them off zen's
        // republished messages, so dropping them here would lose attribution
        // at the zen hop.
        let mut headers = HeaderMap::new();
        copy_forward_headers(msg.headers.as_ref(), &mut headers);

        let result_subject = if let Some(suffix) = &cfg.result_subject_suffix {
            Some(format!(
                "{}.{}",
                msg.subject,
                suffix.trim_start_matches('.')
            ))
        } else {
            cfg.result_subject.clone()
        };

        if let Some(result_subject) = result_subject {
            debug!("published result to {result_subject}");
            if headers.is_empty() {
                js.publish(result_subject, data.into()).await?.await?;
            } else {
                js.publish_with_headers(result_subject, headers, data.into())
                    .await?
                    .await?;
            }

            if let Some(counters) = counters {
                counters.record_forwarded();
                if passthrough {
                    counters.record_passthrough();
                    debug!(
                        "no decision rules for {}; republished unchanged (passthrough)",
                        msg.subject
                    );
                }
            }
        }
    }

    Ok(())
}

/// Headers copied through from the consumed message to every republished
/// message: ServiceRadar attribution headers stamped by the central collector
/// and edge relay, plus W3C trace context so the trace survives the zen hop.
const FORWARDED_HEADERS: [&str; 5] = [
    "Sr-Ingest-Identity",
    "Sr-Agent-Id",
    "Sr-Partition",
    "traceparent",
    "tracestate",
];

/// Copy the forwardable headers from the consumed message into `outgoing`.
///
/// Incoming header names are matched case-insensitively and written with
/// canonical casing. Headers absent upstream are simply not set, and headers
/// already present in `outgoing` (set by zen itself) are preserved.
pub(crate) fn copy_forward_headers(incoming: Option<&HeaderMap>, outgoing: &mut HeaderMap) {
    let Some(incoming) = incoming else {
        return;
    };

    for canonical in FORWARDED_HEADERS {
        if outgoing.get(canonical).is_some() {
            continue;
        }

        for (name, values) in incoming.iter() {
            let name: &str = name.as_ref();
            if name.eq_ignore_ascii_case(canonical) {
                for value in values {
                    outgoing.append(canonical, value.clone());
                }
            }
        }
    }
}

/// True when an OTEL log message with no decision rules should be
/// republished unchanged instead of silently dropped.
pub(crate) fn passthrough_applies(cfg: &Config, format: &MessageFormat, rules: &[String]) -> bool {
    rules.is_empty() && cfg.passthrough_when_unmatched && *format == MessageFormat::Protobuf
}

pub(crate) fn merge_rule_result(previous: Value, result: Value) -> Value {
    match (previous, result) {
        (Value::Object(mut previous), Value::Object(result)) => {
            for (key, value) in result {
                let merged = match (previous.remove(&key), value) {
                    (Some(Value::Object(previous_nested)), Value::Object(result_nested)) => {
                        merge_rule_result(
                            Value::Object(previous_nested),
                            Value::Object(result_nested),
                        )
                    }
                    (_, value) => value,
                };

                previous.insert(key, merged);
            }

            Value::Object(previous)
        }
        (_, result) => result,
    }
}

#[cfg(test)]
mod tests {
    use crate::config::{Config, DecisionGroupConfig, MessageFormat, RuleEntry};
    use async_nats::HeaderMap;
    use prost::Message;
    use serde_json::json;

    fn create_test_config() -> Config {
        Config {
            nats_url: "nats://localhost:4222".to_string(),
            domain: None,
            stream_name: "test-stream".to_string(),
            stream_replicas: 1,
            consumer_name: "test-consumer".to_string(),
            subjects: vec![
                "events.json".to_string(),
                "events.protobuf".to_string(),
                "events.metrics".to_string(),
            ],
            subject_prefix: None,
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
            discover_rules_from_kv: false,
            passthrough_when_unmatched: true,
            nats_creds_file: None,
            kv_bucket: "test-kv".to_string(),
            agent_id: "test-agent".to_string(),
            listen_addr: None,
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
    fn test_rule_results_overlay_previous_context() {
        let previous = json!({
            "host": "docker-mailserver",
            "short_message": "dovecot: disconnected",
            "attributes": {
                "serviceradar.ingest": {
                    "subject": "logs.syslog"
                }
            }
        });

        let result = json!({
            "severity": "Unknown",
            "attributes": {
                "waf": {
                    "rule_id": null
                }
            }
        });

        let merged = super::merge_rule_result(previous, result);

        assert_eq!(merged["host"], "docker-mailserver");
        assert_eq!(merged["short_message"], "dovecot: disconnected");
        assert_eq!(merged["severity"], "Unknown");
        assert_eq!(
            merged["attributes"]["serviceradar.ingest"]["subject"],
            "logs.syslog"
        );
        assert!(merged["attributes"]["waf"]["rule_id"].is_null());
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
    fn passthrough_applies_only_to_unmatched_otel_logs() {
        let mut cfg = create_test_config();

        // No rules + otel log format + flag on => passthrough.
        assert!(super::passthrough_applies(
            &cfg,
            &MessageFormat::Protobuf,
            &[]
        ));

        // Rules present => the normal evaluation path publishes.
        assert!(!super::passthrough_applies(
            &cfg,
            &MessageFormat::Protobuf,
            &["some_rule".to_string()]
        ));

        // Non-otel-log formats keep their existing behavior.
        assert!(!super::passthrough_applies(&cfg, &MessageFormat::Json, &[]));
        assert!(!super::passthrough_applies(
            &cfg,
            &MessageFormat::OtelMetrics,
            &[]
        ));
        assert!(!super::passthrough_applies(
            &cfg,
            &MessageFormat::FlowProtobuf,
            &[]
        ));

        // Strict mode restores the old consumed-and-ACKed drop.
        cfg.passthrough_when_unmatched = false;
        assert!(!super::passthrough_applies(
            &cfg,
            &MessageFormat::Protobuf,
            &[]
        ));
    }

    #[test]
    fn forwarded_headers_copied_case_insensitively_with_canonical_casing() {
        let mut incoming = HeaderMap::new();
        incoming.insert("sr-ingest-identity", "spiffe://example/central-collector");
        incoming.insert("SR-AGENT-ID", "agent-1");
        incoming.insert("Sr-Partition", "partition-a");
        incoming.insert(
            "TraceParent",
            "00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01",
        );
        incoming.insert("tracestate", "vendor=foo");
        incoming.append("tracestate", "other=bar");
        // Unrelated upstream headers must not be copied through (re-sending
        // e.g. Nats-Msg-Id would collide with JetStream dedupe).
        incoming.insert("Nats-Msg-Id", "dedupe-key");

        let mut outgoing = HeaderMap::new();
        super::copy_forward_headers(Some(&incoming), &mut outgoing);

        assert_eq!(
            outgoing.get("Sr-Ingest-Identity").map(|v| v.as_str()),
            Some("spiffe://example/central-collector")
        );
        assert_eq!(
            outgoing.get("Sr-Agent-Id").map(|v| v.as_str()),
            Some("agent-1")
        );
        assert_eq!(
            outgoing.get("Sr-Partition").map(|v| v.as_str()),
            Some("partition-a")
        );
        assert_eq!(
            outgoing.get("traceparent").map(|v| v.as_str()),
            Some("00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01")
        );

        // Multi-valued headers keep every value.
        let tracestate: Vec<&str> = outgoing.get_all("tracestate").map(|v| v.as_str()).collect();
        assert_eq!(tracestate, vec!["vendor=foo", "other=bar"]);

        // Written with canonical casing, not whatever casing arrived.
        assert!(outgoing.get("SR-AGENT-ID").is_none());
        assert!(outgoing.get("sr-ingest-identity").is_none());
        assert!(outgoing.get("TraceParent").is_none());

        // Unrelated headers stay behind.
        assert!(outgoing.get("Nats-Msg-Id").is_none());
    }

    #[test]
    fn absent_forwarded_headers_are_not_set() {
        // No incoming header block at all.
        let mut outgoing = HeaderMap::new();
        super::copy_forward_headers(None, &mut outgoing);
        assert!(outgoing.is_empty());

        // Incoming headers present, but none forwardable.
        let mut incoming = HeaderMap::new();
        incoming.insert("Nats-Msg-Id", "dedupe-key");
        let mut outgoing = HeaderMap::new();
        super::copy_forward_headers(Some(&incoming), &mut outgoing);
        assert!(outgoing.is_empty());

        // Partial set: only the headers actually present are copied.
        let mut incoming = HeaderMap::new();
        incoming.insert("Sr-Agent-Id", "agent-1");
        let mut outgoing = HeaderMap::new();
        super::copy_forward_headers(Some(&incoming), &mut outgoing);
        assert_eq!(
            outgoing.get("Sr-Agent-Id").map(|v| v.as_str()),
            Some("agent-1")
        );
        assert!(outgoing.get("Sr-Ingest-Identity").is_none());
        assert!(outgoing.get("Sr-Partition").is_none());
        assert!(outgoing.get("traceparent").is_none());
        assert!(outgoing.get("tracestate").is_none());
    }

    #[test]
    fn existing_outgoing_headers_are_preserved() {
        let mut incoming = HeaderMap::new();
        incoming.insert("Sr-Agent-Id", "upstream-agent");
        incoming.insert("Sr-Partition", "upstream-partition");

        let mut outgoing = HeaderMap::new();
        outgoing.insert("Sr-Agent-Id", "zen-set-agent");
        outgoing.insert("X-Zen-Rule", "matched");

        super::copy_forward_headers(Some(&incoming), &mut outgoing);

        // Headers zen already set win over the upstream copy...
        assert_eq!(
            outgoing.get("Sr-Agent-Id").map(|v| v.as_str()),
            Some("zen-set-agent")
        );
        assert_eq!(
            outgoing.get("X-Zen-Rule").map(|v| v.as_str()),
            Some("matched")
        );
        // ...while everything else still copies through.
        assert_eq!(
            outgoing.get("Sr-Partition").map(|v| v.as_str()),
            Some("upstream-partition")
        );
    }

    #[test]
    fn passthrough_republish_carries_forwarded_headers() {
        // The passthrough branch republished through the same publish path
        // as rule-matched messages, so an unmatched OTEL log message keeps
        // its attribution headers too.
        let cfg = create_test_config();
        assert!(super::passthrough_applies(
            &cfg,
            &MessageFormat::Protobuf,
            &[]
        ));

        let mut incoming = HeaderMap::new();
        incoming.insert("sr-ingest-identity", "spiffe://example/edge-relay");
        incoming.insert("Sr-Agent-Id", "agent-7");
        incoming.insert(
            "traceparent",
            "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01",
        );

        let mut outgoing = HeaderMap::new();
        super::copy_forward_headers(Some(&incoming), &mut outgoing);

        assert_eq!(
            outgoing.get("Sr-Ingest-Identity").map(|v| v.as_str()),
            Some("spiffe://example/edge-relay")
        );
        assert_eq!(
            outgoing.get("Sr-Agent-Id").map(|v| v.as_str()),
            Some("agent-7")
        );
        assert_eq!(
            outgoing.get("traceparent").map(|v| v.as_str()),
            Some("00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01")
        );
    }

    #[test]
    fn test_configured_rules_for_subject() {
        let cfg = create_test_config();

        let json_rules = cfg.configured_rules_for_subject("events.json");
        assert_eq!(json_rules, vec!["test_rule"]);

        let protobuf_rules = cfg.configured_rules_for_subject("events.protobuf");
        assert_eq!(protobuf_rules, vec!["test_rule"]);

        let metrics_rules = cfg.configured_rules_for_subject("events.metrics");
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
