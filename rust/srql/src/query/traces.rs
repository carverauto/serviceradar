use super::{BindParam, QueryPlan};
use crate::{
    error::{Result, ServiceError},
    jsonb::DbJson,
    models::TraceSpanRow,
    parser::{Entity, Filter, FilterOp, OrderClause, OrderDirection},
    schema::otel_traces::dsl::{
        deployment_environment as col_deployment_environment, end_time_unix_nano as col_end,
        ingest_agent_id as col_ingest_agent_id, ingest_identity as col_ingest_identity,
        ingest_partition as col_ingest_partition, kind as col_kind, name as col_name, otel_traces,
        parent_span_id as col_parent_span_id, scope_name as col_scope_name,
        scope_version as col_scope_version, service_instance as col_service_instance,
        service_name as col_service_name, service_namespace as col_service_namespace,
        service_version as col_service_version, span_id as col_span_id,
        start_time_unix_nano as col_start, status_code as col_status_code,
        status_message as col_status_message, timestamp as col_timestamp, trace_id as col_trace_id,
    },
    time::TimeRange,
};
use chrono::{DateTime, Utc};
use diesel::PgTextExpressionMethods;
use diesel::deserialize::QueryableByName;
use diesel::pg::Pg;
use diesel::prelude::*;
use diesel::query_builder::{AsQuery, BoxedSelectStatement, BoxedSqlQuery, FromClause, SqlQuery};
use diesel::sql_query;
use diesel::sql_types::{Int4, Jsonb, Nullable, Text, Timestamptz};
use diesel_async::{AsyncPgConnection, RunQueryDsl};

type TracesTable = crate::schema::otel_traces::table;
type TracesFromClause = FromClause<TracesTable>;
type TracesQuery<'a> =
    BoxedSelectStatement<'a, <TracesTable as AsQuery>::SqlType, TracesFromClause, Pg>;

pub(super) async fn execute(
    conn: &mut AsyncPgConnection,
    plan: &QueryPlan,
) -> Result<Vec<serde_json::Value>> {
    ensure_entity(plan)?;

    // Handle rollup_stats queries against pre-computed CAGGs
    if let Some(rollup_sql) = build_rollup_stats_query(plan)? {
        let query = rollup_sql.to_boxed_query();
        let rows: Vec<TracesStatsPayload> = query
            .load::<TracesStatsPayload>(conn)
            .await
            .map_err(|err| ServiceError::Internal(err.into()))?;
        return Ok(rows
            .into_iter()
            .filter_map(|row| row.payload.map(serde_json::Value::from))
            .collect());
    }

    let query = build_query(plan)?;
    let rows: Vec<TraceSpanRow> = query
        .select(TraceSpanRow::as_select())
        .limit(plan.limit)
        .offset(plan.offset)
        .load::<TraceSpanRow>(conn)
        .await
        .map_err(|err| ServiceError::Internal(err.into()))?;

    Ok(rows.into_iter().map(TraceSpanRow::into_json).collect())
}

pub(super) fn to_sql_and_params(plan: &QueryPlan) -> Result<(String, Vec<BindParam>)> {
    ensure_entity(plan)?;

    // Handle rollup_stats queries against pre-computed CAGGs
    if let Some(rollup_sql) = build_rollup_stats_query(plan)? {
        let sql = rewrite_placeholders(&rollup_sql.sql);
        let params = rollup_sql
            .binds
            .into_iter()
            .map(bind_param_from_stats)
            .collect();
        return Ok((sql, params));
    }

    let query = build_query(plan)?.limit(plan.limit).offset(plan.offset);
    let sql = super::diesel_sql(&query)?;

    let mut params = Vec::new();
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

fn ensure_entity(plan: &QueryPlan) -> Result<()> {
    match plan.entity {
        Entity::Traces => Ok(()),
        _ => Err(ServiceError::InvalidRequest(
            "entity not supported by traces query".into(),
        )),
    }
}

// ============================================================================
// Rollup stats support for traces_stats_5m CAGG
// ============================================================================

#[derive(Debug, Clone)]
struct TracesStatsSql {
    sql: String,
    binds: Vec<SqlBindValue>,
}

impl TracesStatsSql {
    fn to_boxed_query(&self) -> BoxedSqlQuery<'_, Pg, SqlQuery> {
        let mut query = sql_query(rewrite_placeholders(&self.sql)).into_boxed::<Pg>();
        for bind in &self.binds {
            query = bind.apply(query);
        }
        query
    }
}

#[derive(Debug, QueryableByName)]
#[diesel(check_for_backend(diesel::pg::Pg))]
struct TracesStatsPayload {
    #[diesel(sql_type = Nullable<Jsonb>)]
    payload: Option<DbJson>,
}

#[derive(Debug, Clone)]
#[allow(dead_code)]
enum SqlBindValue {
    Text(String),
    Int(i32),
    Timestamp(DateTime<Utc>),
}

impl SqlBindValue {
    fn apply<'a>(&self, query: BoxedSqlQuery<'a, Pg, SqlQuery>) -> BoxedSqlQuery<'a, Pg, SqlQuery> {
        match self {
            SqlBindValue::Text(value) => query.bind::<Text, _>(value.clone()),
            SqlBindValue::Int(value) => query.bind::<Int4, _>(*value),
            SqlBindValue::Timestamp(value) => query.bind::<Timestamptz, _>(*value),
        }
    }
}

fn bind_param_from_stats(value: SqlBindValue) -> BindParam {
    match value {
        SqlBindValue::Text(value) => BindParam::Text(value),
        SqlBindValue::Int(value) => BindParam::Int(i64::from(value)),
        SqlBindValue::Timestamp(value) => BindParam::timestamptz(value),
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

/// Build a rollup_stats query against the traces_stats_5m CAGG.
/// Returns None if rollup_stats is not set in the plan.
fn build_rollup_stats_query(plan: &QueryPlan) -> Result<Option<TracesStatsSql>> {
    let stat_type = match plan.rollup_stats.as_ref() {
        Some(st) if !st.trim().is_empty() => st.trim(),
        _ => return Ok(None),
    };

    match stat_type {
        "summary" => build_summary_rollup_stats(plan),
        "red" => build_red_rollup_stats(plan),
        other => Err(ServiceError::InvalidRequest(format!(
            "unsupported rollup_stats type for traces: '{other}' (supported: summary, red)"
        ))),
    }
}

/// Query the traces_stats_5m CAGG for trace summary stats.
fn build_summary_rollup_stats(plan: &QueryPlan) -> Result<Option<TracesStatsSql>> {
    let mut binds = Vec::new();
    let mut clauses = Vec::new();

    // Apply time range filter on bucket column
    if let Some(TimeRange { start, end }) = &plan.time_range {
        clauses.push("bucket >= ?".to_string());
        binds.push(SqlBindValue::Timestamp(*start));
        clauses.push("bucket < ?".to_string());
        binds.push(SqlBindValue::Timestamp(*end));
    }

    // Apply service_name filter if present
    for filter in &plan.filters {
        match filter.field.as_str() {
            "service_name" | "service.name" => {
                if let Some((clause, mut values)) =
                    build_rollup_text_clause("service_name", filter)?
                {
                    clauses.push(clause);
                    binds.append(&mut values);
                }
            }
            other => {
                return Err(ServiceError::InvalidRequest(format!(
                    "rollup_stats:summary only supports service_name filter, got: '{other}'"
                )));
            }
        }
    }

    // Build SQL to sum counts from the CAGG and return as JSON payload
    let mut sql = String::from(
        r#"SELECT jsonb_build_object(
    'total', COALESCE(SUM(total_count), 0)::bigint,
    'errors', COALESCE(SUM(error_count), 0)::bigint,
    'avg_duration_ms', COALESCE(AVG(avg_duration_ms), 0)::float,
    'p95_duration_ms', COALESCE(PERCENTILE_CONT(0.95) WITHIN GROUP (ORDER BY p95_duration_ms), 0)::float
) AS payload
FROM traces_stats_5m"#,
    );

    if !clauses.is_empty() {
        sql.push_str("\nWHERE ");
        sql.push_str(&clauses.join(" AND "));
    }

    Ok(Some(TracesStatsSql { sql, binds }))
}

/// Query the spans_red_1h CAGG for RED (rate / errors / duration) stats.
///
/// Contract with the CAGG schema: bucket timestamptz, service_name text,
/// total_count bigint, error_count bigint, slow_count bigint,
/// avg_duration_ms double precision, p50_duration_ms double precision,
/// p95_duration_ms double precision, max_duration_ms double precision.
fn build_red_rollup_stats(plan: &QueryPlan) -> Result<Option<TracesStatsSql>> {
    let mut binds = Vec::new();
    let mut clauses = Vec::new();

    // Apply time range filter on bucket column
    if let Some(TimeRange { start, end }) = &plan.time_range {
        clauses.push("bucket >= ?".to_string());
        binds.push(SqlBindValue::Timestamp(*start));
        clauses.push("bucket < ?".to_string());
        binds.push(SqlBindValue::Timestamp(*end));
    }

    // Apply service_name / service_namespace / deployment_environment filters
    // if present (the spans_red_1h CAGG groups by all three).
    for filter in &plan.filters {
        let column = match filter.field.as_str() {
            "service_name" | "service.name" => "service_name",
            "service_namespace" | "service.namespace" => "service_namespace",
            "deployment_environment" | "deployment.environment" => "deployment_environment",
            other => {
                return Err(ServiceError::InvalidRequest(format!(
                    "rollup_stats:red only supports service_name, service_namespace, and deployment_environment filters, got: '{other}'"
                )));
            }
        };
        if let Some((clause, mut values)) = build_rollup_text_clause(column, filter)? {
            clauses.push(clause);
            binds.append(&mut values);
        }
    }

    // Aggregate the per-bucket RED counters across the requested window.
    // avg is weighted by total_count; p50/p95 mirror the summary handler's
    // percentile-of-bucket-percentiles approximation.
    let mut sql = String::from(
        r#"SELECT jsonb_build_object(
    'total', COALESCE(SUM(total_count), 0)::bigint,
    'errors', COALESCE(SUM(error_count), 0)::bigint,
    'slow', COALESCE(SUM(slow_count), 0)::bigint,
    'error_rate', (CASE WHEN COALESCE(SUM(total_count), 0) > 0
        THEN SUM(error_count)::float / SUM(total_count)::float * 100.0
        ELSE 0 END)::float,
    'avg_duration_ms', (CASE WHEN COALESCE(SUM(total_count), 0) > 0
        THEN SUM(avg_duration_ms * total_count) / SUM(total_count)::float
        ELSE 0 END)::float,
    'p50_duration_ms', COALESCE(PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY p50_duration_ms), 0)::float,
    'p95_duration_ms', COALESCE(PERCENTILE_CONT(0.95) WITHIN GROUP (ORDER BY p95_duration_ms), 0)::float,
    'max_duration_ms', COALESCE(MAX(max_duration_ms), 0)::float
) AS payload
FROM spans_red_1h"#,
    );

    if !clauses.is_empty() {
        sql.push_str("\nWHERE ");
        sql.push_str(&clauses.join(" AND "));
    }

    Ok(Some(TracesStatsSql { sql, binds }))
}

/// Build text filter clause for rollup_stats queries.
fn build_rollup_text_clause(
    column: &str,
    filter: &Filter,
) -> Result<Option<(String, Vec<SqlBindValue>)>> {
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
            format!("{column} NOT ILIKE ?")
        }
        FilterOp::In | FilterOp::NotIn => {
            let values = filter.value.as_list()?.to_vec();
            if values.is_empty() {
                return Ok(None);
            }
            let mut placeholders = Vec::new();
            for value in values {
                placeholders.push("?".to_string());
                binds.push(SqlBindValue::Text(value));
            }
            let operator = if matches!(filter.op, FilterOp::In) {
                "IN"
            } else {
                "NOT IN"
            };
            format!("{column} {operator} ({})", placeholders.join(", "))
        }
        _ => {
            return Err(ServiceError::InvalidRequest(format!(
                "rollup_stats filter {column} does not support operator {:?}",
                filter.op
            )));
        }
    };

    Ok(Some((clause, binds)))
}

fn build_query(plan: &QueryPlan) -> Result<TracesQuery<'static>> {
    let mut query = otel_traces.into_boxed::<Pg>();

    if let Some(TimeRange { start, end }) = &plan.time_range {
        query = query.filter(col_timestamp.ge(*start).and(col_timestamp.le(*end)));
    }

    for filter in &plan.filters {
        query = apply_filter(query, filter)?;
    }

    query = apply_ordering(query, plan);
    Ok(query)
}

/// True when the plan pins the query to specific trace(s) by equality, in
/// which case the natural default ordering is span start time (waterfall
/// order) rather than ingest timestamp.
fn has_trace_id_equality(plan: &QueryPlan) -> bool {
    plan.filters.iter().any(|filter| {
        filter.field == "trace_id" && matches!(filter.op, FilterOp::Eq | FilterOp::In)
    })
}

fn apply_filter<'a>(mut query: TracesQuery<'a>, filter: &Filter) -> Result<TracesQuery<'a>> {
    match filter.field.as_str() {
        "trace_id" => {
            query = apply_text_filter!(query, filter, col_trace_id)?;
        }
        "span_id" => {
            query = apply_text_filter!(query, filter, col_span_id)?;
        }
        "parent_span_id" => {
            query = apply_text_filter!(query, filter, col_parent_span_id)?;
        }
        "service_name" | "service.name" => {
            query = apply_text_filter!(query, filter, col_service_name)?;
        }
        "service_namespace" | "service.namespace" => {
            query = apply_text_filter!(query, filter, col_service_namespace)?;
        }
        "deployment_environment" | "deployment.environment" => {
            query = apply_text_filter!(query, filter, col_deployment_environment)?;
        }
        "service_version" => {
            query = apply_text_filter!(query, filter, col_service_version)?;
        }
        "service_instance" => {
            query = apply_text_filter!(query, filter, col_service_instance)?;
        }
        "scope_name" => {
            query = apply_text_filter!(query, filter, col_scope_name)?;
        }
        "scope_version" => {
            query = apply_text_filter!(query, filter, col_scope_version)?;
        }
        "name" | "span_name" => {
            query = apply_text_filter!(query, filter, col_name)?;
        }
        "status_message" => {
            query = apply_text_filter!(query, filter, col_status_message)?;
        }
        "ingest_identity" => {
            query = apply_text_filter!(query, filter, col_ingest_identity)?;
        }
        "ingest_agent_id" => {
            query = apply_text_filter!(query, filter, col_ingest_agent_id)?;
        }
        "ingest_partition" => {
            query = apply_text_filter!(query, filter, col_ingest_partition)?;
        }
        "status_code" => {
            query = apply_status_code_filter(query, filter)?;
        }
        "kind" | "span_kind" => {
            query = apply_kind_filter(query, filter)?;
        }
        other => {
            return Err(ServiceError::InvalidRequest(format!(
                "unsupported filter field for traces: '{other}'"
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

fn collect_i32_list(params: &mut Vec<BindParam>, filter: &Filter, err: &str) -> Result<()> {
    let values: Vec<i32> = filter
        .value
        .as_list()?
        .iter()
        .map(|v| v.parse::<i32>())
        .collect::<std::result::Result<Vec<_>, _>>()
        .map_err(|_| ServiceError::InvalidRequest(err.into()))?;
    if values.is_empty() {
        return Ok(());
    }
    params.push(BindParam::IntArray(
        values.into_iter().map(i64::from).collect(),
    ));
    Ok(())
}

fn collect_filter_params(params: &mut Vec<BindParam>, filter: &Filter) -> Result<()> {
    match filter.field.as_str() {
        "trace_id"
        | "span_id"
        | "parent_span_id"
        | "service_name"
        | "service.name"
        | "service_namespace"
        | "service.namespace"
        | "deployment_environment"
        | "deployment.environment"
        | "service_version"
        | "service_instance"
        | "scope_name"
        | "scope_version"
        | "name"
        | "span_name"
        | "status_message"
        | "ingest_identity"
        | "ingest_agent_id"
        | "ingest_partition" => collect_text_params(params, filter),
        "status_code" => match filter.op {
            FilterOp::Eq | FilterOp::NotEq => {
                let value = filter.value.as_scalar()?.parse::<i32>().map_err(|_| {
                    ServiceError::InvalidRequest("status_code must be an integer".into())
                })?;
                params.push(BindParam::Int(i64::from(value)));
                Ok(())
            }
            FilterOp::In | FilterOp::NotIn => {
                collect_i32_list(params, filter, "status_code list must be integers")
            }
            _ => Err(ServiceError::InvalidRequest(
                "status_code filter only supports equality or list comparisons".into(),
            )),
        },
        "kind" | "span_kind" => match filter.op {
            FilterOp::Eq | FilterOp::NotEq => {
                let value = filter.value.as_scalar()?.parse::<i32>().map_err(|_| {
                    ServiceError::InvalidRequest("span kind must be an integer".into())
                })?;
                params.push(BindParam::Int(i64::from(value)));
                Ok(())
            }
            FilterOp::In | FilterOp::NotIn => {
                collect_i32_list(params, filter, "span kind list must be integers")
            }
            _ => Err(ServiceError::InvalidRequest(
                "kind filter only supports equality comparisons".into(),
            )),
        },
        other => Err(ServiceError::InvalidRequest(format!(
            "unsupported filter field for traces: '{other}'"
        ))),
    }
}

fn apply_status_code_filter<'a>(
    mut query: TracesQuery<'a>,
    filter: &Filter,
) -> Result<TracesQuery<'a>> {
    match filter.op {
        FilterOp::Eq | FilterOp::NotEq => {
            let value = filter.value.as_scalar()?.parse::<i32>().map_err(|_| {
                ServiceError::InvalidRequest("status_code must be an integer".into())
            })?;
            query = match filter.op {
                FilterOp::Eq => query.filter(col_status_code.eq(value)),
                FilterOp::NotEq => query.filter(col_status_code.ne(value)),
                _ => unreachable!(),
            };
            Ok(query)
        }
        FilterOp::In | FilterOp::NotIn => {
            let values: Vec<i32> = filter
                .value
                .as_list()?
                .iter()
                .map(|v| v.parse::<i32>())
                .collect::<std::result::Result<Vec<_>, _>>()
                .map_err(|_| {
                    ServiceError::InvalidRequest("status_code list must be integers".into())
                })?;
            if values.is_empty() {
                return Ok(query);
            }
            query = match filter.op {
                FilterOp::In => query.filter(col_status_code.eq_any(values)),
                FilterOp::NotIn => query.filter(col_status_code.ne_all(values)),
                _ => unreachable!(),
            };
            Ok(query)
        }
        _ => Err(ServiceError::InvalidRequest(
            "status_code filter only supports equality or list comparisons".into(),
        )),
    }
}

fn apply_kind_filter<'a>(mut query: TracesQuery<'a>, filter: &Filter) -> Result<TracesQuery<'a>> {
    match filter.op {
        FilterOp::Eq | FilterOp::NotEq => {
            let value =
                filter.value.as_scalar()?.parse::<i32>().map_err(|_| {
                    ServiceError::InvalidRequest("span kind must be an integer".into())
                })?;
            query = match filter.op {
                FilterOp::Eq => query.filter(col_kind.eq(value)),
                FilterOp::NotEq => query.filter(col_kind.ne(value)),
                _ => unreachable!(),
            };
            Ok(query)
        }
        FilterOp::In | FilterOp::NotIn => {
            let values: Vec<i32> = filter
                .value
                .as_list()?
                .iter()
                .map(|v| v.parse::<i32>())
                .collect::<std::result::Result<Vec<_>, _>>()
                .map_err(|_| {
                    ServiceError::InvalidRequest("span kind list must be integers".into())
                })?;
            if values.is_empty() {
                return Ok(query);
            }
            query = match filter.op {
                FilterOp::In => query.filter(col_kind.eq_any(values)),
                FilterOp::NotIn => query.filter(col_kind.ne_all(values)),
                _ => unreachable!(),
            };
            Ok(query)
        }
        _ => Err(ServiceError::InvalidRequest(
            "kind filter only supports equality comparisons".into(),
        )),
    }
}

fn apply_ordering<'a>(mut query: TracesQuery<'a>, plan: &QueryPlan) -> TracesQuery<'a> {
    let order: &[OrderClause] = &plan.order;
    let mut applied = false;
    for clause in order {
        query = if !applied {
            applied = true;
            match clause.field.as_str() {
                "timestamp" => match clause.direction {
                    OrderDirection::Asc => query.order(col_timestamp.asc()),
                    OrderDirection::Desc => query.order(col_timestamp.desc()),
                },
                "start_time_unix_nano" => match clause.direction {
                    OrderDirection::Asc => query.order(col_start.asc()),
                    OrderDirection::Desc => query.order(col_start.desc()),
                },
                "end_time_unix_nano" => match clause.direction {
                    OrderDirection::Asc => query.order(col_end.asc()),
                    OrderDirection::Desc => query.order(col_end.desc()),
                },
                "service_name" => match clause.direction {
                    OrderDirection::Asc => query.order(col_service_name.asc()),
                    OrderDirection::Desc => query.order(col_service_name.desc()),
                },
                _ => {
                    applied = false;
                    query
                }
            }
        } else {
            match clause.field.as_str() {
                "timestamp" => match clause.direction {
                    OrderDirection::Asc => query.then_order_by(col_timestamp.asc()),
                    OrderDirection::Desc => query.then_order_by(col_timestamp.desc()),
                },
                "start_time_unix_nano" => match clause.direction {
                    OrderDirection::Asc => query.then_order_by(col_start.asc()),
                    OrderDirection::Desc => query.then_order_by(col_start.desc()),
                },
                "end_time_unix_nano" => match clause.direction {
                    OrderDirection::Asc => query.then_order_by(col_end.asc()),
                    OrderDirection::Desc => query.then_order_by(col_end.desc()),
                },
                "service_name" => match clause.direction {
                    OrderDirection::Asc => query.then_order_by(col_service_name.asc()),
                    OrderDirection::Desc => query.then_order_by(col_service_name.desc()),
                },
                _ => query,
            }
        };
    }

    if !applied {
        // Default ordering: when the query is pinned to specific trace ids,
        // return spans in waterfall (start time) order; otherwise newest-first.
        query = if has_trace_id_equality(plan) {
            query.order(col_start.asc())
        } else {
            query.order(col_timestamp.desc())
        };
    }

    query
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::parser::{Entity, Filter, FilterOp, FilterValue};
    use chrono::{Duration as ChronoDuration, TimeZone, Utc};

    fn base_plan(filters: Vec<Filter>) -> QueryPlan {
        let start = Utc.with_ymd_and_hms(2025, 1, 1, 0, 0, 0).unwrap();
        let end = start + ChronoDuration::hours(1);
        QueryPlan {
            entity: Entity::Traces,
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
        }
    }

    #[test]
    fn ingest_identity_eq_filter_generates_sql_and_bind() {
        let plan = base_plan(vec![Filter {
            field: "ingest_identity".into(),
            op: FilterOp::Eq,
            value: FilterValue::Scalar("spiffe://sr/agent/edge-1".to_string()),
        }]);

        let (sql, params) = to_sql_and_params(&plan).expect("sql should generate");

        assert!(
            sql.contains("\"otel_traces\".\"ingest_identity\" = $3"),
            "{sql}"
        );
        assert!(
            matches!(&params[2], BindParam::Text(value) if value == "spiffe://sr/agent/edge-1"),
            "params: {params:?}"
        );
    }

    #[test]
    fn ingest_agent_id_like_filter_uses_ilike() {
        let plan = base_plan(vec![Filter {
            field: "ingest_agent_id".into(),
            op: FilterOp::Like,
            value: FilterValue::Scalar("%edge%".to_string()),
        }]);

        let (sql, params) = to_sql_and_params(&plan).expect("sql should generate");

        assert!(
            sql.contains("\"otel_traces\".\"ingest_agent_id\" ILIKE $3"),
            "{sql}"
        );
        assert!(
            matches!(&params[2], BindParam::Text(value) if value == "%edge%"),
            "params: {params:?}"
        );
    }

    #[test]
    fn ingest_partition_in_filter_generates_any_clause() {
        let plan = base_plan(vec![Filter {
            field: "ingest_partition".into(),
            op: FilterOp::In,
            value: FilterValue::List(vec!["default".into(), "tenant-a".into()]),
        }]);

        let (sql, params) = to_sql_and_params(&plan).expect("sql should generate");

        assert!(
            sql.contains("\"otel_traces\".\"ingest_partition\" = ANY($3)"),
            "{sql}"
        );
        assert!(
            matches!(&params[2], BindParam::TextArray(values)
                if values == &vec!["default".to_string(), "tenant-a".to_string()]),
            "params: {params:?}"
        );
    }

    #[test]
    fn unknown_filter_field_returns_error() {
        let plan = base_plan(vec![Filter {
            field: "unknown_field".into(),
            op: FilterOp::Eq,
            value: FilterValue::Scalar("test".to_string()),
        }]);

        let result = build_query(&plan);
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
}
