use super::{BindParam, QueryPlan};
use crate::{
    error::{Result, ServiceError},
    models::LogRow,
    parser::{Entity, Filter, FilterOp, OrderClause, OrderDirection},
    schema::logs::dsl::{
        body as col_body, logs, scope_name as col_scope_name, scope_version as col_scope_version,
        service_instance as col_service_instance, service_name as col_service_name,
        service_version as col_service_version, severity_number as col_severity_number,
        severity_text as col_severity_text, span_id as col_span_id, timestamp as col_timestamp,
        trace_id as col_trace_id,
    },
    time::TimeRange,
};
use chrono::{DateTime, Utc};
use diesel::deserialize::QueryableByName;
use diesel::pg::Pg;
use diesel::prelude::*;
use diesel::query_builder::{AsQuery, BoxedSelectStatement, BoxedSqlQuery, FromClause, SqlQuery};
use diesel::sql_query;
use diesel::sql_types::{Int4, Jsonb, Nullable, Text, Timestamptz};
use diesel::PgTextExpressionMethods;
use diesel_async::{AsyncPgConnection, RunQueryDsl};
use serde_json::Value;

type LogsTable = crate::schema::logs::table;
type LogsFromClause = FromClause<LogsTable>;
type LogsQuery<'a> = BoxedSelectStatement<'a, <LogsTable as AsQuery>::SqlType, LogsFromClause, Pg>;

const MAX_LIST_FILTER_VALUES: usize = 200;

pub(super) async fn execute(conn: &mut AsyncPgConnection, plan: &QueryPlan) -> Result<Vec<Value>> {
    ensure_entity(plan)?;

    // Handle rollup_stats queries against pre-computed CAGGs
    if let Some(rollup_sql) = build_rollup_stats_query(plan)? {
        let query = rollup_sql.to_boxed_query();
        let rows: Vec<LogsStatsPayload> = query
            .load(conn)
            .await
            .map_err(|err| ServiceError::Internal(err.into()))?;
        return Ok(rows.into_iter().filter_map(|row| row.payload).collect());
    }

    if let Some(stats_sql) = build_stats_query(plan)? {
        let query = stats_sql.to_boxed_query();
        let rows: Vec<LogsStatsPayload> = query
            .load(conn)
            .await
            .map_err(|err| ServiceError::Internal(err.into()))?;
        return Ok(rows.into_iter().filter_map(|row| row.payload).collect());
    }

    let query = build_query(plan)?;
    let rows: Vec<LogRow> = query
        .limit(plan.limit)
        .offset(plan.offset)
        .load(conn)
        .await
        .map_err(|err| ServiceError::Internal(err.into()))?;

    Ok(rows.into_iter().map(LogRow::into_json).collect())
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

    if let Some(stats_sql) = build_stats_query(plan)? {
        let sql = rewrite_placeholders(&stats_sql.sql);
        let params = stats_sql
            .binds
            .into_iter()
            .map(bind_param_from_stats)
            .collect();
        return Ok((sql, params));
    }

    let query = build_query(plan)?;
    let sql = super::diesel_sql(&query.limit(plan.limit).offset(plan.offset))?;

    let mut params = Vec::new();
    if let Some(TimeRange { start, end }) = &plan.time_range {
        params.push(BindParam::timestamptz(*start));
        params.push(BindParam::timestamptz(*end));
    }

    for filter in &plan.filters {
        collect_filter_params(&mut params, filter)?;
    }

    params.push(BindParam::Int(plan.limit));
    params.push(BindParam::Int(plan.offset));

    Ok((sql, params))
}

fn ensure_entity(plan: &QueryPlan) -> Result<()> {
    match plan.entity {
        Entity::Logs => Ok(()),
        _ => Err(ServiceError::InvalidRequest(
            "entity not supported by logs query".into(),
        )),
    }
}

fn build_query(plan: &QueryPlan) -> Result<LogsQuery<'static>> {
    let mut query = logs.into_boxed::<Pg>();

    if let Some(TimeRange { start, end }) = &plan.time_range {
        query = query.filter(col_timestamp.ge(*start).and(col_timestamp.le(*end)));
    }

    for filter in &plan.filters {
        query = apply_filter(query, filter)?;
    }

    query = apply_ordering(query, &plan.order);
    Ok(query)
}

#[derive(Debug, Clone)]
struct LogsStatsSql {
    sql: String,
    binds: Vec<SqlBindValue>,
}

impl LogsStatsSql {
    fn to_boxed_query(&self) -> BoxedSqlQuery<'_, Pg, SqlQuery> {
        let mut query = sql_query(rewrite_placeholders(&self.sql)).into_boxed::<Pg>();
        for bind in &self.binds {
            query = bind.apply(query);
        }
        query
    }
}

#[derive(Debug, QueryableByName)]
struct LogsStatsPayload {
    #[diesel(sql_type = Nullable<Jsonb>)]
    payload: Option<Value>,
}

#[derive(Debug, Clone)]
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
        "trace_id" | "span_id" | "service_name" | "service_version" | "service_instance"
        | "scope_name" | "scope_version" | "severity_text" | "severity" | "level" | "body" => {
            collect_text_params(params, filter)
        }
        "severity_number" => match filter.op {
            FilterOp::Eq | FilterOp::NotEq => {
                let value = filter.value.as_scalar()?.parse::<i32>().map_err(|_| {
                    ServiceError::InvalidRequest("severity_number must be an integer".into())
                })?;
                params.push(BindParam::Int(i64::from(value)));
                Ok(())
            }
            FilterOp::In | FilterOp::NotIn => {
                let values: Vec<i32> = filter
                    .value
                    .as_list()?
                    .iter()
                    .map(|v| v.parse::<i32>())
                    .collect::<std::result::Result<Vec<_>, _>>()
                    .map_err(|_| {
                        ServiceError::InvalidRequest("severity_number list must be integers".into())
                    })?;
                if values.is_empty() {
                    return Ok(());
                }
                params.push(BindParam::IntArray(
                    values.into_iter().map(i64::from).collect(),
                ));
                Ok(())
            }
            _ => Err(ServiceError::InvalidRequest(
                "severity_number filter does not support this operator".into(),
            )),
        },
        other => Err(ServiceError::InvalidRequest(format!(
            "unsupported filter field for logs: '{other}'"
        ))),
    }
}

fn build_stats_query(plan: &QueryPlan) -> Result<Option<LogsStatsSql>> {
    let stats_raw = match plan.stats.as_ref() {
        Some(raw) if !raw.as_raw().trim().is_empty() => raw.as_raw().trim(),
        _ => return Ok(None),
    };

    let expressions = parse_stats_expressions(stats_raw)?;
    if expressions.is_empty() {
        return Err(ServiceError::InvalidRequest(
            "stats expression required for logs queries".into(),
        ));
    }

    let mut binds = Vec::new();
    let mut clauses = Vec::new();

    if let Some(TimeRange { start, end }) = &plan.time_range {
        clauses.push("timestamp >= ?".to_string());
        binds.push(SqlBindValue::Timestamp(*start));
        clauses.push("timestamp <= ?".to_string());
        binds.push(SqlBindValue::Timestamp(*end));
    }

    for filter in &plan.filters {
        if let Some((clause, mut values)) = build_stats_filter_clause(filter)? {
            clauses.push(clause);
            binds.append(&mut values);
        }
    }

    let mut parts = Vec::new();
    for expr in expressions {
        parts.push(expr.to_sql_fragment());
    }

    let mut sql = String::from("SELECT jsonb_build_object(");
    sql.push_str(&parts.join(", "));
    sql.push_str(") AS payload\nFROM logs");
    if !clauses.is_empty() {
        sql.push_str("\nWHERE ");
        sql.push_str(&clauses.join(" AND "));
    }

    Ok(Some(LogsStatsSql { sql, binds }))
}

/// Build a rollup_stats query against the logs_severity_stats_5m CAGG.
/// Returns None if rollup_stats is not set in the plan.
fn build_rollup_stats_query(plan: &QueryPlan) -> Result<Option<LogsStatsSql>> {
    let stat_type = match plan.rollup_stats.as_ref() {
        Some(st) if !st.trim().is_empty() => st.trim(),
        _ => return Ok(None),
    };

    match stat_type {
        "severity" => build_severity_rollup_stats(plan),
        other => Err(ServiceError::InvalidRequest(format!(
            "unsupported rollup_stats type for logs: '{other}' (supported: severity)"
        ))),
    }
}

/// Query the logs_severity_stats_5m CAGG for severity counts.
fn build_severity_rollup_stats(plan: &QueryPlan) -> Result<Option<LogsStatsSql>> {
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
            "service_name" | "service" => {
                if let Some((clause, mut values)) =
                    build_rollup_text_clause("service_name", filter)?
                {
                    clauses.push(clause);
                    binds.append(&mut values);
                }
            }
            other => {
                return Err(ServiceError::InvalidRequest(format!(
                    "rollup_stats:severity only supports service_name filter, got: '{other}'"
                )));
            }
        }
    }

    // Build SQL to sum counts from the CAGG and return as JSON payload
    let mut sql = String::from(
        r#"SELECT jsonb_build_object(
    'total', COALESCE(SUM(total_count), 0)::bigint,
    'fatal', COALESCE(SUM(fatal_count), 0)::bigint,
    'error', COALESCE(SUM(error_count), 0)::bigint,
    'warning', COALESCE(SUM(warning_count), 0)::bigint,
    'info', COALESCE(SUM(info_count), 0)::bigint,
    'debug', COALESCE(SUM(debug_count), 0)::bigint
) AS payload
FROM logs_severity_stats_5m"#,
    );

    if !clauses.is_empty() {
        sql.push_str("\nWHERE ");
        sql.push_str(&clauses.join(" AND "));
    }

    Ok(Some(LogsStatsSql { sql, binds }))
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
            enforce_list_limit(&filter.field, values.len())?;
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
            )))
        }
    };

    Ok(Some((clause, binds)))
}

fn apply_filter<'a>(mut query: LogsQuery<'a>, filter: &Filter) -> Result<LogsQuery<'a>> {
    match filter.field.as_str() {
        "trace_id" => {
            query = apply_text_filter!(query, filter, col_trace_id)?;
        }
        "span_id" => {
            query = apply_text_filter!(query, filter, col_span_id)?;
        }
        "service_name" => {
            query = apply_text_filter!(query, filter, col_service_name)?;
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
        "severity_text" | "severity" | "level" => {
            query = apply_text_filter!(query, filter, col_severity_text)?;
        }
        "body" => {
            query = apply_text_filter!(query, filter, col_body)?;
        }
        "severity_number" => match filter.op {
            FilterOp::Eq | FilterOp::NotEq => {
                let value = filter.value.as_scalar()?.parse::<i32>().map_err(|_| {
                    ServiceError::InvalidRequest("severity_number must be an integer".into())
                })?;
                query = match filter.op {
                    FilterOp::Eq => query.filter(col_severity_number.eq(value)),
                    FilterOp::NotEq => query.filter(col_severity_number.ne(value)),
                    _ => unreachable!(),
                };
            }
            FilterOp::In | FilterOp::NotIn => {
                let values: Vec<i32> = filter
                    .value
                    .as_list()?
                    .iter()
                    .map(|v| v.parse::<i32>())
                    .collect::<std::result::Result<Vec<_>, _>>()
                    .map_err(|_| {
                        ServiceError::InvalidRequest("severity_number list must be integers".into())
                    })?;
                if values.is_empty() {
                    return Ok(query);
                }
                query = match filter.op {
                    FilterOp::In => query.filter(col_severity_number.eq_any(values)),
                    FilterOp::NotIn => query.filter(col_severity_number.ne_all(values)),
                    _ => unreachable!(),
                };
            }
            _ => {
                return Err(ServiceError::InvalidRequest(
                    "severity_number only supports equality and IN/NOT IN comparisons".into(),
                ))
            }
        },
        other => {
            return Err(ServiceError::InvalidRequest(format!(
                "unsupported filter field for logs: '{other}'"
            )));
        }
    }

    Ok(query)
}

fn apply_ordering<'a>(mut query: LogsQuery<'a>, order: &[OrderClause]) -> LogsQuery<'a> {
    let mut applied = false;
    for clause in order {
        query = if !applied {
            applied = true;
            match clause.field.as_str() {
                "timestamp" => match clause.direction {
                    OrderDirection::Asc => query.order(col_timestamp.asc()),
                    OrderDirection::Desc => query.order(col_timestamp.desc()),
                },
                "severity_number" => match clause.direction {
                    OrderDirection::Asc => query.order(col_severity_number.asc()),
                    OrderDirection::Desc => query.order(col_severity_number.desc()),
                },
                _ => query,
            }
        } else {
            match clause.field.as_str() {
                "timestamp" => match clause.direction {
                    OrderDirection::Asc => query.then_order_by(col_timestamp.asc()),
                    OrderDirection::Desc => query.then_order_by(col_timestamp.desc()),
                },
                "severity_number" => match clause.direction {
                    OrderDirection::Asc => query.then_order_by(col_severity_number.asc()),
                    OrderDirection::Desc => query.then_order_by(col_severity_number.desc()),
                },
                _ => query,
            }
        };
    }

    if !applied {
        query = query
            .order(col_timestamp.desc())
            .then_order_by(col_severity_number.desc());
    }

    query
}

#[derive(Debug, Clone)]
enum LogsStatsExpr {
    Count { alias: String },
    GroupUniqArray { alias: String, column: &'static str },
}

impl LogsStatsExpr {
    fn to_sql_fragment(&self) -> String {
        match self {
            LogsStatsExpr::Count { alias } => {
                format!("'{}', coalesce(COUNT(*), 0)", alias)
            }
            LogsStatsExpr::GroupUniqArray { alias, column } => {
                format!(
                    "'{}', coalesce(jsonb_agg(DISTINCT {column}) FILTER (WHERE {column} IS NOT NULL), '[]'::jsonb)",
                    alias
                )
            }
        }
    }
}

fn parse_stats_expressions(raw: &str) -> Result<Vec<LogsStatsExpr>> {
    let segments = split_stats_segments(raw);
    let mut expressions = Vec::new();
    for segment in segments {
        if segment.trim().is_empty() {
            continue;
        }
        expressions.push(parse_stats_expr(&segment)?);
    }
    Ok(expressions)
}

fn split_stats_segments(raw: &str) -> Vec<String> {
    let mut parts = Vec::new();
    let mut current = String::new();
    let mut depth = 0usize;
    let mut in_string = None;

    for ch in raw.chars() {
        if let Some(q) = in_string {
            current.push(ch);
            if ch == q {
                in_string = None;
            }
            continue;
        }

        match ch {
            '(' => {
                depth += 1;
                current.push(ch);
            }
            ')' => {
                depth = depth.saturating_sub(1);
                current.push(ch);
            }
            '\'' | '"' | '`' => {
                in_string = Some(ch);
                current.push(ch);
            }
            ',' if depth == 0 => {
                parts.push(current.trim().to_string());
                current.clear();
            }
            _ => current.push(ch),
        }
    }

    if !current.trim().is_empty() {
        parts.push(current.trim().to_string());
    }

    parts
}

fn parse_stats_expr(segment: &str) -> Result<LogsStatsExpr> {
    let (expr_raw, alias_raw) = split_alias(segment)?;
    let alias = sanitize_alias(alias_raw)?;
    let expr = expr_raw.trim();

    if expr.eq_ignore_ascii_case("count()") {
        return Ok(LogsStatsExpr::Count { alias });
    }

    if expr.to_lowercase().starts_with("group_uniq_array(") && expr.ends_with(')') {
        let start = expr.find('(').unwrap_or(0) + 1;
        let inner = expr[start..expr.len() - 1].trim();
        let column = resolve_group_field(inner)?;
        return Ok(LogsStatsExpr::GroupUniqArray { alias, column });
    }

    Err(ServiceError::InvalidRequest(format!(
        "unsupported stats expression '{expr}'"
    )))
}

fn split_alias(segment: &str) -> Result<(String, String)> {
    let lower = segment.to_lowercase();
    if let Some(idx) = lower.rfind(" as ") {
        let expr = segment[..idx].trim().to_string();
        let alias = segment[idx + 4..]
            .trim()
            .trim_matches('"')
            .trim_matches('\'');
        return Ok((expr, alias.to_string()));
    }
    Err(ServiceError::InvalidRequest(
        "stats expressions must include an alias".into(),
    ))
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

fn resolve_group_field(field: &str) -> Result<&'static str> {
    match field.trim().to_lowercase().as_str() {
        "service_name" | "service" | "name" => Ok("service_name"),
        "service_version" | "version" => Ok("service_version"),
        "service_instance" | "instance" => Ok("service_instance"),
        "scope_name" | "scope" => Ok("scope_name"),
        "scope_version" => Ok("scope_version"),
        "severity_text" | "severity" | "level" => Ok("severity_text"),
        "trace_id" => Ok("trace_id"),
        "span_id" => Ok("span_id"),
        "body" => Ok("body"),
        other => Err(ServiceError::InvalidRequest(format!(
            "unsupported field '{other}' for group_uniq_array"
        ))),
    }
}

fn build_stats_filter_clause(filter: &Filter) -> Result<Option<(String, Vec<SqlBindValue>)>> {
    match filter.field.as_str() {
        "trace_id" => build_text_clause("trace_id", filter),
        "span_id" => build_text_clause("span_id", filter),
        "service_name" | "service" => build_text_clause("service_name", filter),
        "service_version" => build_text_clause("service_version", filter),
        "service_instance" => build_text_clause("service_instance", filter),
        "scope_name" => build_text_clause("scope_name", filter),
        "scope_version" => build_text_clause("scope_version", filter),
        "severity_text" | "severity" | "level" => build_text_clause("severity_text", filter),
        "body" => build_text_clause("body", filter),
        "severity_number" => build_numeric_clause("severity_number", filter),
        other => Err(ServiceError::InvalidRequest(format!(
            "unsupported filter field for logs stats: '{other}'"
        ))),
    }
}

fn build_text_clause(column: &str, filter: &Filter) -> Result<Option<(String, Vec<SqlBindValue>)>> {
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
            enforce_list_limit(&filter.field, values.len())?;
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
                "text filter {column} does not support operator {:?}",
                filter.op
            )))
        }
    };

    Ok(Some((clause, binds)))
}

fn build_numeric_clause(
    column: &str,
    filter: &Filter,
) -> Result<Option<(String, Vec<SqlBindValue>)>> {
    let mut binds = Vec::new();
    let clause = match filter.op {
        FilterOp::Eq | FilterOp::NotEq => {
            let value = filter
                .value
                .as_scalar()?
                .parse::<i32>()
                .map_err(|_| ServiceError::InvalidRequest("invalid integer value".into()))?;
            binds.push(SqlBindValue::Int(value));
            if matches!(filter.op, FilterOp::Eq) {
                format!("{column} = ?")
            } else {
                format!("{column} <> ?")
            }
        }
        FilterOp::In | FilterOp::NotIn => {
            let values = filter.value.as_list()?;
            if values.is_empty() {
                return Ok(None);
            }
            enforce_list_limit(&filter.field, values.len())?;
            let mut placeholders = Vec::new();
            for raw in values {
                let parsed = raw
                    .parse::<i32>()
                    .map_err(|_| ServiceError::InvalidRequest("invalid integer value".into()))?;
                placeholders.push("?".to_string());
                binds.push(SqlBindValue::Int(parsed));
            }
            let operator = if matches!(filter.op, FilterOp::In) {
                "IN"
            } else {
                "NOT IN"
            };
            format!("{column} {operator} ({})", placeholders.join(", "))
        }
        _ => {
            return Err(ServiceError::InvalidRequest(
                "severity_number only supports equality or IN comparisons".into(),
            ))
        }
    };

    Ok(Some((clause, binds)))
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

fn enforce_list_limit(field: &str, len: usize) -> Result<()> {
    if len > MAX_LIST_FILTER_VALUES {
        return Err(ServiceError::InvalidRequest(format!(
            "{field} filters support at most {MAX_LIST_FILTER_VALUES} values"
        )));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::parser::{Entity, Filter, FilterOp, FilterValue};
    use chrono::{Duration as ChronoDuration, TimeZone, Utc};

    #[test]
    fn stats_query_counts_logs_for_service() {
        let plan = stats_plan(
            r#"count() as total, group_uniq_array(service_name) as services"#,
            "serviceradar-core",
        );
        let stats_sql = build_stats_query(&plan).expect("stats query should parse");
        let stats_sql = stats_sql.expect("stats SQL expected");

        let lower = stats_sql.sql.to_lowercase();
        assert!(
            lower.contains("count(") && lower.contains("jsonb_agg"),
            "unexpected stats SQL: {}",
            stats_sql.sql
        );
        assert!(
            lower.contains("jsonb_build_object('total'") && lower.contains("'services'"),
            "payload should be shaped as JSON object: {}",
            stats_sql.sql
        );
        assert_eq!(
            stats_sql.binds.len(),
            3,
            "time range + filter binds expected"
        );
    }

    fn stats_plan(stats: &str, service_name: &str) -> QueryPlan {
        let start = Utc.with_ymd_and_hms(2025, 1, 1, 0, 0, 0).unwrap();
        let end = start + ChronoDuration::hours(24);
        QueryPlan {
            entity: Entity::Logs,
            filters: vec![Filter {
                field: "service_name".into(),
                op: FilterOp::Eq,
                value: FilterValue::Scalar(service_name.to_string()),
            }],
            order: Vec::new(),
            limit: 100,
            offset: 0,
            time_range: Some(TimeRange { start, end }),
            stats: Some(crate::parser::StatsSpec::from_raw(stats)),
            downsample: None,
            rollup_stats: None,
        }
    }

    #[test]
    fn unknown_filter_field_returns_error() {
        let start = Utc.with_ymd_and_hms(2025, 1, 1, 0, 0, 0).unwrap();
        let end = start + ChronoDuration::hours(24);
        let plan = QueryPlan {
            entity: Entity::Logs,
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
        };

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

    #[test]
    fn unknown_stats_filter_field_returns_error() {
        let start = Utc.with_ymd_and_hms(2025, 1, 1, 0, 0, 0).unwrap();
        let end = start + ChronoDuration::hours(24);
        let plan = QueryPlan {
            entity: Entity::Logs,
            filters: vec![Filter {
                field: "unknown_field".into(),
                op: FilterOp::Eq,
                value: FilterValue::Scalar("test".to_string()),
            }],
            order: Vec::new(),
            limit: 100,
            offset: 0,
            time_range: Some(TimeRange { start, end }),
            stats: Some(crate::parser::StatsSpec::from_raw("count() as total")),
            downsample: None,
            rollup_stats: None,
        };

        let result = build_stats_query(&plan);
        match result {
            Err(err) => {
                assert!(
                    err.to_string().contains("unsupported filter field"),
                    "error should mention unsupported filter field: {}",
                    err
                );
            }
            Ok(_) => panic!("expected error for unknown stats filter field"),
        }
    }

    #[test]
    fn rollup_stats_severity_builds_cagg_query() {
        let start = Utc.with_ymd_and_hms(2025, 1, 1, 0, 0, 0).unwrap();
        let end = start + ChronoDuration::hours(24);
        let plan = QueryPlan {
            entity: Entity::Logs,
            filters: Vec::new(),
            order: Vec::new(),
            limit: 100,
            offset: 0,
            time_range: Some(TimeRange { start, end }),
            stats: None,
            downsample: None,
            rollup_stats: Some("severity".to_string()),
        };

        let result = build_rollup_stats_query(&plan).expect("should build rollup_stats query");
        let sql = result.expect("severity rollup_stats should return SQL");

        let lower = sql.sql.to_lowercase();
        assert!(
            lower.contains("logs_severity_stats_5m"),
            "should query the CAGG: {}",
            sql.sql
        );
        assert!(
            lower.contains("sum(total_count)") && lower.contains("sum(fatal_count)"),
            "should sum counts: {}",
            sql.sql
        );
        assert!(
            lower.contains("jsonb_build_object"),
            "should return JSON payload: {}",
            sql.sql
        );
        assert_eq!(sql.binds.len(), 2, "should have time range binds");
    }

    #[test]
    fn rollup_stats_severity_with_service_filter() {
        let start = Utc.with_ymd_and_hms(2025, 1, 1, 0, 0, 0).unwrap();
        let end = start + ChronoDuration::hours(24);
        let plan = QueryPlan {
            entity: Entity::Logs,
            filters: vec![Filter {
                field: "service_name".into(),
                op: FilterOp::Eq,
                value: FilterValue::Scalar("core".to_string()),
            }],
            order: Vec::new(),
            limit: 100,
            offset: 0,
            time_range: Some(TimeRange { start, end }),
            stats: None,
            downsample: None,
            rollup_stats: Some("severity".to_string()),
        };

        let result = build_rollup_stats_query(&plan).expect("should build rollup_stats query");
        let sql = result.expect("severity rollup_stats should return SQL");

        let lower = sql.sql.to_lowercase();
        assert!(
            lower.contains("service_name = ?"),
            "should filter by service_name: {}",
            sql.sql
        );
        assert_eq!(sql.binds.len(), 3, "should have time range + service binds");
    }

    #[test]
    fn rollup_stats_unknown_type_returns_error() {
        let start = Utc.with_ymd_and_hms(2025, 1, 1, 0, 0, 0).unwrap();
        let end = start + ChronoDuration::hours(24);
        let plan = QueryPlan {
            entity: Entity::Logs,
            filters: Vec::new(),
            order: Vec::new(),
            limit: 100,
            offset: 0,
            time_range: Some(TimeRange { start, end }),
            stats: None,
            downsample: None,
            rollup_stats: Some("unknown".to_string()),
        };

        let result = build_rollup_stats_query(&plan);
        match result {
            Err(err) => {
                assert!(
                    err.to_string().contains("unsupported rollup_stats type"),
                    "error should mention unsupported type: {}",
                    err
                );
            }
            Ok(_) => panic!("expected error for unknown rollup_stats type"),
        }
    }
}
