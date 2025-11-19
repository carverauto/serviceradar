use super::QueryPlan;
use crate::{
    error::{Result, ServiceError},
    models::OtelMetricRow,
    parser::{Entity, Filter, FilterOp, OrderClause, OrderDirection},
    schema::otel_metrics::dsl::{
        component as col_component, grpc_method as col_grpc_method,
        grpc_service as col_grpc_service, grpc_status_code as col_grpc_status,
        http_method as col_http_method, http_route as col_http_route,
        http_status_code as col_http_status, is_slow as col_is_slow, level as col_level,
        metric_type as col_metric_type, otel_metrics, service_name as col_service_name,
        span_id as col_span_id, span_kind as col_span_kind, span_name as col_span_name,
        timestamp as col_timestamp, trace_id as col_trace_id,
    },
    time::TimeRange,
};
use chrono::{DateTime, Utc};
use diesel::pg::Pg;
use diesel::prelude::*;
use diesel::query_builder::{AsQuery, BoxedSelectStatement, BoxedSqlQuery, FromClause, SqlQuery};
use diesel::sql_query;
use diesel::sql_types::{Array, Bool, Jsonb, Nullable, Text, Timestamptz};
use diesel::PgTextExpressionMethods;
use diesel_async::{AsyncPgConnection, RunQueryDsl};
use serde_json::Value;

type MetricsTable = crate::schema::otel_metrics::table;
type MetricsFromClause = FromClause<MetricsTable>;
type MetricsQuery<'a> =
    BoxedSelectStatement<'a, <MetricsTable as AsQuery>::SqlType, MetricsFromClause, Pg>;

pub(super) async fn execute(conn: &mut AsyncPgConnection, plan: &QueryPlan) -> Result<Vec<Value>> {
    ensure_entity(plan)?;

    if let Some(stats_sql) = build_stats_query(plan)? {
        let query = stats_sql.to_boxed_query();
        let rows: Vec<MetricsStatsPayload> = query
            .load(conn)
            .await
            .map_err(|err| ServiceError::Internal(err.into()))?;
        return Ok(rows.into_iter().filter_map(|row| row.payload).collect());
    }

    let query = build_query(plan)?;
    let rows: Vec<OtelMetricRow> = query
        .limit(plan.limit)
        .offset(plan.offset)
        .load(conn)
        .await
        .map_err(|err| ServiceError::Internal(err.into()))?;

    Ok(rows.into_iter().map(OtelMetricRow::into_json).collect())
}

pub(super) fn to_debug_sql(plan: &QueryPlan) -> Result<String> {
    ensure_entity(plan)?;
    if let Some(stats_sql) = build_stats_query(plan)? {
        return Ok(stats_sql.sql);
    }

    let query = build_query(plan)?;
    Ok(diesel::debug_query::<Pg, _>(&query.limit(plan.limit).offset(plan.offset)).to_string())
}

fn ensure_entity(plan: &QueryPlan) -> Result<()> {
    match plan.entity {
        Entity::OtelMetrics => Ok(()),
        _ => Err(ServiceError::InvalidRequest(
            "entity not supported by otel_metrics query".into(),
        )),
    }
}

fn build_query(plan: &QueryPlan) -> Result<MetricsQuery<'static>> {
    let mut query = otel_metrics.into_boxed::<Pg>();

    if let Some(TimeRange { start, end }) = &plan.time_range {
        query = query.filter(col_timestamp.ge(*start).and(col_timestamp.le(*end)));
    }

    for filter in &plan.filters {
        query = apply_filter(query, filter)?;
    }

    query = apply_ordering(query, &plan.order);
    Ok(query)
}

fn apply_filter<'a>(mut query: MetricsQuery<'a>, filter: &Filter) -> Result<MetricsQuery<'a>> {
    match filter.field.as_str() {
        "trace_id" => {
            query = apply_text_filter!(query, filter, col_trace_id)?;
        }
        "span_id" => {
            query = apply_text_filter!(query, filter, col_span_id)?;
        }
        "service_name" | "service" => {
            query = apply_text_filter!(query, filter, col_service_name)?;
        }
        "span_name" => {
            query = apply_text_filter!(query, filter, col_span_name)?;
        }
        "span_kind" => {
            query = apply_text_filter!(query, filter, col_span_kind)?;
        }
        "metric_type" | "type" => {
            query = apply_text_filter!(query, filter, col_metric_type)?;
        }
        "component" => {
            query = apply_text_filter!(query, filter, col_component)?;
        }
        "level" => {
            query = apply_text_filter!(query, filter, col_level)?;
        }
        "http_method" => {
            query = apply_text_filter!(query, filter, col_http_method)?;
        }
        "http_route" => {
            query = apply_text_filter!(query, filter, col_http_route)?;
        }
        "http_status_code" => {
            query = apply_text_filter!(query, filter, col_http_status)?;
        }
        "grpc_service" => {
            query = apply_text_filter!(query, filter, col_grpc_service)?;
        }
        "grpc_method" => {
            query = apply_text_filter!(query, filter, col_grpc_method)?;
        }
        "grpc_status_code" => {
            query = apply_text_filter!(query, filter, col_grpc_status)?;
        }
        "is_slow" => {
            let value = parse_bool(filter.value.as_scalar()?)?;
            match filter.op {
                FilterOp::Eq => query = query.filter(col_is_slow.eq(value)),
                FilterOp::NotEq => query = query.filter(col_is_slow.ne(value)),
                _ => {
                    return Err(ServiceError::InvalidRequest(
                        "is_slow filter only supports equality".into(),
                    ))
                }
            }
        }
        _ => {}
    }

    Ok(query)
}

fn apply_ordering<'a>(mut query: MetricsQuery<'a>, order: &[OrderClause]) -> MetricsQuery<'a> {
    let mut applied = false;
    for clause in order {
        query = if !applied {
            applied = true;
            match clause.field.as_str() {
                "timestamp" => match clause.direction {
                    OrderDirection::Asc => query.order(col_timestamp.asc()),
                    OrderDirection::Desc => query.order(col_timestamp.desc()),
                },
                "service_name" | "service" => match clause.direction {
                    OrderDirection::Asc => query.order(col_service_name.asc()),
                    OrderDirection::Desc => query.order(col_service_name.desc()),
                },
                "metric_type" | "type" => match clause.direction {
                    OrderDirection::Asc => query.order(col_metric_type.asc()),
                    OrderDirection::Desc => query.order(col_metric_type.desc()),
                },
                _ => query,
            }
        } else {
            match clause.field.as_str() {
                "timestamp" => match clause.direction {
                    OrderDirection::Asc => query.then_order_by(col_timestamp.asc()),
                    OrderDirection::Desc => query.then_order_by(col_timestamp.desc()),
                },
                "service_name" | "service" => match clause.direction {
                    OrderDirection::Asc => query.then_order_by(col_service_name.asc()),
                    OrderDirection::Desc => query.then_order_by(col_service_name.desc()),
                },
                "metric_type" | "type" => match clause.direction {
                    OrderDirection::Asc => query.then_order_by(col_metric_type.asc()),
                    OrderDirection::Desc => query.then_order_by(col_metric_type.desc()),
                },
                _ => query,
            }
        };
    }

    if !applied {
        query = query.order(col_timestamp.desc());
    }

    query
}

fn parse_bool(raw: &str) -> Result<bool> {
    match raw.to_lowercase().as_str() {
        "true" | "1" | "yes" => Ok(true),
        "false" | "0" | "no" => Ok(false),
        other => Err(ServiceError::InvalidRequest(format!(
            "invalid boolean value '{other}'"
        ))),
    }
}

#[derive(Debug, Clone)]
struct MetricsStatsSql {
    sql: String,
    binds: Vec<SqlBindValue>,
}

impl MetricsStatsSql {
    fn to_boxed_query(&self) -> BoxedSqlQuery<'_, Pg, SqlQuery> {
        let mut query = sql_query(rewrite_placeholders(&self.sql)).into_boxed::<Pg>();
        for bind in &self.binds {
            query = bind.apply(query);
        }
        query
    }
}

#[derive(Debug, Clone)]
enum SqlBindValue {
    Text(String),
    TextArray(Vec<String>),
    Bool(bool),
    Timestamp(DateTime<Utc>),
}

impl SqlBindValue {
    fn apply<'a>(&self, query: BoxedSqlQuery<'a, Pg, SqlQuery>) -> BoxedSqlQuery<'a, Pg, SqlQuery> {
        match self {
            SqlBindValue::Text(value) => query.bind::<Text, _>(value.clone()),
            SqlBindValue::TextArray(values) => query.bind::<Array<Text>, _>(values.clone()),
            SqlBindValue::Bool(value) => query.bind::<Bool, _>(*value),
            SqlBindValue::Timestamp(value) => query.bind::<Timestamptz, _>(*value),
        }
    }
}

#[derive(Debug, QueryableByName)]
struct MetricsStatsPayload {
    #[diesel(sql_type = Nullable<Jsonb>)]
    payload: Option<Value>,
}

#[derive(Debug, Clone)]
struct MetricsStatsSpec {
    alias: String,
    group_field: Option<MetricsGroupField>,
}

#[derive(Debug, Clone, Copy)]
enum MetricsGroupField {
    ServiceName,
}

impl MetricsGroupField {
    fn column(&self) -> &'static str {
        match self {
            MetricsGroupField::ServiceName => "service_name",
        }
    }

    fn response_key(&self) -> &'static str {
        match self {
            MetricsGroupField::ServiceName => "service_name",
        }
    }
}

fn build_stats_query(plan: &QueryPlan) -> Result<Option<MetricsStatsSql>> {
    let stats_raw = match plan.stats.as_ref() {
        Some(value) if !value.trim().is_empty() => value.trim(),
        _ => return Ok(None),
    };

    let stats = parse_stats_spec(stats_raw)?;
    let mut binds = Vec::new();
    let mut clauses = Vec::new();

    if let Some(TimeRange { start, end }) = &plan.time_range {
        clauses.push("timestamp >= ?".to_string());
        binds.push(SqlBindValue::Timestamp(*start));
        clauses.push("timestamp <= ?".to_string());
        binds.push(SqlBindValue::Timestamp(*end));
    }

    for filter in &plan.filters {
        if let Some((clause, mut bind_values)) = build_stats_filter_clause(filter)? {
            clauses.push(clause);
            binds.append(&mut bind_values);
        }
    }

    let mut sql = String::from("SELECT ");
    if let Some(group_field) = stats.group_field {
        let column = group_field.column();
        sql.push_str(&format!(
            "jsonb_build_object('{}', {column}, '{}', COUNT(*)) AS payload",
            group_field.response_key(),
            stats.alias
        ));
    } else {
        sql.push_str(&format!(
            "jsonb_build_object('{}', COUNT(*)) AS payload",
            stats.alias
        ));
    }
    sql.push_str("\nFROM otel_metrics");
    if !clauses.is_empty() {
        sql.push_str("\nWHERE ");
        sql.push_str(&clauses.join(" AND "));
    }

    if stats.group_field.is_some() {
        let column = stats.group_field.unwrap().column();
        sql.push_str(&format!("\nGROUP BY {column}"));
        let order_sql = build_stats_order_clause(plan, stats.alias.as_str(), column);
        sql.push_str(&order_sql);
        sql.push_str(&format!("\nLIMIT {} OFFSET {}", plan.limit, plan.offset));
    }

    Ok(Some(MetricsStatsSql { sql, binds }))
}

fn build_stats_order_clause(plan: &QueryPlan, alias: &str, group_column: &str) -> String {
    if plan.order.is_empty() {
        return "\nORDER BY COUNT(*) DESC".to_string();
    }

    let mut parts = Vec::new();
    for clause in &plan.order {
        let expr = if clause.field.eq_ignore_ascii_case(alias) {
            "COUNT(*)".to_string()
        } else if matches!(clause.field.as_str(), "service" | "service_name" | "name") {
            group_column.to_string()
        } else {
            continue;
        };

        let dir = match clause.direction {
            OrderDirection::Asc => "ASC",
            OrderDirection::Desc => "DESC",
        };
        parts.push(format!("{expr} {dir}"));
    }

    if parts.is_empty() {
        "\nORDER BY COUNT(*) DESC".to_string()
    } else {
        format!("\nORDER BY {}", parts.join(", "))
    }
}

fn build_stats_filter_clause(filter: &Filter) -> Result<Option<(String, Vec<SqlBindValue>)>> {
    let mut binds = Vec::new();
    let clause = match filter.field.as_str() {
        "trace_id" => build_text_clause("trace_id", filter, &mut binds)?,
        "span_id" => build_text_clause("span_id", filter, &mut binds)?,
        "service_name" | "service" => build_text_clause("service_name", filter, &mut binds)?,
        "span_name" => build_text_clause("span_name", filter, &mut binds)?,
        "metric_type" | "type" => build_text_clause("metric_type", filter, &mut binds)?,
        "component" => build_text_clause("component", filter, &mut binds)?,
        "http_method" => build_text_clause("http_method", filter, &mut binds)?,
        "http_route" => build_text_clause("http_route", filter, &mut binds)?,
        "http_status_code" => build_text_clause("http_status_code", filter, &mut binds)?,
        "grpc_service" => build_text_clause("grpc_service", filter, &mut binds)?,
        "grpc_method" => build_text_clause("grpc_method", filter, &mut binds)?,
        "grpc_status_code" => build_text_clause("grpc_status_code", filter, &mut binds)?,
        "is_slow" => {
            let value = parse_bool(filter.value.as_scalar()?)?;
            binds.push(SqlBindValue::Bool(value));
            match filter.op {
                FilterOp::Eq => "is_slow = ?".to_string(),
                FilterOp::NotEq => "(is_slow IS NULL OR is_slow <> ?)".to_string(),
                _ => {
                    return Err(ServiceError::InvalidRequest(
                        "is_slow filter only supports equality".into(),
                    ))
                }
            }
        }
        _ => return Ok(None),
    };

    Ok(Some((clause, binds)))
}

fn build_text_clause(
    column: &str,
    filter: &Filter,
    binds: &mut Vec<SqlBindValue>,
) -> Result<String> {
    match filter.op {
        FilterOp::Eq => {
            binds.push(SqlBindValue::Text(filter.value.as_scalar()?.to_string()));
            Ok(format!("{column} = ?"))
        }
        FilterOp::NotEq => {
            binds.push(SqlBindValue::Text(filter.value.as_scalar()?.to_string()));
            Ok(format!("{column} <> ?"))
        }
        FilterOp::Like => {
            binds.push(SqlBindValue::Text(filter.value.as_scalar()?.to_string()));
            Ok(format!("{column} ILIKE ?"))
        }
        FilterOp::NotLike => {
            binds.push(SqlBindValue::Text(filter.value.as_scalar()?.to_string()));
            Ok(format!("{column} NOT ILIKE ?"))
        }
        FilterOp::In | FilterOp::NotIn => {
            let values: Vec<String> = filter
                .value
                .as_list()?
                .iter()
                .map(|v| v.to_string())
                .collect();
            if values.is_empty() {
                return Ok("1=1".into());
            }
            binds.push(SqlBindValue::TextArray(values));
            let operator = if matches!(filter.op, FilterOp::In) {
                "= ANY(?)"
            } else {
                "<> ALL(?)"
            };
            Ok(format!("{column} {operator}"))
        }
        _ => Err(ServiceError::InvalidRequest(format!(
            "text filter {column} does not support operator {:?}",
            filter.op
        ))),
    }
}

fn parse_stats_spec(raw: &str) -> Result<MetricsStatsSpec> {
    let tokens: Vec<&str> = raw.split_whitespace().collect();
    if tokens.len() < 3 {
        return Err(ServiceError::InvalidRequest(
            "stats expressions must be of the form 'count() as alias'".into(),
        ));
    }

    if !tokens[0].eq_ignore_ascii_case("count()") || !tokens[1].eq_ignore_ascii_case("as") {
        return Err(ServiceError::InvalidRequest(
            "only count() aggregations are supported for otel_metrics".into(),
        ));
    }

    let alias = tokens[2]
        .trim_matches('"')
        .trim_matches('\'')
        .to_lowercase();
    if alias.is_empty() {
        return Err(ServiceError::InvalidRequest(
            "stats alias cannot be empty".into(),
        ));
    }

    let mut group_field = None;
    if tokens.len() >= 5 {
        if !tokens[3].eq_ignore_ascii_case("by") {
            return Err(ServiceError::InvalidRequest(
                "expected 'by <field>' after stats alias".into(),
            ));
        }
        group_field = Some(parse_group_field(tokens[4])?);
    }

    Ok(MetricsStatsSpec { alias, group_field })
}

fn parse_group_field(raw: &str) -> Result<MetricsGroupField> {
    match raw.to_lowercase().as_str() {
        "service_name" | "service" | "name" => Ok(MetricsGroupField::ServiceName),
        other => Err(ServiceError::InvalidRequest(format!(
            "unsupported stats group field '{other}'"
        ))),
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
