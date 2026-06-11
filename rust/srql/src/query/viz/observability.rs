//! Viz metadata builders for OTel observability entities: logs, traces,
//! trace summaries, and OTel metrics/metric points.

use super::{col, ColumnSemantic, ColumnType, VizKind, VizMeta, VizSuggestion};

pub(super) fn logs() -> VizMeta {
    VizMeta {
        columns: vec![
            col("id", ColumnType::Text, Some(ColumnSemantic::Id)),
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
    }
}

pub(super) fn traces() -> VizMeta {
    VizMeta {
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
    }
}

pub(super) fn trace_summaries() -> VizMeta {
    VizMeta {
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
    }
}

pub(super) fn otel_metrics() -> VizMeta {
    VizMeta {
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
    }
}

pub(super) fn otel_metric_points() -> VizMeta {
    VizMeta {
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
            col("unit", ColumnType::Text, None),
            col("temporality", ColumnType::Text, None),
            col("is_monotonic", ColumnType::Bool, None),
            col("service_name", ColumnType::Text, None),
            col("attributes", ColumnType::Text, None),
            col(
                "attributes_hash",
                ColumnType::Text,
                Some(ColumnSemantic::Id),
            ),
            col("value", ColumnType::Float, Some(ColumnSemantic::Value)),
            col("count", ColumnType::Int, Some(ColumnSemantic::Value)),
            col("sum", ColumnType::Float, Some(ColumnSemantic::Value)),
            col("bucket_counts", ColumnType::Text, None),
            col("explicit_bounds", ColumnType::Text, None),
        ],
        suggestions: vec![VizSuggestion {
            kind: VizKind::Timeseries,
            x: Some("timestamp".to_string()),
            y: Some("value".to_string()),
            series: Some("metric_name".to_string()),
        }],
    }
}
