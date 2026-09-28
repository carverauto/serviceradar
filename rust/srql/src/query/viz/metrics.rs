//! Viz metadata builders for system/poller metric entities: generic
//! timeseries metrics and CPU/memory/disk/process metrics.

use super::{ColumnSemantic, ColumnType, VizKind, VizMeta, VizSuggestion, col};

pub(super) fn timeseries_metrics() -> VizMeta {
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
            col("device_id", ColumnType::Text, Some(ColumnSemantic::Id)),
            col("gateway_id", ColumnType::Text, Some(ColumnSemantic::Id)),
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
    }
}

pub(super) fn timeseries_metric_disk_hourly() -> VizMeta {
    VizMeta {
        columns: vec![
            col(
                "bucket",
                ColumnType::Timestamptz,
                Some(ColumnSemantic::Time),
            ),
            col("device_id", ColumnType::Text, Some(ColumnSemantic::Id)),
            col("metric_type", ColumnType::Text, None),
            col("metric_name", ColumnType::Text, None),
            col("series_key", ColumnType::Text, None),
            col(
                "mount_point",
                ColumnType::Text,
                Some(ColumnSemantic::Series),
            ),
            col("avg_value", ColumnType::Float, Some(ColumnSemantic::Value)),
            col("min_value", ColumnType::Float, Some(ColumnSemantic::Value)),
            col("max_value", ColumnType::Float, Some(ColumnSemantic::Value)),
            col("sample_count", ColumnType::Int, None),
        ],
        suggestions: vec![VizSuggestion {
            kind: VizKind::Timeseries,
            x: Some("bucket".to_string()),
            y: Some("avg_value".to_string()),
            series: Some("mount_point".to_string()),
        }],
    }
}
