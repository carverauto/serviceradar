use super::{BindParam, QueryPlan};
use crate::{
    error::{Result, ServiceError},
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

const ROOT_PREDICATE: &str = "coalesce(parent_span_id, '') = ''";
const MAX_TRACE_STATS_EXPRESSIONS: usize = 25;

pub(super) async fn execute(conn: &mut AsyncPgConnection, plan: &QueryPlan) -> Result<Vec<Value>> {
    ensure_entity(plan)?;
    let summary_query = build_summary_query(plan)?;

    match summary_query.mode {
        SummaryMode::Data => {
            let sql_debug = summary_query.sql.clone();
            let binds_debug = summary_query.binds.clone();
            let query = summary_query.to_boxed_query();
            let rows: Vec<TraceSummaryRow> = query.load(conn).await.map_err(|err| {
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
            let rows: Vec<TraceStatsPayload> = query.load(conn).await.map_err(|err| {
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
                .and_then(|row| row.payload)
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
        Entity::TraceSummaries => Ok(()),
        _ => Err(ServiceError::InvalidRequest(
            "entity not supported by trace summaries query".into(),
        )),
    }
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
struct TraceStatsPayload {
    #[diesel(sql_type = Nullable<Jsonb>)]
    payload: Option<Value>,
}

fn build_summary_query(plan: &QueryPlan) -> Result<TraceSummarySql> {
    let mut sql = String::from("WITH trace_summaries AS (\n");
    sql.push_str(
        "    SELECT\n        trace_id,\n        max(timestamp) AS timestamp,\n        max(span_id) FILTER (WHERE ",
    );
    sql.push_str(ROOT_PREDICATE);
    sql.push_str(") AS root_span_id,\n        max(name) FILTER (WHERE ");
    sql.push_str(ROOT_PREDICATE);
    sql.push_str(") AS root_span_name,\n        max(service_name) FILTER (WHERE ");
    sql.push_str(ROOT_PREDICATE);
    sql.push_str(") AS root_service_name,\n        max(kind) FILTER (WHERE ");
    sql.push_str(ROOT_PREDICATE);
    sql.push_str(
        ") AS root_span_kind,\n        min(start_time_unix_nano) AS start_time_unix_nano,\n        max(end_time_unix_nano) AS end_time_unix_nano,\n        greatest(0, coalesce((max(end_time_unix_nano) - min(start_time_unix_nano))::double precision / 1000000.0, 0)) AS duration_ms,\n        max(status_code) FILTER (WHERE ",
    );
    sql.push_str(ROOT_PREDICATE);
    sql.push_str(") AS status_code,\n        max(status_message) FILTER (WHERE ");
    sql.push_str(ROOT_PREDICATE);
    sql.push_str(
        ") AS status_message,\n        array_agg(DISTINCT service_name) FILTER (WHERE service_name IS NOT NULL) AS service_set,\n        count(*) AS span_count,\n        sum(CASE WHEN coalesce(status_code, 0) != 1 THEN 1 ELSE 0 END) AS error_count\n    FROM otel_traces\n    WHERE trace_id IS NOT NULL",
    );

    let mut binds = Vec::new();
    if let Some(TimeRange { start, end }) = &plan.time_range {
        sql.push_str("\n      AND timestamp >= ?\n      AND timestamp <= ?");
        binds.push(SqlBindValue::Timestamp(*start));
        binds.push(SqlBindValue::Timestamp(*end));
    }

    sql.push_str("\n    GROUP BY trace_id\n)\n");

    if let Some(raw_stats) = plan.stats.as_ref().and_then(|s| {
        let trimmed = s.trim();
        if trimmed.is_empty() {
            None
        } else {
            Some(trimmed)
        }
    }) {
        let stats = parse_stats(raw_stats)?;
        let (select_sql, mut stats_binds) = build_stats_select(&stats)?;
        sql.push_str("SELECT ");
        sql.push_str(&select_sql);
        sql.push_str(" AS payload\nFROM trace_summaries");
        binds.append(&mut stats_binds);
        let (where_sql, mut where_binds) = build_filters_clause(plan)?;
        sql.push_str(&where_sql);
        binds.append(&mut where_binds);
        return Ok(TraceSummarySql {
            sql,
            binds,
            mode: SummaryMode::Stats,
        });
    }

    sql.push_str(
        "SELECT\n        timestamp,\n        trace_id,\n        root_span_id,\n        root_span_name,\n        root_service_name,\n        root_span_kind,\n        start_time_unix_nano,\n        end_time_unix_nano,\n        duration_ms,\n        status_code,\n        status_message,\n        service_set,\n        span_count,\n        error_count\n    FROM trace_summaries",
    );
    let (where_sql, mut where_binds) = build_filters_clause(plan)?;
    sql.push_str(&where_sql);
    binds.append(&mut where_binds);
    let order_sql = build_order_clause(&plan.order);
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

fn build_filters_clause(plan: &QueryPlan) -> Result<(String, Vec<SqlBindValue>)> {
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
                )))
            }
        }
    }

    if clauses.is_empty() {
        Ok((String::new(), binds))
    } else {
        Ok((format!("\nWHERE {}", clauses.join(" AND ")), binds))
    }
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
            )))
        }
    }

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

fn add_i64_condition(
    clauses: &mut Vec<String>,
    binds: &mut Vec<SqlBindValue>,
    column: &str,
    filter: &Filter,
) -> Result<()> {
    match filter.op {
        FilterOp::Eq | FilterOp::NotEq => {
            let value = parse_i64(filter)?;
            clauses.push(match filter.op {
                FilterOp::Eq => format!("{column} = ?"),
                _ => format!("{column} <> ?"),
            });
            binds.push(SqlBindValue::BigInt(value));
            Ok(())
        }
        _ => Err(ServiceError::InvalidRequest(format!(
            "{column} filter only supports equality"
        ))),
    }
}

fn add_float_condition(
    clauses: &mut Vec<String>,
    binds: &mut Vec<SqlBindValue>,
    column: &str,
    filter: &Filter,
) -> Result<()> {
    match filter.op {
        FilterOp::Eq | FilterOp::NotEq => {
            let value = parse_f64(filter)?;
            clauses.push(match filter.op {
                FilterOp::Eq => format!("{column} = ?"),
                _ => format!("{column} <> ?"),
            });
            binds.push(SqlBindValue::Float(value));
            Ok(())
        }
        _ => Err(ServiceError::InvalidRequest(format!(
            "{column} filter only supports equality"
        ))),
    }
}

fn parse_i32(filter: &Filter) -> Result<i32> {
    filter
        .value
        .as_scalar()?
        .parse::<i32>()
        .map_err(|_| ServiceError::InvalidRequest("integer value required".into()))
}

fn parse_i64(filter: &Filter) -> Result<i64> {
    filter
        .value
        .as_scalar()?
        .parse::<i64>()
        .map_err(|_| ServiceError::InvalidRequest("numeric value required".into()))
}

fn parse_f64(filter: &Filter) -> Result<f64> {
    filter
        .value
        .as_scalar()?
        .parse::<f64>()
        .map_err(|_| ServiceError::InvalidRequest("numeric value required".into()))
}

fn build_order_clause(order: &[OrderClause]) -> String {
    if order.is_empty() {
        return "\nORDER BY timestamp DESC".to_string();
    }

    let mut clauses = Vec::new();
    for clause in order {
        let column = match clause.field.as_str() {
            "timestamp" => Some("timestamp"),
            "duration_ms" => Some("duration_ms"),
            "span_count" => Some("span_count"),
            "error_count" => Some("error_count"),
            "root_service_name" => Some("root_service_name"),
            _ => None,
        };
        if let Some(col) = column {
            clauses.push(format!(
                "{col} {}",
                match clause.direction {
                    OrderDirection::Asc => "ASC",
                    OrderDirection::Desc => "DESC",
                }
            ));
        }
    }

    if clauses.is_empty() {
        "\nORDER BY timestamp DESC".to_string()
    } else {
        format!("\nORDER BY {}", clauses.join(", "))
    }
}

#[derive(Debug)]
struct TraceStatsExpr {
    alias: String,
    kind: StatsExprKind,
}

#[derive(Debug)]
enum StatsExprKind {
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
enum StatsComparator {
    Eq,
    NotEq,
    GreaterThan,
}

impl TraceStatsExpr {
    fn to_sql(&self) -> (String, Vec<SqlBindValue>) {
        match &self.kind {
            StatsExprKind::Count => ("coalesce(COUNT(*), 0)".into(), Vec::new()),
            StatsExprKind::StatusCompare { comparator, value } => {
                let op = match comparator {
                    StatsComparator::Eq => "=",
                    StatsComparator::NotEq => "<>",
                    _ => "=",
                };
                let fragment = format!(
                    "coalesce(SUM(CASE WHEN coalesce(status_code, 0) {op} ? THEN 1 ELSE 0 END), 0)"
                );
                (fragment, vec![SqlBindValue::Int(*value)])
            }
            StatsExprKind::DurationCompare {
                comparator,
                threshold,
            } => {
                let op = match comparator {
                    StatsComparator::GreaterThan => ">",
                    _ => ">",
                };
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

fn parse_stats(raw: &str) -> Result<Vec<TraceStatsExpr>> {
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
                            ))
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
                    let comparator = match *op {
                        ">" | ">=" => StatsComparator::GreaterThan,
                        _ => {
                            return Err(ServiceError::InvalidRequest(
                                "duration_ms comparisons only support '>'".into(),
                            ))
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
