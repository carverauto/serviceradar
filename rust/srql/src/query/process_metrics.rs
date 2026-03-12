use super::{BindParam, QueryPlan};
use crate::{
    error::{Result, ServiceError},
    models::ProcessMetricRow,
    parser::{Entity, Filter, FilterOp, OrderClause, OrderDirection},
    schema::process_metrics::dsl::{
        agent_id as col_agent_id, cpu_usage as col_cpu_usage, device_id as col_device_id,
        gateway_id as col_gateway_id, host_id as col_host_id, memory_usage as col_memory_usage,
        name as col_name, partition as col_partition, pid as col_pid, process_metrics,
        start_time as col_start_time, status as col_status, timestamp as col_timestamp,
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
use diesel::QueryDsl;
use diesel_async::{AsyncPgConnection, RunQueryDsl};
use serde_json::Value;

type ProcessTable = crate::schema::process_metrics::table;
type ProcessFromClause = FromClause<ProcessTable>;
type ProcessQuery<'a> =
    BoxedSelectStatement<'a, <ProcessTable as AsQuery>::SqlType, ProcessFromClause, Pg>;
#[derive(Debug, Clone)]
struct ProcessStatsSpec {
    alias: String,
    field: String,
}

#[derive(Debug, Clone)]
struct ProcessStatsSql {
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
struct ProcessStatsPayload {
    #[diesel(sql_type = Nullable<Jsonb>)]
    payload: Option<Value>,
}

pub(super) async fn execute(conn: &mut AsyncPgConnection, plan: &QueryPlan) -> Result<Vec<Value>> {
    ensure_entity(plan)?;

    if let Some(spec) = parse_stats_spec(plan.stats.as_ref().map(|s| s.as_raw()))? {
        return execute_stats(conn, plan, &spec).await;
    }

    let query = build_query(plan)?;
    let rows: Vec<ProcessMetricRow> = query
        .limit(plan.limit)
        .offset(plan.offset)
        .load(conn)
        .await
        .map_err(|err| ServiceError::Internal(err.into()))?;

    Ok(rows.into_iter().map(ProcessMetricRow::into_json).collect())
}

pub(super) fn to_sql_and_params(plan: &QueryPlan) -> Result<(String, Vec<BindParam>)> {
    ensure_entity(plan)?;

    if let Some(spec) = parse_stats_spec(plan.stats.as_ref().map(|s| s.as_raw()))? {
        let sql = if should_route_stats_to_cagg(plan) {
            build_cagg_stats_query(plan, &spec)?
        } else {
            build_stats_query(plan, &spec)?
        };
        let params = sql.binds.into_iter().map(bind_param_from_stats).collect();
        return Ok((rewrite_placeholders(&sql.sql), params));
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
        Entity::ProcessMetrics => Ok(()),
        _ => Err(ServiceError::InvalidRequest(
            "entity not supported by process metrics query".into(),
        )),
    }
}

fn build_query(plan: &QueryPlan) -> Result<ProcessQuery<'static>> {
    let mut query = process_metrics.into_boxed::<Pg>();

    if let Some(TimeRange { start, end }) = &plan.time_range {
        query = query.filter(col_timestamp.ge(*start).and(col_timestamp.le(*end)));
    }

    for filter in &plan.filters {
        query = apply_filter(query, filter)?;
    }

    query = apply_ordering(query, &plan.order);
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
        "gateway_id" | "agent_id" | "host_id" | "device_id" | "partition" | "name" | "status"
        | "start_time" => collect_text_params(params, filter),
        "pid" => {
            params.push(BindParam::Int(i64::from(parse_i32(
                filter.value.as_scalar()?,
            )?)));
            Ok(())
        }
        "cpu_usage" => {
            params.push(BindParam::Float(f64::from(parse_f32(
                filter.value.as_scalar()?,
            )?)));
            Ok(())
        }
        "memory_usage" => {
            params.push(BindParam::Int(parse_i64(filter.value.as_scalar()?)?));
            Ok(())
        }
        other => Err(ServiceError::InvalidRequest(format!(
            "unsupported filter field for process_metrics: '{other}'"
        ))),
    }
}

fn apply_filter<'a>(mut query: ProcessQuery<'a>, filter: &Filter) -> Result<ProcessQuery<'a>> {
    match filter.field.as_str() {
        "gateway_id" => {
            query = apply_text_filter!(query, filter, col_gateway_id)?;
        }
        "agent_id" => {
            query = apply_text_filter!(query, filter, col_agent_id)?;
        }
        "host_id" => {
            query = apply_text_filter!(query, filter, col_host_id)?;
        }
        "device_id" => {
            query = apply_text_filter!(query, filter, col_device_id)?;
        }
        "partition" => {
            query = apply_text_filter!(query, filter, col_partition)?;
        }
        "name" => {
            query = apply_text_filter!(query, filter, col_name)?;
        }
        "status" => {
            query = apply_text_filter!(query, filter, col_status)?;
        }
        "start_time" => {
            query = apply_text_filter!(query, filter, col_start_time)?;
        }
        "pid" => {
            let value = parse_i32(filter.value.as_scalar()?)?;
            query = apply_eq_filter!(
                query,
                filter,
                col_pid,
                value,
                "pid filter only supports equality"
            )?;
        }
        "cpu_usage" => {
            let value = parse_f32(filter.value.as_scalar()?)?;
            match filter.op {
                FilterOp::Eq => query = query.filter(col_cpu_usage.eq(value)),
                FilterOp::NotEq => query = query.filter(col_cpu_usage.ne(value)),
                FilterOp::Gt => query = query.filter(col_cpu_usage.gt(value)),
                FilterOp::Gte => query = query.filter(col_cpu_usage.ge(value)),
                FilterOp::Lt => query = query.filter(col_cpu_usage.lt(value)),
                FilterOp::Lte => query = query.filter(col_cpu_usage.le(value)),
                _ => {
                    return Err(ServiceError::InvalidRequest(
                        "cpu_usage filter does not support this operator".into(),
                    ))
                }
            }
        }
        "memory_usage" => {
            let value = parse_i64(filter.value.as_scalar()?)?;
            match filter.op {
                FilterOp::Eq => query = query.filter(col_memory_usage.eq(value)),
                FilterOp::NotEq => query = query.filter(col_memory_usage.ne(value)),
                FilterOp::Gt => query = query.filter(col_memory_usage.gt(value)),
                FilterOp::Gte => query = query.filter(col_memory_usage.ge(value)),
                FilterOp::Lt => query = query.filter(col_memory_usage.lt(value)),
                FilterOp::Lte => query = query.filter(col_memory_usage.le(value)),
                _ => {
                    return Err(ServiceError::InvalidRequest(
                        "memory_usage filter does not support this operator".into(),
                    ))
                }
            }
        }
        other => {
            return Err(ServiceError::InvalidRequest(format!(
                "unsupported filter field for process_metrics: '{other}'"
            )));
        }
    }

    Ok(query)
}

fn apply_ordering<'a>(mut query: ProcessQuery<'a>, order: &[OrderClause]) -> ProcessQuery<'a> {
    let mut applied = false;
    for clause in order {
        query = if !applied {
            applied = true;
            apply_primary_order(query, clause)
        } else {
            apply_secondary_order(query, clause)
        };
    }

    if !applied {
        query = query.order(col_timestamp.desc());
    }

    query
}

fn apply_primary_order<'a>(query: ProcessQuery<'a>, clause: &OrderClause) -> ProcessQuery<'a> {
    match clause.field.as_str() {
        "timestamp" => match clause.direction {
            OrderDirection::Asc => query.order(col_timestamp.asc()),
            OrderDirection::Desc => query.order(col_timestamp.desc()),
        },
        "cpu_usage" => match clause.direction {
            OrderDirection::Asc => query.order(col_cpu_usage.asc()),
            OrderDirection::Desc => query.order(col_cpu_usage.desc()),
        },
        "memory_usage" => match clause.direction {
            OrderDirection::Asc => query.order(col_memory_usage.asc()),
            OrderDirection::Desc => query.order(col_memory_usage.desc()),
        },
        "pid" => match clause.direction {
            OrderDirection::Asc => query.order(col_pid.asc()),
            OrderDirection::Desc => query.order(col_pid.desc()),
        },
        "name" => match clause.direction {
            OrderDirection::Asc => query.order(col_name.asc()),
            OrderDirection::Desc => query.order(col_name.desc()),
        },
        _ => query,
    }
}

fn apply_secondary_order<'a>(query: ProcessQuery<'a>, clause: &OrderClause) -> ProcessQuery<'a> {
    match clause.field.as_str() {
        "timestamp" => match clause.direction {
            OrderDirection::Asc => diesel::QueryDsl::then_order_by(query, col_timestamp.asc()),
            OrderDirection::Desc => diesel::QueryDsl::then_order_by(query, col_timestamp.desc()),
        },
        "cpu_usage" => match clause.direction {
            OrderDirection::Asc => diesel::QueryDsl::then_order_by(query, col_cpu_usage.asc()),
            OrderDirection::Desc => diesel::QueryDsl::then_order_by(query, col_cpu_usage.desc()),
        },
        "memory_usage" => match clause.direction {
            OrderDirection::Asc => diesel::QueryDsl::then_order_by(query, col_memory_usage.asc()),
            OrderDirection::Desc => diesel::QueryDsl::then_order_by(query, col_memory_usage.desc()),
        },
        "pid" => match clause.direction {
            OrderDirection::Asc => diesel::QueryDsl::then_order_by(query, col_pid.asc()),
            OrderDirection::Desc => diesel::QueryDsl::then_order_by(query, col_pid.desc()),
        },
        "name" => match clause.direction {
            OrderDirection::Asc => diesel::QueryDsl::then_order_by(query, col_name.asc()),
            OrderDirection::Desc => diesel::QueryDsl::then_order_by(query, col_name.desc()),
        },
        _ => query,
    }
}

fn parse_f32(raw: &str) -> Result<f32> {
    raw.parse::<f32>()
        .map_err(|_| ServiceError::InvalidRequest("value must be numeric".into()))
}

fn parse_i32(raw: &str) -> Result<i32> {
    raw.parse::<i32>()
        .map_err(|_| ServiceError::InvalidRequest("value must be an integer".into()))
}

fn parse_i64(raw: &str) -> Result<i64> {
    raw.parse::<i64>()
        .map_err(|_| ServiceError::InvalidRequest("value must be an integer".into()))
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
    spec: &ProcessStatsSpec,
) -> Result<Vec<Value>> {
    let sql = if should_route_stats_to_cagg(plan) {
        build_cagg_stats_query(plan, spec)?
    } else {
        build_stats_query(plan, spec)?
    };
    let mut query = sql_query(rewrite_placeholders(&sql.sql)).into_boxed::<Pg>();
    for bind in &sql.binds {
        query = bind.apply(query);
    }
    let rows: Vec<ProcessStatsPayload> = query
        .load::<ProcessStatsPayload>(conn)
        .await
        .map_err(|err| ServiceError::Internal(err.into()))?;
    Ok(rows.into_iter().filter_map(|row| row.payload).collect())
}

fn build_stats_query(plan: &QueryPlan, spec: &ProcessStatsSpec) -> Result<ProcessStatsSql> {
    let agg_expr = format!("AVG({})", spec.field);
    build_stats_query_with_source(plan, spec, "process_metrics", "timestamp", &agg_expr, false)
}

fn build_cagg_stats_query(plan: &QueryPlan, spec: &ProcessStatsSpec) -> Result<ProcessStatsSql> {
    let mapped_col = super::cagg_column_for_entity(&Entity::ProcessMetrics, "avg", &spec.field)
        .ok_or_else(|| {
            ServiceError::InvalidRequest(format!(
                "missing CAGG mapping for avg({}) on process_metrics",
                spec.field
            ))
        })?;
    let agg_expr = format!(
        "CASE WHEN SUM(sample_count) = 0 THEN NULL ELSE SUM({mapped_col} * sample_count)::float8 / SUM(sample_count)::float8 END"
    );
    build_stats_query_with_source(
        plan,
        spec,
        "process_metrics_hourly",
        "bucket",
        &agg_expr,
        true,
    )
}

fn build_stats_query_with_source(
    plan: &QueryPlan,
    spec: &ProcessStatsSpec,
    table: &str,
    time_col: &str,
    agg_expr: &str,
    cagg_mode: bool,
) -> Result<ProcessStatsSql> {
    let mut clauses = Vec::new();
    let mut binds = Vec::new();

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

    Ok(ProcessStatsSql { sql, binds })
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
            "host_id" => Ok(Some(build_text_clause("host_id", filter)?)),
            "device_id" => Ok(Some(build_text_clause("device_id", filter)?)),
            "name" => Ok(Some(build_text_clause("name", filter)?)),
            _ => Ok(None),
        };
    }

    match filter.field.as_str() {
        "gateway_id" => Ok(Some(build_text_clause("gateway_id", filter)?)),
        "agent_id" => Ok(Some(build_text_clause("agent_id", filter)?)),
        "host_id" => Ok(Some(build_text_clause("host_id", filter)?)),
        "device_id" => Ok(Some(build_text_clause("device_id", filter)?)),
        "partition" => Ok(Some(build_text_clause("partition", filter)?)),
        "name" => Ok(Some(build_text_clause("name", filter)?)),
        "status" => Ok(Some(build_text_clause("status", filter)?)),
        "start_time" => Ok(Some(build_text_clause("start_time", filter)?)),
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

fn parse_stats_spec(raw: Option<&str>) -> Result<Option<ProcessStatsSpec>> {
    let stats_raw = match raw {
        Some(value) if !value.trim().is_empty() => value.trim(),
        _ => return Ok(None),
    };

    if stats_raw.contains(',') {
        return Err(ServiceError::InvalidRequest(
            "process metrics stats only support a single expression".into(),
        ));
    }

    let (expr_segment, group_segment) = split_group_clause(stats_raw).ok_or_else(|| {
        ServiceError::InvalidRequest("stats expression must include 'by device_id'".into())
    })?;

    if !group_segment.eq_ignore_ascii_case("device_id") {
        return Err(ServiceError::InvalidRequest(
            "process metrics stats only support grouping by device_id".into(),
        ));
    }

    let (expr, alias_raw) = split_alias(&expr_segment)?;
    let alias = sanitize_alias(alias_raw)?;
    let expr_lower = expr.trim().to_lowercase();
    if !expr_lower.starts_with("avg(") || !expr_lower.ends_with(')') {
        return Err(ServiceError::InvalidRequest(
            "process metrics stats only support avg(field) expressions".into(),
        ));
    }
    let field = expr_lower
        .trim_start_matches("avg(")
        .trim_end_matches(')')
        .trim()
        .to_string();
    let allowed = ["cpu_usage", "memory_usage"];
    if !allowed.contains(&field.as_str()) {
        return Err(ServiceError::InvalidRequest(
            "process metrics stats only support avg(cpu_usage|memory_usage)".into(),
        ));
    }

    Ok(Some(ProcessStatsSpec { alias, field }))
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

    plan.filters
        .iter()
        .all(|filter| matches!(filter.field.as_str(), "device_id" | "host_id" | "name"))
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
    use crate::parser::{FilterValue, OrderClause, OrderDirection};
    use chrono::{Duration as ChronoDuration, TimeZone, Utc};

    #[test]
    fn unknown_filter_field_returns_error() {
        let plan = QueryPlan {
            entity: Entity::ProcessMetrics,
            filters: vec![Filter {
                field: "unknown".into(),
                op: FilterOp::Eq,
                value: FilterValue::Scalar("x".into()),
            }],
            order: vec![],
            limit: 10,
            offset: 0,
            time_range: Some(TimeRange {
                start: Utc.timestamp_opt(0, 0).unwrap(),
                end: Utc::now() + ChronoDuration::minutes(1),
            }),
            stats: None,
            downsample: None,
            rollup_stats: None,
            include_deleted: false,
        };

        let err = build_query(&plan).err().expect("expected error");
        assert!(matches!(err, ServiceError::InvalidRequest(_)));
    }

    #[test]
    fn stats_query_supports_process_language_reference() {
        let start = Utc.with_ymd_and_hms(2025, 1, 1, 0, 0, 0).unwrap();
        let end = start + ChronoDuration::hours(1);
        let plan = QueryPlan {
            entity: Entity::ProcessMetrics,
            filters: vec![Filter {
                field: "partition".into(),
                op: FilterOp::Eq,
                value: FilterValue::Scalar("demo".to_string()),
            }],
            order: vec![OrderClause {
                field: "avg_cpu".into(),
                direction: OrderDirection::Desc,
            }],
            limit: 100,
            offset: 0,
            time_range: Some(TimeRange { start, end }),
            stats: Some(crate::parser::StatsSpec::from_raw(
                "avg(cpu_usage) as avg_cpu by device_id",
            )),
            downsample: None,
            rollup_stats: None,
            include_deleted: false,
        };

        let spec = parse_stats_spec(plan.stats.as_ref().map(|s| s.as_raw()))
            .unwrap()
            .unwrap();
        let sql = build_stats_query(&plan, &spec).expect("stats SQL should build");
        assert!(
            sql.sql.contains("FROM process_metrics")
                && sql.sql.contains("AVG(cpu_usage)")
                && sql.sql.contains("GROUP BY device_id"),
            "unexpected stats SQL: {}",
            sql.sql
        );
    }

    #[test]
    fn stats_query_uses_process_hourly_cagg_for_large_windows() {
        let start = Utc.with_ymd_and_hms(2025, 1, 1, 0, 0, 0).unwrap();
        let end = start + ChronoDuration::hours(7);
        let plan = QueryPlan {
            entity: Entity::ProcessMetrics,
            filters: vec![Filter {
                field: "device_id".into(),
                op: FilterOp::Eq,
                value: FilterValue::Scalar("dev-1".to_string()),
            }],
            order: vec![OrderClause {
                field: "avg_cpu".into(),
                direction: OrderDirection::Desc,
            }],
            limit: 100,
            offset: 0,
            time_range: Some(TimeRange { start, end }),
            stats: Some(crate::parser::StatsSpec::from_raw(
                "avg(cpu_usage) as avg_cpu by device_id",
            )),
            downsample: None,
            rollup_stats: None,
            include_deleted: false,
        };

        let spec = parse_stats_spec(plan.stats.as_ref().map(|s| s.as_raw()))
            .unwrap()
            .unwrap();
        let sql = build_cagg_stats_query(&plan, &spec).expect("cagg stats SQL should build");
        assert!(
            sql.sql.contains("FROM process_metrics_hourly")
                && sql.sql.contains("avg_cpu_usage")
                && sql.sql.contains("sample_count"),
            "unexpected cagg stats SQL: {}",
            sql.sql
        );
        assert!(should_route_stats_to_cagg(&plan));
    }
}
