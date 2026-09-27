use super::{BindParam, QueryPlan};
use crate::{
    error::{Result, ServiceError},
    jsonb::DbJson,
    models::TraceSummaryRow,
    parser::{Entity, Filter, FilterOp, OrderClause, OrderDirection},
    time::TimeRange,
};
use chrono::{DateTime, Utc};
use diesel::deserialize::QueryableByName;
use diesel::pg::Pg;
use diesel::query_builder::{BoxedSqlQuery, SqlQuery};
use diesel::sql_query;
use diesel::sql_types::{Array, Float8, Int4, Int8, Jsonb, Nullable, Text, Timestamptz};
use diesel_async::{AsyncPgConnection, RunQueryDsl};
use serde_json::Value;
use tracing::error;

const MAX_TRACE_STATS_EXPRESSIONS: usize = 25;

pub(super) async fn execute(conn: &mut AsyncPgConnection, plan: &QueryPlan) -> Result<Vec<Value>> {
    ensure_entity(plan)?;
    let summary_query = build_summary_query(plan)?;

    match summary_query.mode {
        SummaryMode::Data => {
            let sql_debug = summary_query.sql.clone();
            let binds_debug = summary_query.binds.clone();
            let query = summary_query.to_boxed_query();
            let rows: Vec<TraceSummaryRow> =
                query.load::<TraceSummaryRow>(conn).await.map_err(|err| {
                    error!(
                        error = ?err,
                        sql = %sql_debug,
                        binds = ?binds_debug,
                        "trace summaries data query failed"
                    );
                    ServiceError::Internal(err.into())
                })?;
            Ok(rows.into_iter().map(TraceSummaryRow::into_json).collect())
        }
        SummaryMode::Stats => {
            let sql_debug = summary_query.sql.clone();
            let binds_debug = summary_query.binds.clone();
            let query = summary_query.to_boxed_query();
            let rows: Vec<TraceStatsPayload> =
                query.load::<TraceStatsPayload>(conn).await.map_err(|err| {
                    error!(
                        error = ?err,
                        sql = %sql_debug,
                        binds = ?binds_debug,
                        "trace summaries stats query failed"
                    );
                    ServiceError::Internal(err.into())
                })?;
            let payload = rows
                .into_iter()
                .next()
                .and_then(|row| row.payload.map(serde_json::Value::from))
                .unwrap_or_else(|| Value::Object(serde_json::Map::new()));
            Ok(vec![payload])
        }
    }
}

pub(super) fn to_sql_and_params(plan: &QueryPlan) -> Result<(String, Vec<BindParam>)> {
    ensure_entity(plan)?;
    let summary_query = build_summary_query(plan)?;
    let sql = rewrite_placeholders(&summary_query.sql);
    let params = summary_query
        .binds
        .into_iter()
        .map(bind_param_from_query)
        .collect();
    Ok((sql, params))
}

fn ensure_entity(plan: &QueryPlan) -> Result<()> {
    match plan.entity {
        Entity::TraceSummaries => refuse_unsupported_clauses(plan),
        _ => Err(ServiceError::InvalidRequest(
            "entity not supported by trace summaries query".into(),
        )),
    }
}

/// Plan clauses the summary builders of either dialect have no translation
/// for. They used to be ignored; now they are refused by name.
pub(super) fn refuse_unsupported_clauses(plan: &QueryPlan) -> Result<()> {
    if let Some(kind) = plan
        .rollup_stats
        .as_deref()
        .map(str::trim)
        .filter(|kind| !kind.is_empty())
    {
        return Err(ServiceError::InvalidRequest(format!(
            "rollup_stats:{kind} is not supported for otel_trace_summaries; \
             use rollup_stats on otel_traces"
        )));
    }
    if plan.downsample.is_some() {
        return Err(ServiceError::InvalidRequest(
            "bucket: is not supported for otel_trace_summaries".into(),
        ));
    }
    Ok(())
}

#[derive(Debug, Clone)]
struct TraceSummarySql {
    sql: String,
    binds: Vec<SqlBindValue>,
    mode: SummaryMode,
}

impl TraceSummarySql {
    fn to_boxed_query(&self) -> BoxedSqlQuery<'_, Pg, SqlQuery> {
        let mut query = sql_query(rewrite_placeholders(&self.sql)).into_boxed::<Pg>();
        for bind in &self.binds {
            query = bind.bind(query);
        }
        query
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum SummaryMode {
    Data,
    Stats,
}

#[derive(Debug, Clone)]
enum SqlBindValue {
    Text(String),
    TextArray(Vec<String>),
    Int(i32),
    BigInt(i64),
    Float(f64),
    Timestamp(DateTime<Utc>),
}

impl SqlBindValue {
    fn bind<'f>(&self, query: BoxedSqlQuery<'f, Pg, SqlQuery>) -> BoxedSqlQuery<'f, Pg, SqlQuery> {
        match self {
            SqlBindValue::Text(value) => query.bind::<Text, _>(value.clone()),
            SqlBindValue::TextArray(values) => query.bind::<Array<Text>, _>(values.clone()),
            SqlBindValue::Int(value) => query.bind::<Int4, _>(*value),
            SqlBindValue::BigInt(value) => query.bind::<Int8, _>(*value),
            SqlBindValue::Float(value) => query.bind::<Float8, _>(*value),
            SqlBindValue::Timestamp(value) => query.bind::<Timestamptz, _>(*value),
        }
    }
}

fn bind_param_from_query(value: SqlBindValue) -> BindParam {
    match value {
        SqlBindValue::Text(value) => BindParam::Text(value),
        SqlBindValue::TextArray(values) => BindParam::TextArray(values),
        SqlBindValue::Int(value) => BindParam::Int(i64::from(value)),
        SqlBindValue::BigInt(value) => BindParam::Int(value),
        SqlBindValue::Float(value) => BindParam::Float(value),
        SqlBindValue::Timestamp(value) => BindParam::timestamptz(value),
    }
}

#[derive(Debug, QueryableByName)]
#[diesel(check_for_backend(diesel::pg::Pg))]
struct TraceStatsPayload {
    #[diesel(sql_type = Nullable<Jsonb>)]
    payload: Option<DbJson>,
}

fn build_summary_query(plan: &QueryPlan) -> Result<TraceSummarySql> {
    // Query directly from the otel_trace_summaries materialized view
    // The MV pre-computes trace aggregations and is refreshed periodically
    let mut binds = Vec::new();

    // Handle stats mode (aggregation queries)
    if let Some(raw_stats) = plan.stats.as_ref().and_then(|s| {
        let trimmed = s.as_raw().trim();
        if trimmed.is_empty() {
            None
        } else {
            Some(trimmed)
        }
    }) {
        let stats = parse_stats(raw_stats)?;
        let (select_sql, mut stats_binds) = build_stats_select(&stats)?;

        let mut sql = String::from("SELECT ");
        sql.push_str(&select_sql);
        sql.push_str(" AS payload\nFROM otel_trace_summaries");

        // IMPORTANT: Stats binds come first because select_sql placeholders appear before WHERE
        binds.append(&mut stats_binds);

        // Build WHERE clause for time range and filters
        let mut where_clauses = Vec::new();

        if let Some(TimeRange { start, end }) = &plan.time_range {
            where_clauses.push("timestamp >= ?".to_string());
            binds.push(SqlBindValue::Timestamp(*start));
            where_clauses.push("timestamp <= ?".to_string());
            binds.push(SqlBindValue::Timestamp(*end));
        }

        let (filter_sql, mut filter_binds) = build_filters_clause_raw(plan)?;
        where_clauses.extend(filter_sql);
        binds.append(&mut filter_binds);

        if !where_clauses.is_empty() {
            sql.push_str("\nWHERE ");
            sql.push_str(&where_clauses.join(" AND "));
        }

        return Ok(TraceSummarySql {
            sql,
            binds,
            mode: SummaryMode::Stats,
        });
    }

    // Data mode: return trace summary rows
    let mut sql = String::from(
        "SELECT\n    timestamp,\n    trace_id,\n    root_span_id,\n    root_span_name,\n    root_service_name,\n    root_service_namespace,\n    deployment_environment,\n    root_span_kind,\n    start_time_unix_nano,\n    end_time_unix_nano,\n    duration_ms,\n    status_code,\n    status_message,\n    service_set,\n    span_count,\n    error_count\nFROM otel_trace_summaries",
    );

    // Build WHERE clause for time range and filters
    let mut where_clauses = Vec::new();

    if let Some(TimeRange { start, end }) = &plan.time_range {
        where_clauses.push("timestamp >= ?".to_string());
        binds.push(SqlBindValue::Timestamp(*start));
        where_clauses.push("timestamp <= ?".to_string());
        binds.push(SqlBindValue::Timestamp(*end));
    }

    let (filter_clauses, mut filter_binds) = build_filters_clause_raw(plan)?;
    where_clauses.extend(filter_clauses);
    binds.append(&mut filter_binds);

    if !where_clauses.is_empty() {
        sql.push_str("\nWHERE ");
        sql.push_str(&where_clauses.join(" AND "));
    }

    let order_sql = build_order_clause(&plan.order)?;
    sql.push_str(&order_sql);
    sql.push_str("\nLIMIT ? OFFSET ?");
    binds.push(SqlBindValue::BigInt(plan.limit));
    binds.push(SqlBindValue::BigInt(plan.offset));

    Ok(TraceSummarySql {
        sql,
        binds,
        mode: SummaryMode::Data,
    })
}

/// Build filter clauses as a list (without WHERE prefix)
fn build_filters_clause_raw(plan: &QueryPlan) -> Result<(Vec<String>, Vec<SqlBindValue>)> {
    let mut clauses = Vec::new();
    let mut binds = Vec::new();

    for filter in &plan.filters {
        match filter.field.as_str() {
            "trace_id" => add_text_condition(&mut clauses, &mut binds, "trace_id", filter)?,
            "root_span_id" => add_text_condition(&mut clauses, &mut binds, "root_span_id", filter)?,
            "root_span_name" => {
                add_text_condition(&mut clauses, &mut binds, "root_span_name", filter)?
            }
            "root_service_name" => {
                add_text_condition(&mut clauses, &mut binds, "root_service_name", filter)?
            }
            "service_name" => add_service_set_condition(&mut clauses, &mut binds, filter)?,
            "root_service_namespace" => {
                add_text_condition(&mut clauses, &mut binds, "root_service_namespace", filter)?
            }
            "deployment_environment" | "deployment.environment" => {
                add_text_condition(&mut clauses, &mut binds, "deployment_environment", filter)?
            }
            "status_code" => add_int_condition(&mut clauses, &mut binds, "status_code", filter)?,
            "root_span_kind" => {
                add_int_condition(&mut clauses, &mut binds, "root_span_kind", filter)?
            }
            "span_count" => add_i64_condition(&mut clauses, &mut binds, "span_count", filter)?,
            "error_count" => add_i64_condition(&mut clauses, &mut binds, "error_count", filter)?,
            "duration_ms" => add_float_condition(&mut clauses, &mut binds, "duration_ms", filter)?,
            other => {
                return Err(ServiceError::InvalidRequest(format!(
                    "unsupported filter field '{other}'"
                )));
            }
        }
    }

    Ok((clauses, binds))
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

fn add_text_condition(
    clauses: &mut Vec<String>,
    binds: &mut Vec<SqlBindValue>,
    column: &str,
    filter: &Filter,
) -> Result<()> {
    match filter.op {
        FilterOp::Eq => {
            let value = filter.value.as_scalar()?.to_string();
            clauses.push(format!("{column} = ?"));
            binds.push(SqlBindValue::Text(value));
        }
        FilterOp::NotEq => {
            let value = filter.value.as_scalar()?.to_string();
            clauses.push(format!("{column} <> ?"));
            binds.push(SqlBindValue::Text(value));
        }
        FilterOp::Like => {
            let value = filter.value.as_scalar()?.to_string();
            clauses.push(format!("{column} ILIKE ?"));
            binds.push(SqlBindValue::Text(value));
        }
        FilterOp::NotLike => {
            let value = filter.value.as_scalar()?.to_string();
            clauses.push(format!("{column} NOT ILIKE ?"));
            binds.push(SqlBindValue::Text(value));
        }
        FilterOp::In => {
            let values = filter.value.as_list()?.to_vec();
            if values.is_empty() {
                clauses.push("1=0".to_string());
                return Ok(());
            }
            clauses.push(format!("{column} = ANY(?)"));
            binds.push(SqlBindValue::TextArray(values));
        }
        FilterOp::NotIn => {
            let values = filter.value.as_list()?.to_vec();
            if values.is_empty() {
                // If "NOT IN" an empty list, it's always true, so no condition needed.
                return Ok(());
            }
            clauses.push(format!("{column} <> ALL(?)"));
            binds.push(SqlBindValue::TextArray(values));
        }
        _ => {
            return Err(ServiceError::InvalidRequest(format!(
                "text filter {column} does not support operator {:?}",
                filter.op
            )));
        }
    }

    Ok(())
}

/// `service_name` matches a trace when ANY of its spans belongs to the service,
/// not only the root span (`root_service_name` keeps that meaning). Array
/// containment is exact, so wildcards are refused rather than silently taken
/// literally. `service_set` is nullable and `NOT (NULL)` drops the row, so the
/// negated forms coalesce it: a trace with no service names does not touch the
/// excluded service and must be returned.
fn add_service_set_condition(
    clauses: &mut Vec<String>,
    binds: &mut Vec<SqlBindValue>,
    filter: &Filter,
) -> Result<()> {
    let (clause, values) = match filter.op {
        FilterOp::Eq => (
            "service_set @> ?",
            vec![filter.value.as_scalar()?.to_string()],
        ),
        FilterOp::NotEq => (
            "NOT (COALESCE(service_set, '{}') @> ?)",
            vec![filter.value.as_scalar()?.to_string()],
        ),
        FilterOp::In => ("service_set && ?", filter.value.as_list()?.to_vec()),
        FilterOp::NotIn => (
            "NOT (COALESCE(service_set, '{}') && ?)",
            filter.value.as_list()?.to_vec(),
        ),
        FilterOp::Like | FilterOp::NotLike => {
            return Err(ServiceError::InvalidRequest(
                "service_name on otel_trace_summaries matches exact service names; \
                 wildcards are not supported (use root_service_name for pattern matches \
                 on the root span)"
                    .into(),
            ));
        }
        _ => {
            return Err(ServiceError::InvalidRequest(format!(
                "service_name filter does not support operator {:?}",
                filter.op
            )));
        }
    };

    clauses.push(clause.to_string());
    binds.push(SqlBindValue::TextArray(values));
    Ok(())
}

fn add_int_condition(
    clauses: &mut Vec<String>,
    binds: &mut Vec<SqlBindValue>,
    column: &str,
    filter: &Filter,
) -> Result<()> {
    match filter.op {
        FilterOp::Eq | FilterOp::NotEq => {
            let value = parse_i32(filter)?;
            clauses.push(match filter.op {
                FilterOp::Eq => format!("{column} = ?"),
                _ => format!("{column} <> ?"),
            });
            binds.push(SqlBindValue::Int(value));
            Ok(())
        }
        _ => Err(ServiceError::InvalidRequest(format!(
            "{column} filter only supports equality",
        ))),
    }
}

fn numeric_comparison_sql(column: &str, op: &FilterOp) -> Result<String> {
    let operator = match op {
        FilterOp::Eq => "=",
        FilterOp::NotEq => "<>",
        FilterOp::Gt => ">",
        FilterOp::Gte => ">=",
        FilterOp::Lt => "<",
        FilterOp::Lte => "<=",
        _ => {
            return Err(ServiceError::InvalidRequest(format!(
                "{column} filter only supports equality or numeric comparisons"
            )));
        }
    };
    Ok(format!("{column} {operator} ?"))
}

fn add_i64_condition(
    clauses: &mut Vec<String>,
    binds: &mut Vec<SqlBindValue>,
    column: &str,
    filter: &Filter,
) -> Result<()> {
    let clause = numeric_comparison_sql(column, &filter.op)?;
    let value = parse_i64(filter)?;
    clauses.push(clause);
    binds.push(SqlBindValue::BigInt(value));
    Ok(())
}

fn add_float_condition(
    clauses: &mut Vec<String>,
    binds: &mut Vec<SqlBindValue>,
    column: &str,
    filter: &Filter,
) -> Result<()> {
    let clause = numeric_comparison_sql(column, &filter.op)?;
    let value = parse_f64(filter)?;
    clauses.push(clause);
    binds.push(SqlBindValue::Float(value));
    Ok(())
}

pub(super) fn parse_i32(filter: &Filter) -> Result<i32> {
    filter
        .value
        .as_scalar()?
        .parse::<i32>()
        .map_err(|_| ServiceError::InvalidRequest("integer value required".into()))
}

pub(super) fn parse_i64(filter: &Filter) -> Result<i64> {
    filter
        .value
        .as_scalar()?
        .parse::<i64>()
        .map_err(|_| ServiceError::InvalidRequest("numeric value required".into()))
}

pub(super) fn parse_f64(filter: &Filter) -> Result<f64> {
    filter
        .value
        .as_scalar()?
        .parse::<f64>()
        .ok()
        .filter(|value| value.is_finite())
        .ok_or_else(|| ServiceError::InvalidRequest("numeric value required".into()))
}

/// Row sort fields both dialects accept. Any other field is refused: it used
/// to be dropped.
pub(super) const ROW_SORT_FIELDS: &[&str] = &[
    "timestamp",
    "duration_ms",
    "span_count",
    "error_count",
    "root_service_name",
];

pub(super) fn row_sort_column(field: &str) -> Result<&'static str> {
    ROW_SORT_FIELDS
        .iter()
        .find(|name| **name == field)
        .copied()
        .ok_or_else(|| {
            ServiceError::InvalidRequest(format!(
                "unsupported sort field for otel_trace_summaries: '{field}'"
            ))
        })
}

fn build_order_clause(order: &[OrderClause]) -> Result<String> {
    if order.is_empty() {
        return Ok("\nORDER BY timestamp DESC".to_string());
    }

    let mut clauses = Vec::new();
    for clause in order {
        let col = row_sort_column(clause.field.as_str())?;
        clauses.push(format!(
            "{col} {}",
            match clause.direction {
                OrderDirection::Asc => "ASC",
                OrderDirection::Desc => "DESC",
            }
        ));
    }

    Ok(format!("\nORDER BY {}", clauses.join(", ")))
}

#[derive(Debug)]
pub(super) struct TraceStatsExpr {
    pub(super) alias: String,
    pub(super) kind: StatsExprKind,
}

#[derive(Debug)]
pub(super) enum StatsExprKind {
    Count,
    StatusCompare {
        comparator: StatsComparator,
        value: i32,
    },
    DurationCompare {
        comparator: StatsComparator,
        threshold: f64,
    },
}

#[derive(Debug, Clone, Copy)]
pub(super) enum StatsComparator {
    Eq,
    NotEq,
    GreaterThan,
    GreaterOrEqual,
}

impl StatsComparator {
    pub(super) fn sql(self) -> &'static str {
        match self {
            StatsComparator::Eq => "=",
            StatsComparator::NotEq => "<>",
            StatsComparator::GreaterThan => ">",
            StatsComparator::GreaterOrEqual => ">=",
        }
    }
}

impl TraceStatsExpr {
    fn to_sql(&self) -> (String, Vec<SqlBindValue>) {
        match &self.kind {
            StatsExprKind::Count => ("coalesce(COUNT(*), 0)".into(), Vec::new()),
            StatsExprKind::StatusCompare { comparator, value } => {
                let op = comparator.sql();
                let fragment = format!(
                    "coalesce(SUM(CASE WHEN coalesce(status_code, 0) {op} ? THEN 1 ELSE 0 END), 0)"
                );
                (fragment, vec![SqlBindValue::Int(*value)])
            }
            StatsExprKind::DurationCompare {
                comparator,
                threshold,
            } => {
                let op = comparator.sql();
                let fragment = format!(
                    "coalesce(SUM(CASE WHEN coalesce(duration_ms, 0) {op} ? THEN 1 ELSE 0 END), 0)"
                );
                (fragment, vec![SqlBindValue::Float(*threshold)])
            }
        }
    }
}

fn build_stats_select(exprs: &[TraceStatsExpr]) -> Result<(String, Vec<SqlBindValue>)> {
    if exprs.is_empty() {
        return Ok(("jsonb_build_object()".to_string(), Vec::new()));
    }

    let mut parts = Vec::new();
    let mut binds = Vec::new();
    for expr in exprs {
        let (fragment, mut expr_binds) = expr.to_sql();
        parts.push(format!("'{}', {}", expr.alias, fragment));
        binds.append(&mut expr_binds);
    }

    Ok((format!("jsonb_build_object({})", parts.join(", ")), binds))
}

pub(super) fn parse_stats(raw: &str) -> Result<Vec<TraceStatsExpr>> {
    let segments = split_segments(raw);
    let mut exprs = Vec::new();
    for segment in segments {
        if segment.trim().is_empty() {
            continue;
        }
        if exprs.len() >= MAX_TRACE_STATS_EXPRESSIONS {
            return Err(ServiceError::InvalidRequest(format!(
                "stats supports at most {MAX_TRACE_STATS_EXPRESSIONS} expressions"
            )));
        }
        exprs.push(parse_stats_expr(&segment)?);
    }
    // An empty list has no result columns to return on either dialect.
    if exprs.is_empty() {
        return Err(ServiceError::InvalidRequest(
            "stats needs at least one expression".into(),
        ));
    }
    Ok(exprs)
}

fn split_segments(raw: &str) -> Vec<String> {
    let mut items = Vec::new();
    let mut current = String::new();
    let mut depth = 0usize;
    for ch in raw.chars() {
        match ch {
            '(' => {
                depth += 1;
                current.push(ch);
            }
            ')' => {
                depth = depth.saturating_sub(1);
                current.push(ch);
            }
            ',' if depth == 0 => {
                items.push(current.trim().to_string());
                current.clear();
            }
            _ => current.push(ch),
        }
    }
    if !current.trim().is_empty() {
        items.push(current.trim().to_string());
    }
    items
}

fn parse_stats_expr(segment: &str) -> Result<TraceStatsExpr> {
    let (expr, alias) = split_alias(segment)?;
    let alias = sanitize_alias(alias)?;
    let normalized = expr.trim();
    if normalized.eq_ignore_ascii_case("count()") {
        return Ok(TraceStatsExpr {
            alias,
            kind: StatsExprKind::Count,
        });
    }

    let kind = parse_sum_if(normalized)?;
    Ok(TraceStatsExpr { alias, kind })
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
        Ok((expr, alias))
    } else {
        Err(ServiceError::InvalidRequest(
            "stats expressions must include an alias".into(),
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

fn parse_sum_if(expr: &str) -> Result<StatsExprKind> {
    let trimmed = expr.trim();
    if !trimmed.to_lowercase().starts_with("sum(") || !trimmed.ends_with(')') {
        return Err(ServiceError::InvalidRequest(format!(
            "unsupported stats expression '{expr}'"
        )));
    }
    let inner = trimmed[4..trimmed.len() - 1].trim();
    if !inner.to_lowercase().starts_with("if(") || !inner.ends_with(')') {
        return Err(ServiceError::InvalidRequest(format!(
            "unsupported stats expression '{expr}'"
        )));
    }
    let args = &inner[3..inner.len() - 1];
    let parts = split_stats_args(args, 3)?;
    let condition = parts[0].trim();
    if parts[1].trim() != "1" || parts[2].trim() != "0" {
        return Err(ServiceError::InvalidRequest(
            "stats IF() expressions must compare against 1 and 0".into(),
        ));
    }
    parse_condition(condition)
}

fn split_stats_args(raw: &str, expected: usize) -> Result<Vec<String>> {
    let mut parts = Vec::new();
    let mut current = String::new();
    let mut depth = 0usize;
    for ch in raw.chars() {
        match ch {
            '(' => {
                depth += 1;
                current.push(ch);
            }
            ')' => {
                depth = depth.saturating_sub(1);
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
    if parts.len() != expected {
        return Err(ServiceError::InvalidRequest(
            "invalid stats IF() clause".into(),
        ));
    }
    Ok(parts)
}

fn parse_condition(raw: &str) -> Result<StatsExprKind> {
    let operators = ["!=", ">=", "<=", "=", ">", "<"];
    for op in &operators {
        if let Some(idx) = raw.find(op) {
            let field = raw[..idx].trim().to_lowercase();
            let value = raw[idx + op.len()..]
                .trim()
                .trim_matches('"')
                .trim_matches('\'');
            return match field.as_str() {
                "status_code" => {
                    let parsed = value.parse::<i32>().map_err(|_| {
                        ServiceError::InvalidRequest(
                            "status_code comparison requires an integer".into(),
                        )
                    })?;
                    let comparator = match *op {
                        "=" => StatsComparator::Eq,
                        "!=" => StatsComparator::NotEq,
                        _ => {
                            return Err(ServiceError::InvalidRequest(
                                "status_code comparisons only support '=' or '!='".into(),
                            ));
                        }
                    };
                    Ok(StatsExprKind::StatusCompare {
                        comparator,
                        value: parsed,
                    })
                }
                "duration_ms" => {
                    let parsed = value.parse::<f64>().map_err(|_| {
                        ServiceError::InvalidRequest(
                            "duration_ms comparison requires a numeric value".into(),
                        )
                    })?;
                    // `>=` used to compile as `>`, dropping every trace exactly
                    // at the threshold.
                    let comparator = match *op {
                        ">" => StatsComparator::GreaterThan,
                        ">=" => StatsComparator::GreaterOrEqual,
                        _ => {
                            return Err(ServiceError::InvalidRequest(
                                "duration_ms comparisons only support '>' or '>='".into(),
                            ));
                        }
                    };
                    Ok(StatsExprKind::DurationCompare {
                        comparator,
                        threshold: parsed,
                    })
                }
                other => Err(ServiceError::InvalidRequest(format!(
                    "unsupported stats condition on '{other}'"
                ))),
            };
        }
    }

    Err(ServiceError::InvalidRequest(
        "unable to parse stats condition".into(),
    ))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{
        config::AppConfig,
        error::ServiceError,
        parser,
        query::{QueryDirection, QueryRequest, build_query_plan},
    };

    fn translate(query: &str) -> Result<(String, Vec<BindParam>)> {
        let request = QueryRequest {
            query: query.to_string(),
            limit: None,
            cursor: None,
            direction: QueryDirection::Next,
            mode: None,
            permitted_signals: None,
        };
        let config = AppConfig::embedded("postgres://srql-test".to_string());
        let ast = parser::parse(query)?;
        let plan = build_query_plan(&config, &request, ast)?;
        to_sql_and_params(&plan)
    }

    fn first_bind(params: &[BindParam]) -> &[String] {
        match params.first() {
            Some(BindParam::TextArray(values)) => values,
            other => panic!("expected a text[] bind, got {other:?}"),
        }
    }

    #[test]
    fn service_name_matches_any_span_in_the_trace() {
        let (sql, params) =
            translate("in:otel_trace_summaries service_name:checkout").expect("translate");
        assert!(sql.contains("WHERE service_set @> $1"), "{sql}");
        assert_eq!(first_bind(&params), ["checkout".to_string()]);

        let (sql, params) = translate("in:otel_trace_summaries service_name:(checkout,billing)")
            .expect("translate");
        assert!(sql.contains("WHERE service_set && $1"), "{sql}");
        assert_eq!(
            first_bind(&params),
            ["checkout".to_string(), "billing".to_string()]
        );
    }

    #[test]
    fn negated_service_name_keeps_traces_with_a_null_service_set() {
        // `NOT (service_set @> ...)` is NULL for a NULL service_set, which would
        // drop exactly the traces that do not touch the service.
        let (sql, _) =
            translate("in:otel_trace_summaries !service_name:checkout").expect("translate");
        assert!(
            sql.contains("WHERE NOT (COALESCE(service_set, '{}') @> $1)"),
            "{sql}"
        );

        let (sql, _) = translate("in:otel_trace_summaries !service_name:(checkout,billing)")
            .expect("translate");
        assert!(
            sql.contains("WHERE NOT (COALESCE(service_set, '{}') && $1)"),
            "{sql}"
        );
    }

    #[test]
    fn service_name_applies_in_stats_mode_too() {
        let (sql, params) =
            translate(r#"in:otel_trace_summaries service_name:checkout stats:"count() as total""#)
                .expect("translate");
        assert!(sql.contains("WHERE service_set @> $1"), "{sql}");
        assert_eq!(first_bind(&params), ["checkout".to_string()]);
    }

    #[test]
    fn service_name_wildcards_are_rejected_naming_the_field() {
        for query in [
            "in:otel_trace_summaries service_name:%check%",
            "in:otel_trace_summaries !service_name:%check%",
        ] {
            match translate(query) {
                Err(ServiceError::InvalidRequest(message)) => {
                    assert!(message.contains("service_name"), "{query}: {message}");
                }
                other => panic!("{query}: expected InvalidRequest, got {other:?}"),
            }
        }
    }

    #[test]
    fn root_service_name_keeps_its_root_only_meaning() {
        let (sql, _) =
            translate("in:otel_trace_summaries root_service_name:checkout").expect("translate");
        assert!(sql.contains("WHERE root_service_name = $1"), "{sql}");
        assert!(!sql.contains("service_set @>"), "{sql}");
    }
}
