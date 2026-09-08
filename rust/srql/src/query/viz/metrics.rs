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

pub(super) fn cpu_metrics() -> VizMeta {
    VizMeta {
        columns: vec![
            col(
                "timestamp",
                ColumnType::Timestamptz,
                Some(ColumnSemantic::Time),
            ),
            col("gateway_id", ColumnType::Text, Some(ColumnSemantic::Id)),
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
    }
}

pub(super) fn memory_metrics() -> VizMeta {
    VizMeta {
        columns: vec![
            col(
                "timestamp",
                ColumnType::Timestamptz,
                Some(ColumnSemantic::Time),
            ),
            col("gateway_id", ColumnType::Text, Some(ColumnSemantic::Id)),
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
    }
}

pub(super) fn disk_metrics() -> VizMeta {
    VizMeta {
        columns: vec![
            col(
                "timestamp",
                ColumnType::Timestamptz,
                Some(ColumnSemantic::Time),
            ),
            col("gateway_id", ColumnType::Text, Some(ColumnSemantic::Id)),
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
    }
}

pub(super) fn process_metrics() -> VizMeta {
    VizMeta {
        columns: vec![
            col(
                "timestamp",
                ColumnType::Timestamptz,
                Some(ColumnSemantic::Time),
            ),
            col("gateway_id", ColumnType::Text, Some(ColumnSemantic::Id)),
            col("agent_id", ColumnType::Text, Some(ColumnSemantic::Id)),
            col("host_id", ColumnType::Text, Some(ColumnSemantic::Id)),
            col("pid", ColumnType::Int, Some(ColumnSemantic::Id)),
            col("name", ColumnType::Text, Some(ColumnSemantic::Label)),
            col("cpu_usage", ColumnType::Float, Some(ColumnSemantic::Value)).with_unit("percent"),
            col("memory_usage", ColumnType::Int, Some(ColumnSemantic::Value)).with_unit("bytes"),
            col("status", ColumnType::Text, None),
            col("device_id", ColumnType::Text, Some(ColumnSemantic::Id)),
        ],
        suggestions: vec![VizSuggestion {
            kind: VizKind::Timeseries,
            x: Some("timestamp".to_string()),
            y: Some("cpu_usage".to_string()),
            series: Some("name".to_string()),
        }],
    }
}
