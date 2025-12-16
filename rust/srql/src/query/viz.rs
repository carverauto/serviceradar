use crate::parser::Entity;
use serde::Serialize;

use super::QueryPlan;

#[derive(Debug, Clone, Serialize)]
pub struct VizMeta {
    pub columns: Vec<ColumnMeta>,
    #[serde(skip_serializing_if = "Vec::is_empty", default)]
    pub suggestions: Vec<VizSuggestion>,
}

#[derive(Debug, Clone, Serialize)]
pub struct ColumnMeta {
    pub name: String,
    #[serde(rename = "type")]
    pub col_type: ColumnType,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub semantic: Option<ColumnSemantic>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub unit: Option<String>,
}

#[derive(Debug, Clone, Copy, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum ColumnType {
    Text,
    TextArray,
    Bool,
    Int,
    IntArray,
    Float,
    Timestamptz,
    Jsonb,
}

#[derive(Debug, Clone, Copy, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum ColumnSemantic {
    Id,
    Time,
    Value,
    Label,
    Series,
}

#[derive(Debug, Clone, Serialize)]
pub struct VizSuggestion {
    pub kind: VizKind,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub x: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub y: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub series: Option<String>,
}

#[derive(Debug, Clone, Copy, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum VizKind {
    Timeseries,
    Table,
}

pub fn meta_for_plan(plan: &QueryPlan) -> Option<VizMeta> {
    if plan.downsample.is_some()
        && matches!(
            plan.entity,
            Entity::TimeseriesMetrics
                | Entity::SnmpMetrics
                | Entity::RperfMetrics
                | Entity::CpuMetrics
                | Entity::MemoryMetrics
                | Entity::DiskMetrics
                | Entity::ProcessMetrics
        )
    {
        return Some(VizMeta {
            columns: vec![
                col(
                    "timestamp",
                    ColumnType::Timestamptz,
                    Some(ColumnSemantic::Time),
                ),
                col("series", ColumnType::Text, Some(ColumnSemantic::Series)),
                col("value", ColumnType::Float, Some(ColumnSemantic::Value)),
            ],
            suggestions: vec![VizSuggestion {
                kind: VizKind::Timeseries,
                x: Some("timestamp".to_string()),
                y: Some("value".to_string()),
                series: Some("series".to_string()),
            }],
        });
    }

    Some(match plan.entity {
        Entity::Devices => VizMeta {
            columns: vec![
                col("device_id", ColumnType::Text, Some(ColumnSemantic::Id)),
                col("hostname", ColumnType::Text, Some(ColumnSemantic::Label)),
                col("ip", ColumnType::Text, None),
                col("mac", ColumnType::Text, None),
                col("poller_id", ColumnType::Text, Some(ColumnSemantic::Id)),
                col("agent_id", ColumnType::Text, Some(ColumnSemantic::Id)),
                col("discovery_sources", ColumnType::TextArray, None),
                col("is_available", ColumnType::Bool, None),
                col(
                    "first_seen",
                    ColumnType::Timestamptz,
                    Some(ColumnSemantic::Time),
                ),
                col(
                    "last_seen",
                    ColumnType::Timestamptz,
                    Some(ColumnSemantic::Time),
                ),
                col(
                    "last_heartbeat",
                    ColumnType::Timestamptz,
                    Some(ColumnSemantic::Time),
                ),
                col("device_type", ColumnType::Text, None),
                col("service_type", ColumnType::Text, None),
                col("service_status", ColumnType::Text, None),
                col("metadata", ColumnType::Jsonb, None),
            ],
            suggestions: vec![VizSuggestion {
                kind: VizKind::Table,
                x: None,
                y: None,
                series: None,
            }],
        },
        Entity::Pollers => VizMeta {
            columns: vec![
                col("poller_id", ColumnType::Text, Some(ColumnSemantic::Id)),
                col("status", ColumnType::Text, None),
                col("spiffe_identity", ColumnType::Text, None),
                col(
                    "first_registered",
                    ColumnType::Timestamptz,
                    Some(ColumnSemantic::Time),
                ),
                col(
                    "first_seen",
                    ColumnType::Timestamptz,
                    Some(ColumnSemantic::Time),
                ),
                col(
                    "last_seen",
                    ColumnType::Timestamptz,
                    Some(ColumnSemantic::Time),
                ),
                col("is_healthy", ColumnType::Bool, None),
                col("agent_count", ColumnType::Int, None),
                col("checker_count", ColumnType::Int, None),
                col("metadata", ColumnType::Jsonb, None),
                col(
                    "updated_at",
                    ColumnType::Timestamptz,
                    Some(ColumnSemantic::Time),
                ),
            ],
            suggestions: vec![VizSuggestion {
                kind: VizKind::Table,
                x: None,
                y: None,
                series: None,
            }],
        },
        Entity::Services => VizMeta {
            columns: vec![
                col(
                    "timestamp",
                    ColumnType::Timestamptz,
                    Some(ColumnSemantic::Time),
                ),
                col("poller_id", ColumnType::Text, Some(ColumnSemantic::Id)),
                col("agent_id", ColumnType::Text, Some(ColumnSemantic::Id)),
                col(
                    "service_name",
                    ColumnType::Text,
                    Some(ColumnSemantic::Label),
                ),
                col("service_type", ColumnType::Text, None),
                col("available", ColumnType::Bool, None),
                col("message", ColumnType::Text, None),
                col("details", ColumnType::Text, None),
                col("partition", ColumnType::Text, None),
                col(
                    "created_at",
                    ColumnType::Timestamptz,
                    Some(ColumnSemantic::Time),
                ),
            ],
            suggestions: vec![VizSuggestion {
                kind: VizKind::Table,
                x: None,
                y: None,
                series: None,
            }],
        },
        Entity::Interfaces => VizMeta {
            columns: vec![
                col(
                    "timestamp",
                    ColumnType::Timestamptz,
                    Some(ColumnSemantic::Time),
                ),
                col("device_id", ColumnType::Text, Some(ColumnSemantic::Id)),
                col("device_ip", ColumnType::Text, None),
                col("if_index", ColumnType::Int, None),
                col("if_name", ColumnType::Text, Some(ColumnSemantic::Label)),
                col("if_descr", ColumnType::Text, None),
                col("if_alias", ColumnType::Text, None),
                col("if_speed", ColumnType::Int, None),
                col("if_phys_address", ColumnType::Text, None),
                col("ip_addresses", ColumnType::TextArray, None),
                col("if_admin_status", ColumnType::Int, None),
                col("if_oper_status", ColumnType::Int, None),
                col("metadata", ColumnType::Jsonb, None),
                col(
                    "created_at",
                    ColumnType::Timestamptz,
                    Some(ColumnSemantic::Time),
                ),
            ],
            suggestions: vec![VizSuggestion {
                kind: VizKind::Table,
                x: None,
                y: None,
                series: None,
            }],
        },
        Entity::Events => VizMeta {
            columns: vec![
                col(
                    "event_timestamp",
                    ColumnType::Timestamptz,
                    Some(ColumnSemantic::Time),
                ),
                col("id", ColumnType::Text, Some(ColumnSemantic::Id)),
                col("event_type", ColumnType::Text, None),
                col("source", ColumnType::Text, None),
                col("subject", ColumnType::Text, None),
                col("severity", ColumnType::Text, None),
                col("short_message", ColumnType::Text, None),
                col(
                    "created_at",
                    ColumnType::Timestamptz,
                    Some(ColumnSemantic::Time),
                ),
            ],
            suggestions: vec![VizSuggestion {
                kind: VizKind::Table,
                x: None,
                y: None,
                series: None,
            }],
        },
        Entity::Logs => VizMeta {
            columns: vec![
                col(
                    "timestamp",
                    ColumnType::Timestamptz,
                    Some(ColumnSemantic::Time),
                ),
                col("trace_id", ColumnType::Text, Some(ColumnSemantic::Id)),
                col("span_id", ColumnType::Text, Some(ColumnSemantic::Id)),
                col("severity_text", ColumnType::Text, None),
                col("severity_number", ColumnType::Int, None),
                col("body", ColumnType::Text, None),
                col("service_name", ColumnType::Text, None),
                col(
                    "created_at",
                    ColumnType::Timestamptz,
                    Some(ColumnSemantic::Time),
                ),
            ],
            suggestions: vec![VizSuggestion {
                kind: VizKind::Table,
                x: None,
                y: None,
                series: None,
            }],
        },
        Entity::LogsHourlyStats => VizMeta {
            columns: vec![
                col("bucket", ColumnType::Timestamptz, Some(ColumnSemantic::Time)),
                col("service_name", ColumnType::Text, Some(ColumnSemantic::Label)),
                col(
                    "total_count",
                    ColumnType::Int,
                    Some(ColumnSemantic::Value),
                ),
                col(
                    "fatal_count",
                    ColumnType::Int,
                    Some(ColumnSemantic::Value),
                ),
                col(
                    "error_count",
                    ColumnType::Int,
                    Some(ColumnSemantic::Value),
                ),
                col(
                    "warning_count",
                    ColumnType::Int,
                    Some(ColumnSemantic::Value),
                ),
                col("info_count", ColumnType::Int, Some(ColumnSemantic::Value)),
                col(
                    "debug_count",
                    ColumnType::Int,
                    Some(ColumnSemantic::Value),
                ),
            ],
            suggestions: vec![VizSuggestion {
                kind: VizKind::Timeseries,
                x: Some("bucket".to_string()),
                y: Some("total_count".to_string()),
                series: Some("service_name".to_string()),
            }],
        },
        Entity::Traces => VizMeta {
            columns: vec![
                col(
                    "timestamp",
                    ColumnType::Timestamptz,
                    Some(ColumnSemantic::Time),
                ),
                col("trace_id", ColumnType::Text, Some(ColumnSemantic::Id)),
                col("span_id", ColumnType::Text, Some(ColumnSemantic::Id)),
                col("parent_span_id", ColumnType::Text, Some(ColumnSemantic::Id)),
                col("name", ColumnType::Text, Some(ColumnSemantic::Label)),
                col("start_time_unix_nano", ColumnType::Int, None),
                col("end_time_unix_nano", ColumnType::Int, None),
                col("service_name", ColumnType::Text, None),
                col("status_code", ColumnType::Int, None),
                col(
                    "created_at",
                    ColumnType::Timestamptz,
                    Some(ColumnSemantic::Time),
                ),
            ],
            suggestions: vec![VizSuggestion {
                kind: VizKind::Table,
                x: None,
                y: None,
                series: None,
            }],
        },
        Entity::TraceSummaries => VizMeta {
            columns: vec![
                col(
                    "timestamp",
                    ColumnType::Timestamptz,
                    Some(ColumnSemantic::Time),
                ),
                col("trace_id", ColumnType::Text, Some(ColumnSemantic::Id)),
                col("root_span_id", ColumnType::Text, Some(ColumnSemantic::Id)),
                col(
                    "root_span_name",
                    ColumnType::Text,
                    Some(ColumnSemantic::Label),
                ),
                col(
                    "root_service_name",
                    ColumnType::Text,
                    Some(ColumnSemantic::Label),
                ),
                col("root_span_kind", ColumnType::Int, None),
                col(
                    "duration_ms",
                    ColumnType::Float,
                    Some(ColumnSemantic::Value),
                )
                .with_unit("ms"),
                col("service_set", ColumnType::TextArray, None),
                col("span_count", ColumnType::Int, Some(ColumnSemantic::Value)),
                col("error_count", ColumnType::Int, Some(ColumnSemantic::Value)),
            ],
            suggestions: vec![VizSuggestion {
                kind: VizKind::Table,
                x: None,
                y: None,
                series: None,
            }],
        },
        Entity::OtelMetrics => VizMeta {
            columns: vec![
                col(
                    "timestamp",
                    ColumnType::Timestamptz,
                    Some(ColumnSemantic::Time),
                ),
                col("trace_id", ColumnType::Text, Some(ColumnSemantic::Id)),
                col("span_id", ColumnType::Text, Some(ColumnSemantic::Id)),
                col("service_name", ColumnType::Text, None),
                col("span_name", ColumnType::Text, Some(ColumnSemantic::Label)),
                col(
                    "duration_ms",
                    ColumnType::Float,
                    Some(ColumnSemantic::Value),
                )
                .with_unit("ms"),
                col("metric_type", ColumnType::Text, None),
                col("http_method", ColumnType::Text, None),
                col("http_route", ColumnType::Text, None),
                col("http_status_code", ColumnType::Text, None),
                col("grpc_service", ColumnType::Text, None),
                col("grpc_method", ColumnType::Text, None),
                col("grpc_status_code", ColumnType::Text, None),
                col("is_slow", ColumnType::Bool, None),
                col("component", ColumnType::Text, None),
                col("level", ColumnType::Text, None),
            ],
            suggestions: vec![VizSuggestion {
                kind: VizKind::Table,
                x: None,
                y: None,
                series: None,
            }],
        },
        Entity::OtelMetricsHourlyStats => VizMeta {
            columns: vec![
                col("bucket", ColumnType::Timestamptz, Some(ColumnSemantic::Time)),
                col("service_name", ColumnType::Text, Some(ColumnSemantic::Label)),
                col("metric_type", ColumnType::Text, None),
                col(
                    "total_count",
                    ColumnType::Int,
                    Some(ColumnSemantic::Value),
                ),
                col(
                    "avg_duration_ms",
                    ColumnType::Float,
                    Some(ColumnSemantic::Value),
                )
                .with_unit("ms"),
                col(
                    "min_duration_ms",
                    ColumnType::Float,
                    Some(ColumnSemantic::Value),
                )
                .with_unit("ms"),
                col(
                    "max_duration_ms",
                    ColumnType::Float,
                    Some(ColumnSemantic::Value),
                )
                .with_unit("ms"),
                col(
                    "p95_duration_ms",
                    ColumnType::Float,
                    Some(ColumnSemantic::Value),
                )
                .with_unit("ms"),
                col(
                    "p99_duration_ms",
                    ColumnType::Float,
                    Some(ColumnSemantic::Value),
                )
                .with_unit("ms"),
                col(
                    "error_count",
                    ColumnType::Int,
                    Some(ColumnSemantic::Value),
                ),
                col("slow_count", ColumnType::Int, Some(ColumnSemantic::Value)),
            ],
            suggestions: vec![VizSuggestion {
                kind: VizKind::Timeseries,
                x: Some("bucket".to_string()),
                y: Some("avg_duration_ms".to_string()),
                series: Some("service_name".to_string()),
            }],
        },
        Entity::TimeseriesMetrics | Entity::SnmpMetrics | Entity::RperfMetrics => VizMeta {
            columns: vec![
                col(
                    "timestamp",
                    ColumnType::Timestamptz,
                    Some(ColumnSemantic::Time),
                ),
                col(
                    "metric_name",
                    ColumnType::Text,
                    Some(ColumnSemantic::Series),
                ),
                col("metric_type", ColumnType::Text, None),
                col("device_id", ColumnType::Text, Some(ColumnSemantic::Id)),
                col("poller_id", ColumnType::Text, Some(ColumnSemantic::Id)),
                col("agent_id", ColumnType::Text, Some(ColumnSemantic::Id)),
                col("value", ColumnType::Float, Some(ColumnSemantic::Value)),
                col("unit", ColumnType::Text, None),
                col("tags", ColumnType::Jsonb, None),
            ],
            suggestions: vec![VizSuggestion {
                kind: VizKind::Timeseries,
                x: Some("timestamp".to_string()),
                y: Some("value".to_string()),
                series: Some("metric_name".to_string()),
            }],
        },
        Entity::CpuMetrics => VizMeta {
            columns: vec![
                col(
                    "timestamp",
                    ColumnType::Timestamptz,
                    Some(ColumnSemantic::Time),
                ),
                col("poller_id", ColumnType::Text, Some(ColumnSemantic::Id)),
                col("agent_id", ColumnType::Text, Some(ColumnSemantic::Id)),
                col("host_id", ColumnType::Text, Some(ColumnSemantic::Id)),
                col("core_id", ColumnType::Int, None),
                col(
                    "usage_percent",
                    ColumnType::Float,
                    Some(ColumnSemantic::Value),
                )
                .with_unit("percent"),
                col(
                    "frequency_hz",
                    ColumnType::Float,
                    Some(ColumnSemantic::Value),
                )
                .with_unit("hz"),
                col("label", ColumnType::Text, Some(ColumnSemantic::Label)),
                col("device_id", ColumnType::Text, Some(ColumnSemantic::Id)),
            ],
            suggestions: vec![VizSuggestion {
                kind: VizKind::Timeseries,
                x: Some("timestamp".to_string()),
                y: Some("usage_percent".to_string()),
                series: Some("label".to_string()),
            }],
        },
        Entity::MemoryMetrics => VizMeta {
            columns: vec![
                col(
                    "timestamp",
                    ColumnType::Timestamptz,
                    Some(ColumnSemantic::Time),
                ),
                col("poller_id", ColumnType::Text, Some(ColumnSemantic::Id)),
                col("agent_id", ColumnType::Text, Some(ColumnSemantic::Id)),
                col("host_id", ColumnType::Text, Some(ColumnSemantic::Id)),
                col(
                    "usage_percent",
                    ColumnType::Float,
                    Some(ColumnSemantic::Value),
                )
                .with_unit("percent"),
                col("used_bytes", ColumnType::Int, Some(ColumnSemantic::Value)).with_unit("bytes"),
                col(
                    "available_bytes",
                    ColumnType::Int,
                    Some(ColumnSemantic::Value),
                )
                .with_unit("bytes"),
                col("total_bytes", ColumnType::Int, Some(ColumnSemantic::Value)).with_unit("bytes"),
                col("device_id", ColumnType::Text, Some(ColumnSemantic::Id)),
            ],
            suggestions: vec![VizSuggestion {
                kind: VizKind::Timeseries,
                x: Some("timestamp".to_string()),
                y: Some("usage_percent".to_string()),
                series: None,
            }],
        },
        Entity::DiskMetrics => VizMeta {
            columns: vec![
                col(
                    "timestamp",
                    ColumnType::Timestamptz,
                    Some(ColumnSemantic::Time),
                ),
                col("poller_id", ColumnType::Text, Some(ColumnSemantic::Id)),
                col("agent_id", ColumnType::Text, Some(ColumnSemantic::Id)),
                col("host_id", ColumnType::Text, Some(ColumnSemantic::Id)),
                col("mount_point", ColumnType::Text, Some(ColumnSemantic::Label)),
                col(
                    "usage_percent",
                    ColumnType::Float,
                    Some(ColumnSemantic::Value),
                )
                .with_unit("percent"),
                col("used_bytes", ColumnType::Int, Some(ColumnSemantic::Value)).with_unit("bytes"),
                col(
                    "available_bytes",
                    ColumnType::Int,
                    Some(ColumnSemantic::Value),
                )
                .with_unit("bytes"),
                col("total_bytes", ColumnType::Int, Some(ColumnSemantic::Value)).with_unit("bytes"),
                col("device_id", ColumnType::Text, Some(ColumnSemantic::Id)),
            ],
            suggestions: vec![VizSuggestion {
                kind: VizKind::Timeseries,
                x: Some("timestamp".to_string()),
                y: Some("usage_percent".to_string()),
                series: Some("mount_point".to_string()),
            }],
        },
        Entity::ProcessMetrics => VizMeta {
            columns: vec![
                col(
                    "timestamp",
                    ColumnType::Timestamptz,
                    Some(ColumnSemantic::Time),
                ),
                col("poller_id", ColumnType::Text, Some(ColumnSemantic::Id)),
                col("agent_id", ColumnType::Text, Some(ColumnSemantic::Id)),
                col("host_id", ColumnType::Text, Some(ColumnSemantic::Id)),
                col("pid", ColumnType::Int, Some(ColumnSemantic::Id)),
                col("name", ColumnType::Text, Some(ColumnSemantic::Label)),
                col("cpu_usage", ColumnType::Float, Some(ColumnSemantic::Value))
                    .with_unit("percent"),
                col("memory_usage", ColumnType::Int, Some(ColumnSemantic::Value))
                    .with_unit("bytes"),
                col("status", ColumnType::Text, None),
                col("device_id", ColumnType::Text, Some(ColumnSemantic::Id)),
            ],
            suggestions: vec![VizSuggestion {
                kind: VizKind::Timeseries,
                x: Some("timestamp".to_string()),
                y: Some("cpu_usage".to_string()),
                series: Some("name".to_string()),
            }],
        },
        Entity::DeviceUpdates => VizMeta {
            columns: vec![
                col(
                    "observed_at",
                    ColumnType::Timestamptz,
                    Some(ColumnSemantic::Time),
                ),
                col("device_id", ColumnType::Text, Some(ColumnSemantic::Id)),
                col("agent_id", ColumnType::Text, Some(ColumnSemantic::Id)),
                col("poller_id", ColumnType::Text, Some(ColumnSemantic::Id)),
                col("discovery_source", ColumnType::Text, None),
                col("ip", ColumnType::Text, None),
                col("mac", ColumnType::Text, None),
                col("hostname", ColumnType::Text, None),
                col("available", ColumnType::Bool, None),
                col("metadata", ColumnType::Jsonb, None),
                col(
                    "created_at",
                    ColumnType::Timestamptz,
                    Some(ColumnSemantic::Time),
                ),
            ],
            suggestions: vec![VizSuggestion {
                kind: VizKind::Table,
                x: None,
                y: None,
                series: None,
            }],
        },
        Entity::DeviceGraph => VizMeta {
            columns: vec![col("result", ColumnType::Jsonb, None)],
            suggestions: vec![VizSuggestion {
                kind: VizKind::Table,
                x: None,
                y: None,
                series: None,
            }],
        },
        Entity::GraphCypher => VizMeta {
            columns: vec![col("result", ColumnType::Jsonb, None)],
            suggestions: vec![VizSuggestion {
                kind: VizKind::Table,
                x: None,
                y: None,
                series: None,
            }],
        },
    })
}

fn col(name: &str, col_type: ColumnType, semantic: Option<ColumnSemantic>) -> ColumnMeta {
    ColumnMeta {
        name: name.to_string(),
        col_type,
        semantic,
        unit: None,
    }
}

impl ColumnMeta {
    fn with_unit(mut self, unit: &str) -> Self {
        self.unit = Some(unit.to_string());
        self
    }
}
