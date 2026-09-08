//! Viz metadata builders for OCSF-style event streams: generic events,
//! security findings, scan activity, and DNS activity.

use super::{ColumnSemantic, ColumnType, VizKind, VizMeta, VizSuggestion, col};

pub(super) fn events() -> VizMeta {
    VizMeta {
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
    }
}

pub(super) fn security_findings() -> VizMeta {
    VizMeta {
        columns: vec![
            col(
                "event_timestamp",
                ColumnType::Timestamptz,
                Some(ColumnSemantic::Time),
            ),
            col("id", ColumnType::Text, Some(ColumnSemantic::Id)),
            col("class_uid", ColumnType::Int, None),
            col("source", ColumnType::Text, Some(ColumnSemantic::Label)),
            col("severity", ColumnType::Text, None),
            col("status", ColumnType::Text, None),
            col("short_message", ColumnType::Text, None),
            col("finding_uid", ColumnType::Text, Some(ColumnSemantic::Id)),
            col(
                "finding_title",
                ColumnType::Text,
                Some(ColumnSemantic::Label),
            ),
            col(
                "source_device_uid",
                ColumnType::Text,
                Some(ColumnSemantic::Id),
            ),
            col("metadata", ColumnType::Jsonb, None),
            col("unmapped", ColumnType::Jsonb, None),
        ],
        suggestions: vec![VizSuggestion {
            kind: VizKind::Table,
            x: None,
            y: None,
            series: None,
        }],
    }
}

pub(super) fn scan_activity() -> VizMeta {
    VizMeta {
        columns: vec![
            col(
                "event_timestamp",
                ColumnType::Timestamptz,
                Some(ColumnSemantic::Time),
            ),
            col("id", ColumnType::Text, Some(ColumnSemantic::Id)),
            col(
                "activity_name",
                ColumnType::Text,
                Some(ColumnSemantic::Label),
            ),
            col("source", ColumnType::Text, Some(ColumnSemantic::Label)),
            col("severity", ColumnType::Text, None),
            col("status", ColumnType::Text, None),
            col("status_code", ColumnType::Text, None),
            col("short_message", ColumnType::Text, None),
            col(
                "source_device_uid",
                ColumnType::Text,
                Some(ColumnSemantic::Id),
            ),
            col("metadata", ColumnType::Jsonb, None),
            col("unmapped", ColumnType::Jsonb, None),
        ],
        suggestions: vec![VizSuggestion {
            kind: VizKind::Table,
            x: None,
            y: None,
            series: None,
        }],
    }
}

pub(super) fn dns_activity() -> VizMeta {
    VizMeta {
        columns: vec![
            col(
                "event_timestamp",
                ColumnType::Timestamptz,
                Some(ColumnSemantic::Time),
            ),
            col("id", ColumnType::Text, Some(ColumnSemantic::Id)),
            col(
                "activity_name",
                ColumnType::Text,
                Some(ColumnSemantic::Label),
            ),
            col("source", ColumnType::Text, Some(ColumnSemantic::Label)),
            col("severity", ColumnType::Text, None),
            col("status", ColumnType::Text, None),
            col("short_message", ColumnType::Text, None),
            col("src_endpoint", ColumnType::Jsonb, None),
            col("dst_endpoint", ColumnType::Jsonb, None),
            col("metadata", ColumnType::Jsonb, None),
            col("unmapped", ColumnType::Jsonb, None),
            col("raw_data", ColumnType::Text, None),
        ],
        suggestions: vec![VizSuggestion {
            kind: VizKind::Table,
            x: None,
            y: None,
            series: None,
        }],
    }
}
