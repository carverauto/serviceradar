//! SRQL support for timeseries-backed metrics (generic, SNMP, and rperf).

use super::{BindParam, QueryPlan};
use crate::{
    error::{Result, ServiceError},
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
use diesel::pg::Pg;
use diesel::prelude::*;
use diesel::query_builder::{
    AsQuery, BoxedSelectStatement, BoxedSqlQuery, FromClause, SqlQuery as DieselSqlQuery,
};
use diesel::sql_query;
use diesel::sql_types::{Array, Jsonb, Nullable, Text, Timestamptz};
use diesel::PgTextExpressionMethods;
use diesel_async::{AsyncPgConnection, RunQueryDsl};
use serde_json::Value;

type TimeseriesTable = crate::schema::timeseries_metrics::table;
type TimeseriesFromClause = FromClause<TimeseriesTable>;
type TimeseriesQuery<'a> =
    BoxedSelectStatement<'a, <TimeseriesTable as AsQuery>::SqlType, TimeseriesFromClause, Pg>;
#[derive(Debug, Clone)]
struct TimeseriesStatsSpec {
    alias: String,
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
            SqlBindValue::Timestamp(value) => query.bind::<Timestamptz, _>(*value),
        }
    }
}

#[derive(Debug, QueryableByName)]
#[diesel(check_for_backend(diesel::pg::Pg))]
struct TimeseriesStatsPayload {
    #[diesel(sql_type = Nullable<Jsonb>)]
    payload: Option<Value>,
}

const RPERF_METRIC_TYPE: &str = "rperf";
const SNMP_METRIC_TYPE: &str = "snmp";

#[derive(Clone, Copy)]
enum MetricScope<'a> {
    Any,
    Forced(&'a str),
}

pub(super) async fn execute(conn: &mut AsyncPgConnection, plan: &QueryPlan) -> Result<Vec<Value>> {
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
    let scope = ensure_entity(plan)?;

    if let Some(spec) = parse_stats_spec(plan.stats.as_ref().map(|s| s.as_raw()))? {
        let sql = if should_route_stats_to_cagg(plan) {
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
        other => {
            return Err(ServiceError::InvalidRequest(format!(
                "unsupported filter field for timeseries_metrics: '{other}'"
            )));
        }
    }

    Ok(query)
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
            ))
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
        SqlBindValue::Timestamp(value) => BindParam::timestamptz(value),
    }
}

async fn execute_stats(
    conn: &mut AsyncPgConnection,
    plan: &QueryPlan,
    scope: MetricScope<'static>,
    spec: &TimeseriesStatsSpec,
) -> Result<Vec<Value>> {
    let sql = if should_route_stats_to_cagg(plan) {
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
    Ok(rows.into_iter().filter_map(|row| row.payload).collect())
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
        "AVG(value)",
        false,
    )
}

fn build_cagg_stats_query(
    plan: &QueryPlan,
    scope: MetricScope<'static>,
    spec: &TimeseriesStatsSpec,
) -> Result<TimeseriesStatsSql> {
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
        &agg_expr,
        true,
    )
}

fn build_stats_query_with_source(
    plan: &QueryPlan,
    scope: MetricScope<'static>,
    spec: &TimeseriesStatsSpec,
    table: &str,
    time_col: &str,
    agg_expr: &str,
    cagg_mode: bool,
) -> Result<TimeseriesStatsSql> {
    let mut clauses = Vec::new();
    let mut binds = Vec::new();

    if let MetricScope::Forced(metric_type) = scope {
        clauses.push("metric_type = ?".to_string());
        binds.push(SqlBindValue::Text(metric_type.to_string()));
    }

    if let Some(TimeRange { start, end }) = &plan.time_range {
        clauses.push(format!("{time_col} >= ?"));
        binds.push(SqlBindValue::Timestamp(*start));
        clauses.push(format!("{time_col} <= ?"));
        binds.push(SqlBindValue::Timestamp(*end));
    }

    for filter in &plan.filters {
        if let Some((clause, mut values)) = build_stats_filter_clause(filter, cagg_mode)? {
            clauses.push(clause);
            binds.append(&mut values);
        }
    }

    let mut sql = String::from("SELECT jsonb_build_object('device_id', device_id, '");
    sql.push_str(&spec.alias);
    sql.push_str("', ");
    sql.push_str(agg_expr);
    sql.push_str(") AS payload\nFROM ");
    sql.push_str(table);
    if !clauses.is_empty() {
        sql.push_str("\nWHERE ");
        sql.push_str(&clauses.join(" AND "));
    }
    sql.push_str("\nGROUP BY device_id");
    sql.push_str(&build_stats_order_clause(plan, &spec.alias, agg_expr));
    sql.push_str(&format!("\nLIMIT {} OFFSET {}", plan.limit, plan.offset));

    Ok(TimeseriesStatsSql { sql, binds })
}

fn build_stats_order_clause(plan: &QueryPlan, alias: &str, aggregate_expr: &str) -> String {
    if plan.order.is_empty() {
        return format!("\nORDER BY {aggregate_expr} DESC");
    }

    let mut parts = Vec::new();
    for clause in &plan.order {
        let column = if clause.field.eq_ignore_ascii_case(alias) {
            aggregate_expr
        } else if clause.field.eq_ignore_ascii_case("device_id") {
            "device_id"
        } else {
            continue;
        };

        let dir = match clause.direction {
            OrderDirection::Asc => "ASC",
            OrderDirection::Desc => "DESC",
        };
        parts.push(format!("{column} {dir}"));
    }

    if parts.is_empty() {
        format!("\nORDER BY {aggregate_expr} DESC")
    } else {
        format!("\nORDER BY {}", parts.join(", "))
    }
}

fn build_stats_filter_clause(
    filter: &Filter,
    cagg_mode: bool,
) -> Result<Option<(String, Vec<SqlBindValue>)>> {
    if cagg_mode {
        return match filter.field.as_str() {
            "device_id" => Ok(Some(build_text_clause("device_id", filter)?)),
            "metric_type" => Ok(Some(build_text_clause("metric_type", filter)?)),
            "metric_name" => Ok(Some(build_text_clause("metric_name", filter)?)),
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
        _ => Ok(None),
    }
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
            )))
        }
    };
    Ok((clause, binds))
}

fn parse_stats_spec(raw: Option<&str>) -> Result<Option<TimeseriesStatsSpec>> {
    let stats_raw = match raw {
        Some(value) if !value.trim().is_empty() => value.trim(),
        _ => return Ok(None),
    };

    if stats_raw.contains(',') {
        return Err(ServiceError::InvalidRequest(
            "timeseries metrics stats only support a single expression".into(),
        ));
    }

    let (expr_segment, group_segment) = split_group_clause(stats_raw).ok_or_else(|| {
        ServiceError::InvalidRequest("stats expression must include 'by device_id'".into())
    })?;

    if !group_segment.eq_ignore_ascii_case("device_id") {
        return Err(ServiceError::InvalidRequest(
            "timeseries metrics stats only support grouping by device_id".into(),
        ));
    }

    let (expr, alias_raw) = split_alias(&expr_segment)?;
    let alias = sanitize_alias(alias_raw)?;
    let expr_lower = expr.trim().to_lowercase();
    if expr_lower != "avg(value)" {
        return Err(ServiceError::InvalidRequest(
            "timeseries metrics stats only support avg(value)".into(),
        ));
    }

    Ok(Some(TimeseriesStatsSpec { alias }))
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

fn should_route_stats_to_cagg(plan: &QueryPlan) -> bool {
    if !super::should_route_plan_to_hourly_cagg(plan) {
        return false;
    }

    plan.filters.iter().all(|filter| {
        matches!(
            filter.field.as_str(),
            "device_id" | "metric_type" | "metric_name"
        )
    })
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
        assert!(should_route_stats_to_cagg(&plan));
    }
}
