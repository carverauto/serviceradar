//! Viz metadata builders for endpoint SBOM inventory entities: scans,
//! per-endpoint packages, and the package catalog.

use super::{ColumnSemantic, ColumnType, VizKind, VizMeta, VizSuggestion, col};

pub(super) fn endpoint_inventory_scans() -> VizMeta {
    VizMeta {
        columns: vec![
            col("id", ColumnType::Text, Some(ColumnSemantic::Id)),
            col("device_uid", ColumnType::Text, Some(ColumnSemantic::Id)),
            col("agent_id", ColumnType::Text, Some(ColumnSemantic::Id)),
            col("scan_id", ColumnType::Text, Some(ColumnSemantic::Id)),
            col("state", ColumnType::Text, Some(ColumnSemantic::Label)),
            col("coverage_state", ColumnType::Text, None),
            col("package_count", ColumnType::Int, None),
            col("current", ColumnType::Bool, None),
            col(
                "last_scan_at",
                ColumnType::Timestamptz,
                Some(ColumnSemantic::Time),
            ),
            col(
                "last_changed_scan_at",
                ColumnType::Timestamptz,
                Some(ColumnSemantic::Time),
            ),
            col("package_set_hash", ColumnType::Text, None),
            col("upload_reason", ColumnType::Text, None),
            col("unchanged_scan_count", ColumnType::Int, None),
            col("freshness_verdict", ColumnType::Text, None),
            col("freshness", ColumnType::Jsonb, None),
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

pub(super) fn endpoint_packages() -> VizMeta {
    VizMeta {
        columns: vec![
            col("id", ColumnType::Text, Some(ColumnSemantic::Id)),
            col("scan_ref", ColumnType::Text, Some(ColumnSemantic::Id)),
            col("device_uid", ColumnType::Text, Some(ColumnSemantic::Id)),
            col("agent_id", ColumnType::Text, Some(ColumnSemantic::Id)),
            col(
                "endpoint_package_ref",
                ColumnType::Text,
                Some(ColumnSemantic::Id),
            ),
            col("package_id", ColumnType::Text, Some(ColumnSemantic::Id)),
            col("name", ColumnType::Text, Some(ColumnSemantic::Label)),
            col("version", ColumnType::Text, None),
            col("architecture", ColumnType::Text, None),
            col("package_manager", ColumnType::Text, None),
            col("ecosystem", ColumnType::Text, None),
            col("purl", ColumnType::Text, None),
            col("purl_canonical", ColumnType::Text, None),
            col("canonical_purl", ColumnType::Text, None),
            col("cpes", ColumnType::TextArray, None),
            col("supplier", ColumnType::Text, None),
            col("license", ColumnType::Text, None),
            col("source", ColumnType::Text, None),
            col("current", ColumnType::Bool, None),
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

pub(super) fn endpoint_package_catalog() -> VizMeta {
    VizMeta {
        columns: vec![
            col("id", ColumnType::Text, Some(ColumnSemantic::Id)),
            col("package_id", ColumnType::Text, Some(ColumnSemantic::Id)),
            col("coordinate_key", ColumnType::Text, Some(ColumnSemantic::Id)),
            col("name", ColumnType::Text, Some(ColumnSemantic::Label)),
            col("version", ColumnType::Text, None),
            col("architecture", ColumnType::Text, None),
            col("package_manager", ColumnType::Text, None),
            col("ecosystem", ColumnType::Text, None),
            col("purl_canonical", ColumnType::Text, None),
            col("canonical_purl", ColumnType::Text, None),
            col("primary_cpe", ColumnType::Text, None),
            col("cpes", ColumnType::TextArray, None),
            col("source_scope", ColumnType::Text, None),
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
