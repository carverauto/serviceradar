//! Viz metadata builders for service monitoring entities: service checks,
//! availability, SLO evaluations, dashboards, and alerts.

use super::{ColumnSemantic, ColumnType, VizKind, VizMeta, VizSuggestion, col};

pub(super) fn services() -> VizMeta {
    VizMeta {
        columns: vec![
            col(
                "timestamp",
                ColumnType::Timestamptz,
                Some(ColumnSemantic::Time),
            ),
            col("gateway_id", ColumnType::Text, Some(ColumnSemantic::Id)),
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
    }
}

pub(super) fn service_availability() -> VizMeta {
    VizMeta {
        columns: vec![
            col("uid", ColumnType::Text, Some(ColumnSemantic::Id)),
            col(
                "service_name",
                ColumnType::Text,
                Some(ColumnSemantic::Label),
            ),
            col("service_key", ColumnType::Text, Some(ColumnSemantic::Id)),
            col("service_kind", ColumnType::Text, None),
            col("descriptor_id", ColumnType::Text, None),
            col("status", ColumnType::Text, None),
            col("available", ColumnType::Bool, None),
            col(
                "response_time_ms",
                ColumnType::Int,
                Some(ColumnSemantic::Value),
            ),
            col("summary", ColumnType::Text, None),
            col(
                "last_observed_at",
                ColumnType::Timestamptz,
                Some(ColumnSemantic::Time),
            ),
            col("gateway_id", ColumnType::Text, Some(ColumnSemantic::Id)),
            col("agent_id", ColumnType::Text, Some(ColumnSemantic::Id)),
            col("partition", ColumnType::Text, None),
        ],
        suggestions: vec![VizSuggestion {
            kind: VizKind::Table,
            x: None,
            y: None,
            series: None,
        }],
    }
}

pub(super) fn monitored_services() -> VizMeta {
    VizMeta {
        columns: vec![
            col("uid", ColumnType::Text, Some(ColumnSemantic::Id)),
            col(
                "display_name",
                ColumnType::Text,
                Some(ColumnSemantic::Label),
            ),
            col("service_key", ColumnType::Text, Some(ColumnSemantic::Id)),
            col("service_kind", ColumnType::Text, None),
            col("protocol", ColumnType::Text, None),
            col("host", ColumnType::Text, None),
            col("port", ColumnType::Int, None),
            col("status", ColumnType::Text, None),
            col("available", ColumnType::Bool, None),
            col(
                "last_observed_at",
                ColumnType::Timestamptz,
                Some(ColumnSemantic::Time),
            ),
            col("gateway_id", ColumnType::Text, Some(ColumnSemantic::Id)),
            col("agent_id", ColumnType::Text, Some(ColumnSemantic::Id)),
            col("partition", ColumnType::Text, None),
        ],
        suggestions: vec![VizSuggestion {
            kind: VizKind::Table,
            x: None,
            y: None,
            series: None,
        }],
    }
}

pub(super) fn slo_evaluations() -> VizMeta {
    VizMeta {
        columns: vec![
            col("uid", ColumnType::Text, Some(ColumnSemantic::Id)),
            col("slo_key", ColumnType::Text, Some(ColumnSemantic::Id)),
            col("slo_name", ColumnType::Text, Some(ColumnSemantic::Label)),
            col("owner", ColumnType::Text, None),
            col("compliance_state", ColumnType::Text, None),
            col("severity", ColumnType::Text, None),
            col(
                "budget_remaining_basis_points",
                ColumnType::Int,
                Some(ColumnSemantic::Value),
            ),
            col(
                "burn_rate_short",
                ColumnType::Float,
                Some(ColumnSemantic::Value),
            ),
            col(
                "projected_exhaustion_at",
                ColumnType::Timestamptz,
                Some(ColumnSemantic::Time),
            ),
            col(
                "evaluated_at",
                ColumnType::Timestamptz,
                Some(ColumnSemantic::Time),
            ),
            col("service_key", ColumnType::Text, Some(ColumnSemantic::Id)),
            col("service_kind", ColumnType::Text, None),
            col("partition", ColumnType::Text, None),
        ],
        suggestions: vec![VizSuggestion {
            kind: VizKind::Table,
            x: None,
            y: None,
            series: None,
        }],
    }
}

pub(super) fn dashboards() -> VizMeta {
    VizMeta {
        columns: vec![
            col("id", ColumnType::Text, Some(ColumnSemantic::Id)),
            col("title", ColumnType::Text, Some(ColumnSemantic::Label)),
            col("description", ColumnType::Text, None),
            col("slug", ColumnType::Text, Some(ColumnSemantic::Id)),
            col("owner_id", ColumnType::Text, Some(ColumnSemantic::Id)),
            col("visibility", ColumnType::Text, None),
            col("status", ColumnType::Text, None),
            col("default_time_range", ColumnType::Text, None),
            col("panel_count", ColumnType::Int, Some(ColumnSemantic::Value)),
            col(
                "report_schedule_count",
                ColumnType::Int,
                Some(ColumnSemantic::Value),
            ),
            col("layout", ColumnType::Jsonb, None),
            col("variables", ColumnType::Jsonb, None),
            col("metadata", ColumnType::Jsonb, None),
            col(
                "inserted_at",
                ColumnType::Timestamptz,
                Some(ColumnSemantic::Time),
            ),
            col(
                "updated_at",
                ColumnType::Timestamptz,
                Some(ColumnSemantic::Time),
            ),
            col(
                "archived_at",
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

pub(super) fn alerts() -> VizMeta {
    VizMeta {
        columns: vec![
            col("id", ColumnType::Text, Some(ColumnSemantic::Id)),
            col("title", ColumnType::Text, None),
            col("description", ColumnType::Text, None),
            col("severity", ColumnType::Text, Some(ColumnSemantic::Label)),
            col("status", ColumnType::Text, Some(ColumnSemantic::Label)),
            col("source_type", ColumnType::Text, None),
            col("source_id", ColumnType::Text, None),
            col("device_uid", ColumnType::Text, None),
            col("agent_uid", ColumnType::Text, None),
            col("metric_name", ColumnType::Text, None),
            col("metric_value", ColumnType::Float, None),
            col("threshold_value", ColumnType::Float, None),
            col("comparison", ColumnType::Text, None),
            col(
                "triggered_at",
                ColumnType::Timestamptz,
                Some(ColumnSemantic::Time),
            ),
            col("acknowledged_at", ColumnType::Timestamptz, None),
            col("acknowledged_by", ColumnType::Text, None),
            col("resolved_at", ColumnType::Timestamptz, None),
            col("resolved_by", ColumnType::Text, None),
            col("escalated_at", ColumnType::Timestamptz, None),
            col("escalation_level", ColumnType::Int, None),
            col("notification_count", ColumnType::Int, None),
            col("tags", ColumnType::TextArray, None),
        ],
        suggestions: vec![VizSuggestion {
            kind: VizKind::Table,
            x: None,
            y: None,
            series: None,
        }],
    }
}
