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

pub(super) fn source_fact_disagreements() -> VizMeta {
    VizMeta {
        columns: vec![
            col("device_uid", ColumnType::Text, Some(ColumnSemantic::Id)),
            col("fact_key", ColumnType::Text, Some(ColumnSemantic::Label)),
            col("status", ColumnType::Text, None),
            col("configuration_conflict", ColumnType::Bool, None),
            col(
                "last_detected_at",
                ColumnType::Timestamptz,
                Some(ColumnSemantic::Time),
            ),
            col("values", ColumnType::Jsonb, None),
        ],
        suggestions: vec![VizSuggestion {
            kind: VizKind::Table,
            x: None,
            y: None,
            series: None,
        }],
    }
}

pub(super) fn merge_audit() -> VizMeta {
    VizMeta {
        columns: vec![
            col("from_device_id", ColumnType::Text, Some(ColumnSemantic::Id)),
            col("to_device_id", ColumnType::Text, Some(ColumnSemantic::Id)),
            col("reason", ColumnType::Text, Some(ColumnSemantic::Label)),
            col("source", ColumnType::Text, None),
            col("depth", ColumnType::Int, None),
            col("direction", ColumnType::Text, None),
            col(
                "created_at",
                ColumnType::Timestamptz,
                Some(ColumnSemantic::Time),
            ),
            col("details", ColumnType::Jsonb, None),
        ],
        suggestions: vec![VizSuggestion {
            kind: VizKind::Table,
            x: None,
            y: None,
            series: None,
        }],
    }
}

pub(super) fn device_revival_audit() -> VizMeta {
    VizMeta {
        columns: vec![
            col("device_uid", ColumnType::Text, Some(ColumnSemantic::Id)),
            col("previous_deleted_by", ColumnType::Text, None),
            col(
                "previous_deleted_reason",
                ColumnType::Text,
                Some(ColumnSemantic::Label),
            ),
            col("revived_by_application", ColumnType::Text, None),
            col("previous_deleted_at", ColumnType::Timestamptz, None),
            col(
                "revived_at",
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

pub(super) fn device_identifiers() -> VizMeta {
    VizMeta {
        columns: vec![
            col("device_id", ColumnType::Text, Some(ColumnSemantic::Id)),
            col(
                "identifier_type",
                ColumnType::Text,
                Some(ColumnSemantic::Label),
            ),
            col("identifier_value", ColumnType::Text, None),
            col("partition", ColumnType::Text, None),
            col("confidence", ColumnType::Text, None),
            col("matches_current_facts", ColumnType::Bool, None),
            col("owner_deleted", ColumnType::Bool, None),
            col("owner_hostname", ColumnType::Text, None),
            col(
                "last_seen",
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

pub(super) fn identity_reconciliation_runs() -> VizMeta {
    VizMeta {
        columns: vec![
            col("run_id", ColumnType::Text, Some(ColumnSemantic::Id)),
            col("status", ColumnType::Text, Some(ColumnSemantic::Label)),
            col("merges", ColumnType::Int, None),
            col("errors", ColumnType::Int, None),
            col("blocked_components", ColumnType::Int, None),
            col("largest_blocked_component", ColumnType::Int, None),
            col("max_merges_configured", ColumnType::Int, None),
            col("merge_cap_reached", ColumnType::Bool, None),
            col("duration_ms", ColumnType::Int, None),
            col(
                "started_at",
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

pub(super) fn identity_evidence_edges() -> VizMeta {
    VizMeta {
        columns: vec![
            col("device_a", ColumnType::Text, Some(ColumnSemantic::Id)),
            col("device_b", ColumnType::Text, Some(ColumnSemantic::Id)),
            col(
                "identifier_type",
                ColumnType::Text,
                Some(ColumnSemantic::Label),
            ),
            col("identifier_value", ColumnType::Text, None),
            col("depth", ColumnType::Int, None),
            col("direct", ColumnType::Bool, None),
            col("cross_partition", ColumnType::Bool, None),
            col("partition_a", ColumnType::Text, None),
            col("partition_b", ColumnType::Text, None),
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
            col("vlan_uid", ColumnType::Text, None),
            col("switch_port_attachment", ColumnType::Jsonb, None),
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

pub(super) fn composite_results() -> VizMeta {
    VizMeta {
        columns: vec![
            col("device_uid", ColumnType::Text, Some(ColumnSemantic::Id)),
            col("check_id", ColumnType::Text, Some(ColumnSemantic::Id)),
            col("check_slug", ColumnType::Text, Some(ColumnSemantic::Label)),
            col("check_name", ColumnType::Text, Some(ColumnSemantic::Label)),
            col("verdict", ColumnType::Text, None),
            col("status", ColumnType::Text, None),
            col(
                "matched_rule_id",
                ColumnType::Text,
                Some(ColumnSemantic::Id),
            ),
            col("inputs", ColumnType::Jsonb, None),
            col(
                "evaluated_at",
                ColumnType::Timestamptz,
                Some(ColumnSemantic::Time),
            ),
            col(
                "changed_at",
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

pub(super) fn sweep_groups() -> VizMeta {
    VizMeta {
        columns: vec![
            col("sweep_group_id", ColumnType::Text, Some(ColumnSemantic::Id)),
            col("name", ColumnType::Text, Some(ColumnSemantic::Label)),
            col("partition", ColumnType::Text, None),
            col("agent_ids", ColumnType::TextArray, None),
            col("enabled", ColumnType::Bool, None),
            col("interval", ColumnType::Text, None),
            col("schedule_type", ColumnType::Text, None),
            col("ports", ColumnType::IntArray, None),
            col("sweep_modes", ColumnType::TextArray, None),
            col(
                "last_run_at",
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

pub(super) fn sweep_profiles() -> VizMeta {
    VizMeta {
        columns: vec![
            col("id", ColumnType::Text, Some(ColumnSemantic::Id)),
            col("name", ColumnType::Text, Some(ColumnSemantic::Label)),
            col("ports", ColumnType::IntArray, None),
            col("sweep_modes", ColumnType::TextArray, None),
            col("concurrency", ColumnType::Int, None),
            col("timeout", ColumnType::Text, None),
            col("admin_only", ColumnType::Bool, None),
            col("enabled", ColumnType::Bool, None),
            col("banner_grab_enabled", ColumnType::Bool, None),
            col("banner_grab_protocols", ColumnType::TextArray, None),
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

pub(super) fn sweep_executions() -> VizMeta {
    VizMeta {
        columns: vec![
            col("id", ColumnType::Text, Some(ColumnSemantic::Id)),
            col("status", ColumnType::Text, Some(ColumnSemantic::Label)),
            col(
                "started_at",
                ColumnType::Timestamptz,
                Some(ColumnSemantic::Time),
            ),
            col("completed_at", ColumnType::Timestamptz, None),
            col("duration_ms", ColumnType::Int, None),
            col("hosts_total", ColumnType::Int, None),
            col("hosts_available", ColumnType::Int, None),
            col("hosts_failed", ColumnType::Int, None),
            col("agent_id", ColumnType::Text, None),
            col("config_version", ColumnType::Text, None),
            col("sweep_group_id", ColumnType::Text, None),
            col("scanner_metrics", ColumnType::Jsonb, None),
            col("banner_grab_summary", ColumnType::Jsonb, None),
        ],
        suggestions: vec![VizSuggestion {
            kind: VizKind::Table,
            x: None,
            y: None,
            series: None,
        }],
    }
}

pub(super) fn sweep_results() -> VizMeta {
    VizMeta {
        columns: vec![
            col("id", ColumnType::Text, Some(ColumnSemantic::Id)),
            col("ip", ColumnType::Text, Some(ColumnSemantic::Label)),
            col("hostname", ColumnType::Text, None),
            col("status", ColumnType::Text, None),
            col("response_time_ms", ColumnType::Int, None),
            col("modes_results", ColumnType::Jsonb, None),
            col("open_ports", ColumnType::IntArray, None),
            col("scanned_ports", ColumnType::IntArray, None),
            col("device_id", ColumnType::Text, None),
            col("agent_id", ColumnType::Text, None),
            col("sweep_group_id", ColumnType::Text, None),
            col("execution_id", ColumnType::Text, None),
            col(
                "inserted_at",
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

pub(super) fn sweep_coverage() -> VizMeta {
    VizMeta {
        columns: vec![
            col("id", ColumnType::Text, Some(ColumnSemantic::Id)),
            // `day` is a real `date` column; there is no distinct viz
            // column type for it, so it is surfaced as the closest fit
            // (Timestamptz) with a Time semantic.
            col("day", ColumnType::Timestamptz, Some(ColumnSemantic::Time)),
            col("device_uid", ColumnType::Text, Some(ColumnSemantic::Label)),
            col("ip", ColumnType::Text, None),
            col("sweep_group_id", ColumnType::Text, None),
            col("agent_id", ColumnType::Text, None),
            col("execution_count", ColumnType::Int, None),
            col("available_count", ColumnType::Int, None),
            col("unavailable_count", ColumnType::Int, None),
            col("error_count", ColumnType::Int, None),
            col("first_seen_at", ColumnType::Timestamptz, None),
            col("last_seen_at", ColumnType::Timestamptz, None),
            col("scanned_ports", ColumnType::IntArray, None),
            col("open_ports", ColumnType::IntArray, None),
            col("modes_requested", ColumnType::TextArray, None),
            col("modes_observed", ColumnType::TextArray, None),
            col("last_status", ColumnType::Text, None),
            col("last_response_time_ms", ColumnType::Int, None),
        ],
        suggestions: vec![VizSuggestion {
            kind: VizKind::Table,
            x: None,
            y: None,
            series: None,
        }],
    }
}

pub(super) fn device_sweep_overlap() -> VizMeta {
    VizMeta {
        columns: vec![
            col("device_uid", ColumnType::Text, Some(ColumnSemantic::Id)),
            col("ip", ColumnType::Text, Some(ColumnSemantic::Label)),
            col("declared_target", ColumnType::Text, None),
            col("covering_declarations", ColumnType::TextArray, None),
            col("observed_ip", ColumnType::Text, None),
            col("sweep_group_id", ColumnType::Text, None),
            col("sweep_group_name", ColumnType::Text, Some(ColumnSemantic::Label)),
            col("profile_id", ColumnType::Text, None),
            col("scanner_profile_name", ColumnType::Text, None),
            col("declared_modes", ColumnType::TextArray, None),
            col("declared_ports", ColumnType::IntArray, None),
            col("agent_id", ColumnType::Text, None),
            col("declared", ColumnType::Bool, None),
            col("observed", ColumnType::Bool, None),
            col("relationship", ColumnType::Text, Some(ColumnSemantic::Series)),
            col("match_kind", ColumnType::Text, None),
            col("match_via", ColumnType::Text, None),
            col(
                "last_seen_at",
                ColumnType::Timestamptz,
                Some(ColumnSemantic::Time),
            ),
            col("available_count", ColumnType::Int, None),
            col("execution_count", ColumnType::Int, None),
            col("config_delivered_at", ColumnType::Timestamptz, None),
            col("has_availability_row", ColumnType::Bool, None),
            col("availability_agent_id", ColumnType::Text, None),
            col("availability_group_id", ColumnType::Text, None),
            col("availability_row_owner", ColumnType::Text, None),
            col("owns_availability_row", ColumnType::Bool, None),
        ],
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
