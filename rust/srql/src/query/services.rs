use super::{BindParam, QueryPlan};
use crate::{
    error::{Result, ServiceError},
    models::ServiceStatusRow,
    parser::{Entity, Filter, FilterOp, OrderClause, OrderDirection},
    schema::service_status::dsl::{
        agent_id as col_agent_id, available as col_available, message as col_message,
        partition as col_partition, gateway_id as col_gateway_id, service_name as col_service_name,
        service_status, service_type as col_service_type, timestamp as col_timestamp,
    },
    time::TimeRange,
};
use chrono::{DateTime, Utc};
use diesel::pg::Pg;
use diesel::prelude::*;
use diesel::query_builder::{AsQuery, BoxedSelectStatement, FromClause};
use diesel::sql_query;
use diesel::sql_types::{BigInt, Jsonb};
use diesel::PgTextExpressionMethods;
use diesel::QueryableByName;
use diesel_async::{AsyncPgConnection, RunQueryDsl};
use serde::{Deserialize, Serialize};
use serde_json::Value;

type ServiceStatusTable = crate::schema::service_status::table;
type ServiceStatusFromClause = FromClause<ServiceStatusTable>;
type ServicesQuery<'a> =
    BoxedSelectStatement<'a, <ServiceStatusTable as AsQuery>::SqlType, ServiceStatusFromClause, Pg>;
type ServicesStatsQuery<'a> = BoxedSelectStatement<'a, BigInt, ServiceStatusFromClause, Pg>;

/// Raw SQL result for rollup stats query - returns JSONB payload
#[derive(Debug, QueryableByName)]
struct ServicesRollupStatsSql {
    #[diesel(sql_type = Jsonb)]
    payload: Value,
}

/// Payload structure for services availability rollup stats (reference/documentation)
#[allow(dead_code)]
#[derive(Debug, Serialize, Deserialize)]
struct ServicesRollupStatsPayload {
    total: i64,
    available: i64,
    unavailable: i64,
    availability_pct: f64,
}

/// Bind value types for rollup stats queries
#[derive(Debug, Clone)]
enum SqlBindValue {
    Timestamptz(DateTime<Utc>),
    Text(String),
}

pub(super) async fn execute(conn: &mut AsyncPgConnection, plan: &QueryPlan) -> Result<Vec<Value>> {
    ensure_entity(plan)?;

    // Handle rollup_stats queries (pre-computed CAGGs)
    if let Some(rollup_result) = build_rollup_stats_query(plan)? {
        let rows: Vec<ServicesRollupStatsSql> = rollup_result
            .query
            .load(conn)
            .await
            .map_err(|err| ServiceError::Internal(err.into()))?;

        if let Some(row) = rows.into_iter().next() {
            return Ok(vec![row.payload]);
        }
        // Return empty stats if no data
        return Ok(vec![serde_json::json!({
            "total": 0,
            "available": 0,
            "unavailable": 0,
            "availability_pct": 0.0
        })]);
    }

    if let Some(spec) = parse_stats_spec(plan.stats.as_ref().map(|s| s.as_raw()))? {
        let query = build_stats_query(plan, &spec)?;
        let values: Vec<i64> = query
            .load(conn)
            .await
            .map_err(|err| ServiceError::Internal(err.into()))?;
        let count = values.into_iter().next().unwrap_or(0);
        return Ok(vec![serde_json::json!({ spec.alias: count })]);
    }

    let query = build_query(plan)?;
    let rows: Vec<ServiceStatusRow> = query
        .limit(plan.limit)
        .offset(plan.offset)
        .load(conn)
        .await
        .map_err(|err| ServiceError::Internal(err.into()))?;

    Ok(rows.into_iter().map(ServiceStatusRow::into_json).collect())
}

pub(super) fn to_sql_and_params(plan: &QueryPlan) -> Result<(String, Vec<BindParam>)> {
    ensure_entity(plan)?;

    // Handle rollup_stats queries (pre-computed CAGGs)
    if let Some(rollup_result) = build_rollup_stats_query(plan)? {
        let params: Vec<BindParam> = rollup_result
            .binds
            .into_iter()
            .map(|v| match v {
                SqlBindValue::Timestamptz(dt) => BindParam::timestamptz(dt),
                SqlBindValue::Text(s) => BindParam::Text(s),
            })
            .collect();
        return Ok((rollup_result.sql, params));
    }

    if let Some(spec) = parse_stats_spec(plan.stats.as_ref().map(|s| s.as_raw()))? {
        let query = build_stats_query(plan, &spec)?;
        let sql = super::diesel_sql(&query)?;

        let mut params = Vec::new();
        if let Some(TimeRange { start, end }) = &plan.time_range {
            params.push(BindParam::timestamptz(*start));
            params.push(BindParam::timestamptz(*end));
        }

        for filter in &plan.filters {
            collect_filter_params(&mut params, filter)?;
        }

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
        Entity::Services => Ok(()),
        _ => Err(ServiceError::InvalidRequest(
            "entity not supported by services query".into(),
        )),
    }
}

fn build_query(plan: &QueryPlan) -> Result<ServicesQuery<'static>> {
    let mut query = service_status.into_boxed::<Pg>();

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
struct ServicesStatsSpec {
    alias: String,
}

fn parse_stats_spec(raw: Option<&str>) -> Result<Option<ServicesStatsSpec>> {
    let raw = match raw {
        Some(raw) if !raw.trim().is_empty() => raw.trim(),
        _ => return Ok(None),
    };

    let tokens: Vec<&str> = raw.split_whitespace().collect();
    if tokens.len() < 3 {
        return Err(ServiceError::InvalidRequest(
            "stats expressions must be of the form 'count() as alias'".into(),
        ));
    }

    if !tokens[0].eq_ignore_ascii_case("count()") || !tokens[1].eq_ignore_ascii_case("as") {
        return Err(ServiceError::InvalidRequest(
            "services stats only support count()".into(),
        ));
    }

    let alias = tokens[2]
        .trim_matches('"')
        .trim_matches('\'')
        .to_lowercase();

    if alias.is_empty()
        || alias
            .chars()
            .any(|ch| !ch.is_ascii_alphanumeric() && ch != '_')
    {
        return Err(ServiceError::InvalidRequest(
            "stats alias must be alphanumeric".into(),
        ));
    }

    if tokens.len() > 3 {
        return Err(ServiceError::InvalidRequest(
            "services stats do not support grouping yet".into(),
        ));
    }

    Ok(Some(ServicesStatsSpec { alias }))
}

fn build_stats_query(
    plan: &QueryPlan,
    spec: &ServicesStatsSpec,
) -> Result<ServicesStatsQuery<'static>> {
    let mut query = service_status.into_boxed::<Pg>();

    if let Some(TimeRange { start, end }) = &plan.time_range {
        query = query.filter(col_timestamp.ge(*start).and(col_timestamp.le(*end)));
    }

    for filter in &plan.filters {
        query = apply_filter(query, filter)?;
    }

    let select_sql = format!("coalesce(COUNT(*), 0) as {}", spec.alias);
    Ok(query.select(diesel::dsl::sql::<BigInt>(&select_sql)))
}

// ─────────────────────────────────────────────────────────────────────────────
// Rollup Stats (pre-computed CAGG queries)
// ─────────────────────────────────────────────────────────────────────────────

/// Result of building a rollup stats query
struct ServicesRollupStatsResult {
    sql: String,
    binds: Vec<SqlBindValue>,
    query: diesel::query_builder::BoxedSqlQuery<'static, Pg, diesel::query_builder::SqlQuery>,
}

/// Build a rollup stats query if the plan specifies rollup_stats
fn build_rollup_stats_query(plan: &QueryPlan) -> Result<Option<ServicesRollupStatsResult>> {
    let rollup_type = match &plan.rollup_stats {
        Some(t) => t.as_str(),
        None => return Ok(None),
    };

    match rollup_type {
        "availability" => build_availability_rollup_stats(plan),
        other => Err(ServiceError::InvalidRequest(format!(
            "unsupported rollup_stats type for services: '{other}' (supported: availability)"
        ))),
    }
}

/// Build query for services availability rollup stats from services_availability_5m CAGG
fn build_availability_rollup_stats(plan: &QueryPlan) -> Result<Option<ServicesRollupStatsResult>> {
    let mut sql = String::from(
        r#"SELECT jsonb_build_object(
    'total', COALESCE(SUM(total_count), 0)::bigint,
    'available', COALESCE(SUM(available_count), 0)::bigint,
    'unavailable', COALESCE(SUM(unavailable_count), 0)::bigint,
    'availability_pct', CASE
        WHEN COALESCE(SUM(total_count), 0) = 0 THEN 0.0
        ELSE (COALESCE(SUM(available_count), 0)::float / COALESCE(SUM(total_count), 0)::float) * 100.0
    END
) AS payload
FROM services_availability_5m"#,
    );

    let mut binds: Vec<SqlBindValue> = Vec::new();
    let mut where_clauses: Vec<String> = Vec::new();
    let mut bind_idx = 1;

    // Add time range filter
    if let Some(TimeRange { start, end }) = &plan.time_range {
        where_clauses.push(format!("bucket >= ${} AND bucket <= ${}", bind_idx, bind_idx + 1));
        binds.push(SqlBindValue::Timestamptz(*start));
        binds.push(SqlBindValue::Timestamptz(*end));
        bind_idx += 2;
    }

    // Add service_name filter if present
    for filter in &plan.filters {
        if filter.field == "service_name" || filter.field == "name" {
            if let Some(clause) = build_rollup_text_clause("service_name", filter, &mut binds, &mut bind_idx)? {
                where_clauses.push(clause);
            }
        }
        if filter.field == "service_type" || filter.field == "type" {
            if let Some(clause) = build_rollup_text_clause("service_type", filter, &mut binds, &mut bind_idx)? {
                where_clauses.push(clause);
            }
        }
    }

    if !where_clauses.is_empty() {
        sql.push_str(" WHERE ");
        sql.push_str(&where_clauses.join(" AND "));
    }

    // Build the query with bind parameters
    let mut query = sql_query(sql.clone()).into_boxed::<Pg>();

    for bind in &binds {
        match bind {
            SqlBindValue::Timestamptz(dt) => {
                query = query.bind::<diesel::sql_types::Timestamptz, _>(*dt);
            }
            SqlBindValue::Text(s) => {
                query = query.bind::<diesel::sql_types::Text, _>(s.clone());
            }
        }
    }

    Ok(Some(ServicesRollupStatsResult { sql, binds, query }))
}

/// Build a WHERE clause for text filters in rollup queries
fn build_rollup_text_clause(
    column: &str,
    filter: &Filter,
    binds: &mut Vec<SqlBindValue>,
    bind_idx: &mut usize,
) -> Result<Option<String>> {
    match filter.op {
        FilterOp::Eq => {
            let clause = format!("{} = ${}", column, *bind_idx);
            binds.push(SqlBindValue::Text(filter.value.as_scalar()?.to_string()));
            *bind_idx += 1;
            Ok(Some(clause))
        }
        FilterOp::NotEq => {
            let clause = format!("{} != ${}", column, *bind_idx);
            binds.push(SqlBindValue::Text(filter.value.as_scalar()?.to_string()));
            *bind_idx += 1;
            Ok(Some(clause))
        }
        FilterOp::Like => {
            let clause = format!("{} LIKE ${}", column, *bind_idx);
            binds.push(SqlBindValue::Text(filter.value.as_scalar()?.to_string()));
            *bind_idx += 1;
            Ok(Some(clause))
        }
        _ => Ok(None), // Other operators not supported for rollup text filters
    }
}

fn apply_filter<'a>(mut query: ServicesQuery<'a>, filter: &Filter) -> Result<ServicesQuery<'a>> {
    match filter.field.as_str() {
        "service_name" | "name" => {
            query = apply_text_filter!(query, filter, col_service_name)?;
        }
        "service_type" | "type" => {
            query = apply_text_filter!(query, filter, col_service_type)?;
        }
        "gateway_id" => {
            query = apply_text_filter!(query, filter, col_gateway_id)?;
        }
        "agent_id" => {
            query = apply_text_filter!(query, filter, col_agent_id)?;
        }
        "partition" => {
            query = apply_text_filter!(query, filter, col_partition)?;
        }
        "message" => {
            query = apply_text_filter!(query, filter, col_message)?;
        }
        "available" => {
            let value = parse_bool(filter.value.as_scalar()?)?;
            match filter.op {
                FilterOp::Eq => {
                    query = query.filter(col_available.eq(value));
                }
                FilterOp::NotEq => {
                    query = query.filter(col_available.ne(value));
                }
                _ => {
                    return Err(ServiceError::InvalidRequest(
                        "available filter only supports equality".into(),
                    ));
                }
            }
        }
        other => {
            return Err(ServiceError::InvalidRequest(format!(
                "unsupported filter field for services: '{other}'"
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
        "service_name" | "name" | "service_type" | "type" | "gateway_id" | "agent_id"
        | "partition" | "message" => collect_text_params(params, filter),
        "available" => {
            params.push(BindParam::Bool(parse_bool(filter.value.as_scalar()?)?));
            Ok(())
        }
        other => Err(ServiceError::InvalidRequest(format!(
            "unsupported filter field for services: '{other}'"
        ))),
    }
}

fn apply_ordering<'a>(mut query: ServicesQuery<'a>, order: &[OrderClause]) -> ServicesQuery<'a> {
    let mut applied = false;
    for clause in order {
        query = if !applied {
            applied = true;
            match clause.field.as_str() {
                "timestamp" | "last_seen" => match clause.direction {
                    OrderDirection::Asc => query.order(col_timestamp.asc()),
                    OrderDirection::Desc => query.order(col_timestamp.desc()),
                },
                "service_name" | "name" => match clause.direction {
                    OrderDirection::Asc => query.order(col_service_name.asc()),
                    OrderDirection::Desc => query.order(col_service_name.desc()),
                },
                "service_type" | "type" => match clause.direction {
                    OrderDirection::Asc => query.order(col_service_type.asc()),
                    OrderDirection::Desc => query.order(col_service_type.desc()),
                },
                _ => query,
            }
        } else {
            match clause.field.as_str() {
                "timestamp" | "last_seen" => match clause.direction {
                    OrderDirection::Asc => query.then_order_by(col_timestamp.asc()),
                    OrderDirection::Desc => query.then_order_by(col_timestamp.desc()),
                },
                "service_name" | "name" => match clause.direction {
                    OrderDirection::Asc => query.then_order_by(col_service_name.asc()),
                    OrderDirection::Desc => query.then_order_by(col_service_name.desc()),
                },
                "service_type" | "type" => match clause.direction {
                    OrderDirection::Asc => query.then_order_by(col_service_type.asc()),
                    OrderDirection::Desc => query.then_order_by(col_service_type.desc()),
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

#[cfg(test)]
mod tests {
    use super::*;
    use crate::parser::{Entity, Filter, FilterOp, FilterValue};
    use chrono::{Duration as ChronoDuration, TimeZone, Utc};

    #[test]
    fn unknown_filter_field_returns_error() {
        let start = Utc.with_ymd_and_hms(2025, 1, 1, 0, 0, 0).unwrap();
        let end = start + ChronoDuration::hours(1);
        let plan = QueryPlan {
            entity: Entity::Services,
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
}
