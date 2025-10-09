use anyhow::Result;
use prost::Message;
use serde_json::{json, Map, Value};

pub mod opentelemetry {
    pub mod proto {
        pub mod collector {
            pub mod metrics {
                pub mod v1 {
                    include!(concat!(
                        env!("OUT_DIR"),
                        "/opentelemetry.proto.collector.metrics.v1.rs"
                    ));
                }
            }
        }
        pub mod metrics {
            pub mod v1 {
                include!(concat!(
                    env!("OUT_DIR"),
                    "/opentelemetry.proto.metrics.v1.rs"
                ));
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

use base64::Engine;
use opentelemetry::proto::collector::metrics::v1::ExportMetricsServiceRequest;
use opentelemetry::proto::common::v1::{any_value::Value as AnyValueEnum, AnyValue, KeyValue};
use opentelemetry::proto::metrics::v1::{metric::Data as MetricData, Metric};

/// Convert OTLP metrics payloads into a JSON summary suitable for rule evaluation.
pub fn otel_metrics_to_json(data: &[u8]) -> Result<Value> {
    let request = ExportMetricsServiceRequest::decode(data)?;
    let mut resource_summaries = Vec::new();

    for resource_metric in &request.resource_metrics {
        let resource_attrs = resource_metric
            .resource
            .as_ref()
            .map(|resource| attributes_to_json(&resource.attributes))
            .unwrap_or_else(|| Value::Object(Map::new()));

        let service_name = extract_service_name(resource_metric);

        let mut scopes = Vec::new();
        for scope_metrics in &resource_metric.scope_metrics {
            let scope_json = scope_metrics.scope.as_ref().map(|scope| {
                json!({
                    "name": scope.name,
                    "version": scope.version,
                    "attributes": attributes_to_json(&scope.attributes),
                })
            });

            let metrics: Vec<Value> = scope_metrics
                .metrics
                .iter()
                .map(|metric| metric_summary(metric))
                .collect();

            scopes.push(json!({
                "scope": scope_json,
                "metrics": metrics,
            }));
        }

        resource_summaries.push(json!({
            "service_name": service_name,
            "resource": resource_attrs,
            "scope_metrics": scopes,
        }));
    }

    let encoded = base64::engine::general_purpose::STANDARD.encode(data);

    Ok(json!({
        "resource_metric_count": request.resource_metrics.len(),
        "resource_summaries": resource_summaries,
        "raw_payload": encoded,
    }))
}

fn metric_summary(metric: &Metric) -> Value {
    let data_type = metric_data_type(metric);
    json!({
        "name": metric.name,
        "description": metric.description,
        "unit": metric.unit,
        "data_type": data_type,
        "data_point_count": count_metric_data_points(metric),
    })
}

fn metric_data_type(metric: &Metric) -> &'static str {
    match metric.data {
        Some(MetricData::Gauge(_)) => "gauge",
        Some(MetricData::Sum(_)) => "sum",
        Some(MetricData::Histogram(_)) => "histogram",
        Some(MetricData::ExponentialHistogram(_)) => "exponential_histogram",
        Some(MetricData::Summary(_)) => "summary",
        None => "unknown",
    }
}

fn count_metric_data_points(metric: &Metric) -> usize {
    match metric.data {
        Some(MetricData::Gauge(ref gauge)) => gauge.data_points.len(),
        Some(MetricData::Sum(ref sum)) => sum.data_points.len(),
        Some(MetricData::Histogram(ref histogram)) => histogram.data_points.len(),
        Some(MetricData::ExponentialHistogram(ref hist)) => hist.data_points.len(),
        Some(MetricData::Summary(ref summary)) => summary.data_points.len(),
        None => 0,
    }
}

fn extract_service_name(
    resource_metric: &opentelemetry::proto::metrics::v1::ResourceMetrics,
) -> Value {
    resource_metric
        .resource
        .as_ref()
        .and_then(|resource| {
            resource.attributes.iter().find_map(|kv| {
                if kv.key == "service.name" {
                    kv.value.as_ref().map(any_value_to_json)
                } else {
                    None
                }
            })
        })
        .unwrap_or(Value::Null)
}

fn attributes_to_json(attrs: &[KeyValue]) -> Value {
    let mut map = Map::new();
    for attr in attrs {
        if let Some(value) = attr.value.as_ref() {
            map.insert(attr.key.clone(), any_value_to_json(value));
        }
    }
    Value::Object(map)
}

fn any_value_to_json(value: &AnyValue) -> Value {
    match &value.value {
        Some(AnyValueEnum::StringValue(v)) => json!(v),
        Some(AnyValueEnum::BoolValue(v)) => json!(v),
        Some(AnyValueEnum::IntValue(v)) => json!(v),
        Some(AnyValueEnum::DoubleValue(v)) => json!(v),
        Some(AnyValueEnum::ArrayValue(arr)) => {
            Value::Array(arr.values.iter().map(any_value_to_json).collect())
        }
        Some(AnyValueEnum::KvlistValue(kv)) => attributes_to_json(&kv.values),
        Some(AnyValueEnum::BytesValue(bytes)) => {
            Value::String(base64::engine::general_purpose::STANDARD.encode(bytes))
        }
        None => Value::Null,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use opentelemetry::proto::{
        collector::metrics::v1::ExportMetricsServiceRequest,
        common::v1::{any_value::Value as AnyValueEnum, AnyValue, InstrumentationScope, KeyValue},
        metrics::v1::{Gauge, Metric, NumberDataPoint, ResourceMetrics, ScopeMetrics},
        resource::v1::Resource,
    };

    #[test]
    fn test_metrics_summary_generation() {
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
                        version: "1.0".to_string(),
                        attributes: vec![],
                        dropped_attributes_count: 0,
                    }),
                    metrics: vec![Metric {
                        name: "cpu.usage".to_string(),
                        description: "CPU Usage".to_string(),
                        unit: "%".to_string(),
                        data: Some(MetricData::Gauge(Gauge {
                            data_points: vec![NumberDataPoint {
                                attributes: vec![],
                                start_time_unix_nano: 0,
                                time_unix_nano: 123,
                                exemplars: vec![],
                                flags: 0,
                                value: Some(
                                    opentelemetry::proto::metrics::v1::number_data_point::Value::AsDouble(
                                        42.5,
                                    ),
                                ),
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

        let summary = otel_metrics_to_json(&buf).unwrap();
        assert_eq!(summary["resource_metric_count"], 1);
        let resources = summary["resource_summaries"].as_array().unwrap();
        assert_eq!(resources.len(), 1);
        assert_eq!(resources[0]["service_name"], "test-service");
        let scopes = resources[0]["scope_metrics"].as_array().unwrap();
        assert_eq!(scopes.len(), 1);
        let metrics = scopes[0]["metrics"].as_array().unwrap();
        assert_eq!(metrics.len(), 1);
        assert_eq!(metrics[0]["name"], "cpu.usage");
        assert_eq!(metrics[0]["data_type"], "gauge");
        assert_eq!(metrics[0]["data_point_count"], 1);
        assert!(summary["raw_payload"].as_str().is_some());
    }
}
