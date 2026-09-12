//! SRQL support for timeseries-backed metrics (generic, SNMP, and rperf).

use super::{BindParam, QueryPlan, build_other_rollup_sql, filters_common::is_valid_jsonb_key};
use crate::{
    error::{Result, ServiceError},
    jsonb::DbJson,
    models::TimeseriesMetricRow,
    parser::{Entity, Filter, FilterOp, OrderClause, OrderDirection},
    schema::timeseries_metrics::dsl::{
        agent_id as col_agent_id, device_id as col_device_id, gateway_id as col_gateway_id,
        if_index as col_if_index, metric_name as col_metric_name, metric_type as col_metric_type,
        partition as col_partition, target_device_ip as col_target_device_ip, timeseries_metrics,
        timestamp as col_timestamp, value as col_value,
    },
    time::TimeRange,
};
use chrono::{DateTime, Utc};
use diesel::PgTextExpressionMethods;
use diesel::pg::Pg;
use diesel::prelude::*;
use diesel::query_builder::{
    AsQuery, BoxedSelectStatement, BoxedSqlQuery, FromClause, SqlQuery as DieselSqlQuery,
};
use diesel::sql_query;
use diesel::sql_types::{Array, BigInt, Float8, Jsonb, Nullable, Text, Timestamptz};
use diesel_async::{AsyncPgConnection, RunQueryDsl};
use serde_json::Value;
use std::path::Path;

const DEFAULT_PROFILE_TIMEZONE: &str = "Etc/UTC";
const ZONEINFO_DIRS: &[&str] = &[
    "/usr/share/zoneinfo",
    "/usr/share/lib/zoneinfo",
    "/etc/zoneinfo",
];

type TimeseriesTable = crate::schema::timeseries_metrics::table;
type TimeseriesFromClause = FromClause<TimeseriesTable>;
type TimeseriesQuery<'a> =
    BoxedSelectStatement<'a, <TimeseriesTable as AsQuery>::SqlType, TimeseriesFromClause, Pg>;
#[derive(Debug, Clone)]
struct TimeseriesStatsSpec {
    aggregations: Vec<TimeseriesAggregationSpec>,
    group_by: Vec<TimeseriesGroupSpec>,
    profile_hour_of_week: Option<String>,
    /// Full `(dow, hod)` profile for edge baseline delivery.  The established
    /// `profile_hour_of_week` route deliberately remains latest-bucket-only
    /// for central disposition compatibility.
    profile_hour_of_week_full: Option<String>,
    profile_hour_of_week_peak: Option<String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum TimeseriesAggFunc {
    Avg,
    Sum,
    Count,
}

#[derive(Debug, Clone)]
struct TimeseriesAggregationSpec {
    func: TimeseriesAggFunc,
    field: Option<String>,
    alias: String,
}

#[derive(Debug, Clone)]
struct TimeseriesGroupSpec {
    field: String,
}

#[derive(Debug, Clone)]
struct TimeseriesStatsSql {
    sql: String,
    binds: Vec<SqlBindValue>,
}

#[derive(Debug, Clone)]
enum SqlBindValue {
    Text(String),
    TextArray(Vec<String>),
    IntArray(Vec<i64>),
    Timestamp(DateTime<Utc>),
}

impl SqlBindValue {
    fn apply<'a>(
        &self,
        query: BoxedSqlQuery<'a, Pg, DieselSqlQuery>,
    ) -> BoxedSqlQuery<'a, Pg, DieselSqlQuery> {
        match self {
            SqlBindValue::Text(value) => query.bind::<Text, _>(value.clone()),
            SqlBindValue::TextArray(values) => query.bind::<Array<Text>, _>(values.clone()),
            SqlBindValue::IntArray(values) => query.bind::<Array<BigInt>, _>(values.clone()),
            SqlBindValue::Timestamp(value) => query.bind::<Timestamptz, _>(*value),
        }
    }
}

#[derive(Debug, QueryableByName)]
#[diesel(check_for_backend(diesel::pg::Pg))]
struct TimeseriesStatsPayload {
    #[diesel(sql_type = Nullable<Jsonb>)]
    payload: Option<DbJson>,
}

const RPERF_METRIC_TYPE: &str = "rperf";
const SNMP_METRIC_TYPE: &str = "snmp";
const INTERFACE_HOURLY_TABLE: &str = "timeseries_metrics_interface_hourly";
const DISK_HOURLY_TABLE: &str = "timeseries_metrics_disk_hourly";

#[derive(Clone, Copy)]
enum MetricScope<'a> {
    Any,
    Forced(&'a str),
}

pub(super) async fn execute(conn: &mut AsyncPgConnection, plan: &QueryPlan) -> Result<Vec<Value>> {
    if matches!(plan.entity, Entity::TimeseriesMetricInterfaceHourly) {
        if let Some(spec) = parse_stats_spec(plan.stats.as_ref().map(|s| s.as_raw()))? {
            return execute_interface_hourly_stats(conn, plan, &spec).await;
        }

        return execute_interface_hourly(conn, plan).await;
    }

    if matches!(plan.entity, Entity::TimeseriesMetricDiskHourly) {
        return execute_disk_hourly(conn, plan).await;
    }

    let scope = ensure_entity(plan)?;

    if let Some(spec) = parse_stats_spec(plan.stats.as_ref().map(|s| s.as_raw()))? {
        return execute_stats(conn, plan, scope, &spec).await;
    }

    let query = build_query(plan, scope)?;
    let rows: Vec<TimeseriesMetricRow> = query
        .select(TimeseriesMetricRow::as_select())
        .limit(plan.limit)
        .offset(plan.offset)
        .load::<TimeseriesMetricRow>(conn)
        .await
        .map_err(|err| ServiceError::Internal(err.into()))?;

    Ok(rows
        .into_iter()
        .map(TimeseriesMetricRow::into_json)
        .collect())
}

pub(super) fn to_sql_and_params(plan: &QueryPlan) -> Result<(String, Vec<BindParam>)> {
    if matches!(plan.entity, Entity::TimeseriesMetricInterfaceHourly) {
        if let Some(spec) = parse_stats_spec(plan.stats.as_ref().map(|s| s.as_raw()))? {
            let sql = build_interface_hourly_stats_query(plan, &spec)?;
            let params = sql.binds.into_iter().map(bind_param_from_stats).collect();
            return Ok((rewrite_placeholders(&sql.sql), params));
        }

        let sql = build_interface_hourly_query(plan, false)?;
        return Ok((rewrite_placeholders(&sql.sql), sql.binds));
    }

    if matches!(plan.entity, Entity::TimeseriesMetricDiskHourly) {
        let sql = build_disk_hourly_query(plan, false)?;
        return Ok((rewrite_placeholders(&sql.sql), sql.binds));
    }

    let scope = ensure_entity(plan)?;

    if let Some(spec) = parse_stats_spec(plan.stats.as_ref().map(|s| s.as_raw()))? {
        let sql = if spec.is_profile_hour_of_week_peak() {
            // mirror execute_stats: the to_sql path was missing the peak branch, so a
            // profile_hour_of_week_peak query fell through to the non-profile builder
            // and errored "requires the profile stats route".
            build_profile_hour_of_week_peak_query(plan, scope, &spec)?
        } else if spec.is_profile_hour_of_week() {
            build_profile_hour_of_week_query(plan, scope, &spec)?
        } else if should_route_stats_to_cagg(plan, &spec) {
            build_cagg_stats_query(plan, scope, &spec)?
        } else {
            build_stats_query(plan, scope, &spec)?
        };
        let params = sql.binds.into_iter().map(bind_param_from_stats).collect();
        return Ok((rewrite_placeholders(&sql.sql), params));
    }

    let query = build_query(plan, scope)?
        .limit(plan.limit)
        .offset(plan.offset);
    let sql = super::diesel_sql(&query)?;

    let mut params = Vec::new();

    if let MetricScope::Forced(metric_type) = scope {
        params.push(BindParam::Text(metric_type.to_string()));
    }

    if let Some(TimeRange { start, end }) = &plan.time_range {
        params.push(BindParam::timestamptz(*start));
        params.push(BindParam::timestamptz(*end));
    }

    for filter in &plan.filters {
        collect_filter_params(&mut params, filter)?;
    }

    super::reconcile_limit_offset_binds(&sql, &mut params, plan.limit, plan.offset)?;

    #[cfg(any(test, debug_assertions))]
    {
        let bind_count = super::diesel_bind_count(&query)?;
        if bind_count != params.len() {
            return Err(ServiceError::Internal(anyhow::anyhow!(
                "bind count mismatch (diesel {bind_count} vs params {})",
                params.len()
            )));
        }
    }

    Ok((sql, params))
}

fn ensure_entity(plan: &QueryPlan) -> Result<MetricScope<'static>> {
    match plan.entity {
        Entity::TimeseriesMetrics => Ok(MetricScope::Any),
        Entity::SnmpMetrics => Ok(MetricScope::Forced(SNMP_METRIC_TYPE)),
        Entity::RperfMetrics => Ok(MetricScope::Forced(RPERF_METRIC_TYPE)),
        _ => Err(ServiceError::InvalidRequest(
            "entity not supported by timeseries metrics query".into(),
        )),
    }
}

struct HourlySql {
    sql: String,
    binds: Vec<BindParam>,
}

async fn execute_interface_hourly(
    conn: &mut AsyncPgConnection,
    plan: &QueryPlan,
) -> Result<Vec<Value>> {
    let sql = build_interface_hourly_query(plan, true)?;
    let mut query = sql_query(rewrite_placeholders(&sql.sql)).into_boxed::<Pg>();

    for bind in sql.binds {
        query = bind_hourly_param(query, bind)?;
    }

    let rows: Vec<TimeseriesStatsPayload> = query
        .load::<TimeseriesStatsPayload>(conn)
        .await
        .map_err(|err| ServiceError::Internal(err.into()))?;

    Ok(rows
        .into_iter()
        .filter_map(|row| row.payload.map(serde_json::Value::from))
        .collect())
}

async fn execute_interface_hourly_stats(
    conn: &mut AsyncPgConnection,
    plan: &QueryPlan,
    spec: &TimeseriesStatsSpec,
) -> Result<Vec<Value>> {
    let sql = build_interface_hourly_stats_query(plan, spec)?;
    let mut query = sql_query(rewrite_placeholders(&sql.sql)).into_boxed::<Pg>();

    for bind in &sql.binds {
        query = bind.apply(query);
    }

    let rows: Vec<TimeseriesStatsPayload> = query
        .load::<TimeseriesStatsPayload>(conn)
        .await
        .map_err(|err| ServiceError::Internal(err.into()))?;

    Ok(rows
        .into_iter()
        .filter_map(|row| row.payload.map(serde_json::Value::from))
        .collect())
}

fn build_interface_hourly_query(plan: &QueryPlan, payload: bool) -> Result<HourlySql> {
    if plan.stats.is_some() {
        return Err(ServiceError::InvalidRequest(
            "stats are not supported for timeseries_metrics_interface_hourly".into(),
        ));
    }

    let mut clauses = Vec::new();
    let mut binds = Vec::new();

    if let Some(TimeRange { start, end }) = &plan.time_range {
        clauses.push(format!(
            "{} AND {}",
            super::hourly_cagg_lower_bound_clause("bucket"),
            super::hourly_cagg_upper_bound_clause("bucket")
        ));
        binds.push(BindParam::timestamptz(*start));
        binds.push(BindParam::timestamptz(*end));
    }

    for filter in &plan.filters {
        if let Some(clause) = build_interface_hourly_filter_clause(filter, &mut binds)? {
            clauses.push(clause);
        }
    }

    binds.push(BindParam::Int(plan.limit));
    binds.push(BindParam::Int(plan.offset));

    let select_sql = if payload {
        "jsonb_build_object(\
            'bucket', bucket, \
            'partition', partition, \
            'device_id', device_id, \
            'target_device_ip', target_device_ip, \
            'if_index', if_index, \
            'metric_type', metric_type, \
            'metric_name', metric_name, \
            'series_key', series_key, \
            'avg_value', avg_value, \
            'min_value', min_value, \
            'max_value', max_value, \
            'delta_value', delta_value, \
            'duration_seconds', duration_seconds, \
            'avg_rate_per_second', avg_rate_per_second, \
            'sample_count', sample_count\
        ) AS payload"
    } else {
        "bucket, partition, device_id, target_device_ip, if_index, metric_type, metric_name, \
         series_key, avg_value, min_value, max_value, delta_value, duration_seconds, \
         avg_rate_per_second, sample_count"
    };

    let where_sql = if clauses.is_empty() {
        String::new()
    } else {
        format!(" WHERE {}", clauses.join(" AND "))
    };

    Ok(HourlySql {
        sql: format!(
            "SELECT {select_sql} FROM {INTERFACE_HOURLY_TABLE}{where_sql}{} LIMIT ? OFFSET ?",
            build_interface_hourly_order_clause(&plan.order)
        ),
        binds,
    })
}

fn build_interface_hourly_stats_query(
    plan: &QueryPlan,
    spec: &TimeseriesStatsSpec,
) -> Result<TimeseriesStatsSql> {
    if spec.is_profile_hour_of_week() {
        build_interface_profile_hour_of_week_query(plan, spec)
    } else if spec.is_profile_hour_of_week_peak() {
        Err(ServiceError::InvalidRequest(
            "profile_hour_of_week_peak is not supported for timeseries_metrics_interface_hourly"
                .into(),
        ))
    } else {
        Err(ServiceError::InvalidRequest(
            "only profile_hour_of_week stats are supported for timeseries_metrics_interface_hourly"
                .into(),
        ))
    }
}

fn build_interface_hourly_filter_clause(
    filter: &Filter,
    binds: &mut Vec<BindParam>,
) -> Result<Option<String>> {
    match filter.field.as_str() {
        "partition" | "device_id" | "target_device_ip" | "metric_type" | "metric_name"
        | "series_key" => build_hourly_text_filter(filter.field.as_str(), filter, binds),
        "if_index" => build_hourly_int_filter("if_index", filter, binds),
        "avg_value"
        | "min_value"
        | "max_value"
        | "delta_value"
        | "duration_seconds"
        | "avg_rate_per_second" => build_hourly_float_filter(filter.field.as_str(), filter, binds),
        "sample_count" => build_hourly_int_filter("sample_count", filter, binds),
        other => Err(ServiceError::InvalidRequest(format!(
            "unsupported filter field for timeseries_metrics_interface_hourly: '{other}'"
        ))),
    }
}

fn build_hourly_text_filter(
    column: &str,
    filter: &Filter,
    binds: &mut Vec<BindParam>,
) -> Result<Option<String>> {
    match filter.op {
        FilterOp::Eq | FilterOp::NotEq | FilterOp::Like | FilterOp::NotLike => {
            binds.push(BindParam::Text(filter.value.as_scalar()?.to_string()));
            let op = match filter.op {
                FilterOp::Eq => "=",
                FilterOp::NotEq => "<>",
                FilterOp::Like => "ILIKE",
                FilterOp::NotLike => "NOT ILIKE",
                _ => unreachable!(),
            };
            Ok(Some(format!("{column} {op} ?")))
        }
        FilterOp::In | FilterOp::NotIn => {
            let values = filter.value.as_list()?.to_vec();
            if values.is_empty() {
                return Ok(None);
            }
            binds.push(BindParam::TextArray(values));
            let op = if matches!(filter.op, FilterOp::In) {
                "= ANY"
            } else {
                "<> ALL"
            };
            Ok(Some(format!("{column} {op}(?)")))
        }
        _ => Err(ServiceError::InvalidRequest(format!(
            "unsupported operator for text filter: {:?}",
            filter.op
        ))),
    }
}

fn build_hourly_int_filter(
    column: &str,
    filter: &Filter,
    binds: &mut Vec<BindParam>,
) -> Result<Option<String>> {
    match filter.op {
        FilterOp::Eq
        | FilterOp::NotEq
        | FilterOp::Gt
        | FilterOp::Gte
        | FilterOp::Lt
        | FilterOp::Lte => {
            let value = filter
                .value
                .as_scalar()?
                .parse::<i64>()
                .map_err(|_| ServiceError::InvalidRequest(format!("invalid {column} value")))?;
            binds.push(BindParam::Int(value));
            Ok(Some(format!(
                "{column} {} ?",
                comparison_operator(&filter.op).expect("comparison op")
            )))
        }
        FilterOp::In | FilterOp::NotIn => {
            let values = parse_i32_list(filter.value.as_list()?)?;
            if values.is_empty() {
                return Ok(None);
            }
            binds.push(BindParam::IntArray(
                values.into_iter().map(i64::from).collect(),
            ));
            let op = if matches!(filter.op, FilterOp::In) {
                "= ANY"
            } else {
                "<> ALL"
            };
            Ok(Some(format!("{column} {op}(?)")))
        }
        _ => Err(ServiceError::InvalidRequest(format!(
            "unsupported operator for integer filter: {:?}",
            filter.op
        ))),
    }
}

fn build_hourly_float_filter(
    column: &str,
    filter: &Filter,
    binds: &mut Vec<BindParam>,
) -> Result<Option<String>> {
    match filter.op {
        FilterOp::Eq
        | FilterOp::NotEq
        | FilterOp::Gt
        | FilterOp::Gte
        | FilterOp::Lt
        | FilterOp::Lte => {
            binds.push(BindParam::Float(parse_f64(filter.value.as_scalar()?)?));
            Ok(Some(format!(
                "{column} {} ?",
                comparison_operator(&filter.op).expect("comparison op")
            )))
        }
        _ => Err(ServiceError::InvalidRequest(format!(
            "unsupported operator for numeric filter: {:?}",
            filter.op
        ))),
    }
}

fn comparison_operator(op: &FilterOp) -> Option<&'static str> {
    match op {
        FilterOp::Eq => Some("="),
        FilterOp::NotEq => Some("<>"),
        FilterOp::Gt => Some(">"),
        FilterOp::Gte => Some(">="),
        FilterOp::Lt => Some("<"),
        FilterOp::Lte => Some("<="),
        _ => None,
    }
}

fn build_interface_hourly_order_clause(order: &[OrderClause]) -> String {
    let clauses: Vec<String> = order
        .iter()
        .filter_map(|clause| {
            interface_hourly_order_column(clause.field.as_str()).map(|column| {
                let direction = match clause.direction {
                    OrderDirection::Asc => "ASC",
                    OrderDirection::Desc => "DESC",
                };
                format!("{column} {direction}")
            })
        })
        .collect();

    if clauses.is_empty() {
        " ORDER BY bucket DESC".to_string()
    } else {
        format!(" ORDER BY {}", clauses.join(", "))
    }
}

fn interface_hourly_order_column(field: &str) -> Option<&'static str> {
    match field {
        "bucket" | "time" | "timestamp" => Some("bucket"),
        "partition" => Some("partition"),
        "device_id" => Some("device_id"),
        "target_device_ip" => Some("target_device_ip"),
        "if_index" => Some("if_index"),
        "metric_type" => Some("metric_type"),
        "metric_name" => Some("metric_name"),
        "series_key" => Some("series_key"),
        "avg_value" => Some("avg_value"),
        "min_value" => Some("min_value"),
        "max_value" => Some("max_value"),
        "delta_value" => Some("delta_value"),
        "duration_seconds" => Some("duration_seconds"),
        "avg_rate_per_second" => Some("avg_rate_per_second"),
        "sample_count" => Some("sample_count"),
        _ => None,
    }
}

fn bind_hourly_param<'a>(
    query: BoxedSqlQuery<'a, Pg, DieselSqlQuery>,
    param: BindParam,
) -> Result<BoxedSqlQuery<'a, Pg, DieselSqlQuery>> {
    match param {
        BindParam::Text(value) => Ok(query.bind::<Text, _>(value)),
        BindParam::TextArray(values) => Ok(query.bind::<Array<Text>, _>(values)),
        BindParam::IntArray(values) => Ok(query.bind::<Array<BigInt>, _>(values)),
        BindParam::Int(value) => Ok(query.bind::<BigInt, _>(value)),
        BindParam::Float(value) => Ok(query.bind::<Float8, _>(value)),
        BindParam::Timestamptz(value) => {
            let timestamp = chrono::DateTime::parse_from_rfc3339(&value)
                .map(|dt| dt.with_timezone(&Utc))
                .map_err(|err| {
                    ServiceError::Internal(anyhow::anyhow!(
                        "invalid timestamptz bind {value:?}: {err}"
                    ))
                })?;
            Ok(query.bind::<Timestamptz, _>(timestamp))
        }
        BindParam::Bool(_) | BindParam::Uuid(_) | BindParam::Date(_) => Err(
            ServiceError::InvalidRequest("unsupported bind type for hourly metric rollups".into()),
        ),
    }
}

async fn execute_disk_hourly(conn: &mut AsyncPgConnection, plan: &QueryPlan) -> Result<Vec<Value>> {
    let sql = build_disk_hourly_query(plan, true)?;
    let mut query = sql_query(rewrite_placeholders(&sql.sql)).into_boxed::<Pg>();

    for bind in sql.binds {
        query = bind_hourly_param(query, bind)?;
    }

    let rows: Vec<TimeseriesStatsPayload> = query
        .load::<TimeseriesStatsPayload>(conn)
        .await
        .map_err(|err| ServiceError::Internal(err.into()))?;

    Ok(rows
        .into_iter()
        .filter_map(|row| row.payload.map(serde_json::Value::from))
        .collect())
}

/// Row query over the mount-keyed disk rollup. Unlike the interface rollup it has
/// no stats route: the aggregate exists so capacity forecasting can read one
/// hourly series per (device, mount) across the raw table's retention.
fn build_disk_hourly_query(plan: &QueryPlan, payload: bool) -> Result<HourlySql> {
    if plan.stats.is_some() {
        return Err(ServiceError::InvalidRequest(
            "stats are not supported for timeseries_metrics_disk_hourly".into(),
        ));
    }

    let mut clauses = Vec::new();
    let mut binds = Vec::new();

    if let Some(TimeRange { start, end }) = &plan.time_range {
        clauses.push(format!(
            "{} AND {}",
            super::hourly_cagg_lower_bound_clause("bucket"),
            super::hourly_cagg_upper_bound_clause("bucket")
        ));
        binds.push(BindParam::timestamptz(*start));
        binds.push(BindParam::timestamptz(*end));
    }

    for filter in &plan.filters {
        if let Some(clause) = build_disk_hourly_filter_clause(filter, &mut binds)? {
            clauses.push(clause);
        }
    }

    binds.push(BindParam::Int(plan.limit));
    binds.push(BindParam::Int(plan.offset));

    let select_sql = if payload {
        "jsonb_build_object(\
            'bucket', bucket, \
            'device_id', device_id, \
            'metric_type', metric_type, \
            'metric_name', metric_name, \
            'series_key', series_key, \
            'mount_point', mount_point, \
            'avg_value', avg_value, \
            'min_value', min_value, \
            'max_value', max_value, \
            'sample_count', sample_count\
        ) AS payload"
    } else {
        "bucket, device_id, metric_type, metric_name, series_key, mount_point, avg_value, \
         min_value, max_value, sample_count"
    };

    let where_sql = if clauses.is_empty() {
        String::new()
    } else {
        format!(" WHERE {}", clauses.join(" AND "))
    };

    Ok(HourlySql {
        sql: format!(
            "SELECT {select_sql} FROM {DISK_HOURLY_TABLE}{where_sql}{} LIMIT ? OFFSET ?",
            build_disk_hourly_order_clause(&plan.order)
        ),
        binds,
    })
}

fn build_disk_hourly_filter_clause(
    filter: &Filter,
    binds: &mut Vec<BindParam>,
) -> Result<Option<String>> {
    match filter.field.as_str() {
        "device_id" | "metric_type" | "metric_name" | "series_key" | "mount_point" => {
            build_hourly_text_filter(filter.field.as_str(), filter, binds)
        }
        "avg_value" | "min_value" | "max_value" => {
            build_hourly_float_filter(filter.field.as_str(), filter, binds)
        }
        "sample_count" => build_hourly_int_filter("sample_count", filter, binds),
        other => Err(ServiceError::InvalidRequest(format!(
            "unsupported filter field for timeseries_metrics_disk_hourly: '{other}'"
        ))),
    }
}

fn build_disk_hourly_order_clause(order: &[OrderClause]) -> String {
    let clauses: Vec<String> = order
        .iter()
        .filter_map(|clause| {
            disk_hourly_order_column(clause.field.as_str()).map(|column| {
                let direction = match clause.direction {
                    OrderDirection::Asc => "ASC",
                    OrderDirection::Desc => "DESC",
                };
                format!("{column} {direction}")
            })
        })
        .collect();

    if clauses.is_empty() {
        " ORDER BY bucket DESC".to_string()
    } else {
        format!(" ORDER BY {}", clauses.join(", "))
    }
}

fn disk_hourly_order_column(field: &str) -> Option<&'static str> {
    match field {
        "bucket" | "time" | "timestamp" => Some("bucket"),
        "device_id" => Some("device_id"),
        "metric_type" => Some("metric_type"),
        "metric_name" => Some("metric_name"),
        "series_key" => Some("series_key"),
        "mount_point" => Some("mount_point"),
        "avg_value" => Some("avg_value"),
        "min_value" => Some("min_value"),
        "max_value" => Some("max_value"),
        "sample_count" => Some("sample_count"),
        _ => None,
    }
}

fn build_query(plan: &QueryPlan, scope: MetricScope<'static>) -> Result<TimeseriesQuery<'static>> {
    let mut query = timeseries_metrics.into_boxed::<Pg>();

    if let MetricScope::Forced(metric_type) = scope {
        query = query.filter(col_metric_type.eq(metric_type));
    }

    if let Some(TimeRange { start, end }) = &plan.time_range {
        query = query.filter(col_timestamp.ge(*start).and(col_timestamp.le(*end)));
    }

    for filter in &plan.filters {
        query = apply_filter(query, filter)?;
    }

    Ok(apply_ordering(query, &plan.order))
}

fn apply_filter<'a>(
    mut query: TimeseriesQuery<'a>,
    filter: &Filter,
) -> Result<TimeseriesQuery<'a>> {
    match filter.field.as_str() {
        "gateway_id" => {
            query = apply_text_filter!(query, filter, col_gateway_id)?;
        }
        "agent_id" => {
            query = apply_text_filter!(query, filter, col_agent_id)?;
        }
        "metric_name" => {
            query = apply_text_filter!(query, filter, col_metric_name)?;
        }
        "metric_type" => {
            query = apply_text_filter!(query, filter, col_metric_type)?;
        }
        "device_id" => {
            query = apply_text_filter!(query, filter, col_device_id)?;
        }
        "target_device_ip" => {
            query = apply_text_filter!(query, filter, col_target_device_ip)?;
        }
        "partition" => {
            query = apply_text_filter!(query, filter, col_partition)?;
        }
        "if_index" => {
            query = apply_if_index_filter(query, filter)?;
        }
        "value" => {
            query = apply_value_filter(query, filter)?;
        }
        field if field.starts_with("tags.") => {
            query = apply_tag_filter(query, filter)?;
        }
        other => {
            return Err(ServiceError::InvalidRequest(format!(
                "unsupported filter field for timeseries_metrics: '{other}'"
            )));
        }
    }

    Ok(query)
}

/// Filter on a single-level JSONB tag, e.g. `tags.site_code:ORD`.
///
/// Values are bound, never interpolated; only the validated key becomes part of
/// the expression text. `NotEq`/`NotLike` deliberately also match rows where the
/// tag is absent, matching the devices entity and the plain-column macro — a row
/// with no `site_code` genuinely is "not ORD", and excluding it would quietly
/// shrink the result.
fn apply_tag_filter<'a>(
    query: TimeseriesQuery<'a>,
    filter: &Filter,
) -> Result<TimeseriesQuery<'a>> {
    use diesel::dsl::sql;
    use diesel::sql_types::Bool;

    let key = tag_key(&filter.field)?;
    let expr = tag_expr(&key);

    let next = match filter.op {
        FilterOp::Eq => {
            let value = filter.value.as_scalar()?.to_string();
            query.filter(sql::<Bool>(&format!("{expr} = ")).bind::<Text, _>(value))
        }
        FilterOp::NotEq => {
            let value = filter.value.as_scalar()?.to_string();
            query.filter(
                sql::<Bool>(&format!("({expr} IS NULL OR {expr} <> "))
                    .bind::<Text, _>(value)
                    .sql(")"),
            )
        }
        FilterOp::Like => {
            let value = filter.value.as_scalar()?.to_string();
            query.filter(sql::<Bool>(&format!("{expr} ILIKE ")).bind::<Text, _>(value))
        }
        FilterOp::NotLike => {
            let value = filter.value.as_scalar()?.to_string();
            query.filter(
                sql::<Bool>(&format!("({expr} IS NULL OR {expr} NOT ILIKE "))
                    .bind::<Text, _>(value)
                    .sql(")"),
            )
        }
        FilterOp::In => {
            let values = filter.value.as_list()?.to_vec();
            if values.is_empty() {
                // An empty IN list matches nothing. Returning the query
                // unchanged would silently match everything instead.
                return Ok(query.filter(sql::<Bool>("1=0")));
            }
            query.filter(
                sql::<Bool>(&format!("{expr} = ANY("))
                    .bind::<Array<Text>, _>(values)
                    .sql(")"),
            )
        }
        FilterOp::NotIn => {
            let values = filter.value.as_list()?.to_vec();
            if values.is_empty() {
                return Ok(query);
            }
            query.filter(
                sql::<Bool>(&format!("({expr} IS NULL OR {expr} <> ALL("))
                    .bind::<Array<Text>, _>(values)
                    .sql("))"),
            )
        }
        _ => {
            return Err(ServiceError::InvalidRequest(format!(
                "unsupported operator for tag filter '{}'",
                filter.field
            )));
        }
    };

    Ok(next)
}

fn collect_text_params(params: &mut Vec<BindParam>, filter: &Filter) -> Result<()> {
    match filter.op {
        FilterOp::Eq | FilterOp::NotEq | FilterOp::Like | FilterOp::NotLike => {
            params.push(BindParam::Text(filter.value.as_scalar()?.to_string()));
            Ok(())
        }
        FilterOp::In | FilterOp::NotIn => {
            let values = filter.value.as_list()?.to_vec();
            if values.is_empty() {
                return Ok(());
            }
            params.push(BindParam::TextArray(values));
            Ok(())
        }
        _ => Err(ServiceError::InvalidRequest(format!(
            "unsupported operator for text filter: {:?}",
            filter.op
        ))),
    }
}

fn collect_filter_params(params: &mut Vec<BindParam>, filter: &Filter) -> Result<()> {
    match filter.field.as_str() {
        "gateway_id" | "agent_id" | "metric_name" | "metric_type" | "device_id"
        | "target_device_ip" | "partition" => collect_text_params(params, filter),
        "if_index" => match filter.op {
            FilterOp::In | FilterOp::NotIn => {
                let values = parse_i32_list(filter.value.as_list()?)?;
                if values.is_empty() {
                    return Ok(());
                }
                params.push(BindParam::IntArray(
                    values.into_iter().map(i64::from).collect(),
                ));
                Ok(())
            }
            _ => {
                let value =
                    filter.value.as_scalar()?.parse::<i32>().map_err(|_| {
                        ServiceError::InvalidRequest("invalid if_index value".into())
                    })?;
                params.push(BindParam::Int(i64::from(value)));
                Ok(())
            }
        },
        "value" => {
            let value = parse_f64(filter.value.as_scalar()?)?;
            params.push(BindParam::Float(value));
            Ok(())
        }
        field if field.starts_with("tags.") => {
            // Validate here too: this runs on the SQL-string path, where the key
            // reaches the query text.
            tag_key(field)?;
            collect_text_params(params, filter)
        }
        other => Err(ServiceError::InvalidRequest(format!(
            "unsupported filter field for timeseries_metrics: '{other}'"
        ))),
    }
}

fn apply_if_index_filter<'a>(
    query: TimeseriesQuery<'a>,
    filter: &Filter,
) -> Result<TimeseriesQuery<'a>> {
    match filter.op {
        FilterOp::In | FilterOp::NotIn => {
            let values = parse_i32_list(filter.value.as_list()?)?;
            if values.is_empty() {
                return Ok(query);
            }
            let query = match filter.op {
                FilterOp::In => query.filter(col_if_index.eq_any(values)),
                FilterOp::NotIn => query.filter(diesel::dsl::not(col_if_index.eq_any(values))),
                _ => query,
            };
            Ok(query)
        }
        FilterOp::Eq | FilterOp::NotEq => {
            let value = filter
                .value
                .as_scalar()?
                .parse::<i32>()
                .map_err(|_| ServiceError::InvalidRequest("invalid if_index value".into()))?;

            let query = match filter.op {
                FilterOp::Eq => query.filter(col_if_index.eq(value)),
                FilterOp::NotEq => query.filter(col_if_index.ne(value)),
                _ => query,
            };

            Ok(query)
        }
        _ => Err(ServiceError::InvalidRequest(
            "if_index filter only supports equality comparisons".into(),
        )),
    }
}

fn apply_value_filter<'a>(
    query: TimeseriesQuery<'a>,
    filter: &Filter,
) -> Result<TimeseriesQuery<'a>> {
    let value = parse_f64(filter.value.as_scalar()?)?;
    let query = match filter.op {
        FilterOp::Eq => query.filter(col_value.eq(value)),
        FilterOp::NotEq => query.filter(col_value.ne(value)),
        FilterOp::Gt => query.filter(col_value.gt(value)),
        FilterOp::Gte => query.filter(col_value.ge(value)),
        FilterOp::Lt => query.filter(col_value.lt(value)),
        FilterOp::Lte => query.filter(col_value.le(value)),
        _ => {
            return Err(ServiceError::InvalidRequest(
                "value filter does not support this operator".into(),
            ));
        }
    };

    Ok(query)
}

fn parse_f64(raw: &str) -> Result<f64> {
    raw.parse::<f64>()
        .map_err(|_| ServiceError::InvalidRequest("invalid numeric value".into()))
}

fn parse_i32_list(values: &[String]) -> Result<Vec<i32>> {
    values
        .iter()
        .map(|value| {
            value
                .parse::<i32>()
                .map_err(|_| ServiceError::InvalidRequest("invalid if_index value".into()))
        })
        .collect()
}

fn apply_ordering<'a>(
    mut query: TimeseriesQuery<'a>,
    order: &[OrderClause],
) -> TimeseriesQuery<'a> {
    let mut applied = false;
    for clause in order {
        query = if !applied {
            applied = true;
            apply_primary_order(query, clause.field.as_str(), clause.direction)
        } else {
            apply_secondary_order(query, clause.field.as_str(), clause.direction)
        };
    }

    if !applied {
        query = query.order(col_timestamp.desc());
    }

    query
}

fn apply_primary_order<'a>(
    query: TimeseriesQuery<'a>,
    field: &str,
    direction: OrderDirection,
) -> TimeseriesQuery<'a> {
    match field {
        "timestamp" => match direction {
            OrderDirection::Asc => query.order(col_timestamp.asc()),
            OrderDirection::Desc => query.order(col_timestamp.desc()),
        },
        "gateway_id" => match direction {
            OrderDirection::Asc => query.order(col_gateway_id.asc()),
            OrderDirection::Desc => query.order(col_gateway_id.desc()),
        },
        "metric_name" => match direction {
            OrderDirection::Asc => query.order(col_metric_name.asc()),
            OrderDirection::Desc => query.order(col_metric_name.desc()),
        },
        "metric_type" => match direction {
            OrderDirection::Asc => query.order(col_metric_type.asc()),
            OrderDirection::Desc => query.order(col_metric_type.desc()),
        },
        "device_id" => match direction {
            OrderDirection::Asc => query.order(col_device_id.asc()),
            OrderDirection::Desc => query.order(col_device_id.desc()),
        },
        "value" => match direction {
            OrderDirection::Asc => query.order(col_value.asc()),
            OrderDirection::Desc => query.order(col_value.desc()),
        },
        _ => query,
    }
}

fn apply_secondary_order<'a>(
    query: TimeseriesQuery<'a>,
    field: &str,
    direction: OrderDirection,
) -> TimeseriesQuery<'a> {
    match field {
        "timestamp" => match direction {
            OrderDirection::Asc => query.then_order_by(col_timestamp.asc()),
            OrderDirection::Desc => query.then_order_by(col_timestamp.desc()),
        },
        "gateway_id" => match direction {
            OrderDirection::Asc => query.then_order_by(col_gateway_id.asc()),
            OrderDirection::Desc => query.then_order_by(col_gateway_id.desc()),
        },
        "metric_name" => match direction {
            OrderDirection::Asc => query.then_order_by(col_metric_name.asc()),
            OrderDirection::Desc => query.then_order_by(col_metric_name.desc()),
        },
        "metric_type" => match direction {
            OrderDirection::Asc => query.then_order_by(col_metric_type.asc()),
            OrderDirection::Desc => query.then_order_by(col_metric_type.desc()),
        },
        "device_id" => match direction {
            OrderDirection::Asc => query.then_order_by(col_device_id.asc()),
            OrderDirection::Desc => query.then_order_by(col_device_id.desc()),
        },
        "value" => match direction {
            OrderDirection::Asc => query.then_order_by(col_value.asc()),
            OrderDirection::Desc => query.then_order_by(col_value.desc()),
        },
        _ => query,
    }
}

fn bind_param_from_stats(value: SqlBindValue) -> BindParam {
    match value {
        SqlBindValue::Text(value) => BindParam::Text(value),
        SqlBindValue::TextArray(values) => BindParam::TextArray(values),
        SqlBindValue::IntArray(values) => BindParam::IntArray(values),
        SqlBindValue::Timestamp(value) => BindParam::timestamptz(value),
    }
}

async fn execute_stats(
    conn: &mut AsyncPgConnection,
    plan: &QueryPlan,
    scope: MetricScope<'static>,
    spec: &TimeseriesStatsSpec,
) -> Result<Vec<Value>> {
    let sql = if spec.is_profile_hour_of_week_peak() {
        build_profile_hour_of_week_peak_query(plan, scope, spec)?
    } else if spec.is_profile_hour_of_week() {
        build_profile_hour_of_week_query(plan, scope, spec)?
    } else if should_route_stats_to_cagg(plan, spec) {
        build_cagg_stats_query(plan, scope, spec)?
    } else {
        build_stats_query(plan, scope, spec)?
    };
    let mut query = sql_query(rewrite_placeholders(&sql.sql)).into_boxed::<Pg>();
    for bind in &sql.binds {
        query = bind.apply(query);
    }
    let rows: Vec<TimeseriesStatsPayload> = query
        .load::<TimeseriesStatsPayload>(conn)
        .await
        .map_err(|err| ServiceError::Internal(err.into()))?;
    Ok(rows
        .into_iter()
        .filter_map(|row| row.payload.map(serde_json::Value::from))
        .collect())
}

fn build_stats_query(
    plan: &QueryPlan,
    scope: MetricScope<'static>,
    spec: &TimeseriesStatsSpec,
) -> Result<TimeseriesStatsSql> {
    build_stats_query_with_source(
        plan,
        scope,
        spec,
        "timeseries_metrics",
        "timestamp",
        None,
        false,
    )
}

fn build_cagg_stats_query(
    plan: &QueryPlan,
    scope: MetricScope<'static>,
    spec: &TimeseriesStatsSpec,
) -> Result<TimeseriesStatsSql> {
    if spec.is_profile_route() {
        return Err(ServiceError::InvalidRequest(
            "profile_hour_of_week cannot use hourly CAGG stats routing".into(),
        ));
    }

    if !spec.is_avg_value_by_device() {
        return Err(ServiceError::InvalidRequest(
            "hourly CAGG stats routing only supports avg(value) by device_id".into(),
        ));
    }

    let avg_col = super::cagg_column_for_entity(&plan.entity, "avg", "value").ok_or_else(|| {
        ServiceError::InvalidRequest("missing CAGG mapping for avg(value)".into())
    })?;
    let agg_expr = format!(
        "CASE WHEN SUM(sample_count) = 0 THEN NULL ELSE SUM({avg_col} * sample_count)::float8 / SUM(sample_count)::float8 END"
    );
    build_stats_query_with_source(
        plan,
        scope,
        spec,
        "timeseries_metrics_hourly",
        "bucket",
        Some(&agg_expr),
        true,
    )
}

fn build_interface_profile_hour_of_week_query(
    plan: &QueryPlan,
    spec: &TimeseriesStatsSpec,
) -> Result<TimeseriesStatsSql> {
    let Some(field) = spec.profile_hour_of_week_field() else {
        return Err(ServiceError::InvalidRequest(
            "interface profile route requires profile_hour_of_week stats".into(),
        ));
    };

    if field != "value" {
        return Err(ServiceError::InvalidRequest(
            "interface profile_hour_of_week only supports value".into(),
        ));
    }

    let mut clauses = vec![
        "device_id IS NOT NULL".to_string(),
        "if_index IS NOT NULL".to_string(),
        "avg_rate_per_second IS NOT NULL".to_string(),
    ];
    let mut binds = Vec::new();

    if let Some(TimeRange { start, end }) = &plan.time_range {
        clauses.push(super::hourly_cagg_lower_bound_clause("bucket"));
        binds.push(SqlBindValue::Timestamp(*start));
        clauses.push(super::hourly_cagg_upper_bound_clause("bucket"));
        binds.push(SqlBindValue::Timestamp(*end));
    } else {
        return Err(ServiceError::InvalidRequest(
            "interface profile_hour_of_week requires an explicit time range".into(),
        ));
    }

    let timezone = profile_timezone(plan)?;

    for filter in &plan.filters {
        if filter.field.eq_ignore_ascii_case("timezone") {
            continue;
        }

        match build_interface_profile_filter_clause(filter)? {
            Some((clause, mut values)) => {
                clauses.push(clause);
                binds.append(&mut values);
            }
            None => {
                return Err(ServiceError::InvalidRequest(format!(
                    "unsupported filter field for interface profile_hour_of_week: '{}'",
                    filter.field
                )));
            }
        }
    }

    let where_sql = format!("WHERE {}", clauses.join(" AND "));

    for _ in 0..4 {
        binds.push(SqlBindValue::Text(timezone.clone()));
    }

    let selected_rows = if spec.is_profile_hour_of_week_full() {
        "profile_rows"
    } else {
        "latest"
    };

    let sql = format!(
        r#"WITH hourly AS (
  SELECT
    device_id AS series,
    partition,
    target_device_ip,
    if_index,
    metric_type,
    metric_name,
    bucket,
    avg_rate_per_second::float8 AS sample_value
  FROM {INTERFACE_HOURLY_TABLE}
  {where_sql}
),
local_hourly AS (
  SELECT
    series,
    partition,
    target_device_ip,
    if_index,
    metric_type,
    metric_name,
    bucket,
    sample_value,
    EXTRACT(DOW FROM timezone(?, bucket))::int AS dow,
    EXTRACT(HOUR FROM timezone(?, bucket))::int AS hod
  FROM hourly
),
latest AS (
  SELECT DISTINCT ON (series, if_index, metric_name)
    series,
    partition,
    target_device_ip,
    if_index,
    metric_type,
    metric_name,
    bucket,
    sample_value,
    EXTRACT(DOW FROM timezone(?, bucket))::int AS dow,
    EXTRACT(HOUR FROM timezone(?, bucket))::int AS hod
  FROM hourly
  ORDER BY series, if_index, metric_name, bucket DESC
),
profile_rows AS (
  SELECT DISTINCT ON (series, if_index, metric_name, dow, hod)
    series,
    partition,
    target_device_ip,
    if_index,
    metric_type,
    metric_name,
    bucket,
    sample_value,
    dow,
    hod
  FROM local_hourly
  ORDER BY series, if_index, metric_name, dow, hod, bucket DESC
),
profile_keys AS (
  SELECT DISTINCT series, if_index, metric_name, dow, hod
  FROM {selected_rows}
),
mean_profile AS (
  SELECT
    h.series,
    h.if_index,
    h.metric_name,
    h.dow,
    h.hod,
    COUNT(*)::bigint AS bucket_count,
    SUM(sample_value)::float8 AS bucket_sum,
    SUM(sample_value * sample_value)::float8 AS bucket_sum_sq
  FROM local_hourly h
  JOIN profile_keys k
    ON k.series = h.series
   AND k.if_index = h.if_index
   AND k.metric_name = h.metric_name
   AND k.dow = h.dow
   AND k.hod = h.hod
  GROUP BY 1, 2, 3, 4, 5
),
robust_values AS (
  SELECT h.*
  FROM local_hourly h
  JOIN profile_keys k
    ON k.series = h.series
   AND k.if_index = h.if_index
   AND k.metric_name = h.metric_name
   AND k.dow = h.dow
   AND k.hod = h.hod
  LEFT JOIN latest l
    ON l.series = h.series
   AND l.if_index = h.if_index
   AND l.metric_name = h.metric_name
   AND l.bucket = h.bucket
  WHERE l.bucket IS NULL
),
robust_base AS (
  SELECT
    series,
    if_index,
    metric_name,
    dow,
    hod,
    percentile_cont(0.5) WITHIN GROUP (ORDER BY sample_value)::float8 AS center,
    percentile_cont(0.05) WITHIN GROUP (ORDER BY sample_value)::float8 AS p05,
    percentile_cont(0.95) WITHIN GROUP (ORDER BY sample_value)::float8 AS p95
  FROM robust_values
  GROUP BY 1, 2, 3, 4, 5
),
robust_profile AS (
  SELECT
    b.series,
    b.if_index,
    b.metric_name,
    b.dow,
    b.hod,
    b.center,
    percentile_cont(0.5) WITHIN GROUP (ORDER BY abs(v.sample_value - b.center))::float8 AS mad,
    b.p05,
    b.p95
  FROM robust_base b
  JOIN robust_values v
    ON v.series = b.series
   AND v.if_index = b.if_index
   AND v.metric_name = b.metric_name
   AND v.dow = b.dow
   AND v.hod = b.hod
  GROUP BY b.series, b.if_index, b.metric_name, b.dow, b.hod, b.center, b.p05, b.p95
)
SELECT jsonb_build_object(
  'series', l.series,
  'partition', l.partition,
  'target_device_ip', l.target_device_ip,
  'if_index', l.if_index,
  'metric_type', l.metric_type,
  'metric_name', l.metric_name,
  'dow', l.dow,
  'hod', l.hod,
  'sample_value', l.sample_value,
  'bucket', l.bucket,
  'bucket_count', p.bucket_count,
  'bucket_sum', p.bucket_sum,
  'bucket_sum_sq', p.bucket_sum_sq,
  'center', r.center,
  'mad', r.mad,
  'p05', r.p05,
  'p95', r.p95
) AS payload
FROM {selected_rows} l
JOIN mean_profile p
  ON p.series = l.series
 AND p.if_index = l.if_index
 AND p.metric_name = l.metric_name
 AND p.dow = l.dow
 AND p.hod = l.hod
LEFT JOIN robust_profile r
  ON r.series = l.series
 AND r.if_index = l.if_index
 AND r.metric_name = l.metric_name
 AND r.dow = l.dow
 AND r.hod = l.hod{}
LIMIT {} OFFSET {}"#,
        build_interface_profile_order_clause(plan),
        plan.limit,
        plan.offset
    );

    Ok(TimeseriesStatsSql { sql, binds })
}

fn build_interface_profile_filter_clause(
    filter: &Filter,
) -> Result<Option<(String, Vec<SqlBindValue>)>> {
    match filter.field.as_str() {
        "partition" | "device_id" | "target_device_ip" | "metric_type" | "metric_name"
        | "series_key" => Ok(Some(build_text_clause(filter.field.as_str(), filter)?)),
        "if_index" if matches!(filter.op, FilterOp::In) => {
            let values = parse_i32_list(filter.value.as_list()?)?;
            Ok(Some((
                "if_index = ANY(?)".to_string(),
                vec![SqlBindValue::IntArray(
                    values.into_iter().map(i64::from).collect(),
                )],
            )))
        }
        _ => Ok(None),
    }
}

fn build_interface_profile_order_clause(plan: &QueryPlan) -> String {
    let mut parts = Vec::new();
    for clause in &plan.order {
        let column = match clause.field.as_str() {
            "series" | "series_key" => "l.series",
            "if_index" => "l.if_index",
            "metric_name" => "l.metric_name",
            "dow" => "l.dow",
            "hod" => "l.hod",
            "bucket" => "l.bucket",
            "sample_value" => "l.sample_value",
            "bucket_count" => "p.bucket_count",
            _ => continue,
        };

        let dir = match clause.direction {
            OrderDirection::Asc => "ASC",
            OrderDirection::Desc => "DESC",
        };
        parts.push(format!("{column} {dir}"));
    }

    // `profile_hour_of_week_full` is paged with OFFSET.  The requested sort
    // normally prioritizes the presentation order (for example dow/hod), but
    // it must end in the complete profile-row identity or pages can duplicate
    // and skip buckets when several interfaces share the same hour.
    for (field, column) in [
        ("series", "l.series"),
        ("if_index", "l.if_index"),
        ("metric_name", "l.metric_name"),
        ("dow", "l.dow"),
        ("hod", "l.hod"),
    ] {
        if !plan.order.iter().any(|clause| {
            matches!(field, "series") && matches!(clause.field.as_str(), "series" | "series_key")
                || clause.field == field
        }) {
            parts.push(format!("{column} ASC"));
        }
    }

    format!("\nORDER BY {}", parts.join(", "))
}

fn build_stats_query_with_source(
    plan: &QueryPlan,
    scope: MetricScope<'static>,
    spec: &TimeseriesStatsSpec,
    table: &str,
    time_col: &str,
    cagg_avg_expr: Option<&str>,
    cagg_mode: bool,
) -> Result<TimeseriesStatsSql> {
    if spec.is_profile_route() {
        return Err(ServiceError::InvalidRequest(
            "profile_hour_of_week requires the profile stats route".into(),
        ));
    }

    let mut clauses = Vec::new();
    let mut binds = Vec::new();

    if let MetricScope::Forced(metric_type) = scope {
        clauses.push("metric_type = ?".to_string());
        binds.push(SqlBindValue::Text(metric_type.to_string()));
    }

    if let Some(TimeRange { start, end }) = &plan.time_range {
        clauses.push(if cagg_mode {
            super::hourly_cagg_lower_bound_clause(time_col)
        } else {
            format!("{time_col} >= ?")
        });
        binds.push(SqlBindValue::Timestamp(*start));
        clauses.push(if cagg_mode {
            super::hourly_cagg_upper_bound_clause(time_col)
        } else {
            format!("{time_col} <= ?")
        });
        binds.push(SqlBindValue::Timestamp(*end));
    }

    for filter in &plan.filters {
        match build_stats_filter_clause(filter, cagg_mode)? {
            Some((clause, mut values)) => {
                clauses.push(clause);
                binds.append(&mut values);
            }
            // Never skip a filter we could not apply. Dropping it here returned
            // a fleet-wide aggregate for a query that asked for one slice of the
            // fleet, with nothing to indicate the difference. In CAGG mode this
            // is unreachable — `should_route_stats_to_cagg` only routes queries
            // whose filters the aggregate can express — so an error there means
            // routing and filtering have drifted apart, which should be loud.
            None => {
                return Err(ServiceError::InvalidRequest(format!(
                    "unsupported filter field for timeseries_metrics: '{}'",
                    filter.field
                )));
            }
        }
    }

    let group_keys: Vec<&str> = spec
        .group_by
        .iter()
        .map(|group| group.field.as_str())
        .collect();
    let group_exprs: Vec<String> = spec
        .group_by
        .iter()
        .map(|group| group_sql_expr(&group.field))
        .collect::<Result<Vec<_>>>()?;
    let agg_sqls: Vec<String> = spec
        .aggregations
        .iter()
        .map(|agg| timeseries_agg_sql(agg, cagg_avg_expr))
        .collect::<Result<Vec<_>>>()?;

    let select_groups = group_exprs
        .iter()
        .enumerate()
        .map(|(idx, expr)| format!("{expr} AS group_value_{idx}"))
        .collect::<Vec<_>>()
        .join(", ");
    let select_aggs = agg_sqls
        .iter()
        .enumerate()
        .map(|(idx, expr)| format!("{expr} AS agg_value_{idx}"))
        .collect::<Vec<_>>()
        .join(", ");

    let mut inner = format!("SELECT {select_groups}, {select_aggs} FROM {table}");
    if !clauses.is_empty() {
        inner.push_str("\nWHERE ");
        inner.push_str(&clauses.join(" AND "));
    }

    inner.push_str("\nGROUP BY ");
    inner.push_str(&group_exprs.join(", "));

    let agg_aliases: Vec<&str> = spec
        .aggregations
        .iter()
        .map(|aggregation| aggregation.alias.as_str())
        .collect();

    let mut json_parts: Vec<String> =
        Vec::with_capacity(group_keys.len() * 2 + spec.aggregations.len() * 2);
    for (idx, key) in group_keys.iter().enumerate() {
        json_parts.push(format!("'{key}'"));
        json_parts.push(format!("group_value_{idx}"));
    }
    for (idx, agg) in spec.aggregations.iter().enumerate() {
        json_parts.push(format!("'{}'", agg.alias));
        json_parts.push(format!("agg_value_{idx}"));
    }

    let sql = if plan.other {
        validate_timeseries_other_rollup(spec)?;

        let rank_order_sql =
            build_timeseries_stats_rank_order_sql(plan, &group_keys, &agg_aliases)?;
        let mut top_json_parts = json_parts.clone();
        top_json_parts.push("'__other__'".to_string());
        top_json_parts.push("false".to_string());

        let mut other_json_parts: Vec<String> =
            Vec::with_capacity(group_keys.len() * 2 + spec.aggregations.len() * 2 + 2);
        for key in &group_keys {
            other_json_parts.push(format!("'{key}'"));
            other_json_parts.push("NULL".to_string());
        }
        for (idx, agg) in spec.aggregations.iter().enumerate() {
            other_json_parts.push(format!("'{}'", agg.alias));
            other_json_parts.push(format!("COALESCE(SUM(agg_value_{idx}), 0)"));
        }
        other_json_parts.push("'__other__'".to_string());
        other_json_parts.push("true".to_string());

        build_other_rollup_sql(
            &inner,
            &rank_order_sql,
            &top_json_parts,
            &other_json_parts,
            "payload",
            plan.limit,
        )
    } else {
        let order_sql = build_timeseries_stats_order_sql(plan, &group_keys, &agg_aliases)?;
        format!(
            "SELECT jsonb_build_object({json_args}) AS payload FROM ({inner}) t{order_sql} LIMIT {limit} OFFSET {offset}",
            json_args = json_parts.join(", "),
            inner = inner,
            order_sql = order_sql,
            limit = plan.limit,
            offset = plan.offset
        )
    };

    Ok(TimeseriesStatsSql { sql, binds })
}

fn timeseries_agg_sql(
    aggregation: &TimeseriesAggregationSpec,
    cagg_avg_expr: Option<&str>,
) -> Result<String> {
    match aggregation.func {
        TimeseriesAggFunc::Avg => cagg_avg_expr
            .map(str::to_string)
            .or_else(|| {
                aggregation
                    .field
                    .as_deref()
                    .map(|field| format!("AVG({field})"))
            })
            .ok_or_else(|| ServiceError::InvalidRequest("avg aggregation requires a field".into())),
        TimeseriesAggFunc::Sum => aggregation
            .field
            .as_deref()
            .map(|field| format!("SUM({field})"))
            .ok_or_else(|| ServiceError::InvalidRequest("sum aggregation requires a field".into())),
        TimeseriesAggFunc::Count => Ok("COUNT(*)".to_string()),
    }
}

fn build_profile_hour_of_week_query(
    plan: &QueryPlan,
    scope: MetricScope<'static>,
    spec: &TimeseriesStatsSpec,
) -> Result<TimeseriesStatsSql> {
    let Some(field) = spec.profile_hour_of_week_field() else {
        return Err(ServiceError::InvalidRequest(
            "profile route requires profile_hour_of_week stats".into(),
        ));
    };

    if field != "value" {
        return Err(ServiceError::InvalidRequest(
            "profile_hour_of_week only supports value".into(),
        ));
    }

    let mut clauses = vec!["device_id IS NOT NULL".to_string()];
    let mut binds = Vec::new();

    if let MetricScope::Forced(metric_type) = scope {
        clauses.push("metric_type = ?".to_string());
        binds.push(SqlBindValue::Text(metric_type.to_string()));
    }

    if let Some(TimeRange { start, end }) = &plan.time_range {
        clauses.push(super::hourly_cagg_lower_bound_clause("bucket"));
        binds.push(SqlBindValue::Timestamp(*start));
        clauses.push(super::hourly_cagg_upper_bound_clause("bucket"));
        binds.push(SqlBindValue::Timestamp(*end));
    } else {
        return Err(ServiceError::InvalidRequest(
            "profile_hour_of_week requires an explicit time range".into(),
        ));
    }

    let timezone = profile_timezone(plan)?;

    for filter in &plan.filters {
        if filter.field.eq_ignore_ascii_case("timezone") {
            continue;
        }

        match build_stats_filter_clause(filter, true)? {
            Some((clause, mut values)) => {
                clauses.push(clause);
                binds.append(&mut values);
            }
            None => {
                return Err(ServiceError::InvalidRequest(format!(
                    "unsupported filter field for profile_hour_of_week: '{}'",
                    filter.field
                )));
            }
        }
    }

    let where_sql = if clauses.is_empty() {
        String::new()
    } else {
        format!("WHERE {}", clauses.join(" AND "))
    };

    for _ in 0..4 {
        binds.push(SqlBindValue::Text(timezone.clone()));
    }

    let selected_rows = if spec.is_profile_hour_of_week_full() {
        "profile_rows"
    } else {
        "latest"
    };

    let sql = format!(
        r#"WITH hourly AS (
  SELECT
    device_id AS series,
    bucket,
    avg_value::float8 AS sample_value
  FROM timeseries_metrics_hourly
  {where_sql}
),
local_hourly AS (
  SELECT
    series,
    bucket,
    sample_value,
    EXTRACT(DOW FROM timezone(?, bucket))::int AS dow,
    EXTRACT(HOUR FROM timezone(?, bucket))::int AS hod
  FROM hourly
),
latest AS (
  SELECT DISTINCT ON (series)
    series,
    bucket,
    sample_value,
    EXTRACT(DOW FROM timezone(?, bucket))::int AS dow,
    EXTRACT(HOUR FROM timezone(?, bucket))::int AS hod
  FROM hourly
  ORDER BY series, bucket DESC
),
profile_rows AS (
  SELECT DISTINCT ON (series, dow, hod)
    series,
    bucket,
    sample_value,
    dow,
    hod
  FROM local_hourly
  ORDER BY series, dow, hod, bucket DESC
),
profile_keys AS (
  SELECT DISTINCT series, dow, hod
  FROM {selected_rows}
),
mean_profile AS (
  SELECT
    h.series,
    h.dow,
    h.hod,
    COUNT(*)::bigint AS bucket_count,
    SUM(sample_value)::float8 AS bucket_sum,
    SUM(sample_value * sample_value)::float8 AS bucket_sum_sq
  FROM local_hourly h
  JOIN profile_keys k
    ON k.series = h.series
   AND k.dow = h.dow
   AND k.hod = h.hod
  GROUP BY 1, 2, 3
),
robust_values AS (
  SELECT h.*
  FROM local_hourly h
  JOIN profile_keys k
    ON k.series = h.series
   AND k.dow = h.dow
   AND k.hod = h.hod
  LEFT JOIN latest l
    ON l.series = h.series
   AND l.bucket = h.bucket
  WHERE l.bucket IS NULL
),
robust_base AS (
  SELECT
    series,
    dow,
    hod,
    percentile_cont(0.5) WITHIN GROUP (ORDER BY sample_value)::float8 AS center,
    percentile_cont(0.05) WITHIN GROUP (ORDER BY sample_value)::float8 AS p05,
    percentile_cont(0.95) WITHIN GROUP (ORDER BY sample_value)::float8 AS p95
  FROM robust_values
  GROUP BY 1, 2, 3
),
robust_profile AS (
  SELECT
    b.series,
    b.dow,
    b.hod,
    b.center,
    percentile_cont(0.5) WITHIN GROUP (ORDER BY abs(v.sample_value - b.center))::float8 AS mad,
    b.p05,
    b.p95
  FROM robust_base b
  JOIN robust_values v
    ON v.series = b.series
   AND v.dow = b.dow
   AND v.hod = b.hod
  GROUP BY b.series, b.dow, b.hod, b.center, b.p05, b.p95
)
SELECT jsonb_build_object(
  'series', l.series,
  'dow', l.dow,
  'hod', l.hod,
  'sample_value', l.sample_value,
  'bucket', l.bucket,
  'bucket_count', p.bucket_count,
  'bucket_sum', p.bucket_sum,
  'bucket_sum_sq', p.bucket_sum_sq,
  'center', r.center,
  'mad', r.mad,
  'p05', r.p05,
  'p95', r.p95
) AS payload
FROM {selected_rows} l
JOIN mean_profile p
  ON p.series = l.series
 AND p.dow = l.dow
 AND p.hod = l.hod
LEFT JOIN robust_profile r
  ON r.series = l.series
 AND r.dow = l.dow
 AND r.hod = l.hod{}
LIMIT {} OFFSET {}"#,
        build_profile_order_clause(plan, "p"),
        plan.limit,
        plan.offset
    );

    Ok(TimeseriesStatsSql { sql, binds })
}

fn build_profile_hour_of_week_peak_query(
    plan: &QueryPlan,
    scope: MetricScope<'static>,
    spec: &TimeseriesStatsSpec,
) -> Result<TimeseriesStatsSql> {
    let Some(field) = spec.profile_hour_of_week_peak.as_deref() else {
        return Err(ServiceError::InvalidRequest(
            "profile route requires profile_hour_of_week_peak stats".into(),
        ));
    };

    if field != "value" {
        return Err(ServiceError::InvalidRequest(
            "profile_hour_of_week_peak only supports value".into(),
        ));
    }

    let mut clauses = vec!["device_id IS NOT NULL".to_string()];
    let mut binds = Vec::new();

    if let MetricScope::Forced(metric_type) = scope {
        clauses.push("metric_type = ?".to_string());
        binds.push(SqlBindValue::Text(metric_type.to_string()));
    }

    if let Some(TimeRange { start, end }) = &plan.time_range {
        clauses.push(super::hourly_cagg_lower_bound_clause("bucket"));
        binds.push(SqlBindValue::Timestamp(*start));
        clauses.push(super::hourly_cagg_upper_bound_clause("bucket"));
        binds.push(SqlBindValue::Timestamp(*end));
    } else {
        return Err(ServiceError::InvalidRequest(
            "profile_hour_of_week_peak requires an explicit time range".into(),
        ));
    }

    let timezone = profile_timezone(plan)?;

    for filter in &plan.filters {
        if filter.field.eq_ignore_ascii_case("timezone") {
            continue;
        }

        match build_stats_filter_clause(filter, true)? {
            Some((clause, mut values)) => {
                clauses.push(clause);
                binds.append(&mut values);
            }
            None => {
                return Err(ServiceError::InvalidRequest(format!(
                    "unsupported filter field for profile_hour_of_week_peak: '{}'",
                    filter.field
                )));
            }
        }
    }

    let where_sql = if clauses.is_empty() {
        String::new()
    } else {
        format!("WHERE {}", clauses.join(" AND "))
    };

    for _ in 0..4 {
        binds.push(SqlBindValue::Text(timezone.clone()));
    }

    let sql = format!(
        r#"WITH hourly AS (
  SELECT
    device_id AS series,
    bucket,
    max_value::float8 AS sample_value
  FROM timeseries_metrics_hourly
  {where_sql}
),
local_hourly AS (
  SELECT
    series,
    bucket,
    sample_value,
    EXTRACT(DOW FROM timezone(?, bucket))::int AS dow,
    EXTRACT(HOUR FROM timezone(?, bucket))::int AS hod
  FROM hourly
),
latest AS (
  SELECT DISTINCT ON (series)
    series,
    bucket,
    sample_value,
    EXTRACT(DOW FROM timezone(?, bucket))::int AS dow,
    EXTRACT(HOUR FROM timezone(?, bucket))::int AS hod
  FROM hourly
  ORDER BY series, bucket DESC
),
profile_values AS (
  SELECT h.*
  FROM local_hourly h
  JOIN latest l
    ON l.series = h.series
   AND l.hod = h.hod
  WHERE h.bucket <> l.bucket
),
prior_values AS (
  SELECT h.*
  FROM local_hourly h
  JOIN latest l
    ON l.series = h.series
  WHERE h.bucket <> l.bucket
),
cell_profile AS (
  SELECT
    series,
    hod,
    COUNT(*)::bigint AS bucket_count,
    percentile_cont(0.5) WITHIN GROUP (ORDER BY sample_value)::float8 AS center,
    percentile_cont(0.05) WITHIN GROUP (ORDER BY sample_value)::float8 AS p05,
    percentile_cont(0.95) WITHIN GROUP (ORDER BY sample_value)::float8 AS p95
  FROM profile_values
  GROUP BY 1, 2
),
series_prior AS (
  SELECT
    series,
    percentile_cont(0.05) WITHIN GROUP (ORDER BY sample_value)::float8 AS prior_p05,
    percentile_cont(0.95) WITHIN GROUP (ORDER BY sample_value)::float8 AS prior_p95
  FROM prior_values
  GROUP BY 1
)
SELECT jsonb_build_object(
  'series', l.series,
  'dow', l.dow,
  'hod', l.hod,
  'sample_value', l.sample_value,
  'bucket', l.bucket,
  'bucket_count', c.bucket_count,
  'center', c.center,
  'p05', c.p05,
  'p95', c.p95,
  'q95', c.p95,
  'scale', ((c.p95 - c.p05) * 0.30398)::float8,
  'prior_scale', ((p.prior_p95 - p.prior_p05) * 0.30398)::float8
) AS payload
FROM latest l
LEFT JOIN cell_profile c
  ON c.series = l.series
 AND c.hod = l.hod
LEFT JOIN series_prior p
  ON p.series = l.series{}
LIMIT {} OFFSET {}"#,
        build_profile_order_clause(plan, "c"),
        plan.limit,
        plan.offset
    );

    Ok(TimeseriesStatsSql { sql, binds })
}

fn validate_timeseries_other_rollup(spec: &TimeseriesStatsSpec) -> Result<()> {
    for agg in &spec.aggregations {
        if !matches!(agg.func, TimeseriesAggFunc::Sum | TimeseriesAggFunc::Count) {
            return Err(ServiceError::InvalidRequest(
                "other:true currently supports only sum(...) and count(...) aggregations".into(),
            ));
        }
    }

    Ok(())
}

fn build_timeseries_stats_order_sql(
    plan: &QueryPlan,
    group_keys: &[&str],
    agg_aliases: &[&str],
) -> Result<String> {
    let parts = build_timeseries_stats_order_parts(plan, group_keys, agg_aliases)?;
    Ok(if parts.is_empty() {
        String::new()
    } else {
        format!(" ORDER BY {}", parts.join(", "))
    })
}

fn build_timeseries_stats_rank_order_sql(
    plan: &QueryPlan,
    group_keys: &[&str],
    agg_aliases: &[&str],
) -> Result<String> {
    let mut parts = build_timeseries_stats_order_parts(plan, group_keys, agg_aliases)?;
    for idx in 0..group_keys.len() {
        let group_expr = format!("group_value_{idx}");
        if !parts.iter().any(|part| part.starts_with(&group_expr)) {
            parts.push(format!("{group_expr} ASC"));
        }
    }

    Ok(format!("ORDER BY {}", parts.join(", ")))
}

fn build_timeseries_stats_order_parts(
    plan: &QueryPlan,
    group_keys: &[&str],
    agg_aliases: &[&str],
) -> Result<Vec<String>> {
    if plan.order.is_empty() {
        return Ok(vec!["agg_value_0 DESC".to_string()]);
    }

    let mut parts: Vec<String> = Vec::new();
    for clause in &plan.order {
        let expr = if let Some(idx) = agg_aliases.iter().position(|a| clause.field == *a) {
            format!("agg_value_{idx}")
        } else if let Some(idx) = group_keys.iter().position(|k| *k == clause.field) {
            format!("group_value_{idx}")
        } else {
            return Err(ServiceError::InvalidRequest(format!(
                "unsupported sort field '{}' for timeseries stats",
                clause.field
            )));
        };

        let dir = match clause.direction {
            OrderDirection::Asc => "ASC",
            OrderDirection::Desc => "DESC",
        };
        parts.push(format!("{expr} {dir}"));
    }

    Ok(parts)
}

fn build_profile_order_clause(plan: &QueryPlan, bucket_count_alias: &str) -> String {
    let mut parts = Vec::new();
    for clause in &plan.order {
        let column = match clause.field.as_str() {
            "series" | "series_key" => "l.series",
            "dow" => "l.dow",
            "hod" => "l.hod",
            "bucket" => "l.bucket",
            "sample_value" => "l.sample_value",
            "bucket_count" => {
                if bucket_count_alias == "c" {
                    "c.bucket_count"
                } else {
                    "p.bucket_count"
                }
            }
            _ => continue,
        };

        let dir = match clause.direction {
            OrderDirection::Asc => "ASC",
            OrderDirection::Desc => "DESC",
        };
        parts.push(format!("{column} {dir}"));
    }

    // Complete the order with the unique profile-row identity.  This is a
    // correctness property for OFFSET pagination, not merely a performance
    // preference: without it two pages can overlap or leave gaps.
    for (field, column) in [("series", "l.series"), ("dow", "l.dow"), ("hod", "l.hod")] {
        if !plan.order.iter().any(|clause| {
            matches!(field, "series") && matches!(clause.field.as_str(), "series" | "series_key")
                || clause.field == field
        }) {
            parts.push(format!("{column} ASC"));
        }
    }

    format!("\nORDER BY {}", parts.join(", "))
}

fn profile_timezone(plan: &QueryPlan) -> Result<String> {
    let timezone = plan
        .filters
        .iter()
        .find(|filter| filter.field.eq_ignore_ascii_case("timezone"))
        .map(|filter| filter.value.as_scalar())
        .transpose()?
        .map(normalize_profile_timezone)
        .unwrap_or_else(|| DEFAULT_PROFILE_TIMEZONE.to_string());

    Ok(timezone)
}

fn normalize_profile_timezone(timezone: &str) -> String {
    let timezone = timezone.trim();

    if timezone == "UTC" || timezone == DEFAULT_PROFILE_TIMEZONE {
        return DEFAULT_PROFILE_TIMEZONE.to_string();
    }

    if safe_profile_timezone(timezone) && zoneinfo_timezone(timezone) {
        timezone.to_string()
    } else {
        DEFAULT_PROFILE_TIMEZONE.to_string()
    }
}

fn safe_profile_timezone(timezone: &str) -> bool {
    if timezone.is_empty()
        || timezone.len() > 128
        || timezone.starts_with('/')
        || timezone.ends_with('/')
    {
        return false;
    }

    timezone.split('/').all(|part| {
        !part.is_empty()
            && part != "."
            && part != ".."
            && part
                .chars()
                .all(|ch| ch.is_ascii_alphanumeric() || matches!(ch, '_' | '-' | '+' | '.'))
    })
}

fn zoneinfo_timezone(timezone: &str) -> bool {
    ZONEINFO_DIRS
        .iter()
        .any(|dir| Path::new(dir).join(timezone).is_file())
}

/// Columns the hourly CAGG projection actually carries.
///
/// A filter on anything else cannot be evaluated against the aggregate, which
/// is why `filters_are_cagg_expressible` refuses to route such a query there
/// rather than dropping the predicate.
const CAGG_FILTERABLE_FIELDS: [&str; 3] = ["device_id", "metric_type", "metric_name"];

/// Whether every filter in the plan can be expressed against the hourly CAGG.
///
/// Routing is decided by time range alone, so without this check the same query
/// meant two different things either side of the six-hour threshold: at
/// `time:last_1h` a `gateway_id` filter was applied, and at `time:last_24h` it
/// was silently discarded and the answer widened to the whole fleet.
fn filters_are_cagg_expressible(plan: &QueryPlan) -> bool {
    plan.filters
        .iter()
        .all(|filter| CAGG_FILTERABLE_FIELDS.contains(&filter.field.as_str()))
}

/// Build the WHERE clause for one filter on the stats path.
///
/// `Ok(None)` means "this field cannot be applied here" and is a signal to the
/// caller, not permission to ignore the filter — the profile routes turn it
/// into their own error, and `build_stats_query_with_source` now does the same.
/// It used to be silently discarded there, so an unrecognised field (a tag key,
/// or simply a typo) dropped out of the query and the aggregate ran unfiltered,
/// reporting a fleet-wide number as though it were scoped.
fn build_stats_filter_clause(
    filter: &Filter,
    cagg_mode: bool,
) -> Result<Option<(String, Vec<SqlBindValue>)>> {
    if cagg_mode {
        return match filter.field.as_str() {
            field if CAGG_FILTERABLE_FIELDS.contains(&field) => {
                Ok(Some(build_text_clause(field, filter)?))
            }
            _ => Ok(None),
        };
    }

    match filter.field.as_str() {
        "gateway_id" => Ok(Some(build_text_clause("gateway_id", filter)?)),
        "agent_id" => Ok(Some(build_text_clause("agent_id", filter)?)),
        "metric_name" => Ok(Some(build_text_clause("metric_name", filter)?)),
        "metric_type" => Ok(Some(build_text_clause("metric_type", filter)?)),
        "device_id" => Ok(Some(build_text_clause("device_id", filter)?)),
        "target_device_ip" => Ok(Some(build_text_clause("target_device_ip", filter)?)),
        "partition" => Ok(Some(build_text_clause("partition", filter)?)),
        field if field.starts_with("tags.") => {
            let key = tag_key(field)?;
            Ok(Some(build_text_clause(&tag_expr(&key), filter)?))
        }
        _ => Ok(None),
    }
}

/// Extract and validate the key from a `tags.<key>` field reference.
///
/// Validation is not cosmetic here: the returned expression is interpolated
/// into SQL by `format!`, both as a WHERE predicate and — for grouping — into
/// the SELECT and GROUP BY lists. `is_valid_jsonb_key` excludes quotes, so the
/// key cannot escape the string literal.
fn tag_key(field: &str) -> Result<String> {
    let key = field.strip_prefix("tags.").unwrap_or_default();
    if !is_valid_jsonb_key(key) {
        return Err(ServiceError::InvalidRequest(format!(
            "invalid tag key '{key}'"
        )));
    }

    Ok(key.to_string())
}

/// Single-level JSONB text extraction, matching what the devices entity emits.
fn tag_expr(key: &str) -> String {
    format!("tags->>'{key}'")
}

/// SQL expression for a stats group field.
///
/// Plain columns pass through; `tags.<key>` becomes a JSONB extraction. The
/// result is interpolated straight into the SELECT and GROUP BY lists, so the
/// tag branch revalidates the key here rather than trusting that parsing
/// already did.
fn group_sql_expr(field: &str) -> Result<String> {
    if field.starts_with("tags.") {
        return Ok(tag_expr(&tag_key(field)?));
    }

    Ok(field.to_string())
}

fn build_text_clause(column: &str, filter: &Filter) -> Result<(String, Vec<SqlBindValue>)> {
    let mut binds = Vec::new();
    let clause = match filter.op {
        FilterOp::Eq => {
            binds.push(SqlBindValue::Text(filter.value.as_scalar()?.to_string()));
            format!("{column} = ?")
        }
        FilterOp::NotEq => {
            binds.push(SqlBindValue::Text(filter.value.as_scalar()?.to_string()));
            format!("{column} <> ?")
        }
        FilterOp::Like => {
            binds.push(SqlBindValue::Text(filter.value.as_scalar()?.to_string()));
            format!("{column} ILIKE ?")
        }
        FilterOp::NotLike => {
            binds.push(SqlBindValue::Text(filter.value.as_scalar()?.to_string()));
            format!("NOT ({column} ILIKE ?)")
        }
        FilterOp::In => {
            let values = filter.value.as_list()?.to_vec();
            if values.is_empty() {
                return Ok(("1=0".to_string(), Vec::new()));
            }
            binds.push(SqlBindValue::TextArray(values));
            format!("{column} = ANY(?)")
        }
        FilterOp::NotIn => {
            let values = filter.value.as_list()?.to_vec();
            if values.is_empty() {
                return Ok(("1=1".to_string(), Vec::new()));
            }
            binds.push(SqlBindValue::TextArray(values));
            format!("{column} <> ALL(?)")
        }
        _ => {
            return Err(ServiceError::InvalidRequest(format!(
                "text filter {column} does not support operator {:?}",
                filter.op
            )));
        }
    };
    Ok((clause, binds))
}

fn parse_stats_spec(raw: Option<&str>) -> Result<Option<TimeseriesStatsSpec>> {
    let stats_raw = match raw {
        Some(value) if !value.trim().is_empty() => value.trim(),
        _ => return Ok(None),
    };

    if let Some(field) = parse_profile_hour_of_week(stats_raw)? {
        return Ok(Some(TimeseriesStatsSpec {
            aggregations: Vec::new(),
            group_by: Vec::new(),
            profile_hour_of_week: Some(field),
            profile_hour_of_week_full: None,
            profile_hour_of_week_peak: None,
        }));
    }

    if let Some(field) = parse_profile_hour_of_week_full(stats_raw)? {
        return Ok(Some(TimeseriesStatsSpec {
            aggregations: Vec::new(),
            group_by: Vec::new(),
            profile_hour_of_week: None,
            profile_hour_of_week_full: Some(field),
            profile_hour_of_week_peak: None,
        }));
    }

    if let Some(field) = parse_profile_hour_of_week_peak(stats_raw)? {
        return Ok(Some(TimeseriesStatsSpec {
            aggregations: Vec::new(),
            group_by: Vec::new(),
            profile_hour_of_week: None,
            profile_hour_of_week_full: None,
            profile_hour_of_week_peak: Some(field),
        }));
    }

    let (expr_segment, group_segment) = split_group_clause(stats_raw).ok_or_else(|| {
        ServiceError::InvalidRequest(
            "timeseries metrics stats expression must include a by clause".into(),
        )
    })?;

    let mut aggregations = Vec::new();
    for segment in expr_segment
        .split(',')
        .map(str::trim)
        .filter(|segment| !segment.is_empty())
    {
        aggregations.push(parse_timeseries_stats_aggregation(segment)?);
    }

    if aggregations.is_empty() {
        return Err(ServiceError::InvalidRequest(
            "timeseries metrics stats expression must include at least one aggregation".into(),
        ));
    }

    let mut group_by = Vec::new();
    for token in group_segment
        .split(',')
        .map(str::trim)
        .filter(|token| !token.is_empty())
    {
        group_by.push(parse_timeseries_group(token)?);
    }

    if group_by.is_empty() {
        return Err(ServiceError::InvalidRequest(
            "timeseries metrics stats expression must include at least one group key".into(),
        ));
    }

    Ok(Some(TimeseriesStatsSpec {
        aggregations,
        group_by,
        profile_hour_of_week: None,
        profile_hour_of_week_full: None,
        profile_hour_of_week_peak: None,
    }))
}

fn parse_profile_hour_of_week(raw: &str) -> Result<Option<String>> {
    let normalized = raw.trim().to_lowercase();
    let Some(inner) = normalized
        .strip_prefix("profile_hour_of_week(")
        .and_then(|value| value.strip_suffix(')'))
    else {
        return Ok(None);
    };

    let field = inner.trim();
    if field != "value" {
        return Err(ServiceError::InvalidRequest(
            "profile_hour_of_week only supports value".into(),
        ));
    }

    Ok(Some(field.to_string()))
}

fn parse_profile_hour_of_week_full(raw: &str) -> Result<Option<String>> {
    let normalized = raw.trim().to_lowercase();
    let Some(inner) = normalized
        .strip_prefix("profile_hour_of_week_full(")
        .and_then(|value| value.strip_suffix(')'))
    else {
        return Ok(None);
    };

    let field = inner.trim();
    if field != "value" {
        return Err(ServiceError::InvalidRequest(
            "profile_hour_of_week_full only supports value".into(),
        ));
    }

    Ok(Some(field.to_string()))
}

fn parse_profile_hour_of_week_peak(raw: &str) -> Result<Option<String>> {
    let normalized = raw.trim().to_lowercase();
    let Some(inner) = normalized
        .strip_prefix("profile_hour_of_week_peak(")
        .and_then(|value| value.strip_suffix(')'))
    else {
        return Ok(None);
    };

    let field = inner.trim();
    if field != "value" {
        return Err(ServiceError::InvalidRequest(
            "profile_hour_of_week_peak only supports value".into(),
        ));
    }

    Ok(Some(field.to_string()))
}

fn split_group_clause(raw: &str) -> Option<(String, String)> {
    let lower = raw.to_lowercase();
    if let Some(idx) = lower.rfind(" by ") {
        let left = raw[..idx].trim().to_string();
        let right = raw[idx + 4..]
            .trim()
            .trim_matches('"')
            .trim_matches('\'')
            .to_string();
        if left.is_empty() || right.is_empty() {
            None
        } else {
            Some((left, right))
        }
    } else {
        None
    }
}

fn split_alias(segment: &str) -> Result<(String, String)> {
    let lower = segment.to_lowercase();
    if let Some(idx) = lower.rfind(" as ") {
        let expr = segment[..idx].trim().to_string();
        let alias = segment[idx + 4..]
            .trim()
            .trim_matches('"')
            .trim_matches('\'')
            .to_string();
        if expr.is_empty() || alias.is_empty() {
            return Err(ServiceError::InvalidRequest(
                "stats expression must include an alias".into(),
            ));
        }
        Ok((expr, alias))
    } else {
        Err(ServiceError::InvalidRequest(
            "stats expression must include an alias".into(),
        ))
    }
}

fn parse_timeseries_stats_aggregation(segment: &str) -> Result<TimeseriesAggregationSpec> {
    let (expr, alias_raw) = split_alias(segment)?;
    let alias = sanitize_alias(alias_raw)?;
    let expr = expr.trim();
    let open = expr.find('(').ok_or_else(|| {
        ServiceError::InvalidRequest("invalid timeseries stats aggregation expression".into())
    })?;
    let close = expr.rfind(')').ok_or_else(|| {
        ServiceError::InvalidRequest("invalid timeseries stats aggregation expression".into())
    })?;
    if close <= open {
        return Err(ServiceError::InvalidRequest(
            "invalid timeseries stats aggregation expression".into(),
        ));
    }

    let func_raw = expr[..open].trim().to_lowercase();
    let field_raw = expr[open + 1..close].trim().to_lowercase();
    let func = match func_raw.as_str() {
        "avg" => TimeseriesAggFunc::Avg,
        "sum" => TimeseriesAggFunc::Sum,
        "count" => TimeseriesAggFunc::Count,
        _ => {
            return Err(ServiceError::InvalidRequest(format!(
                "unsupported timeseries aggregation function '{func_raw}'"
            )));
        }
    };

    let field = match func {
        TimeseriesAggFunc::Count if field_raw == "*" => None,
        TimeseriesAggFunc::Count => {
            return Err(ServiceError::InvalidRequest(
                "timeseries count aggregation only supports count(*)".into(),
            ));
        }
        TimeseriesAggFunc::Avg | TimeseriesAggFunc::Sum => {
            if field_raw != "value" {
                return Err(ServiceError::InvalidRequest(
                    "timeseries avg/sum aggregations only support value".into(),
                ));
            }
            Some("value".to_string())
        }
    };

    Ok(TimeseriesAggregationSpec { func, field, alias })
}

fn parse_timeseries_group(raw: &str) -> Result<TimeseriesGroupSpec> {
    let field = raw
        .trim()
        .trim_matches('"')
        .trim_matches('\'')
        .to_lowercase();
    match field.as_str() {
        "gateway_id" | "agent_id" | "series_key" | "metric_name" | "metric_type" | "device_id"
        | "unit" | "partition" | "target_device_ip" | "if_index" => {
            Ok(TimeseriesGroupSpec { field })
        }
        // `tags.<key>` groups on a single-level JSONB extraction. tag_key
        // validates before the key can reach the interpolated group expression.
        candidate if candidate.starts_with("tags.") => {
            tag_key(candidate)?;
            Ok(TimeseriesGroupSpec { field })
        }
        _ => Err(ServiceError::InvalidRequest(format!(
            "unsupported timeseries stats group field '{field}'"
        ))),
    }
}

fn sanitize_alias(raw: String) -> Result<String> {
    let alias = raw.trim().to_lowercase();
    if alias.is_empty()
        || alias
            .chars()
            .any(|ch| !ch.is_ascii_alphanumeric() && ch != '_')
    {
        return Err(ServiceError::InvalidRequest(
            "stats alias must be alphanumeric".into(),
        ));
    }
    Ok(alias)
}

fn should_route_stats_to_cagg(plan: &QueryPlan, spec: &TimeseriesStatsSpec) -> bool {
    if plan.other
        || !spec.is_avg_value_by_device()
        || !super::should_route_plan_to_hourly_cagg(plan)
    {
        return false;
    }

    filters_are_cagg_expressible(plan)
}

impl TimeseriesStatsSpec {
    fn is_profile_hour_of_week(&self) -> bool {
        self.profile_hour_of_week.is_some() || self.profile_hour_of_week_full.is_some()
    }

    fn is_profile_hour_of_week_full(&self) -> bool {
        self.profile_hour_of_week_full.is_some()
    }

    fn profile_hour_of_week_field(&self) -> Option<&str> {
        self.profile_hour_of_week
            .as_deref()
            .or(self.profile_hour_of_week_full.as_deref())
    }

    fn is_profile_hour_of_week_peak(&self) -> bool {
        self.profile_hour_of_week_peak.is_some()
    }

    fn is_profile_route(&self) -> bool {
        self.is_profile_hour_of_week() || self.is_profile_hour_of_week_peak()
    }

    fn is_avg_value_by_device(&self) -> bool {
        !self.is_profile_route()
            && self.aggregations.len() == 1
            && self.group_by.len() == 1
            && self.group_by[0].field == "device_id"
            && self.aggregations[0].func == TimeseriesAggFunc::Avg
            && self.aggregations[0].field.as_deref() == Some("value")
    }
}

fn rewrite_placeholders(sql: &str) -> String {
    let mut rewritten = String::with_capacity(sql.len());
    let mut index = 1;
    for ch in sql.chars() {
        if ch == '?' {
            rewritten.push('$');
            rewritten.push_str(&index.to_string());
            index += 1;
        } else {
            rewritten.push(ch);
        }
    }
    rewritten
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::parser::{Entity, Filter, FilterOp, FilterValue, OrderClause, OrderDirection};
    use chrono::{Duration as ChronoDuration, TimeZone, Utc};

    /// Build a plan for the stats path with the supplied filters.
    fn stats_plan(filters: Vec<Filter>, group: &str) -> (QueryPlan, TimeseriesStatsSpec) {
        let start = Utc.with_ymd_and_hms(2025, 1, 1, 0, 0, 0).unwrap();
        let end = start + ChronoDuration::hours(1);
        let spec = TimeseriesStatsSpec {
            aggregations: vec![TimeseriesAggregationSpec {
                func: TimeseriesAggFunc::Avg,
                field: Some("value".to_string()),
                alias: "v".to_string(),
            }],
            group_by: vec![parse_timeseries_group(group).expect("group should parse")],
            profile_hour_of_week: None,
            profile_hour_of_week_full: None,
            profile_hour_of_week_peak: None,
        };
        let plan = QueryPlan {
            entity: Entity::TimeseriesMetrics,
            filters,
            order: Vec::new(),
            limit: 100,
            offset: 0,
            time_range: Some(TimeRange { start, end }),
            stats: None,
            downsample: None,
            rollup_stats: None,
            other: false,
            include_deleted: false,
        };
        (plan, spec)
    }

    fn eq_filter(field: &str, value: &str) -> Filter {
        Filter {
            field: field.into(),
            op: FilterOp::Eq,
            value: FilterValue::Scalar(value.to_string()),
        }
    }

    // The bug this change exists to fix: the stats path used to return
    // Ok(None) for any field it did not recognise, drop the predicate, and
    // report a fleet-wide aggregate as though it were scoped. Verified
    // end-to-end before the fix: the SQL carried no site predicate and only the
    // two time-bound binds.
    #[test]
    fn stats_path_errors_instead_of_dropping_an_unknown_filter() {
        let (plan, spec) = stats_plan(vec![eq_filter("nonsense_field", "x")], "device_id");
        let err = build_stats_query(&plan, MetricScope::Any, &spec)
            .expect_err("an inapplicable filter must not be silently dropped");

        assert!(
            err.to_string().contains("unsupported filter field"),
            "unexpected error: {err}"
        );
    }

    // A typo is the common way to hit this, and silently widening the query is
    // the worst possible response to one.
    #[test]
    fn stats_path_errors_on_a_misspelled_field() {
        let (plan, spec) = stats_plan(vec![eq_filter("metric_nmae", "cpu")], "device_id");
        assert!(build_stats_query(&plan, MetricScope::Any, &spec).is_err());
    }

    #[test]
    fn stats_path_matches_the_non_stats_path_on_unknown_fields() {
        let (plan, spec) = stats_plan(vec![eq_filter("nonsense_field", "x")], "device_id");
        let stats_err = build_stats_query(&plan, MetricScope::Any, &spec).unwrap_err();
        let raw_err = match build_query(&plan, MetricScope::Any) {
            Err(err) => err,
            // The boxed select statement is not Debug, so this cannot use
            // unwrap_err().
            Ok(_) => panic!("the raw path should also reject an unknown field"),
        };

        assert_eq!(
            stats_err.to_string(),
            raw_err.to_string(),
            "the two paths should reject identical input identically"
        );
    }

    #[test]
    fn stats_path_applies_a_tag_filter() {
        let (plan, spec) = stats_plan(vec![eq_filter("tags.site_code", "ORD")], "device_id");
        let sql = build_stats_query(&plan, MetricScope::Any, &spec).expect("tag filter applies");

        assert!(
            sql.sql.contains("tags->>'site_code'"),
            "expected a tag predicate: {}",
            sql.sql
        );
        // Two time bounds plus the site value.
        assert_eq!(
            sql.binds.len(),
            3,
            "site value should be bound: {}",
            sql.sql
        );
    }

    #[test]
    fn stats_groups_by_a_tag() {
        let (plan, spec) = stats_plan(Vec::new(), "tags.site_code");
        let sql = build_stats_query(&plan, MetricScope::Any, &spec).expect("tag group builds");

        assert!(
            sql.sql.contains("tags->>'site_code' AS group_value_0"),
            "expected a tag group expression: {}",
            sql.sql
        );
        // The projected key keeps the caller's spelling so it is distinguishable
        // from a real column of the same name.
        assert!(
            sql.sql.contains("'tags.site_code'"),
            "expected the tag projected under its own key: {}",
            sql.sql
        );
    }

    // Group expressions are interpolated into the SELECT and GROUP BY lists, so
    // an unvalidated key would be a straightforward injection.
    #[test]
    fn tag_group_rejects_keys_that_could_escape_the_literal() {
        for bad in [
            "tags.a'b",
            "tags.a\"b",
            "tags.a b",
            "tags.",
            "tags.a;DROP TABLE x--",
        ] {
            assert!(
                parse_timeseries_group(bad).is_err(),
                "{bad} should be rejected as a group field"
            );
        }
    }

    #[test]
    fn tag_filter_rejects_an_unsafe_key() {
        let (plan, spec) = stats_plan(vec![eq_filter("tags.a'b", "x")], "device_id");
        let err = build_stats_query(&plan, MetricScope::Any, &spec)
            .expect_err("an unsafe tag key must be rejected");

        assert!(
            err.to_string().contains("invalid tag key"),
            "unexpected error: {err}"
        );
    }

    // CAGG routing already refuses queries whose filters the aggregate cannot
    // express, so this guards the invariant rather than a reachable bug.
    #[test]
    fn cagg_routing_is_refused_when_a_filter_is_not_expressible() {
        let now = Utc::now();
        let plan = QueryPlan {
            entity: Entity::TimeseriesMetrics,
            filters: vec![eq_filter("gateway_id", "g1")],
            order: Vec::new(),
            limit: 100,
            offset: 0,
            time_range: Some(TimeRange {
                start: now - ChronoDuration::hours(24),
                end: now,
            }),
            stats: None,
            downsample: None,
            rollup_stats: None,
            other: false,
            include_deleted: false,
        };
        let spec = TimeseriesStatsSpec {
            aggregations: vec![TimeseriesAggregationSpec {
                func: TimeseriesAggFunc::Avg,
                field: Some("value".to_string()),
                alias: "v".to_string(),
            }],
            group_by: vec![TimeseriesGroupSpec {
                field: "device_id".into(),
            }],
            profile_hour_of_week: None,
            profile_hour_of_week_full: None,
            profile_hour_of_week_peak: None,
        };

        assert!(
            !should_route_stats_to_cagg(&plan, &spec),
            "a gateway_id filter must keep the query on the raw table"
        );

        let sql = build_stats_query(&plan, MetricScope::Any, &spec).expect("raw path builds");
        assert!(
            sql.sql.contains("gateway_id"),
            "the predicate must survive: {}",
            sql.sql
        );
    }

    #[test]
    fn unknown_filter_field_returns_error() {
        let start = Utc.with_ymd_and_hms(2025, 1, 1, 0, 0, 0).unwrap();
        let end = start + ChronoDuration::hours(1);
        let plan = QueryPlan {
            entity: Entity::TimeseriesMetrics,
            filters: vec![Filter {
                field: "unknown_field".into(),
                op: FilterOp::Eq,
                value: FilterValue::Scalar("test".to_string()),
            }],
            order: Vec::new(),
            limit: 100,
            offset: 0,
            time_range: Some(TimeRange { start, end }),
            stats: None,
            downsample: None,
            rollup_stats: None,
            other: false,
            include_deleted: false,
        };

        let result = build_query(&plan, MetricScope::Any);
        match result {
            Err(err) => {
                assert!(
                    err.to_string().contains("unsupported filter field"),
                    "error should mention unsupported filter field: {}",
                    err
                );
            }
            Ok(_) => panic!("expected error for unknown filter field"),
        }
    }

    #[test]
    fn stats_query_supports_timeseries_language_reference() {
        let start = Utc.with_ymd_and_hms(2025, 1, 1, 0, 0, 0).unwrap();
        let end = start + ChronoDuration::hours(1);
        let plan = QueryPlan {
            entity: Entity::TimeseriesMetrics,
            filters: vec![Filter {
                field: "partition".into(),
                op: FilterOp::Eq,
                value: FilterValue::Scalar("demo".to_string()),
            }],
            order: vec![OrderClause {
                field: "avg_value".into(),
                direction: OrderDirection::Desc,
            }],
            limit: 100,
            offset: 0,
            time_range: Some(TimeRange { start, end }),
            stats: Some(crate::parser::StatsSpec::from_raw(
                "avg(value) as avg_value by device_id",
            )),
            downsample: None,
            rollup_stats: None,
            other: false,
            include_deleted: false,
        };

        let spec = parse_stats_spec(plan.stats.as_ref().map(|s| s.as_raw()))
            .unwrap()
            .unwrap();
        let sql =
            build_stats_query(&plan, MetricScope::Any, &spec).expect("stats SQL should build");
        assert!(
            sql.sql.contains("FROM timeseries_metrics")
                && sql.sql.contains("AVG(value)")
                && sql.sql.contains("GROUP BY device_id"),
            "unexpected stats SQL: {}",
            sql.sql
        );
    }

    #[test]
    fn stats_query_uses_timeseries_hourly_cagg_for_large_windows() {
        let start = Utc.with_ymd_and_hms(2025, 1, 1, 0, 0, 0).unwrap();
        let end = start + ChronoDuration::hours(7);
        let plan = QueryPlan {
            entity: Entity::TimeseriesMetrics,
            filters: vec![Filter {
                field: "device_id".into(),
                op: FilterOp::Eq,
                value: FilterValue::Scalar("dev-1".to_string()),
            }],
            order: vec![OrderClause {
                field: "avg_value".into(),
                direction: OrderDirection::Desc,
            }],
            limit: 100,
            offset: 0,
            time_range: Some(TimeRange { start, end }),
            stats: Some(crate::parser::StatsSpec::from_raw(
                "avg(value) as avg_value by device_id",
            )),
            downsample: None,
            rollup_stats: None,
            other: false,
            include_deleted: false,
        };

        let spec = parse_stats_spec(plan.stats.as_ref().map(|s| s.as_raw()))
            .unwrap()
            .unwrap();
        let sql = build_cagg_stats_query(&plan, MetricScope::Any, &spec)
            .expect("cagg stats SQL should build");
        assert!(
            sql.sql.contains("FROM timeseries_metrics_hourly")
                && sql.sql.contains("avg_value")
                && sql.sql.contains("sample_count"),
            "unexpected cagg stats SQL: {}",
            sql.sql
        );
        assert!(should_route_stats_to_cagg(&plan, &spec));
    }

    #[test]
    fn stats_query_other_rollup_ranks_full_result_and_sums_tail() {
        let start = Utc.with_ymd_and_hms(2025, 1, 1, 0, 0, 0).unwrap();
        let end = start + ChronoDuration::hours(1);
        let plan = QueryPlan {
            entity: Entity::TimeseriesMetrics,
            filters: vec![Filter {
                field: "metric_type".into(),
                op: FilterOp::Eq,
                value: FilterValue::Scalar("snmp".to_string()),
            }],
            order: vec![OrderClause {
                field: "total_value".into(),
                direction: OrderDirection::Desc,
            }],
            limit: 10,
            offset: 0,
            time_range: Some(TimeRange { start, end }),
            stats: Some(crate::parser::StatsSpec::from_raw(
                "sum(value) as total_value, count(*) as sample_count by device_id",
            )),
            downsample: None,
            rollup_stats: None,
            other: true,
            include_deleted: false,
        };

        let spec = parse_stats_spec(plan.stats.as_ref().map(|s| s.as_raw()))
            .unwrap()
            .unwrap();
        let sql = build_stats_query(&plan, MetricScope::Any, &spec)
            .expect("other rollup stats SQL should build");

        assert!(
            sql.sql.contains("WITH grouped AS"),
            "expected grouped CTE: {}",
            sql.sql
        );
        assert!(
            sql.sql.contains("ranked AS")
                && sql.sql.contains(
                    "ROW_NUMBER() OVER (ORDER BY agg_value_0 DESC, group_value_0 ASC) AS rn"
                ),
            "expected deterministic ranked CTE: {}",
            sql.sql
        );
        assert!(
            sql.sql.contains("WHERE rn <= 10")
                && sql.sql.contains("UNION ALL")
                && sql.sql.contains("WHERE rn > 10"),
            "expected top-N plus tail union: {}",
            sql.sql
        );
        assert!(
            sql.sql.contains("'device_id', NULL")
                && sql
                    .sql
                    .contains("'total_value', COALESCE(SUM(agg_value_0), 0)")
                && sql
                    .sql
                    .contains("'sample_count', COALESCE(SUM(agg_value_1), 0)")
                && sql.sql.contains("'__other__', true"),
            "expected Other JSON payload: {}",
            sql.sql
        );
        assert!(
            !should_route_stats_to_cagg(&plan, &spec),
            "other:true additive stats must stay on raw grouped rows"
        );
    }

    #[test]
    fn other_rollup_rejects_non_additive_timeseries_aggregates() {
        let start = Utc.with_ymd_and_hms(2025, 1, 1, 0, 0, 0).unwrap();
        let end = start + ChronoDuration::hours(1);
        let plan = QueryPlan {
            entity: Entity::TimeseriesMetrics,
            filters: Vec::new(),
            order: vec![OrderClause {
                field: "avg_value".into(),
                direction: OrderDirection::Desc,
            }],
            limit: 10,
            offset: 0,
            time_range: Some(TimeRange { start, end }),
            stats: Some(crate::parser::StatsSpec::from_raw(
                "avg(value) as avg_value by device_id",
            )),
            downsample: None,
            rollup_stats: None,
            other: true,
            include_deleted: false,
        };

        let spec = parse_stats_spec(plan.stats.as_ref().map(|s| s.as_raw()))
            .unwrap()
            .unwrap();
        let err = build_stats_query(&plan, MetricScope::Any, &spec)
            .expect_err("avg with other:true should fail");

        assert!(
            err.to_string().contains("sum(...) and count(...)"),
            "expected additive aggregate error, got: {err}"
        );
    }

    #[test]
    fn profile_hour_of_week_builds_timezone_aware_profile_sql() {
        let start = Utc.with_ymd_and_hms(2025, 1, 1, 0, 0, 0).unwrap();
        let end = start + ChronoDuration::days(30);
        let plan = QueryPlan {
            entity: Entity::TimeseriesMetrics,
            filters: vec![
                Filter {
                    field: "metric_type".into(),
                    op: FilterOp::Eq,
                    value: FilterValue::Scalar("sysmon.cpu".to_string()),
                },
                Filter {
                    field: "metric_name".into(),
                    op: FilterOp::Eq,
                    value: FilterValue::Scalar("cpu.usage_percent".to_string()),
                },
                Filter {
                    field: "timezone".into(),
                    op: FilterOp::Eq,
                    value: FilterValue::Scalar("America/Chicago".to_string()),
                },
            ],
            order: vec![
                OrderClause {
                    field: "dow".into(),
                    direction: OrderDirection::Asc,
                },
                OrderClause {
                    field: "hod".into(),
                    direction: OrderDirection::Asc,
                },
            ],
            limit: 100,
            offset: 0,
            time_range: Some(TimeRange { start, end }),
            stats: Some(crate::parser::StatsSpec::from_raw(
                "profile_hour_of_week(value)",
            )),
            downsample: None,
            rollup_stats: None,
            other: false,
            include_deleted: false,
        };

        let spec = parse_stats_spec(plan.stats.as_ref().map(|s| s.as_raw()))
            .unwrap()
            .unwrap();
        let sql = build_profile_hour_of_week_query(&plan, MetricScope::Any, &spec)
            .expect("profile SQL should build");

        assert!(
            sql.sql.contains("FROM timeseries_metrics_hourly")
                && sql.sql.contains("EXTRACT(DOW FROM timezone")
                && sql.sql.contains("robust_profile")
                && sql.sql.contains("profile_keys AS")
                && sql.sql.contains("JOIN profile_keys k")
                && sql.sql.contains("ORDER BY l.dow ASC, l.hod ASC"),
            "unexpected profile SQL: {}",
            sql.sql
        );
        assert_eq!(sql.binds.len(), 8);
        assert!(
            !should_route_stats_to_cagg(&plan, &spec),
            "profile stats must use the dedicated hourly profile route"
        );
    }

    #[test]
    fn interface_profile_hour_of_week_builds_ifindex_rate_profile_sql() {
        let start = Utc.with_ymd_and_hms(2025, 1, 1, 0, 0, 0).unwrap();
        let end = start + ChronoDuration::days(30);
        let plan = QueryPlan {
            entity: Entity::TimeseriesMetricInterfaceHourly,
            filters: vec![
                Filter {
                    field: "metric_name".into(),
                    op: FilterOp::Eq,
                    value: FilterValue::Scalar("ifInOctets".to_string()),
                },
                Filter {
                    field: "timezone".into(),
                    op: FilterOp::Eq,
                    value: FilterValue::Scalar("America/Chicago".to_string()),
                },
            ],
            order: vec![
                OrderClause {
                    field: "series".into(),
                    direction: OrderDirection::Asc,
                },
                OrderClause {
                    field: "if_index".into(),
                    direction: OrderDirection::Asc,
                },
                OrderClause {
                    field: "dow".into(),
                    direction: OrderDirection::Asc,
                },
                OrderClause {
                    field: "hod".into(),
                    direction: OrderDirection::Asc,
                },
            ],
            limit: 100,
            offset: 0,
            time_range: Some(TimeRange { start, end }),
            stats: Some(crate::parser::StatsSpec::from_raw(
                "profile_hour_of_week(value)",
            )),
            downsample: None,
            rollup_stats: None,
            other: false,
            include_deleted: false,
        };

        let spec = parse_stats_spec(plan.stats.as_ref().map(|s| s.as_raw()))
            .unwrap()
            .unwrap();
        let sql = build_interface_profile_hour_of_week_query(&plan, &spec)
            .expect("interface profile SQL should build");

        assert!(
            sql.sql.contains("FROM timeseries_metrics_interface_hourly")
                && sql
                    .sql
                    .contains("avg_rate_per_second::float8 AS sample_value")
                && sql
                    .sql
                    .contains("SELECT DISTINCT ON (series, if_index, metric_name)")
                && sql.sql.contains("profile_keys AS")
                && sql.sql.contains("JOIN profile_keys k")
                && sql.sql.contains("'if_index', l.if_index")
                && sql.sql.contains("'target_device_ip', l.target_device_ip")
                && sql.sql.contains(
                    "ORDER BY l.series ASC, l.if_index ASC, l.dow ASC, l.hod ASC, l.metric_name ASC"
                ),
            "unexpected interface profile SQL: {}",
            sql.sql
        );
        assert_eq!(sql.binds.len(), 7);
    }

    #[test]
    fn full_profile_hour_of_week_returns_each_populated_bucket_for_edge_delivery() {
        let start = Utc.with_ymd_and_hms(2025, 1, 1, 0, 0, 0).unwrap();
        let end = start + ChronoDuration::days(30);
        let plan = QueryPlan {
            entity: Entity::TimeseriesMetrics,
            filters: vec![Filter {
                field: "metric_type".into(),
                op: FilterOp::Eq,
                value: FilterValue::Scalar("sysmon.cpu".to_string()),
            }],
            order: vec![
                OrderClause {
                    field: "dow".into(),
                    direction: OrderDirection::Asc,
                },
                OrderClause {
                    field: "hod".into(),
                    direction: OrderDirection::Asc,
                },
            ],
            limit: 50_000,
            offset: 0,
            time_range: Some(TimeRange { start, end }),
            stats: Some(crate::parser::StatsSpec::from_raw(
                "profile_hour_of_week_full(value)",
            )),
            downsample: None,
            rollup_stats: None,
            other: false,
            include_deleted: false,
        };

        let spec = parse_stats_spec(plan.stats.as_ref().map(|s| s.as_raw()))
            .unwrap()
            .unwrap();
        let sql = build_profile_hour_of_week_query(&plan, MetricScope::Any, &spec)
            .expect("full profile SQL should build");

        assert!(spec.is_profile_hour_of_week_full());
        assert!(sql.sql.contains("profile_rows AS"));
        assert!(sql.sql.contains("FROM profile_rows l"));
        assert!(sql.sql.contains("WHERE l.bucket IS NULL"));
        assert!(!sql.sql.contains("FROM latest l\nJOIN mean_profile"));
    }

    #[test]
    fn full_interface_profile_hour_of_week_returns_each_populated_bucket() {
        let start = Utc.with_ymd_and_hms(2025, 1, 1, 0, 0, 0).unwrap();
        let end = start + ChronoDuration::days(30);
        let plan = QueryPlan {
            entity: Entity::TimeseriesMetricInterfaceHourly,
            filters: vec![Filter {
                field: "metric_name".into(),
                op: FilterOp::Eq,
                value: FilterValue::Scalar("ifInOctets".to_string()),
            }],
            order: vec![],
            limit: 50_000,
            offset: 0,
            time_range: Some(TimeRange { start, end }),
            stats: Some(crate::parser::StatsSpec::from_raw(
                "profile_hour_of_week_full(value)",
            )),
            downsample: None,
            rollup_stats: None,
            other: false,
            include_deleted: false,
        };

        let spec = parse_stats_spec(plan.stats.as_ref().map(|s| s.as_raw()))
            .unwrap()
            .unwrap();
        let sql = build_interface_profile_hour_of_week_query(&plan, &spec)
            .expect("full interface profile SQL should build");

        assert!(spec.is_profile_hour_of_week_full());
        assert!(sql.sql.contains("profile_rows AS"));
        assert!(sql.sql.contains("FROM profile_rows l"));
        assert!(sql.sql.contains("WHERE l.bucket IS NULL"));
    }

    #[test]
    fn profile_hour_of_week_peak_builds_matched_resolution_peak_sql() {
        let start = Utc.with_ymd_and_hms(2025, 1, 1, 0, 0, 0).unwrap();
        let end = start + ChronoDuration::days(30);
        let plan = QueryPlan {
            entity: Entity::TimeseriesMetrics,
            filters: vec![
                Filter {
                    field: "metric_type".into(),
                    op: FilterOp::Eq,
                    value: FilterValue::Scalar("sysmon.cpu".to_string()),
                },
                Filter {
                    field: "metric_name".into(),
                    op: FilterOp::Eq,
                    value: FilterValue::Scalar("cpu.usage_percent".to_string()),
                },
                Filter {
                    field: "timezone".into(),
                    op: FilterOp::Eq,
                    value: FilterValue::Scalar("America/Chicago".to_string()),
                },
            ],
            order: vec![
                OrderClause {
                    field: "dow".into(),
                    direction: OrderDirection::Asc,
                },
                OrderClause {
                    field: "hod".into(),
                    direction: OrderDirection::Asc,
                },
            ],
            limit: 100,
            offset: 0,
            time_range: Some(TimeRange { start, end }),
            stats: Some(crate::parser::StatsSpec::from_raw(
                "profile_hour_of_week_peak(value)",
            )),
            downsample: None,
            rollup_stats: None,
            other: false,
            include_deleted: false,
        };

        let spec = parse_stats_spec(plan.stats.as_ref().map(|s| s.as_raw()))
            .unwrap()
            .unwrap();
        let sql = build_profile_hour_of_week_peak_query(&plan, MetricScope::Any, &spec)
            .expect("peak profile SQL should build");

        assert!(
            sql.sql.contains("FROM timeseries_metrics_hourly")
                && sql.sql.contains("max_value::float8 AS sample_value")
                && sql.sql.contains("prior_values AS")
                && sql.sql.contains("cell_profile")
                && sql.sql.contains("FROM prior_values")
                && sql
                    .sql
                    .contains("'scale', ((c.p95 - c.p05) * 0.30398)::float8")
                && sql
                    .sql
                    .contains("'prior_scale', ((p.prior_p95 - p.prior_p05) * 0.30398)::float8")
                && sql.sql.contains("ORDER BY l.dow ASC, l.hod ASC"),
            "unexpected peak profile SQL: {}",
            sql.sql
        );
        assert!(
            !sql.sql.contains("l.dow = h.dow"),
            "peak profile cells must collapse DOW and match history on (series, hod): {}",
            sql.sql
        );
        assert_eq!(sql.binds.len(), 8);
        assert!(
            !should_route_stats_to_cagg(&plan, &spec),
            "peak profile stats must use the dedicated hourly profile route"
        );
    }

    #[test]
    fn profile_hour_of_week_peak_sort_bucket_count_uses_cell_profile_alias() {
        let start = Utc.with_ymd_and_hms(2025, 1, 1, 0, 0, 0).unwrap();
        let end = start + ChronoDuration::days(30);
        let plan = QueryPlan {
            entity: Entity::TimeseriesMetrics,
            filters: vec![
                Filter {
                    field: "metric_type".into(),
                    op: FilterOp::Eq,
                    value: FilterValue::Scalar("sysmon.cpu".to_string()),
                },
                Filter {
                    field: "metric_name".into(),
                    op: FilterOp::Eq,
                    value: FilterValue::Scalar("cpu.usage_percent".to_string()),
                },
            ],
            order: vec![OrderClause {
                field: "bucket_count".into(),
                direction: OrderDirection::Desc,
            }],
            limit: 25,
            offset: 0,
            time_range: Some(TimeRange { start, end }),
            stats: Some(crate::parser::StatsSpec::from_raw(
                "profile_hour_of_week_peak(value)",
            )),
            downsample: None,
            rollup_stats: None,
            other: false,
            include_deleted: false,
        };

        let spec = parse_stats_spec(plan.stats.as_ref().map(|s| s.as_raw()))
            .unwrap()
            .unwrap();
        let sql = build_profile_hour_of_week_peak_query(&plan, MetricScope::Any, &spec)
            .expect("peak profile SQL should build");

        assert!(
            sql.sql.contains("ORDER BY c.bucket_count DESC"),
            "peak profile bucket_count sort must use the cell_profile alias: {}",
            sql.sql
        );
        assert!(
            !sql.sql.contains("ORDER BY p.bucket_count"),
            "series_prior does not expose bucket_count: {}",
            sql.sql
        );
    }

    #[test]
    fn profile_hour_of_week_falls_back_for_unknown_or_unsafe_timezone() {
        assert_eq!(normalize_profile_timezone("UTC"), DEFAULT_PROFILE_TIMEZONE);
        assert_eq!(
            normalize_profile_timezone("Foo/Bar"),
            DEFAULT_PROFILE_TIMEZONE
        );
        assert_eq!(
            normalize_profile_timezone("Etc/UTC\" sort:sample_value:desc"),
            DEFAULT_PROFILE_TIMEZONE
        );

        let start = Utc.with_ymd_and_hms(2025, 1, 1, 0, 0, 0).unwrap();
        let end = start + ChronoDuration::days(30);
        let plan = QueryPlan {
            entity: Entity::TimeseriesMetrics,
            filters: vec![Filter {
                field: "timezone".into(),
                op: FilterOp::Eq,
                value: FilterValue::Scalar("Foo/Bar".to_string()),
            }],
            order: Vec::new(),
            limit: 100,
            offset: 0,
            time_range: Some(TimeRange { start, end }),
            stats: Some(crate::parser::StatsSpec::from_raw(
                "profile_hour_of_week(value)",
            )),
            downsample: None,
            rollup_stats: None,
            other: false,
            include_deleted: false,
        };

        let spec = parse_stats_spec(plan.stats.as_ref().map(|s| s.as_raw()))
            .unwrap()
            .unwrap();
        let sql = build_profile_hour_of_week_query(&plan, MetricScope::Any, &spec)
            .expect("profile SQL should build with fallback timezone");

        assert!(sql.binds.iter().rev().take(4).all(|bind| {
            matches!(bind, SqlBindValue::Text(value) if value == DEFAULT_PROFILE_TIMEZONE)
        }));
    }

    #[test]
    fn profile_hour_of_week_rejects_non_value_field() {
        let err = parse_stats_spec(Some("profile_hour_of_week(avg_value)")).unwrap_err();

        assert!(
            err.to_string()
                .contains("profile_hour_of_week only supports value"),
            "unexpected error: {err}"
        );
    }

    #[test]
    fn profile_hour_of_week_peak_rejects_non_value_field() {
        let err = parse_stats_spec(Some("profile_hour_of_week_peak(avg_value)")).unwrap_err();

        assert!(
            err.to_string()
                .contains("profile_hour_of_week_peak only supports value"),
            "unexpected error: {err}"
        );
    }

    #[test]
    fn profile_hour_of_week_requires_time_range() {
        let plan = QueryPlan {
            entity: Entity::TimeseriesMetrics,
            filters: Vec::new(),
            order: Vec::new(),
            limit: 100,
            offset: 0,
            time_range: None,
            stats: Some(crate::parser::StatsSpec::from_raw(
                "profile_hour_of_week(value)",
            )),
            downsample: None,
            rollup_stats: None,
            other: false,
            include_deleted: false,
        };

        let spec = parse_stats_spec(plan.stats.as_ref().map(|s| s.as_raw()))
            .unwrap()
            .unwrap();
        let err = build_profile_hour_of_week_query(&plan, MetricScope::Any, &spec).unwrap_err();

        assert!(
            err.to_string()
                .contains("profile_hour_of_week requires an explicit time range"),
            "unexpected error: {err}"
        );
    }

    #[test]
    fn profile_hour_of_week_rejects_filters_not_available_on_hourly_rollup() {
        let start = Utc.with_ymd_and_hms(2025, 1, 1, 0, 0, 0).unwrap();
        let end = start + ChronoDuration::days(30);
        let plan = QueryPlan {
            entity: Entity::TimeseriesMetrics,
            filters: vec![Filter {
                field: "partition".into(),
                op: FilterOp::Eq,
                value: FilterValue::Scalar("demo".to_string()),
            }],
            order: Vec::new(),
            limit: 100,
            offset: 0,
            time_range: Some(TimeRange { start, end }),
            stats: Some(crate::parser::StatsSpec::from_raw(
                "profile_hour_of_week(value)",
            )),
            downsample: None,
            rollup_stats: None,
            other: false,
            include_deleted: false,
        };

        let spec = parse_stats_spec(plan.stats.as_ref().map(|s| s.as_raw()))
            .unwrap()
            .unwrap();
        let err = build_profile_hour_of_week_query(&plan, MetricScope::Any, &spec).unwrap_err();

        assert!(
            err.to_string()
                .contains("unsupported filter field for profile_hour_of_week: 'partition'"),
            "unexpected error: {err}"
        );
    }
}
