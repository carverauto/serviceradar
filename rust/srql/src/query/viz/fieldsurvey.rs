//! Viz metadata builders for field-survey entities: sessions, rasters,
//! artifacts, RF/pose/spectrum observations, and RF-pose matches.

use super::{ColumnMeta, ColumnSemantic, ColumnType, VizKind, VizMeta, VizSuggestion, col};

pub(super) fn sessions() -> VizMeta {
    fieldsurvey_table_meta(vec![
        col("session_id", ColumnType::Text, Some(ColumnSemantic::Id)),
        col("site_id", ColumnType::Text, None),
        col("site_name", ColumnType::Text, Some(ColumnSemantic::Label)),
        col("building_id", ColumnType::Text, None),
        col("building_name", ColumnType::Text, None),
        col("floor_id", ColumnType::Text, None),
        col("floor_name", ColumnType::Text, None),
        col("floor_index", ColumnType::Int, None),
        col("tags", ColumnType::TextArray, None),
        col("has_floorplan", ColumnType::Bool, None),
        col("raster_count", ColumnType::Int, None),
        col("artifact_count", ColumnType::Int, None),
        col(
            "updated_at",
            ColumnType::Timestamptz,
            Some(ColumnSemantic::Time),
        ),
    ])
}

pub(super) fn rasters() -> VizMeta {
    fieldsurvey_table_meta(vec![
        col("raster_id", ColumnType::Text, Some(ColumnSemantic::Id)),
        col("session_id", ColumnType::Text, Some(ColumnSemantic::Id)),
        col(
            "overlay_type",
            ColumnType::Text,
            Some(ColumnSemantic::Label),
        ),
        col("selector_type", ColumnType::Text, None),
        col("selector_value", ColumnType::Text, None),
        col("cell_count", ColumnType::Int, Some(ColumnSemantic::Value)),
        col("site_id", ColumnType::Text, None),
        col("building_id", ColumnType::Text, None),
        col("floor_index", ColumnType::Int, None),
        col("has_floorplan", ColumnType::Bool, None),
        col(
            "generated_at",
            ColumnType::Timestamptz,
            Some(ColumnSemantic::Time),
        ),
        col("metadata", ColumnType::Jsonb, None),
    ])
}

pub(super) fn artifacts() -> VizMeta {
    fieldsurvey_table_meta(vec![
        col("artifact_id", ColumnType::Text, Some(ColumnSemantic::Id)),
        col("session_id", ColumnType::Text, Some(ColumnSemantic::Id)),
        col(
            "artifact_type",
            ColumnType::Text,
            Some(ColumnSemantic::Label),
        ),
        col("content_type", ColumnType::Text, None),
        col("byte_size", ColumnType::Int, Some(ColumnSemantic::Value)),
        col(
            "uploaded_at",
            ColumnType::Timestamptz,
            Some(ColumnSemantic::Time),
        ),
        col("metadata", ColumnType::Jsonb, None),
    ])
}

pub(super) fn rf_observations() -> VizMeta {
    fieldsurvey_table_meta(vec![
        col("id", ColumnType::Text, Some(ColumnSemantic::Id)),
        col("session_id", ColumnType::Text, Some(ColumnSemantic::Id)),
        col("bssid", ColumnType::Text, Some(ColumnSemantic::Series)),
        col("ssid", ColumnType::Text, Some(ColumnSemantic::Label)),
        col("rssi_dbm", ColumnType::Int, Some(ColumnSemantic::Value)),
        col("channel", ColumnType::Int, None),
        col("frequency_mhz", ColumnType::Int, None),
        col(
            "captured_at",
            ColumnType::Timestamptz,
            Some(ColumnSemantic::Time),
        ),
    ])
}

pub(super) fn pose_samples() -> VizMeta {
    fieldsurvey_table_meta(vec![
        col("id", ColumnType::Text, Some(ColumnSemantic::Id)),
        col("session_id", ColumnType::Text, Some(ColumnSemantic::Id)),
        col("scanner_device_id", ColumnType::Text, None),
        col("x", ColumnType::Float, None),
        col("y", ColumnType::Float, None),
        col("z", ColumnType::Float, None),
        col("tracking_quality", ColumnType::Text, None),
        col(
            "captured_at",
            ColumnType::Timestamptz,
            Some(ColumnSemantic::Time),
        ),
    ])
}

pub(super) fn rf_pose_matches() -> VizMeta {
    fieldsurvey_table_meta(vec![
        col(
            "rf_observation_id",
            ColumnType::Text,
            Some(ColumnSemantic::Id),
        ),
        col("pose_sample_id", ColumnType::Text, None),
        col("session_id", ColumnType::Text, Some(ColumnSemantic::Id)),
        col("bssid", ColumnType::Text, Some(ColumnSemantic::Series)),
        col("ssid", ColumnType::Text, Some(ColumnSemantic::Label)),
        col("rssi_dbm", ColumnType::Int, Some(ColumnSemantic::Value)),
        col("channel", ColumnType::Int, None),
        col("x", ColumnType::Float, None),
        col("y", ColumnType::Float, None),
        col("z", ColumnType::Float, None),
        col(
            "rf_captured_at",
            ColumnType::Timestamptz,
            Some(ColumnSemantic::Time),
        ),
    ])
}

pub(super) fn spectrum_observations() -> VizMeta {
    fieldsurvey_table_meta(vec![
        col("id", ColumnType::Text, Some(ColumnSemantic::Id)),
        col("session_id", ColumnType::Text, Some(ColumnSemantic::Id)),
        col("sdr_id", ColumnType::Text, Some(ColumnSemantic::Series)),
        col("device_kind", ColumnType::Text, None),
        col("sweep_id", ColumnType::Int, None),
        col("start_frequency_hz", ColumnType::Int, None),
        col("stop_frequency_hz", ColumnType::Int, None),
        col(
            "peak_power_dbm",
            ColumnType::Float,
            Some(ColumnSemantic::Value),
        ),
        col(
            "avg_power_dbm",
            ColumnType::Float,
            Some(ColumnSemantic::Value),
        ),
        col(
            "captured_at",
            ColumnType::Timestamptz,
            Some(ColumnSemantic::Time),
        ),
    ])
}

fn fieldsurvey_table_meta(columns: Vec<ColumnMeta>) -> VizMeta {
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
