//! Query support for `otel_metric_points`: real OTLP metric data points
//! (sum/gauge/histogram) written by the EventWriter pipeline, as opposed to
//! the span-derived samples in `otel_metrics`. This entity has no trace/span
//! identifiers, so telemetry id normalization intentionally does not apply.

use super::{BindParam, QueryPlan};
use crate::{
    error::{Result, ServiceError},
    jsonb::DbJson,
    models::OtelMetricPointRow,
    parser::{Entity, Filter, FilterOp, OrderClause, OrderDirection},
    schema::otel_metric_points::dsl::{
        attributes as col_attributes, ingest_agent_id as col_ingest_agent_id,
        ingest_identity as col_ingest_identity, ingest_partition as col_ingest_partition,
        is_monotonic as col_is_monotonic, metric_name as col_metric_name,
        metric_type as col_metric_type, otel_metric_points, scope_name as col_scope_name,
        service_instance_id as col_service_instance_id, service_name as col_service_name,
        temporality as col_temporality, timestamp as col_timestamp, unit as col_unit,
        value as col_value,
    },
    time::TimeRange,
};
use chrono::{DateTime, Utc};
use diesel::PgTextExpressionMethods;
use diesel::pg::Pg;
use diesel::prelude::*;
use diesel::query_builder::{AsQuery, BoxedSelectStatement, BoxedSqlQuery, FromClause, SqlQuery};
use diesel::sql_query;
use diesel::sql_types::{Array, Bool, Float8, Jsonb, Nullable, Text, Timestamptz};
use diesel_async::{AsyncPgConnection, RunQueryDsl};
use serde_json::Value;

type PointsTable = crate::schema::otel_metric_points::table;
type PointsFromClause = FromClause<PointsTable>;
type PointsQuery<'a> =
    BoxedSelectStatement<'a, <PointsTable as AsQuery>::SqlType, PointsFromClause, Pg>;

pub(super) async fn execute(conn: &mut AsyncPgConnection, plan: &QueryPlan) -> Result<Vec<Value>> {
    ensure_entity(plan)?;

    if let Some(stats_sql) = build_stats_query(plan)? {
        let query = stats_sql.to_boxed_query();
        let rows: Vec<PointsStatsPayload> = query
            .load::<PointsStatsPayload>(conn)
            .await
            .map_err(|err| ServiceError::Internal(err.into()))?;
        return Ok(rows
            .into_iter()
            .filter_map(|row| row.payload.map(serde_json::Value::from))
            .collect());
    }

    let query = build_query(plan)?;
    let rows: Vec<OtelMetricPointRow> = query
        .limit(plan.limit)
        .offset(plan.offset)
        .load(conn)
        .await
        .map_err(|err| ServiceError::Internal(err.into()))?;

    Ok(rows
        .into_iter()
        .map(OtelMetricPointRow::into_json)
        .collect())
}

pub(super) fn to_sql_and_params(plan: &QueryPlan) -> Result<(String, Vec<BindParam>)> {
    ensure_entity(plan)?;

    if let Some(stats_sql) = build_stats_query(plan)? {
        let sql = rewrite_placeholders(&stats_sql.sql);
        let params = stats_sql
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
        Entity::OtelMetricPoints => Ok(()),
        _ => Err(ServiceError::InvalidRequest(
            "entity not supported by otel_metric_points query".into(),
        )),
    }
}

fn build_query(plan: &QueryPlan) -> Result<PointsQuery<'static>> {
    let mut query = otel_metric_points.into_boxed::<Pg>();

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
        "metric_name"
        | "service_name"
        | "service"
        | "metric_type"
        | "type"
        | "unit"
        | "temporality"
        | "scope_name"
        | "service_instance_id"
        | "service_instance"
        | "ingest_identity"
        | "ingest_agent_id"
        | "ingest_partition" => collect_text_params(params, filter),
        "attributes" => {
            params.push(BindParam::Text(attributes_pattern(filter)?));
            Ok(())
        }
        "is_monotonic" => {
            params.push(BindParam::Bool(parse_bool(filter.value.as_scalar()?)?));
            Ok(())
        }
        "value" => {
            params.push(BindParam::Float(parse_f64(filter.value.as_scalar()?)?));
            Ok(())
        }
        other => Err(ServiceError::InvalidRequest(format!(
            "unsupported filter field for otel_metric_points: '{other}'"
        ))),
    }
}

/// Substring match over the JSON attributes text: bare values are wrapped in
/// `%...%`; values that already contain SQL wildcards are passed through.
fn attributes_pattern(filter: &Filter) -> Result<String> {
    let raw = filter.value.as_scalar()?;
    if raw.is_empty() {
        return Err(ServiceError::InvalidRequest(
            "attributes filter value must not be empty".into(),
        ));
    }
    if raw.contains('%') {
        Ok(raw.to_string())
    } else {
        Ok(format!("%{raw}%"))
    }
}

fn apply_filter<'a>(mut query: PointsQuery<'a>, filter: &Filter) -> Result<PointsQuery<'a>> {
    match filter.field.as_str() {
        "metric_name" => {
            query = apply_text_filter!(query, filter, col_metric_name)?;
        }
        "service_name" | "service" => {
            query = apply_text_filter!(query, filter, col_service_name)?;
        }
        "metric_type" | "type" => {
            query = apply_text_filter!(query, filter, col_metric_type)?;
        }
        "unit" => {
            query = apply_text_filter!(query, filter, col_unit)?;
        }
        "temporality" => {
            query = apply_text_filter!(query, filter, col_temporality)?;
        }
        "scope_name" => {
            query = apply_text_filter!(query, filter, col_scope_name)?;
        }
        "service_instance_id" | "service_instance" => {
            query = apply_text_filter!(query, filter, col_service_instance_id)?;
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
        "attributes" => {
            let pattern = attributes_pattern(filter)?;
            match filter.op {
                FilterOp::Eq | FilterOp::Like => {
                    query = query.filter(col_attributes.ilike(pattern));
                }
                FilterOp::NotEq | FilterOp::NotLike => {
                    query = query.filter(col_attributes.not_ilike(pattern));
                }
                _ => {
                    return Err(ServiceError::InvalidRequest(
                        "attributes filter only supports substring matching".into(),
                    ));
                }
            }
        }
        "is_monotonic" => {
            let value = parse_bool(filter.value.as_scalar()?)?;
            match filter.op {
                FilterOp::Eq => query = query.filter(col_is_monotonic.eq(value)),
                FilterOp::NotEq => query = query.filter(col_is_monotonic.ne(value)),
                _ => {
                    return Err(ServiceError::InvalidRequest(
                        "is_monotonic filter only supports equality".into(),
                    ));
                }
            }
        }
        "value" => {
            let value = parse_f64(filter.value.as_scalar()?)?;
            match filter.op {
                FilterOp::Eq => query = query.filter(col_value.eq(value)),
                FilterOp::NotEq => query = query.filter(col_value.ne(value)),
                FilterOp::Gt => query = query.filter(col_value.gt(value)),
                FilterOp::Gte => query = query.filter(col_value.ge(value)),
                FilterOp::Lt => query = query.filter(col_value.lt(value)),
                FilterOp::Lte => query = query.filter(col_value.le(value)),
                _ => {
                    return Err(ServiceError::InvalidRequest(
                        "value filter does not support this operator".into(),
                    ));
                }
            }
        }
        other => {
            return Err(ServiceError::InvalidRequest(format!(
                "unsupported filter field for otel_metric_points: '{other}'"
            )));
        }
    }

    Ok(query)
}

fn apply_ordering<'a>(mut query: PointsQuery<'a>, order: &[OrderClause]) -> PointsQuery<'a> {
    let mut applied = false;
    for clause in order {
        query = if !applied {
            applied = true;
            match clause.field.as_str() {
                "timestamp" => match clause.direction {
                    OrderDirection::Asc => query.order(col_timestamp.asc()),
                    OrderDirection::Desc => query.order(col_timestamp.desc()),
                },
                "value" => match clause.direction {
                    OrderDirection::Asc => query.order(col_value.asc()),
                    OrderDirection::Desc => query.order(col_value.desc()),
                },
                _ => query,
            }
        } else {
            match clause.field.as_str() {
                "timestamp" => match clause.direction {
                    OrderDirection::Asc => query.then_order_by(col_timestamp.asc()),
                    OrderDirection::Desc => query.then_order_by(col_timestamp.desc()),
                },
                "value" => match clause.direction {
                    OrderDirection::Asc => query.then_order_by(col_value.asc()),
                    OrderDirection::Desc => query.then_order_by(col_value.desc()),
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

fn parse_f64(raw: &str) -> Result<f64> {
    raw.parse::<f64>()
        .map_err(|_| ServiceError::InvalidRequest("value must be numeric".into()))
}

#[derive(Debug, Clone)]
struct PointsStatsSql {
    sql: String,
    binds: Vec<SqlBindValue>,
}

impl PointsStatsSql {
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
    Float(f64),
    Timestamp(DateTime<Utc>),
}

impl SqlBindValue {
    fn apply<'a>(&self, query: BoxedSqlQuery<'a, Pg, SqlQuery>) -> BoxedSqlQuery<'a, Pg, SqlQuery> {
        match self {
            SqlBindValue::Text(value) => query.bind::<Text, _>(value.clone()),
            SqlBindValue::TextArray(values) => query.bind::<Array<Text>, _>(values.clone()),
            SqlBindValue::Bool(value) => query.bind::<Bool, _>(*value),
            SqlBindValue::Float(value) => query.bind::<Float8, _>(*value),
            SqlBindValue::Timestamp(value) => query.bind::<Timestamptz, _>(*value),
        }
    }
}

fn bind_param_from_stats(value: SqlBindValue) -> BindParam {
    match value {
        SqlBindValue::Text(value) => BindParam::Text(value),
        SqlBindValue::TextArray(values) => BindParam::TextArray(values),
        SqlBindValue::Bool(value) => BindParam::Bool(value),
        SqlBindValue::Float(value) => BindParam::Float(value),
        SqlBindValue::Timestamp(value) => BindParam::timestamptz(value),
    }
}

#[derive(Debug, QueryableByName)]
#[diesel(check_for_backend(diesel::pg::Pg))]
struct PointsStatsPayload {
    #[diesel(sql_type = Nullable<Jsonb>)]
    payload: Option<DbJson>,
}

#[derive(Debug, Clone)]
struct PointsStatsSpec {
    alias: String,
    group_field: Option<PointsGroupField>,
}

#[derive(Debug, Clone, Copy)]
enum PointsGroupField {
    MetricName,
    ServiceName,
}

impl PointsGroupField {
    fn column(&self) -> &'static str {
        match self {
            PointsGroupField::MetricName => "metric_name",
            PointsGroupField::ServiceName => "service_name",
        }
    }

    fn response_key(&self) -> &'static str {
        match self {
            PointsGroupField::MetricName => "metric_name",
            PointsGroupField::ServiceName => "service_name",
        }
    }

    fn matches_order_field(&self, field: &str) -> bool {
        match self {
            PointsGroupField::MetricName => matches!(field, "metric_name" | "name"),
            PointsGroupField::ServiceName => matches!(field, "service_name" | "service"),
        }
    }
}

/// Grouped count listing (e.g. `stats:"count() as points by metric_name"`),
/// mirroring the `otel_metrics` stats support. This is the cheap way to list
/// which metric names / services have stored points until a CAGG exists.
fn build_stats_query(plan: &QueryPlan) -> Result<Option<PointsStatsSql>> {
    let stats_raw = match plan.stats.as_ref() {
        Some(value) if !value.as_raw().trim().is_empty() => value.as_raw().trim(),
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
    let group_field = stats.group_field;
    if let Some(group_field) = group_field {
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
    sql.push_str("\nFROM otel_metric_points");
    if !clauses.is_empty() {
        sql.push_str("\nWHERE ");
        sql.push_str(&clauses.join(" AND "));
    }

    if let Some(group_field) = group_field {
        let column = group_field.column();
        sql.push_str(&format!("\nGROUP BY {column}"));
        let order_sql = build_stats_order_clause(plan, stats.alias.as_str(), group_field);
        sql.push_str(&order_sql);
        sql.push_str(&format!("\nLIMIT {} OFFSET {}", plan.limit, plan.offset));
    }

    Ok(Some(PointsStatsSql { sql, binds }))
}

fn build_stats_order_clause(
    plan: &QueryPlan,
    alias: &str,
    group_field: PointsGroupField,
) -> String {
    if plan.order.is_empty() {
        return "\nORDER BY COUNT(*) DESC".to_string();
    }

    let mut parts = Vec::new();
    for clause in &plan.order {
        let expr = if clause.field.eq_ignore_ascii_case(alias) {
            "COUNT(*)".to_string()
        } else if group_field.matches_order_field(clause.field.as_str()) {
            group_field.column().to_string()
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
        "metric_name" => build_text_clause("metric_name", filter, &mut binds)?,
        "service_name" | "service" => build_text_clause("service_name", filter, &mut binds)?,
        "metric_type" | "type" => build_text_clause("metric_type", filter, &mut binds)?,
        "unit" => build_text_clause("unit", filter, &mut binds)?,
        "temporality" => build_text_clause("temporality", filter, &mut binds)?,
        "scope_name" => build_text_clause("scope_name", filter, &mut binds)?,
        "service_instance_id" | "service_instance" => {
            build_text_clause("service_instance_id", filter, &mut binds)?
        }
        "ingest_identity" => build_text_clause("ingest_identity", filter, &mut binds)?,
        "ingest_agent_id" => build_text_clause("ingest_agent_id", filter, &mut binds)?,
        "ingest_partition" => build_text_clause("ingest_partition", filter, &mut binds)?,
        "attributes" => {
            let pattern = attributes_pattern(filter)?;
            binds.push(SqlBindValue::Text(pattern));
            match filter.op {
                FilterOp::Eq | FilterOp::Like => "COALESCE(attributes, '') ILIKE ?".to_string(),
                FilterOp::NotEq | FilterOp::NotLike => {
                    "COALESCE(attributes, '') NOT ILIKE ?".to_string()
                }
                _ => {
                    return Err(ServiceError::InvalidRequest(
                        "attributes filter only supports substring matching".into(),
                    ));
                }
            }
        }
        "is_monotonic" => {
            let value = parse_bool(filter.value.as_scalar()?)?;
            binds.push(SqlBindValue::Bool(value));
            match filter.op {
                FilterOp::Eq => "is_monotonic = ?".to_string(),
                FilterOp::NotEq => "(is_monotonic IS NULL OR is_monotonic <> ?)".to_string(),
                _ => {
                    return Err(ServiceError::InvalidRequest(
                        "is_monotonic filter only supports equality".into(),
                    ));
                }
            }
        }
        "value" => {
            let value = parse_f64(filter.value.as_scalar()?)?;
            binds.push(SqlBindValue::Float(value));
            let operator = match filter.op {
                FilterOp::Eq => "=",
                FilterOp::NotEq => "<>",
                FilterOp::Gt => ">",
                FilterOp::Gte => ">=",
                FilterOp::Lt => "<",
                FilterOp::Lte => "<=",
                _ => {
                    return Err(ServiceError::InvalidRequest(
                        "value filter does not support this operator".into(),
                    ));
                }
            };
            format!("value {operator} ?")
        }
        other => {
            return Err(ServiceError::InvalidRequest(format!(
                "unsupported filter field for otel_metric_points stats: '{other}'"
            )));
        }
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

fn parse_stats_spec(raw: &str) -> Result<PointsStatsSpec> {
    let tokens: Vec<&str> = raw.split_whitespace().collect();
    if tokens.len() < 3 {
        return Err(ServiceError::InvalidRequest(
            "stats expressions must be of the form 'count() as alias'".into(),
        ));
    }

    if !tokens[0].eq_ignore_ascii_case("count()") || !tokens[1].eq_ignore_ascii_case("as") {
        return Err(ServiceError::InvalidRequest(
            "only count() aggregations are supported for otel_metric_points".into(),
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

    Ok(PointsStatsSpec { alias, group_field })
}

fn parse_group_field(raw: &str) -> Result<PointsGroupField> {
    match raw.to_lowercase().as_str() {
        "metric_name" | "name" => Ok(PointsGroupField::MetricName),
        "service_name" | "service" => Ok(PointsGroupField::ServiceName),
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

#[cfg(test)]
mod tests {
    use super::*;
    use crate::parser::{self, Entity, Filter, FilterOp, FilterValue};
    use chrono::{Duration as ChronoDuration, TimeZone, Utc};

    fn base_plan() -> QueryPlan {
        let start = Utc.with_ymd_and_hms(2026, 6, 1, 0, 0, 0).unwrap();
        let end = start + ChronoDuration::hours(1);
        QueryPlan {
            entity: Entity::OtelMetricPoints,
            filters: Vec::new(),
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

    fn filter(field: &str, op: FilterOp, value: &str) -> Filter {
        Filter {
            field: field.into(),
            op,
            value: FilterValue::Scalar(value.to_string()),
        }
    }

    #[test]
    fn resolves_entity_aliases() {
        let ast = parser::parse("in:otel_metric_points time:last_1h").unwrap();
        assert_eq!(ast.entity, Entity::OtelMetricPoints);

        let ast = parser::parse("in:metric_points time:last_1h").unwrap();
        assert_eq!(ast.entity, Entity::OtelMetricPoints);
    }

    #[test]
    fn generates_sql_for_metric_name_and_time_filter() {
        let mut plan = base_plan();
        plan.filters
            .push(filter("metric_name", FilterOp::Eq, "gen"));

        let (sql, params) = to_sql_and_params(&plan).expect("sql should generate");

        assert!(sql.contains("\"otel_metric_points\""), "{sql}");
        assert!(sql.contains("\"timestamp\" >= $1"), "{sql}");
        assert!(sql.contains("\"timestamp\" <= $2"), "{sql}");
        assert!(sql.contains("\"metric_name\" = $3"), "{sql}");
        // 2 time bounds + metric_name + limit + offset
        assert_eq!(params.len(), 5, "params: {params:?}");
        assert!(
            matches!(&params[2], BindParam::Text(value) if value == "gen"),
            "params: {params:?}"
        );
    }

    #[test]
    fn select_list_includes_extended_point_columns() {
        let plan = base_plan();
        let (sql, _) = to_sql_and_params(&plan).expect("sql should generate");

        assert!(sql.contains("\"start_time_unix_nano\""), "{sql}");
        assert!(
            sql.contains("\"otel_metric_points\".\"scope_name\""),
            "{sql}"
        );
        assert!(sql.contains("\"service_instance_id\""), "{sql}");
    }

    #[test]
    fn generates_sql_for_scope_name_filter() {
        let mut plan = base_plan();
        plan.filters
            .push(filter("scope_name", FilterOp::Eq, "io.opentelemetry.sdk"));

        let (sql, params) = to_sql_and_params(&plan).expect("sql should generate");

        assert!(sql.contains("\"scope_name\" = $3"), "{sql}");
        assert!(
            matches!(&params[2], BindParam::Text(value) if value == "io.opentelemetry.sdk"),
            "params: {params:?}"
        );
    }

    #[test]
    fn generates_sql_for_service_instance_id_filter() {
        let mut plan = base_plan();
        plan.filters
            .push(filter("service_instance_id", FilterOp::Eq, "instance-1"));

        let (sql, params) = to_sql_and_params(&plan).expect("sql should generate");

        assert!(sql.contains("\"service_instance_id\" = $3"), "{sql}");
        assert!(
            matches!(&params[2], BindParam::Text(value) if value == "instance-1"),
            "params: {params:?}"
        );
    }

    #[test]
    fn generates_sql_for_metric_type_filter() {
        let mut plan = base_plan();
        plan.filters
            .push(filter("metric_type", FilterOp::Eq, "histogram"));

        let (sql, params) = to_sql_and_params(&plan).expect("sql should generate");

        assert!(sql.contains("\"metric_type\" = $3"), "{sql}");
        assert!(
            matches!(&params[2], BindParam::Text(value) if value == "histogram"),
            "params: {params:?}"
        );
    }

    #[test]
    fn generates_sql_for_value_greater_than() {
        let mut plan = base_plan();
        plan.filters.push(filter("value", FilterOp::Gt, "42"));

        let (sql, params) = to_sql_and_params(&plan).expect("sql should generate");

        assert!(sql.contains("\"value\" > $3"), "{sql}");
        assert!(
            matches!(&params[2], BindParam::Float(value) if (*value - 42.0).abs() < f64::EPSILON),
            "params: {params:?}"
        );
    }

    #[test]
    fn defaults_to_timestamp_desc_ordering() {
        let plan = base_plan();
        let (sql, _) = to_sql_and_params(&plan).expect("sql should generate");
        assert!(
            sql.contains("ORDER BY \"otel_metric_points\".\"timestamp\" DESC"),
            "{sql}"
        );
    }

    #[test]
    fn orders_by_value_when_requested() {
        let mut plan = base_plan();
        plan.order.push(crate::parser::OrderClause {
            field: "value".into(),
            direction: OrderDirection::Asc,
        });
        let (sql, _) = to_sql_and_params(&plan).expect("sql should generate");
        assert!(
            sql.contains("ORDER BY \"otel_metric_points\".\"value\" ASC"),
            "{sql}"
        );
    }

    #[test]
    fn ingest_identity_eq_filter_generates_sql_and_bind() {
        let mut plan = base_plan();
        plan.filters.push(filter(
            "ingest_identity",
            FilterOp::Eq,
            "spiffe://sr/agent/edge-1",
        ));

        let (sql, params) = to_sql_and_params(&plan).expect("sql should generate");

        assert!(sql.contains("\"ingest_identity\" = $3"), "{sql}");
        assert!(
            matches!(&params[2], BindParam::Text(value) if value == "spiffe://sr/agent/edge-1"),
            "params: {params:?}"
        );
    }

    #[test]
    fn ingest_agent_id_like_filter_uses_ilike() {
        let mut plan = base_plan();
        plan.filters
            .push(filter("ingest_agent_id", FilterOp::Like, "%edge%"));

        let (sql, params) = to_sql_and_params(&plan).expect("sql should generate");

        assert!(sql.contains("\"ingest_agent_id\" ILIKE $3"), "{sql}");
        assert!(
            matches!(&params[2], BindParam::Text(value) if value == "%edge%"),
            "params: {params:?}"
        );
    }

    #[test]
    fn ingest_partition_in_filter_generates_any_clause() {
        let mut plan = base_plan();
        plan.filters.push(Filter {
            field: "ingest_partition".into(),
            op: FilterOp::In,
            value: FilterValue::List(vec!["default".into(), "tenant-a".into()]),
        });

        let (sql, params) = to_sql_and_params(&plan).expect("sql should generate");

        assert!(sql.contains("\"ingest_partition\" = ANY($3)"), "{sql}");
        assert!(
            matches!(&params[2], BindParam::TextArray(values)
                if values == &vec!["default".to_string(), "tenant-a".to_string()]),
            "params: {params:?}"
        );
    }

    #[test]
    fn attributes_filter_uses_substring_ilike() {
        let mut plan = base_plan();
        plan.filters
            .push(filter("attributes", FilterOp::Eq, "host.name"));

        let (sql, params) = to_sql_and_params(&plan).expect("sql should generate");

        assert!(sql.contains("\"attributes\" ILIKE $3"), "{sql}");
        assert!(
            matches!(&params[2], BindParam::Text(value) if value == "%host.name%"),
            "params: {params:?}"
        );
    }

    #[test]
    fn stats_count_by_metric_name_generates_grouped_listing() {
        let mut plan = base_plan();
        plan.stats = Some(crate::parser::StatsSpec::from_raw(
            "count() as points by metric_name",
        ));

        let (sql, params) = to_sql_and_params(&plan).expect("sql should generate");

        assert!(
            sql.contains("jsonb_build_object('metric_name', metric_name, 'points', COUNT(*))"),
            "{sql}"
        );
        assert!(sql.contains("FROM otel_metric_points"), "{sql}");
        assert!(sql.contains("GROUP BY metric_name"), "{sql}");
        assert!(sql.contains("ORDER BY COUNT(*) DESC"), "{sql}");
        assert_eq!(params.len(), 2, "params: {params:?}");
    }

    #[test]
    fn unknown_filter_field_returns_error() {
        let mut plan = base_plan();
        plan.filters
            .push(filter("span_id", FilterOp::Eq, "deadbeef"));

        match build_query(&plan) {
            Err(err) => assert!(
                err.to_string().contains("unsupported filter field"),
                "error should mention unsupported filter field: {err}"
            ),
            Ok(_) => panic!("expected error for unknown filter field"),
        }
    }
}
