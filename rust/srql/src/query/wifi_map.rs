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
    TextArray,
    JsonbKey,
    Date,
}

#[derive(Clone, Copy)]
struct EntitySpec {
    from_sql: &'static str,
    select_sql: &'static str,
    time_column: &'static str,
}

fn ensure_entity(plan: &QueryPlan) -> Result<()> {
    if matches!(
        plan.entity,
        Entity::WifiSites
            | Entity::WifiSiteSnapshots
            | Entity::WifiAccessPoints
            | Entity::WifiControllers
            | Entity::WifiRadiusGroups
            | Entity::WifiFleetHistory
            | Entity::WifiSiteReferences
    ) {
        Ok(())
    } else {
        Err(ServiceError::InvalidRequest(
            "entity not supported by WiFi map query".into(),
        ))
    }
}

fn build_sql(plan: &QueryPlan) -> Result<BuiltSql> {
    if plan.stats.is_some() {
        return Err(ServiceError::InvalidRequest(
            "WiFi map stats/grouping is not implemented yet".into(),
        ));
    }

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
    }

    for filter in &plan.filters {
        where_parts.push(filter_condition(&plan.entity, filter, &mut binds)?);
    }

    let where_sql = if where_parts.is_empty() {
        String::new()
    } else {
        format!(" WHERE {}", where_parts.join(" AND "))
    };

    let order_sql = order_sql(&plan.entity, spec, &plan.order);

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

impl EntitySpec {
    fn for_entity(entity: &Entity) -> Result<Self> {
        match entity {
            Entity::WifiSites => Ok(Self {
                from_sql: "platform.wifi_sites s
                    LEFT JOIN LATERAL (
                        SELECT ss.*
                        FROM platform.wifi_site_snapshots ss
                        WHERE ss.source_id = s.source_id AND ss.site_code = s.site_code
                        ORDER BY ss.collection_timestamp DESC
                        LIMIT 1
                    ) latest ON true",
                time_column: "COALESCE(latest.collection_timestamp, s.last_seen_at, s.updated_at)",
                select_sql: "jsonb_build_object(
                    'entity', 'wifi_site',
                    'feature_id', concat(s.source_id::text, ':', s.site_code),
                    'source_id', s.source_id::text,
                    'site_code', s.site_code,
                    'name', s.name,
                    'label', s.site_code,
                    'site_type', s.site_type,
                    'region', s.region,
                    'latitude', s.latitude,
                    'longitude', s.longitude,
                    'location', CASE WHEN s.location IS NULL THEN NULL ELSE ST_AsGeoJSON(s.location::geometry)::jsonb END,
                    'ap_count', COALESCE(latest.ap_count, 0),
                    'up_count', COALESCE(latest.up_count, 0),
                    'down_count', COALESCE(latest.down_count, 0),
                    'model_breakdown', COALESCE(latest.model_breakdown, '{}'::jsonb),
                    'controller_names', COALESCE(to_jsonb(latest.controller_names), '[]'::jsonb),
                    'wlc_count', COALESCE(latest.wlc_count, 0),
                    'wlc_model_breakdown', COALESCE(latest.wlc_model_breakdown, '{}'::jsonb),
                    'aos_version_breakdown', COALESCE(latest.aos_version_breakdown, '{}'::jsonb),
                    'server_group', latest.server_group,
                    'cluster', latest.cluster,
                    'all_server_groups', COALESCE(to_jsonb(latest.all_server_groups), '[]'::jsonb),
                    'aaa_profile', latest.aaa_profile,
                    'collection_timestamp', latest.collection_timestamp,
                    'first_seen_at', s.first_seen_at,
                    'last_seen_at', s.last_seen_at,
                    'metadata', COALESCE(s.metadata, '{}'::jsonb)
                )",
            }),
            Entity::WifiSiteSnapshots => Ok(Self {
                from_sql: "platform.wifi_site_snapshots ss",
                time_column: "ss.collection_timestamp",
                select_sql: "jsonb_build_object(
                    'entity', 'wifi_site_snapshot',
                    'id', ss.id::text,
                    'source_id', ss.source_id::text,
                    'batch_id', ss.batch_id::text,
                    'site_code', ss.site_code,
                    'collection_timestamp', ss.collection_timestamp,
                    'ap_count', ss.ap_count,
                    'up_count', ss.up_count,
                    'down_count', ss.down_count,
                    'model_breakdown', COALESCE(ss.model_breakdown, '{}'::jsonb),
                    'controller_names', COALESCE(to_jsonb(ss.controller_names), '[]'::jsonb),
                    'wlc_count', ss.wlc_count,
                    'wlc_model_breakdown', COALESCE(ss.wlc_model_breakdown, '{}'::jsonb),
                    'aos_version_breakdown', COALESCE(ss.aos_version_breakdown, '{}'::jsonb),
                    'server_group', ss.server_group,
                    'cluster', ss.cluster,
                    'all_server_groups', COALESCE(to_jsonb(ss.all_server_groups), '[]'::jsonb),
                    'aaa_profile', ss.aaa_profile,
                    'metadata', COALESCE(ss.metadata, '{}'::jsonb)
                )",
            }),
            Entity::WifiAccessPoints => Ok(Self {
                from_sql: "platform.wifi_access_point_observations ap
                    LEFT JOIN platform.wifi_sites s ON s.source_id = ap.source_id AND s.site_code = ap.site_code",
                time_column: "ap.collection_timestamp",
                select_sql: "jsonb_build_object(
                    'entity', 'wifi_access_point',
                    'id', ap.id::text,
                    'source_id', ap.source_id::text,
                    'batch_id', ap.batch_id::text,
                    'device_uid', ap.device_uid,
                    'site_code', ap.site_code,
                    'site_name', s.name,
                    'region', s.region,
                    'latitude', s.latitude,
                    'longitude', s.longitude,
                    'collection_timestamp', ap.collection_timestamp,
                    'name', ap.name,
                    'hostname', ap.hostname,
                    'mac', ap.mac,
                    'serial', ap.serial,
                    'ip', ap.ip,
                    'status', ap.status,
                    'model', ap.model,
                    'vendor_name', ap.vendor_name,
                    'metadata', COALESCE(ap.metadata, '{}'::jsonb)
                )",
            }),
            Entity::WifiControllers => Ok(Self {
                from_sql: "platform.wifi_controller_observations c
                    LEFT JOIN platform.wifi_sites s ON s.source_id = c.source_id AND s.site_code = c.site_code",
                time_column: "c.collection_timestamp",
                select_sql: "jsonb_build_object(
                    'entity', 'wifi_controller',
                    'id', c.id::text,
                    'source_id', c.source_id::text,
                    'batch_id', c.batch_id::text,
                    'device_uid', c.device_uid,
                    'site_code', c.site_code,
                    'site_name', s.name,
                    'region', s.region,
                    'latitude', s.latitude,
                    'longitude', s.longitude,
                    'collection_timestamp', c.collection_timestamp,
                    'name', c.name,
                    'hostname', c.hostname,
                    'ip', c.ip,
                    'mac', c.mac,
                    'base_mac', c.base_mac,
                    'serial', c.serial,
                    'model', c.model,
                    'aos_version', c.aos_version,
                    'psu_status', c.psu_status,
                    'uptime', c.uptime,
                    'reboot_cause', c.reboot_cause,
                    'metadata', COALESCE(c.metadata, '{}'::jsonb)
                )",
            }),
            Entity::WifiRadiusGroups => Ok(Self {
                from_sql: "platform.wifi_radius_group_observations r
                    LEFT JOIN platform.wifi_sites s ON s.source_id = r.source_id AND s.site_code = r.site_code",
                time_column: "r.collection_timestamp",
                select_sql: "jsonb_build_object(
                    'entity', 'wifi_radius_group',
                    'id', r.id::text,
                    'source_id', r.source_id::text,
                    'batch_id', r.batch_id::text,
                    'controller_device_uid', r.controller_device_uid,
                    'site_code', r.site_code,
                    'site_name', s.name,
                    'region', s.region,
                    'latitude', s.latitude,
                    'longitude', s.longitude,
                    'collection_timestamp', r.collection_timestamp,
                    'controller_alias', r.controller_alias,
                    'aaa_profile', r.aaa_profile,
                    'server_group', r.server_group,
                    'cluster', r.cluster,
                    'all_server_groups', COALESCE(to_jsonb(r.all_server_groups), '[]'::jsonb),
                    'status', r.status,
                    'metadata', COALESCE(r.metadata, '{}'::jsonb)
                )",
            }),
            Entity::WifiFleetHistory => Ok(Self {
                from_sql: "platform.wifi_fleet_history h",
                time_column: "h.build_date::timestamptz",
                select_sql: "jsonb_build_object(
                    'entity', 'wifi_fleet_history',
                    'source_id', h.source_id::text,
                    'batch_id', h.batch_id::text,
                    'build_date', h.build_date,
                    'ap_total', h.ap_total,
                    'count_2xx', h.count_2xx,
                    'count_3xx', h.count_3xx,
                    'count_4xx', h.count_4xx,
                    'count_5xx', h.count_5xx,
                    'count_6xx', h.count_6xx,
                    'count_7xx', h.count_7xx,
                    'count_other', h.count_other,
                    'count_ap325', h.count_ap325,
                    'pct_6xx', h.pct_6xx,
                    'pct_legacy', h.pct_legacy,
                    'site_count', h.site_count,
                    'metadata', COALESCE(h.metadata, '{}'::jsonb),
                    'inserted_at', h.inserted_at,
                    'updated_at', h.updated_at
                )",
            }),
            Entity::WifiSiteReferences => Ok(Self {
                from_sql: "platform.wifi_site_references ref",
                time_column: "ref.updated_at",
                select_sql: "jsonb_build_object(
                    'entity', 'wifi_site_reference',
                    'source_id', ref.source_id::text,
                    'site_code', ref.site_code,
                    'name', ref.name,
                    'site_type', ref.site_type,
                    'region', ref.region,
                    'latitude', ref.latitude,
                    'longitude', ref.longitude,
                    'location', CASE WHEN ref.location IS NULL THEN NULL ELSE ST_AsGeoJSON(ref.location::geometry)::jsonb END,
                    'reference_hash', ref.reference_hash,
                    'reference_metadata', COALESCE(ref.reference_metadata, '{}'::jsonb),
                    'updated_at', ref.updated_at
                )",
            }),
            _ => Err(ServiceError::InvalidRequest(
                "entity not supported by WiFi map query".into(),
            )),
        }
    }
}

fn filter_condition(
    entity: &Entity,
    filter: &Filter,
    binds: &mut Vec<BindParam>,
) -> Result<String> {
    let Some((field_sql, kind)) = field_sql(entity, filter.field.as_str()) else {
        return Err(ServiceError::InvalidRequest(format!(
            "unsupported filter field for WiFi map entity: '{}'",
            filter.field
        )));
    };

    match kind {
        FieldKind::Text => text_condition(field_sql, filter, binds),
        FieldKind::Int => numeric_condition(field_sql, filter, binds, NumericKind::Int),
        FieldKind::Float => numeric_condition(field_sql, filter, binds, NumericKind::Float),
        FieldKind::TextArray => text_array_condition(field_sql, filter, binds),
        FieldKind::JsonbKey => jsonb_key_condition(field_sql, filter, binds),
        FieldKind::Date => date_condition(field_sql, filter, binds),
    }
}

fn field_sql(entity: &Entity, field: &str) -> Option<(&'static str, FieldKind)> {
    let common_site = match field {
        "source_id" => Some(("source_id::text", FieldKind::Text)),
        "site_code" | "iata" => Some(("site_code", FieldKind::Text)),
        "name" | "site_name" => Some(("name", FieldKind::Text)),
        "site_type" => Some(("site_type", FieldKind::Text)),
        "region" => Some(("region", FieldKind::Text)),
        "latitude" | "lat" => Some(("latitude", FieldKind::Float)),
        "longitude" | "lon" | "lng" => Some(("longitude", FieldKind::Float)),
        _ => None,
    };

    match entity {
        Entity::WifiSites => match field {
            "source_id" => Some(("s.source_id::text", FieldKind::Text)),
            "site_code" | "iata" => Some(("s.site_code", FieldKind::Text)),
            "name" | "site_name" => Some(("s.name", FieldKind::Text)),
            "site_type" => Some(("s.site_type", FieldKind::Text)),
            "region" => Some(("s.region", FieldKind::Text)),
            "latitude" | "lat" => Some(("s.latitude", FieldKind::Float)),
            "longitude" | "lon" | "lng" => Some(("s.longitude", FieldKind::Float)),
            "ap_count" => Some(("COALESCE(latest.ap_count, 0)", FieldKind::Int)),
            "up_count" => Some(("COALESCE(latest.up_count, 0)", FieldKind::Int)),
            "down_count" => Some(("COALESCE(latest.down_count, 0)", FieldKind::Int)),
            "wlc_count" => Some(("COALESCE(latest.wlc_count, 0)", FieldKind::Int)),
            "ap_family" | "ap_model" | "model_family" => Some((
                "COALESCE(latest.model_breakdown, '{}'::jsonb)",
                FieldKind::JsonbKey,
            )),
            "wlc_model" => Some((
                "COALESCE(latest.wlc_model_breakdown, '{}'::jsonb)",
                FieldKind::JsonbKey,
            )),
            "aos_version" => Some((
                "COALESCE(latest.aos_version_breakdown, '{}'::jsonb)",
                FieldKind::JsonbKey,
            )),
            "server_group" => Some(("latest.server_group", FieldKind::Text)),
            "cluster" => Some(("latest.cluster", FieldKind::Text)),
            "aaa_profile" => Some(("latest.aaa_profile", FieldKind::Text)),
            "all_server_groups" => Some(("latest.all_server_groups", FieldKind::TextArray)),
            "controller_names" | "controllers" => {
                Some(("latest.controller_names", FieldKind::TextArray))
            }
            _ => None,
        },
        Entity::WifiSiteSnapshots => match field {
            "id" => Some(("ss.id::text", FieldKind::Text)),
            "source_id" => Some(("ss.source_id::text", FieldKind::Text)),
            "batch_id" => Some(("ss.batch_id::text", FieldKind::Text)),
            "site_code" | "iata" => Some(("ss.site_code", FieldKind::Text)),
            "ap_count" => Some(("ss.ap_count", FieldKind::Int)),
            "up_count" => Some(("ss.up_count", FieldKind::Int)),
            "down_count" => Some(("ss.down_count", FieldKind::Int)),
            "wlc_count" => Some(("ss.wlc_count", FieldKind::Int)),
            "ap_family" | "ap_model" | "model_family" => Some((
                "COALESCE(ss.model_breakdown, '{}'::jsonb)",
                FieldKind::JsonbKey,
            )),
            "wlc_model" => Some((
                "COALESCE(ss.wlc_model_breakdown, '{}'::jsonb)",
                FieldKind::JsonbKey,
            )),
            "aos_version" => Some((
                "COALESCE(ss.aos_version_breakdown, '{}'::jsonb)",
                FieldKind::JsonbKey,
            )),
            "server_group" => Some(("ss.server_group", FieldKind::Text)),
            "cluster" => Some(("ss.cluster", FieldKind::Text)),
            "aaa_profile" => Some(("ss.aaa_profile", FieldKind::Text)),
            "all_server_groups" => Some(("ss.all_server_groups", FieldKind::TextArray)),
            "controller_names" | "controllers" => {
                Some(("ss.controller_names", FieldKind::TextArray))
            }
            _ => None,
        },
        Entity::WifiAccessPoints => wifi_device_field_sql("ap", field),
        Entity::WifiControllers => match field {
            "aos_version" => Some(("c.aos_version", FieldKind::Text)),
            "base_mac" => Some(("c.base_mac", FieldKind::Text)),
            "psu_status" => Some(("c.psu_status", FieldKind::Text)),
            _ => wifi_device_field_sql("c", field),
        },
        Entity::WifiRadiusGroups => match field {
            "id" => Some(("r.id::text", FieldKind::Text)),
            "source_id" => Some(("r.source_id::text", FieldKind::Text)),
            "batch_id" => Some(("r.batch_id::text", FieldKind::Text)),
            "controller_device_uid" => Some(("r.controller_device_uid", FieldKind::Text)),
            "site_code" | "iata" => Some(("r.site_code", FieldKind::Text)),
            "site_name" => Some(("s.name", FieldKind::Text)),
            "region" => Some(("s.region", FieldKind::Text)),
            "latitude" | "lat" => Some(("s.latitude", FieldKind::Float)),
            "longitude" | "lon" | "lng" => Some(("s.longitude", FieldKind::Float)),
            "controller_alias" | "controller" => Some(("r.controller_alias", FieldKind::Text)),
            "aaa_profile" => Some(("r.aaa_profile", FieldKind::Text)),
            "server_group" => Some(("r.server_group", FieldKind::Text)),
            "cluster" => Some(("r.cluster", FieldKind::Text)),
            "all_server_groups" => Some(("r.all_server_groups", FieldKind::TextArray)),
            "status" => Some(("r.status", FieldKind::Text)),
            _ => None,
        },
        Entity::WifiFleetHistory => match field {
            "source_id" => Some(("h.source_id::text", FieldKind::Text)),
            "batch_id" => Some(("h.batch_id::text", FieldKind::Text)),
            "build_date" | "date" => Some(("h.build_date", FieldKind::Date)),
            "ap_total" => Some(("h.ap_total", FieldKind::Int)),
            "count_2xx" => Some(("h.count_2xx", FieldKind::Int)),
            "count_3xx" => Some(("h.count_3xx", FieldKind::Int)),
            "count_4xx" => Some(("h.count_4xx", FieldKind::Int)),
            "count_5xx" => Some(("h.count_5xx", FieldKind::Int)),
            "count_6xx" => Some(("h.count_6xx", FieldKind::Int)),
            "count_7xx" => Some(("h.count_7xx", FieldKind::Int)),
            "count_other" => Some(("h.count_other", FieldKind::Int)),
            "count_ap325" => Some(("h.count_ap325", FieldKind::Int)),
            "pct_6xx" => Some(("h.pct_6xx", FieldKind::Float)),
            "pct_legacy" => Some(("h.pct_legacy", FieldKind::Float)),
            "site_count" => Some(("h.site_count", FieldKind::Int)),
            _ => None,
        },
        Entity::WifiSiteReferences => common_site
            .map(|(column, kind)| {
                let column = match column {
                    "source_id::text" => "ref.source_id::text",
                    "site_code" => "ref.site_code",
                    "name" => "ref.name",
                    "site_type" => "ref.site_type",
                    "region" => "ref.region",
                    "latitude" => "ref.latitude",
                    "longitude" => "ref.longitude",
                    other => other,
                };
                (column, kind)
            })
            .or(match field {
                "reference_hash" => Some(("ref.reference_hash", FieldKind::Text)),
                _ => None,
            }),
        _ => None,
    }
}

fn wifi_device_field_sql(alias: &'static str, field: &str) -> Option<(&'static str, FieldKind)> {
    match (alias, field) {
        ("ap", "id") => Some(("ap.id::text", FieldKind::Text)),
        ("ap", "source_id") => Some(("ap.source_id::text", FieldKind::Text)),
        ("ap", "batch_id") => Some(("ap.batch_id::text", FieldKind::Text)),
        ("ap", "device_uid") => Some(("ap.device_uid", FieldKind::Text)),
        ("ap", "site_code" | "iata") => Some(("ap.site_code", FieldKind::Text)),
        ("ap", "site_name") => Some(("s.name", FieldKind::Text)),
        ("ap", "region") => Some(("s.region", FieldKind::Text)),
        ("ap", "latitude" | "lat") => Some(("s.latitude", FieldKind::Float)),
        ("ap", "longitude" | "lon" | "lng") => Some(("s.longitude", FieldKind::Float)),
        ("ap", "name" | "hostname" | "host") => {
            Some(("COALESCE(ap.hostname, ap.name)", FieldKind::Text))
        }
        ("ap", "mac") => Some(("ap.mac", FieldKind::Text)),
        ("ap", "serial") => Some(("ap.serial", FieldKind::Text)),
        ("ap", "ip") => Some(("ap.ip", FieldKind::Text)),
        ("ap", "status") => Some(("ap.status", FieldKind::Text)),
        ("ap", "model") => Some(("ap.model", FieldKind::Text)),
        ("ap", "vendor_name" | "vendor") => Some(("ap.vendor_name", FieldKind::Text)),
        ("c", "id") => Some(("c.id::text", FieldKind::Text)),
        ("c", "source_id") => Some(("c.source_id::text", FieldKind::Text)),
        ("c", "batch_id") => Some(("c.batch_id::text", FieldKind::Text)),
        ("c", "device_uid") => Some(("c.device_uid", FieldKind::Text)),
        ("c", "site_code" | "iata") => Some(("c.site_code", FieldKind::Text)),
        ("c", "site_name") => Some(("s.name", FieldKind::Text)),
        ("c", "region") => Some(("s.region", FieldKind::Text)),
        ("c", "latitude" | "lat") => Some(("s.latitude", FieldKind::Float)),
        ("c", "longitude" | "lon" | "lng") => Some(("s.longitude", FieldKind::Float)),
        ("c", "name" | "hostname" | "host") => {
            Some(("COALESCE(c.hostname, c.name)", FieldKind::Text))
        }
        ("c", "mac") => Some(("c.mac", FieldKind::Text)),
        ("c", "serial") => Some(("c.serial", FieldKind::Text)),
        ("c", "ip") => Some(("c.ip", FieldKind::Text)),
        ("c", "model") => Some(("c.model", FieldKind::Text)),
        _ => None,
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
            "unsupported operator for text WiFi map filter: {:?}",
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
                "unsupported operator for numeric WiFi map filter: {:?}",
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

fn text_array_condition(
    field_sql: &str,
    filter: &Filter,
    binds: &mut Vec<BindParam>,
) -> Result<String> {
    let values = match filter.op {
        FilterOp::Eq | FilterOp::NotEq => vec![filter.value.as_scalar()?.to_string()],
        FilterOp::In | FilterOp::NotIn => filter.value.as_list()?.to_vec(),
        _ => {
            return Err(ServiceError::InvalidRequest(
                "WiFi map array filters only support equality and list filters".into(),
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

fn jsonb_key_condition(
    field_sql: &str,
    filter: &Filter,
    binds: &mut Vec<BindParam>,
) -> Result<String> {
    match filter.op {
        FilterOp::Eq | FilterOp::NotEq => {
            binds.push(BindParam::Text(filter.value.as_scalar()?.to_string()));
            let condition = format!("jsonb_exists({field_sql}, ?)");

            if matches!(filter.op, FilterOp::NotEq) {
                Ok(format!("NOT ({condition})"))
            } else {
                Ok(condition)
            }
        }
        FilterOp::In | FilterOp::NotIn => {
            let values = filter.value.as_list()?.to_vec();
            if values.is_empty() {
                return Ok("TRUE".into());
            }

            binds.push(BindParam::TextArray(values));
            let condition = format!("jsonb_exists_any({field_sql}, ?)");

            if matches!(filter.op, FilterOp::NotIn) {
                Ok(format!("NOT ({condition})"))
            } else {
                Ok(condition)
            }
        }
        FilterOp::Like | FilterOp::NotLike => {
            binds.push(BindParam::Text(filter.value.as_scalar()?.to_string()));
            let condition = format!(
                "EXISTS (SELECT 1 FROM jsonb_object_keys({field_sql}) AS wifi_map_jsonb_key(key_name) WHERE wifi_map_jsonb_key.key_name ILIKE ?)"
            );

            if matches!(filter.op, FilterOp::NotLike) {
                Ok(format!("NOT ({condition})"))
            } else {
                Ok(condition)
            }
        }
        _ => Err(ServiceError::InvalidRequest(format!(
            "unsupported operator for WiFi map JSONB key filter: {:?}",
            filter.op
        ))),
    }
}

fn date_condition(field_sql: &str, filter: &Filter, binds: &mut Vec<BindParam>) -> Result<String> {
    let op = match filter.op {
        FilterOp::Eq => "=",
        FilterOp::NotEq => "<>",
        FilterOp::Gt => ">",
        FilterOp::Gte => ">=",
        FilterOp::Lt => "<",
        FilterOp::Lte => "<=",
        _ => {
            return Err(ServiceError::InvalidRequest(format!(
                "unsupported operator for date WiFi map filter: {:?}",
                filter.op
            )))
        }
    };
    binds.push(BindParam::Text(filter.value.as_scalar()?.to_string()));
    Ok(format!("{field_sql} {op} ?::date"))
}

fn order_sql(entity: &Entity, spec: EntitySpec, order: &[OrderClause]) -> String {
    let clauses: Vec<String> = order
        .iter()
        .filter_map(|clause| {
            order_column(entity, spec, clause.field.as_str()).map(|column| {
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

fn order_column(entity: &Entity, spec: EntitySpec, field: &str) -> Option<&'static str> {
    match field {
        "time" | "timestamp" | "collection_timestamp" | "updated_at" | "build_date" => {
            Some(spec.time_column)
        }
        _ => field_sql(entity, field).map(|(column, _)| column),
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
        ServiceError::InvalidRequest(format!("expected integer WiFi map filter value: {raw}"))
    })
}

fn parse_f64(raw: &str) -> Result<f64> {
    raw.parse::<f64>().map_err(|_| {
        ServiceError::InvalidRequest(format!("expected numeric WiFi map filter value: {raw}"))
    })
}

#[cfg(test)]
mod tests {
    use crate::{
        config::AppConfig,
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
        .expect("translate")
        .sql
    }

    #[test]
    fn wifi_sites_sql_uses_latest_snapshot_for_marker_metrics() {
        let sql = translate("in:wifi_sites region:AM-East ap_count:>0 sort:ap_count:desc limit:50");

        assert!(sql.contains("platform.wifi_sites s"));
        assert!(sql.contains("LEFT JOIN LATERAL"));
        assert!(sql.contains("'feature_id', concat(s.source_id::text, ':', s.site_code)"));
        assert!(sql.contains("'latitude', s.latitude"));
        assert!(sql.contains("'ap_count', COALESCE(latest.ap_count, 0)"));
        assert!(sql.contains("s.region = $1"));
        assert!(sql.contains("COALESCE(latest.ap_count, 0) > $2"));
        assert!(sql.contains("ORDER BY COALESCE(latest.ap_count, 0) DESC"));
    }

    #[test]
    fn wifi_ap_search_supports_site_and_device_fields() {
        let sql = translate("in:wifi_aps site_code:IAH hostname:%WAP% status:Up sort:name:asc");

        assert!(sql.contains("platform.wifi_access_point_observations ap"));
        assert!(sql.contains("LEFT JOIN platform.wifi_sites s"));
        assert!(sql.contains("ap.site_code = $1"));
        assert!(sql.contains("COALESCE(ap.hostname, ap.name) ILIKE $2"));
        assert!(sql.contains("ap.status = $3"));
        assert!(sql.contains("ORDER BY COALESCE(ap.hostname, ap.name) ASC"));
    }

    #[test]
    fn wifi_radius_group_array_filter_uses_overlap() {
        let sql = translate("in:wifi_radius_groups all_server_groups:(aaa-primary,aaa-backup)");

        assert!(sql.contains("platform.wifi_radius_group_observations r"));
        assert!(sql.contains("COALESCE(r.all_server_groups, '{}'::text[]) && $1"));
    }

    #[test]
    fn wifi_site_jsonb_breakdown_filters_match_keys() {
        let sql = translate(
            "in:wifi_sites ap_family:(6xx,7xx) wlc_model:7030 aos_version:%8.11% limit:10",
        );

        assert!(sql.contains("jsonb_exists_any(COALESCE(latest.model_breakdown, '{}'::jsonb), $1)"));
        assert!(sql.contains("jsonb_exists(COALESCE(latest.wlc_model_breakdown, '{}'::jsonb), $2)"));
        assert!(
            sql.contains("jsonb_object_keys(COALESCE(latest.aos_version_breakdown, '{}'::jsonb))")
        );
        assert!(sql.contains("wifi_map_jsonb_key.key_name ILIKE $3"));
    }

    #[test]
    fn wifi_site_jsonb_breakdown_filters_support_negation() {
        let sql = translate("in:wifi_sites !ap_family:(2xx,3xx) !wlc_model:7205");

        assert!(sql
            .contains("NOT (jsonb_exists_any(COALESCE(latest.model_breakdown, '{}'::jsonb), $1))"));
        assert!(sql
            .contains("NOT (jsonb_exists(COALESCE(latest.wlc_model_breakdown, '{}'::jsonb), $2))"));
    }

    #[test]
    fn unsupported_wifi_filter_fails() {
        let err = translate_request(
            &AppConfig::embedded("postgres://srql-test".to_string()),
            QueryRequest {
                query: "in:wifi_sites unknown_field:foo".to_string(),
                limit: None,
                cursor: None,
                direction: Default::default(),
                mode: None,
            },
        )
        .unwrap_err();

        assert!(err.to_string().contains("unsupported filter field"));
    }

    #[test]
    fn wifi_stats_fail_until_grouping_is_implemented() {
        let err = translate_request(
            &AppConfig::embedded("postgres://srql-test".to_string()),
            QueryRequest {
                query: "in:wifi_sites stats:\"count() as total by region\"".to_string(),
                limit: None,
                cursor: None,
                direction: Default::default(),
                mode: None,
            },
        )
        .unwrap_err();

        assert!(err.to_string().contains("stats/grouping"));
    }
}
