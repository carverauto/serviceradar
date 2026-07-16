//! Viz metadata builders for wifi-map entities: sites, snapshots, access
//! points, controllers, RADIUS groups, fleet history, and site references.

use super::{ColumnMeta, ColumnSemantic, ColumnType, VizKind, VizMeta, VizSuggestion, col};

pub(super) fn sites() -> VizMeta {
    wifi_map_table_meta(vec![
        col("source_id", ColumnType::Text, Some(ColumnSemantic::Id)),
        col("site_code", ColumnType::Text, Some(ColumnSemantic::Id)),
        col("name", ColumnType::Text, Some(ColumnSemantic::Label)),
        col("site_type", ColumnType::Text, None),
        col("region", ColumnType::Text, None),
        col("latitude", ColumnType::Float, None),
        col("longitude", ColumnType::Float, None),
        col("ap_count", ColumnType::Int, Some(ColumnSemantic::Value)),
        col("up_count", ColumnType::Int, Some(ColumnSemantic::Value)),
        col("down_count", ColumnType::Int, Some(ColumnSemantic::Value)),
        col("wlc_count", ColumnType::Int, Some(ColumnSemantic::Value)),
        col(
            "collection_timestamp",
            ColumnType::Timestamptz,
            Some(ColumnSemantic::Time),
        ),
        col("metadata", ColumnType::Jsonb, None),
    ])
}

pub(super) fn site_snapshots() -> VizMeta {
    wifi_map_table_meta(vec![
        col("id", ColumnType::Text, Some(ColumnSemantic::Id)),
        col("site_code", ColumnType::Text, Some(ColumnSemantic::Id)),
        col(
            "collection_timestamp",
            ColumnType::Timestamptz,
            Some(ColumnSemantic::Time),
        ),
        col("ap_count", ColumnType::Int, Some(ColumnSemantic::Value)),
        col("up_count", ColumnType::Int, Some(ColumnSemantic::Value)),
        col("down_count", ColumnType::Int, Some(ColumnSemantic::Value)),
        col("wlc_count", ColumnType::Int, Some(ColumnSemantic::Value)),
        col("cluster", ColumnType::Text, None),
        col("server_group", ColumnType::Text, None),
        col("metadata", ColumnType::Jsonb, None),
    ])
}

pub(super) fn access_points() -> VizMeta {
    wifi_map_table_meta(vec![
        col("id", ColumnType::Text, Some(ColumnSemantic::Id)),
        col("device_uid", ColumnType::Text, Some(ColumnSemantic::Id)),
        col("site_code", ColumnType::Text, Some(ColumnSemantic::Id)),
        col(
            "collection_timestamp",
            ColumnType::Timestamptz,
            Some(ColumnSemantic::Time),
        ),
        col("name", ColumnType::Text, Some(ColumnSemantic::Label)),
        col("hostname", ColumnType::Text, None),
        col("mac", ColumnType::Text, None),
        col("serial", ColumnType::Text, None),
        col("ip", ColumnType::Text, None),
        col("status", ColumnType::Text, None),
        col("model", ColumnType::Text, None),
        col("metadata", ColumnType::Jsonb, None),
    ])
}

pub(super) fn controllers() -> VizMeta {
    wifi_map_table_meta(vec![
        col("id", ColumnType::Text, Some(ColumnSemantic::Id)),
        col("device_uid", ColumnType::Text, Some(ColumnSemantic::Id)),
        col("site_code", ColumnType::Text, Some(ColumnSemantic::Id)),
        col(
            "collection_timestamp",
            ColumnType::Timestamptz,
            Some(ColumnSemantic::Time),
        ),
        col("name", ColumnType::Text, Some(ColumnSemantic::Label)),
        col("hostname", ColumnType::Text, None),
        col("ip", ColumnType::Text, None),
        col("base_mac", ColumnType::Text, None),
        col("serial", ColumnType::Text, None),
        col("model", ColumnType::Text, None),
        col("aos_version", ColumnType::Text, None),
        col("metadata", ColumnType::Jsonb, None),
    ])
}

pub(super) fn radius_groups() -> VizMeta {
    wifi_map_table_meta(vec![
        col("id", ColumnType::Text, Some(ColumnSemantic::Id)),
        col("site_code", ColumnType::Text, Some(ColumnSemantic::Id)),
        col(
            "collection_timestamp",
            ColumnType::Timestamptz,
            Some(ColumnSemantic::Time),
        ),
        col(
            "controller_alias",
            ColumnType::Text,
            Some(ColumnSemantic::Label),
        ),
        col("aaa_profile", ColumnType::Text, None),
        col("server_group", ColumnType::Text, None),
        col("cluster", ColumnType::Text, None),
        col("all_server_groups", ColumnType::TextArray, None),
        col("status", ColumnType::Text, None),
        col("metadata", ColumnType::Jsonb, None),
    ])
}

pub(super) fn fleet_history() -> VizMeta {
    wifi_map_table_meta(vec![
        col(
            "build_date",
            ColumnType::Timestamptz,
            Some(ColumnSemantic::Time),
        ),
        col("ap_total", ColumnType::Int, Some(ColumnSemantic::Value)),
        col("count_6xx", ColumnType::Int, Some(ColumnSemantic::Value)),
        col("pct_6xx", ColumnType::Float, Some(ColumnSemantic::Value)),
        col("pct_legacy", ColumnType::Float, Some(ColumnSemantic::Value)),
        col("site_count", ColumnType::Int, Some(ColumnSemantic::Value)),
        col("metadata", ColumnType::Jsonb, None),
    ])
}

pub(super) fn site_references() -> VizMeta {
    wifi_map_table_meta(vec![
        col("source_id", ColumnType::Text, Some(ColumnSemantic::Id)),
        col("site_code", ColumnType::Text, Some(ColumnSemantic::Id)),
        col("name", ColumnType::Text, Some(ColumnSemantic::Label)),
        col("site_type", ColumnType::Text, None),
        col("region", ColumnType::Text, None),
        col("latitude", ColumnType::Float, None),
        col("longitude", ColumnType::Float, None),
        col("reference_hash", ColumnType::Text, None),
        col("reference_metadata", ColumnType::Jsonb, None),
    ])
}

fn wifi_map_table_meta(columns: Vec<ColumnMeta>) -> VizMeta {
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
