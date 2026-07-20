//! Viz metadata builders for fleet inventory entities: agents, devices,
//! gateways, virtualization, and device-graph queries.

use super::{ColumnMeta, ColumnSemantic, ColumnType, VizKind, VizMeta, VizSuggestion, col};

pub(super) fn agents() -> VizMeta {
    VizMeta {
        columns: vec![
            col("uid", ColumnType::Text, Some(ColumnSemantic::Id)),
            col("name", ColumnType::Text, Some(ColumnSemantic::Label)),
            col("type_id", ColumnType::Int, None),
            col("type", ColumnType::Text, None),
            col("version", ColumnType::Text, None),
            col("vendor_name", ColumnType::Text, None),
            col("gateway_id", ColumnType::Text, Some(ColumnSemantic::Id)),
            col("capabilities", ColumnType::TextArray, None),
            col("ip", ColumnType::Text, None),
            col(
                "first_seen_time",
                ColumnType::Timestamptz,
                Some(ColumnSemantic::Time),
            ),
            col(
                "last_seen_time",
                ColumnType::Timestamptz,
                Some(ColumnSemantic::Time),
            ),
            col("metadata", ColumnType::Jsonb, None),
        ],
        suggestions: vec![VizSuggestion {
            kind: VizKind::Table,
            x: None,
            y: None,
            series: None,
        }],
    }
}

pub(super) fn addon_statuses() -> VizMeta {
    VizMeta {
        columns: vec![
            col("agent_uid", ColumnType::Text, Some(ColumnSemantic::Id)),
            col("addon_id", ColumnType::Text, Some(ColumnSemantic::Id)),
            col("state", ColumnType::Text, Some(ColumnSemantic::Label)),
            col("active", ColumnType::Bool, None),
            col("degradation_reason", ColumnType::Text, None),
            col("pid", ColumnType::Int, None),
            col("restart_count", ColumnType::Int, None),
            col(
                "last_health_at",
                ColumnType::Timestamptz,
                Some(ColumnSemantic::Time),
            ),
            col("version", ColumnType::Text, None),
            col("arch", ColumnType::Text, None),
            col(
                "reported_at",
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

pub(super) fn addon_fleet() -> VizMeta {
    VizMeta {
        columns: vec![
            col("agent_uid", ColumnType::Text, Some(ColumnSemantic::Id)),
            col("agent_label", ColumnType::Text, Some(ColumnSemantic::Label)),
            col("addon_id", ColumnType::Text, Some(ColumnSemantic::Id)),
            col("addon_name", ColumnType::Text, Some(ColumnSemantic::Label)),
            col("assigned", ColumnType::Bool, None),
            col("assigned_version", ColumnType::Text, None),
            col("observed_state", ColumnType::Text, None),
            col("observed_version", ColumnType::Text, None),
            col("active", ColumnType::Bool, None),
            col("category", ColumnType::Text, Some(ColumnSemantic::Label)),
            col("reason_code", ColumnType::Text, None),
            col("evidence_age_seconds", ColumnType::Int, None),
            col(
                "reported_at",
                ColumnType::Timestamptz,
                Some(ColumnSemantic::Time),
            ),
            col("rollout_state", ColumnType::Text, None),
            col("update_policy", ColumnType::Text, None),
            col("package_status", ColumnType::Text, None),
            col("degradation_reason", ColumnType::Text, None),
        ],
        suggestions: vec![VizSuggestion {
            kind: VizKind::Table,
            x: None,
            y: None,
            series: None,
        }],
    }
}

pub(super) fn devices() -> VizMeta {
    VizMeta {
        columns: vec![
            col("uid", ColumnType::Text, Some(ColumnSemantic::Id)),
            col("hostname", ColumnType::Text, Some(ColumnSemantic::Label)),
            col("ip", ColumnType::Text, None),
            col("mac", ColumnType::Text, None),
            col("gateway_id", ColumnType::Text, Some(ColumnSemantic::Id)),
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
    }
}

pub(super) fn gateways() -> VizMeta {
    VizMeta {
        columns: vec![
            col("gateway_id", ColumnType::Text, Some(ColumnSemantic::Id)),
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
    }
}

pub(super) fn virtualization() -> VizMeta {
    virtualization_table_meta(vec![
        col("id", ColumnType::Text, Some(ColumnSemantic::Id)),
        col("provider", ColumnType::Text, None),
        col("provider_ref", ColumnType::Text, Some(ColumnSemantic::Id)),
        col("name", ColumnType::Text, Some(ColumnSemantic::Label)),
        col("node", ColumnType::Text, None),
        col("cluster_name", ColumnType::Text, None),
        col("host_name", ColumnType::Text, None),
        col("device_uid", ColumnType::Text, Some(ColumnSemantic::Id)),
        col("guest_type", ColumnType::Text, None),
        col("vmid", ColumnType::Int, None),
        col("storage", ColumnType::Text, None),
        col("storage_type", ColumnType::Text, None),
        col("storage_system_type", ColumnType::Text, None),
        col("health", ColumnType::Text, None),
        col("ceph_health", ColumnType::Text, None),
        col("status", ColumnType::Text, None),
        col(
            "observed_at",
            ColumnType::Timestamptz,
            Some(ColumnSemantic::Time),
        ),
        col("metadata", ColumnType::Jsonb, None),
    ])
}

pub(super) fn device_graph() -> VizMeta {
    VizMeta {
        columns: vec![col("result", ColumnType::Jsonb, None)],
        suggestions: vec![VizSuggestion {
            kind: VizKind::Table,
            x: None,
            y: None,
            series: None,
        }],
    }
}

pub(super) fn graph_cypher() -> VizMeta {
    VizMeta {
        columns: vec![col("result", ColumnType::Jsonb, None)],
        suggestions: vec![VizSuggestion {
            kind: VizKind::Table,
            x: None,
            y: None,
            series: None,
        }],
    }
}

fn virtualization_table_meta(columns: Vec<ColumnMeta>) -> VizMeta {
    VizMeta {
        columns,
        suggestions: vec![VizSuggestion {
            kind: VizKind::Table,
            x: None,
            y: None,
            series: None,
        }],
    }
}
