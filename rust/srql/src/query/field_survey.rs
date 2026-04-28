use super::{BindParam, QueryPlan};
use crate::{
    error::{Result, ServiceError},
    jsonb::DbJson,
    parser::{Entity, Filter, FilterOp, OrderClause, OrderDirection},
    time::TimeRange,
};
use diesel::deserialize::QueryableByName;
use diesel::pg::Pg;
use diesel::query_builder::{BoxedSqlQuery, SqlQuery};
use diesel::sql_query;
use diesel::sql_types::{Array, BigInt, Bool, Float8, Jsonb, Text, Timestamptz};
use diesel_async::{AsyncPgConnection, RunQueryDsl};
use serde_json::Value;

#[derive(Debug, QueryableByName)]
#[diesel(check_for_backend(diesel::pg::Pg))]
struct JsonPayload {
    #[diesel(sql_type = Jsonb)]
    payload: DbJson,
}

pub(super) async fn execute(conn: &mut AsyncPgConnection, plan: &QueryPlan) -> Result<Vec<Value>> {
    ensure_entity(plan)?;
    let built = build_sql(plan)?;
    let mut query = sql_query(&built.sql).into_boxed::<Pg>();

    for bind in built.binds {
        query = bind_param(query, bind)?;
    }

    let rows: Vec<JsonPayload> = query
        .load::<JsonPayload>(conn)
        .await
        .map_err(|err| ServiceError::Internal(err.into()))?;

    Ok(rows
        .into_iter()
        .map(|row| serde_json::Value::from(row.payload))
        .collect())
}

pub(super) fn to_sql_and_params(plan: &QueryPlan) -> Result<(String, Vec<BindParam>)> {
    ensure_entity(plan)?;
    let built = build_sql(plan)?;
    Ok((rewrite_placeholders(&built.sql), built.binds))
}

struct BuiltSql {
    sql: String,
    binds: Vec<BindParam>,
}

#[derive(Clone, Copy)]
enum FieldKind {
    Text,
    Int,
    Float,
    Bool,
    Tags,
}

fn ensure_entity(plan: &QueryPlan) -> Result<()> {
    if matches!(
        plan.entity,
        Entity::FieldSurveySessions
            | Entity::FieldSurveyRasters
            | Entity::FieldSurveyArtifacts
            | Entity::FieldSurveyRfObservations
            | Entity::FieldSurveyPoseSamples
            | Entity::FieldSurveyRfPoseMatches
            | Entity::FieldSurveySpectrumObservations
    ) {
        Ok(())
    } else {
        Err(ServiceError::InvalidRequest(
            "entity not supported by FieldSurvey query".into(),
        ))
    }
}

fn is_raw_entity(entity: &Entity) -> bool {
    matches!(
        entity,
        Entity::FieldSurveyRfObservations
            | Entity::FieldSurveyPoseSamples
            | Entity::FieldSurveyRfPoseMatches
            | Entity::FieldSurveySpectrumObservations
    )
}

fn build_sql(plan: &QueryPlan) -> Result<BuiltSql> {
    let spec = EntitySpec::for_entity(&plan.entity)?;
    let mut where_parts = Vec::new();
    let mut binds = Vec::new();

    if let Some(TimeRange { start, end }) = &plan.time_range {
        where_parts.push(format!(
            "{} >= ? AND {} <= ?",
            spec.time_column, spec.time_column
        ));
        binds.push(BindParam::timestamptz(*start));
        binds.push(BindParam::timestamptz(*end));
    } else if is_raw_entity(&plan.entity) {
        where_parts.push(format!("{} >= now() - interval '1 hour'", spec.time_column));
    }

    for filter in &plan.filters {
        let condition = filter_condition(spec, filter, &mut binds)?;
        if let Some(condition) = condition {
            where_parts.push(condition);
        }
    }

    let where_sql = if where_parts.is_empty() {
        String::new()
    } else {
        format!(" WHERE {}", where_parts.join(" AND "))
    };

    let order_sql = order_sql(spec, &plan.order);

    binds.push(BindParam::Int(plan.limit));
    binds.push(BindParam::Int(plan.offset));

    Ok(BuiltSql {
        sql: format!(
            "SELECT {} AS payload FROM {}{}{} LIMIT ? OFFSET ?",
            spec.select_sql, spec.from_sql, where_sql, order_sql
        ),
        binds,
    })
}

#[derive(Clone, Copy)]
struct EntitySpec {
    from_sql: &'static str,
    select_sql: &'static str,
    time_column: &'static str,
}

impl EntitySpec {
    fn for_entity(entity: &Entity) -> Result<Self> {
        match entity {
            Entity::FieldSurveySessions => Ok(Self {
                from_sql: "platform.survey_session_metadata m",
                time_column: "m.updated_at",
                select_sql: "jsonb_build_object(
                    'entity', 'field_survey_session',
                    'session_id', m.session_id,
                    'user_id', m.user_id,
                    'site_id', m.site_id,
                    'site_name', m.site_name,
                    'building_id', m.building_id,
                    'building_name', m.building_name,
                    'floor_id', m.floor_id,
                    'floor_name', m.floor_name,
                    'floor_index', m.floor_index,
                    'tags', COALESCE(to_jsonb(m.tags), '[]'::jsonb),
                    'metadata', COALESCE(m.metadata, '{}'::jsonb),
                    'updated_at', m.updated_at,
                    'inserted_at', m.inserted_at,
                    'raster_count', (
                        SELECT count(*) FROM platform.survey_coverage_rasters r
                        WHERE r.session_id = m.session_id AND r.user_id = m.user_id
                    ),
                    'artifact_count', (
                        SELECT count(*) FROM platform.survey_room_artifacts a
                        WHERE a.session_id = m.session_id AND a.user_id = m.user_id
                    ),
                    'has_floorplan', EXISTS (
                        SELECT 1 FROM platform.survey_room_artifacts a
                        WHERE a.session_id = m.session_id
                          AND a.user_id = m.user_id
                          AND a.artifact_type = 'floorplan_geojson'
                          AND jsonb_typeof(a.metadata->'floorplan_segments') = 'array'
                          AND jsonb_array_length(a.metadata->'floorplan_segments') > 0
                    )
                )",
            }),
            Entity::FieldSurveyRasters => Ok(Self {
                from_sql: "platform.survey_coverage_rasters r LEFT JOIN platform.survey_session_metadata m ON m.session_id = r.session_id AND m.user_id = r.user_id",
                time_column: "r.generated_at",
                select_sql: "jsonb_build_object(
                    'entity', 'field_survey_raster',
                    'raster_id', r.id,
                    'session_id', r.session_id,
                    'user_id', r.user_id,
                    'overlay_type', r.overlay_type,
                    'selector_type', r.selector_type,
                    'selector_value', r.selector_value,
                    'cell_size_m', r.cell_size_m,
                    'min_x', r.min_x,
                    'max_x', r.max_x,
                    'min_z', r.min_z,
                    'max_z', r.max_z,
                    'columns', r.columns,
                    'rows', r.rows,
                    'cell_count', COALESCE(jsonb_array_length(r.cells->'cells'), 0),
                    'cells', r.cells,
                    'metadata', COALESCE(r.metadata, '{}'::jsonb),
                    'generated_at', r.generated_at,
                    'site_id', m.site_id,
                    'site_name', m.site_name,
                    'building_id', m.building_id,
                    'building_name', m.building_name,
                    'floor_id', m.floor_id,
                    'floor_name', m.floor_name,
                    'floor_index', m.floor_index,
                    'tags', COALESCE(to_jsonb(m.tags), '[]'::jsonb),
                    'artifact_count', (
                        SELECT count(*) FROM platform.survey_room_artifacts a
                        WHERE a.session_id = r.session_id AND a.user_id = r.user_id
                    ),
                    'has_floorplan', EXISTS (
                        SELECT 1 FROM platform.survey_room_artifacts a
                        WHERE a.session_id = r.session_id
                          AND a.user_id = r.user_id
                          AND a.artifact_type = 'floorplan_geojson'
                          AND jsonb_typeof(a.metadata->'floorplan_segments') = 'array'
                          AND jsonb_array_length(a.metadata->'floorplan_segments') > 0
                    )
                )",
            }),
            Entity::FieldSurveyArtifacts => Ok(Self {
                from_sql: "platform.survey_room_artifacts a LEFT JOIN platform.survey_session_metadata m ON m.session_id = a.session_id AND m.user_id = a.user_id",
                time_column: "a.uploaded_at",
                select_sql: "jsonb_build_object(
                    'entity', 'field_survey_artifact',
                    'artifact_id', a.id,
                    'session_id', a.session_id,
                    'user_id', a.user_id,
                    'artifact_type', a.artifact_type,
                    'content_type', a.content_type,
                    'object_key', a.object_key,
                    'byte_size', a.byte_size,
                    'sha256', a.sha256,
                    'captured_at', a.captured_at,
                    'uploaded_at', a.uploaded_at,
                    'metadata', COALESCE(a.metadata, '{}'::jsonb),
                    'site_id', m.site_id,
                    'site_name', m.site_name,
                    'building_id', m.building_id,
                    'building_name', m.building_name,
                    'floor_id', m.floor_id,
                    'floor_name', m.floor_name,
                    'floor_index', m.floor_index,
                    'tags', COALESCE(to_jsonb(m.tags), '[]'::jsonb)
                )",
            }),
            Entity::FieldSurveyRfObservations => Ok(Self {
                from_sql: "platform.survey_rf_observations rf",
                time_column: "rf.captured_at",
                select_sql: "jsonb_build_object(
                    'entity', 'field_survey_rf_observation',
                    'id', rf.id,
                    'session_id', rf.session_id,
                    'sidekick_id', rf.sidekick_id,
                    'radio_id', rf.radio_id,
                    'interface_name', rf.interface_name,
                    'bssid', rf.bssid,
                    'ssid', rf.ssid,
                    'hidden_ssid', rf.hidden_ssid,
                    'frame_type', rf.frame_type,
                    'rssi_dbm', rf.rssi_dbm,
                    'noise_floor_dbm', rf.noise_floor_dbm,
                    'snr_db', rf.snr_db,
                    'frequency_mhz', rf.frequency_mhz,
                    'channel', rf.channel,
                    'channel_width_mhz', rf.channel_width_mhz,
                    'captured_at', rf.captured_at,
                    'captured_at_unix_nanos', rf.captured_at_unix_nanos,
                    'captured_at_monotonic_nanos', rf.captured_at_monotonic_nanos,
                    'parser_confidence', rf.parser_confidence
                )",
            }),
            Entity::FieldSurveyPoseSamples => Ok(Self {
                from_sql: "platform.survey_pose_samples p",
                time_column: "p.captured_at",
                select_sql: "jsonb_build_object(
                    'entity', 'field_survey_pose_sample',
                    'id', p.id,
                    'session_id', p.session_id,
                    'scanner_device_id', p.scanner_device_id,
                    'captured_at', p.captured_at,
                    'captured_at_unix_nanos', p.captured_at_unix_nanos,
                    'captured_at_monotonic_nanos', p.captured_at_monotonic_nanos,
                    'x', p.x,
                    'y', p.y,
                    'z', p.z,
                    'qx', p.qx,
                    'qy', p.qy,
                    'qz', p.qz,
                    'qw', p.qw,
                    'latitude', p.latitude,
                    'longitude', p.longitude,
                    'altitude', p.altitude,
                    'accuracy_m', p.accuracy_m,
                    'tracking_quality', p.tracking_quality
                )",
            }),
            Entity::FieldSurveyRfPoseMatches => Ok(Self {
                from_sql: "platform.survey_rf_pose_matches rpm",
                time_column: "rpm.rf_captured_at",
                select_sql: "jsonb_build_object(
                    'entity', 'field_survey_rf_pose_match',
                    'rf_observation_id', rpm.rf_observation_id,
                    'pose_sample_id', rpm.pose_sample_id,
                    'session_id', rpm.session_id,
                    'sidekick_id', rpm.sidekick_id,
                    'radio_id', rpm.radio_id,
                    'interface_name', rpm.interface_name,
                    'bssid', rpm.bssid,
                    'ssid', rpm.ssid,
                    'hidden_ssid', rpm.hidden_ssid,
                    'frame_type', rpm.frame_type,
                    'rssi_dbm', rpm.rssi_dbm,
                    'noise_floor_dbm', rpm.noise_floor_dbm,
                    'snr_db', rpm.snr_db,
                    'frequency_mhz', rpm.frequency_mhz,
                    'channel', rpm.channel,
                    'channel_width_mhz', rpm.channel_width_mhz,
                    'rf_captured_at', rpm.rf_captured_at,
                    'pose_captured_at', rpm.pose_captured_at,
                    'pose_offset_nanos', rpm.pose_offset_nanos,
                    'scanner_device_id', rpm.scanner_device_id,
                    'x', rpm.x,
                    'y', rpm.y,
                    'z', rpm.z,
                    'qx', rpm.qx,
                    'qy', rpm.qy,
                    'qz', rpm.qz,
                    'qw', rpm.qw,
                    'latitude', rpm.latitude,
                    'longitude', rpm.longitude,
                    'altitude', rpm.altitude,
                    'accuracy_m', rpm.accuracy_m,
                    'tracking_quality', rpm.tracking_quality
                )",
            }),
            Entity::FieldSurveySpectrumObservations => Ok(Self {
                from_sql: "platform.survey_spectrum_observations s",
                time_column: "s.captured_at",
                select_sql: "jsonb_build_object(
                    'entity', 'field_survey_spectrum_observation',
                    'id', s.id,
                    'session_id', s.session_id,
                    'sidekick_id', s.sidekick_id,
                    'sdr_id', s.sdr_id,
                    'device_kind', s.device_kind,
                    'serial_number', s.serial_number,
                    'sweep_id', s.sweep_id,
                    'started_at', s.started_at,
                    'captured_at', s.captured_at,
                    'start_frequency_hz', s.start_frequency_hz,
                    'stop_frequency_hz', s.stop_frequency_hz,
                    'bin_width_hz', s.bin_width_hz,
                    'sample_count', s.sample_count,
                    'peak_power_dbm', (
                        SELECT max(value)::float8 FROM unnest(s.power_bins_dbm) AS value
                    ),
                    'avg_power_dbm', (
                        SELECT avg(value)::float8 FROM unnest(s.power_bins_dbm) AS value
                    )
                )",
            }),
            _ => Err(ServiceError::InvalidRequest(
                "entity not supported by FieldSurvey query".into(),
            )),
        }
    }
}

fn field_sql(entity: &Entity, field: &str) -> Option<(&'static str, FieldKind)> {
    match entity {
        Entity::FieldSurveySessions => match field {
            "session_id" => Some(("m.session_id", FieldKind::Text)),
            "user_id" => Some(("m.user_id", FieldKind::Text)),
            "site_id" => Some(("m.site_id", FieldKind::Text)),
            "site_name" => Some(("m.site_name", FieldKind::Text)),
            "building_id" => Some(("m.building_id", FieldKind::Text)),
            "building_name" => Some(("m.building_name", FieldKind::Text)),
            "floor_id" => Some(("m.floor_id", FieldKind::Text)),
            "floor_name" => Some(("m.floor_name", FieldKind::Text)),
            "floor_index" => Some(("m.floor_index", FieldKind::Int)),
            "tags" => Some(("m.tags", FieldKind::Tags)),
            "has_floorplan" => Some((
                "EXISTS (SELECT 1 FROM platform.survey_room_artifacts a WHERE a.session_id = m.session_id AND a.user_id = m.user_id AND a.artifact_type = 'floorplan_geojson' AND jsonb_typeof(a.metadata->'floorplan_segments') = 'array' AND jsonb_array_length(a.metadata->'floorplan_segments') > 0)",
                FieldKind::Bool,
            )),
            _ => None,
        },
        Entity::FieldSurveyRasters => match field {
            "id" | "raster_id" => Some(("r.id::text", FieldKind::Text)),
            "session_id" => Some(("r.session_id", FieldKind::Text)),
            "user_id" => Some(("r.user_id", FieldKind::Text)),
            "overlay_type" => Some(("r.overlay_type", FieldKind::Text)),
            "selector_type" => Some(("r.selector_type", FieldKind::Text)),
            "selector_value" => Some(("r.selector_value", FieldKind::Text)),
            "site_id" => Some(("m.site_id", FieldKind::Text)),
            "site_name" => Some(("m.site_name", FieldKind::Text)),
            "building_id" => Some(("m.building_id", FieldKind::Text)),
            "building_name" => Some(("m.building_name", FieldKind::Text)),
            "floor_id" => Some(("m.floor_id", FieldKind::Text)),
            "floor_name" => Some(("m.floor_name", FieldKind::Text)),
            "floor_index" => Some(("m.floor_index", FieldKind::Int)),
            "tags" => Some(("m.tags", FieldKind::Tags)),
            "has_floorplan" => Some((
                "EXISTS (SELECT 1 FROM platform.survey_room_artifacts a WHERE a.session_id = r.session_id AND a.user_id = r.user_id AND a.artifact_type = 'floorplan_geojson' AND jsonb_typeof(a.metadata->'floorplan_segments') = 'array' AND jsonb_array_length(a.metadata->'floorplan_segments') > 0)",
                FieldKind::Bool,
            )),
            _ => None,
        },
        Entity::FieldSurveyArtifacts => match field {
            "id" | "artifact_id" => Some(("a.id::text", FieldKind::Text)),
            "session_id" => Some(("a.session_id", FieldKind::Text)),
            "user_id" => Some(("a.user_id", FieldKind::Text)),
            "artifact_type" => Some(("a.artifact_type", FieldKind::Text)),
            "content_type" => Some(("a.content_type", FieldKind::Text)),
            "object_key" => Some(("a.object_key", FieldKind::Text)),
            "sha256" => Some(("a.sha256", FieldKind::Text)),
            "site_id" => Some(("m.site_id", FieldKind::Text)),
            "site_name" => Some(("m.site_name", FieldKind::Text)),
            "building_id" => Some(("m.building_id", FieldKind::Text)),
            "building_name" => Some(("m.building_name", FieldKind::Text)),
            "floor_id" => Some(("m.floor_id", FieldKind::Text)),
            "floor_name" => Some(("m.floor_name", FieldKind::Text)),
            "floor_index" => Some(("m.floor_index", FieldKind::Int)),
            "tags" => Some(("m.tags", FieldKind::Tags)),
            _ => None,
        },
        Entity::FieldSurveyRfObservations => match field {
            "id" => Some(("rf.id::text", FieldKind::Text)),
            "session_id" => Some(("rf.session_id", FieldKind::Text)),
            "sidekick_id" => Some(("rf.sidekick_id", FieldKind::Text)),
            "radio_id" => Some(("rf.radio_id", FieldKind::Text)),
            "interface_name" => Some(("rf.interface_name", FieldKind::Text)),
            "bssid" => Some(("rf.bssid", FieldKind::Text)),
            "ssid" => Some(("rf.ssid", FieldKind::Text)),
            "frame_type" => Some(("rf.frame_type", FieldKind::Text)),
            "frequency_mhz" => Some(("rf.frequency_mhz", FieldKind::Int)),
            "channel" => Some(("rf.channel", FieldKind::Int)),
            "rssi_dbm" => Some(("rf.rssi_dbm", FieldKind::Int)),
            "noise_floor_dbm" => Some(("rf.noise_floor_dbm", FieldKind::Int)),
            "snr_db" => Some(("rf.snr_db", FieldKind::Int)),
            _ => None,
        },
        Entity::FieldSurveyPoseSamples => match field {
            "id" => Some(("p.id::text", FieldKind::Text)),
            "session_id" => Some(("p.session_id", FieldKind::Text)),
            "scanner_device_id" => Some(("p.scanner_device_id", FieldKind::Text)),
            "tracking_quality" => Some(("p.tracking_quality", FieldKind::Text)),
            "x" => Some(("p.x", FieldKind::Float)),
            "y" => Some(("p.y", FieldKind::Float)),
            "z" => Some(("p.z", FieldKind::Float)),
            _ => None,
        },
        Entity::FieldSurveyRfPoseMatches => match field {
            "rf_observation_id" => Some(("rpm.rf_observation_id::text", FieldKind::Text)),
            "pose_sample_id" => Some(("rpm.pose_sample_id::text", FieldKind::Text)),
            "session_id" => Some(("rpm.session_id", FieldKind::Text)),
            "sidekick_id" => Some(("rpm.sidekick_id", FieldKind::Text)),
            "radio_id" => Some(("rpm.radio_id", FieldKind::Text)),
            "interface_name" => Some(("rpm.interface_name", FieldKind::Text)),
            "bssid" => Some(("rpm.bssid", FieldKind::Text)),
            "ssid" => Some(("rpm.ssid", FieldKind::Text)),
            "frame_type" => Some(("rpm.frame_type", FieldKind::Text)),
            "frequency_mhz" => Some(("rpm.frequency_mhz", FieldKind::Int)),
            "channel" => Some(("rpm.channel", FieldKind::Int)),
            "rssi_dbm" => Some(("rpm.rssi_dbm", FieldKind::Int)),
            "pose_offset_nanos" => Some(("rpm.pose_offset_nanos", FieldKind::Int)),
            "scanner_device_id" => Some(("rpm.scanner_device_id", FieldKind::Text)),
            "tracking_quality" => Some(("rpm.tracking_quality", FieldKind::Text)),
            _ => None,
        },
        Entity::FieldSurveySpectrumObservations => match field {
            "id" => Some(("s.id::text", FieldKind::Text)),
            "session_id" => Some(("s.session_id", FieldKind::Text)),
            "sidekick_id" => Some(("s.sidekick_id", FieldKind::Text)),
            "sdr_id" => Some(("s.sdr_id", FieldKind::Text)),
            "device_kind" => Some(("s.device_kind", FieldKind::Text)),
            "serial_number" => Some(("s.serial_number", FieldKind::Text)),
            "sweep_id" => Some(("s.sweep_id", FieldKind::Int)),
            "start_frequency_hz" => Some(("s.start_frequency_hz", FieldKind::Int)),
            "stop_frequency_hz" => Some(("s.stop_frequency_hz", FieldKind::Int)),
            "sample_count" => Some(("s.sample_count", FieldKind::Int)),
            _ => None,
        },
        _ => None,
    }
}

fn filter_condition(
    spec: EntitySpec,
    filter: &Filter,
    binds: &mut Vec<BindParam>,
) -> Result<Option<String>> {
    let Some((field_sql, kind)) = field_sql(&filter_entity(spec)?, filter.field.as_str()) else {
        return Err(ServiceError::InvalidRequest(format!(
            "unsupported filter field for FieldSurvey entity: '{}'",
            filter.field
        )));
    };

    match kind {
        FieldKind::Text => text_condition(field_sql, filter, binds).map(Some),
        FieldKind::Int => numeric_condition(field_sql, filter, binds, NumericKind::Int).map(Some),
        FieldKind::Float => {
            numeric_condition(field_sql, filter, binds, NumericKind::Float).map(Some)
        }
        FieldKind::Bool => bool_condition(field_sql, filter, binds).map(Some),
        FieldKind::Tags => tags_condition(field_sql, filter, binds).map(Some),
    }
}

fn filter_entity(spec: EntitySpec) -> Result<Entity> {
    match spec.from_sql {
        "platform.survey_session_metadata m" => Ok(Entity::FieldSurveySessions),
        from if from.starts_with("platform.survey_coverage_rasters") => {
            Ok(Entity::FieldSurveyRasters)
        }
        from if from.starts_with("platform.survey_room_artifacts") => {
            Ok(Entity::FieldSurveyArtifacts)
        }
        "platform.survey_rf_observations rf" => Ok(Entity::FieldSurveyRfObservations),
        "platform.survey_pose_samples p" => Ok(Entity::FieldSurveyPoseSamples),
        "platform.survey_rf_pose_matches rpm" => Ok(Entity::FieldSurveyRfPoseMatches),
        "platform.survey_spectrum_observations s" => Ok(Entity::FieldSurveySpectrumObservations),
        _ => Err(ServiceError::InvalidRequest(
            "unknown FieldSurvey entity spec".into(),
        )),
    }
}

fn text_condition(field_sql: &str, filter: &Filter, binds: &mut Vec<BindParam>) -> Result<String> {
    match filter.op {
        FilterOp::Eq => {
            binds.push(BindParam::Text(filter.value.as_scalar()?.to_string()));
            Ok(format!("{field_sql} = ?"))
        }
        FilterOp::NotEq => {
            binds.push(BindParam::Text(filter.value.as_scalar()?.to_string()));
            Ok(format!("{field_sql} <> ?"))
        }
        FilterOp::Like => {
            binds.push(BindParam::Text(filter.value.as_scalar()?.to_string()));
            Ok(format!("{field_sql} ILIKE ?"))
        }
        FilterOp::NotLike => {
            binds.push(BindParam::Text(filter.value.as_scalar()?.to_string()));
            Ok(format!("{field_sql} NOT ILIKE ?"))
        }
        FilterOp::In => {
            let values = filter.value.as_list()?.to_vec();
            if values.is_empty() {
                Ok("TRUE".into())
            } else {
                binds.push(BindParam::TextArray(values));
                Ok(format!("{field_sql} = ANY(?)"))
            }
        }
        FilterOp::NotIn => {
            let values = filter.value.as_list()?.to_vec();
            if values.is_empty() {
                Ok("TRUE".into())
            } else {
                binds.push(BindParam::TextArray(values));
                Ok(format!("NOT ({field_sql} = ANY(?))"))
            }
        }
        _ => Err(ServiceError::InvalidRequest(format!(
            "unsupported operator for text FieldSurvey filter: {:?}",
            filter.op
        ))),
    }
}

enum NumericKind {
    Int,
    Float,
}

fn numeric_condition(
    field_sql: &str,
    filter: &Filter,
    binds: &mut Vec<BindParam>,
    kind: NumericKind,
) -> Result<String> {
    let op = match filter.op {
        FilterOp::Eq => "=",
        FilterOp::NotEq => "<>",
        FilterOp::Gt => ">",
        FilterOp::Gte => ">=",
        FilterOp::Lt => "<",
        FilterOp::Lte => "<=",
        _ => {
            return Err(ServiceError::InvalidRequest(format!(
                "unsupported operator for numeric FieldSurvey filter: {:?}",
                filter.op
            )))
        }
    };

    match kind {
        NumericKind::Int => binds.push(BindParam::Int(parse_i64(filter.value.as_scalar()?)?)),
        NumericKind::Float => binds.push(BindParam::Float(parse_f64(filter.value.as_scalar()?)?)),
    }

    Ok(format!("{field_sql} {op} ?"))
}

fn bool_condition(field_sql: &str, filter: &Filter, binds: &mut Vec<BindParam>) -> Result<String> {
    let value = parse_bool(filter.value.as_scalar()?)?;
    match filter.op {
        FilterOp::Eq => {
            binds.push(BindParam::Bool(value));
            Ok(format!("({field_sql}) = ?"))
        }
        FilterOp::NotEq => {
            binds.push(BindParam::Bool(value));
            Ok(format!("({field_sql}) <> ?"))
        }
        _ => Err(ServiceError::InvalidRequest(
            "boolean FieldSurvey filters only support equality".into(),
        )),
    }
}

fn tags_condition(field_sql: &str, filter: &Filter, binds: &mut Vec<BindParam>) -> Result<String> {
    let values = match filter.op {
        FilterOp::Eq | FilterOp::NotEq => vec![filter.value.as_scalar()?.to_string()],
        FilterOp::In | FilterOp::NotIn => filter.value.as_list()?.to_vec(),
        _ => {
            return Err(ServiceError::InvalidRequest(
                "tags filter only supports equality and list filters".into(),
            ))
        }
    };

    if values.is_empty() {
        return Ok("TRUE".into());
    }

    binds.push(BindParam::TextArray(values));
    let condition = format!("COALESCE({field_sql}, '{{}}'::text[]) && ?");
    if matches!(filter.op, FilterOp::NotEq | FilterOp::NotIn) {
        Ok(format!("NOT ({condition})"))
    } else {
        Ok(condition)
    }
}

fn order_sql(spec: EntitySpec, order: &[OrderClause]) -> String {
    let clauses: Vec<String> = order
        .iter()
        .filter_map(|clause| {
            order_column(spec, clause.field.as_str()).map(|column| {
                let direction = match clause.direction {
                    OrderDirection::Asc => "ASC",
                    OrderDirection::Desc => "DESC",
                };
                format!("{column} {direction}")
            })
        })
        .collect();

    if clauses.is_empty() {
        format!(" ORDER BY {} DESC", spec.time_column)
    } else {
        format!(" ORDER BY {}", clauses.join(", "))
    }
}

fn order_column(spec: EntitySpec, field: &str) -> Option<&'static str> {
    let entity = filter_entity(spec).ok()?;
    match field {
        "time" | "timestamp" | "captured_at" | "generated_at" | "uploaded_at" | "updated_at"
        | "rf_captured_at" => Some(spec.time_column),
        _ => field_sql(&entity, field).map(|(column, _)| column),
    }
}

fn bind_param<'a>(
    query: BoxedSqlQuery<'a, Pg, SqlQuery>,
    param: BindParam,
) -> Result<BoxedSqlQuery<'a, Pg, SqlQuery>> {
    match param {
        BindParam::Text(value) => Ok(query.bind::<Text, _>(value)),
        BindParam::TextArray(values) => Ok(query.bind::<Array<Text>, _>(values)),
        BindParam::IntArray(values) => Ok(query.bind::<Array<BigInt>, _>(values)),
        BindParam::Bool(value) => Ok(query.bind::<Bool, _>(value)),
        BindParam::Int(value) => Ok(query.bind::<BigInt, _>(value)),
        BindParam::Float(value) => Ok(query.bind::<Float8, _>(value)),
        BindParam::Timestamptz(value) => {
            let timestamp = chrono::DateTime::parse_from_rfc3339(&value)
                .map(|dt| dt.with_timezone(&chrono::Utc))
                .map_err(|err| {
                    ServiceError::Internal(anyhow::anyhow!(
                        "invalid timestamptz bind {value:?}: {err}"
                    ))
                })?;
            Ok(query.bind::<Timestamptz, _>(timestamp))
        }
        BindParam::Uuid(value) => Ok(query.bind::<diesel::sql_types::Uuid, _>(value)),
    }
}

fn rewrite_placeholders(sql: &str) -> String {
    let mut result = String::with_capacity(sql.len());
    let mut index = 1;
    for ch in sql.chars() {
        if ch == '?' {
            result.push('$');
            result.push_str(&index.to_string());
            index += 1;
        } else {
            result.push(ch);
        }
    }
    result
}

fn parse_i64(raw: &str) -> Result<i64> {
    raw.parse::<i64>().map_err(|_| {
        ServiceError::InvalidRequest(format!("expected integer FieldSurvey filter value: {raw}"))
    })
}

fn parse_f64(raw: &str) -> Result<f64> {
    raw.parse::<f64>().map_err(|_| {
        ServiceError::InvalidRequest(format!("expected numeric FieldSurvey filter value: {raw}"))
    })
}

fn parse_bool(raw: &str) -> Result<bool> {
    match raw.to_ascii_lowercase().as_str() {
        "true" | "1" | "yes" => Ok(true),
        "false" | "0" | "no" => Ok(false),
        _ => Err(ServiceError::InvalidRequest(format!(
            "expected boolean FieldSurvey filter value: {raw}"
        ))),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{
        config::AppConfig,
        parser,
        query::{translate_request, QueryRequest},
    };

    fn translate(query: &str) -> String {
        translate_request(
            &AppConfig::embedded("postgres://srql-test".to_string()),
            QueryRequest {
                query: query.to_string(),
                limit: None,
                cursor: None,
                direction: Default::default(),
                mode: None,
            },
        )
        .unwrap()
        .sql
        .to_lowercase()
    }

    #[test]
    fn parses_fieldsurvey_rasters_entity() {
        let ast = parser::parse("in:field_survey_rasters overlay_type:wifi_rssi").unwrap();
        assert!(matches!(ast.entity, Entity::FieldSurveyRasters));
    }

    #[test]
    fn fieldsurvey_raster_sql_includes_metadata_filters() {
        let sql = translate(
            "in:field_survey_rasters site_id:ORD building_id:terminal-b floor_index:2 overlay_type:wifi_rssi has_floorplan:true sort:generated_at:desc limit:1",
        );

        assert!(sql.contains("survey_coverage_rasters"));
        assert!(sql.contains("survey_session_metadata"));
        assert!(sql.contains("m.site_id = $1"));
        assert!(sql.contains("m.building_id = $2"));
        assert!(sql.contains("m.floor_index = $3"));
        assert!(sql.contains("r.overlay_type = $4"));
        assert!(sql.contains("has_floorplan"));
    }

    #[test]
    fn fieldsurvey_order_and_pagination_binds_are_preserved() {
        let response = translate_request(
            &AppConfig::embedded("postgres://srql-test".to_string()),
            QueryRequest {
                query: "in:field_survey_rasters overlay_type:wifi_rssi sort:generated_at:asc"
                    .into(),
                limit: Some(5),
                cursor: None,
                direction: Default::default(),
                mode: None,
            },
        )
        .unwrap();

        let sql = response.sql.to_lowercase();
        assert!(sql.contains("order by r.generated_at asc limit $2 offset $3"));
        assert_eq!(response.params.len(), 3);
    }

    #[test]
    fn fieldsurvey_raw_match_sql_is_bounded_by_time() {
        let sql = translate(
            "in:field_survey_rf_pose_matches session_id:abc bssid:aa:bb:cc:dd:ee:ff time:last_1h limit:100",
        );

        assert!(sql.contains("survey_rf_pose_matches"));
        assert!(sql.contains("rpm.rf_captured_at >= $1"));
        assert!(sql.contains("rpm.session_id = $3"));
        assert!(sql.contains("rpm.bssid = $4"));
    }

    #[test]
    fn fieldsurvey_raw_query_without_time_gets_default_bound() {
        let sql = translate("in:field_survey_rf_observations session_id:abc");
        assert!(sql.contains("rf.captured_at >= now() - interval '1 hour'"));
    }

    #[test]
    fn fieldsurvey_tags_filter_uses_array_overlap() {
        let sql = translate("in:field_survey_sessions tags:[airport,ord]");
        assert!(sql.contains("m.tags"));
        assert!(sql.contains("&& $1"));
    }

    #[test]
    fn unsupported_fieldsurvey_filter_fails() {
        let result = translate_request(
            &AppConfig::embedded("postgres://srql-test".to_string()),
            QueryRequest {
                query: "in:field_survey_rasters raw_packet:yes".into(),
                limit: None,
                cursor: None,
                direction: Default::default(),
                mode: None,
            },
        );

        assert!(result.is_err());
    }
}
