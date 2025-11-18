use super::QueryPlan;
use crate::{
    error::{Result, ServiceError},
    models::CpuMetricRow,
    parser::{Entity, Filter, FilterOp, OrderClause, OrderDirection},
    schema::cpu_metrics::dsl::{
        agent_id as col_agent_id, cluster as col_cluster, core_id as col_core_id, cpu_metrics,
        device_id as col_device_id, frequency_hz as col_frequency_hz, host_id as col_host_id,
        label as col_label, partition as col_partition, poller_id as col_poller_id,
        timestamp as col_timestamp, usage_percent as col_usage_percent,
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
use diesel::sql_types::{Array, Float8, Int4, Jsonb, Nullable, Text, Timestamptz};
use diesel::PgTextExpressionMethods;
use diesel::QueryDsl;
use diesel_async::{AsyncPgConnection, RunQueryDsl};
use serde_json::Value;

type CpuMetricsTable = crate::schema::cpu_metrics::table;
type CpuMetricsFromClause = FromClause<CpuMetricsTable>;
type CpuQuery<'a> =
    BoxedSelectStatement<'a, <CpuMetricsTable as AsQuery>::SqlType, CpuMetricsFromClause, Pg>;
#[derive(Debug, Clone)]
struct CpuStatsSpec {
    alias: String,
}

#[derive(Debug, Clone)]
struct CpuStatsSql {
    sql: String,
    binds: Vec<SqlBindValue>,
}

#[derive(Debug, Clone)]
enum SqlBindValue {
    Text(String),
    TextArray(Vec<String>),
    Int(i32),
    Float(f64),
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
            SqlBindValue::Int(value) => query.bind::<Int4, _>(*value),
            SqlBindValue::Float(value) => query.bind::<Float8, _>(*value),
            SqlBindValue::Timestamp(value) => query.bind::<Timestamptz, _>(*value),
        }
    }
}

#[derive(QueryableByName)]
struct CpuStatsPayload {
    #[diesel(sql_type = Nullable<Jsonb>)]
    payload: Option<Value>,
}

pub(super) async fn execute(conn: &mut AsyncPgConnection, plan: &QueryPlan) -> Result<Vec<Value>> {
    ensure_entity(plan)?;

    if let Some(spec) = parse_stats_spec(plan.stats.as_deref())? {
        let payload = execute_stats(conn, plan, &spec).await?;
        return Ok(payload);
    }

    let query = build_query(plan)?;
    let rows: Vec<CpuMetricRow> = query
        .limit(plan.limit)
        .offset(plan.offset)
        .load(conn)
        .await
        .map_err(|err| ServiceError::Internal(err.into()))?;

    Ok(rows.into_iter().map(CpuMetricRow::into_json).collect())
}

pub(super) fn to_debug_sql(plan: &QueryPlan) -> Result<String> {
    ensure_entity(plan)?;

    if let Some(spec) = parse_stats_spec(plan.stats.as_deref())? {
        let sql = build_stats_query(plan, &spec)?;
        return Ok(sql.sql);
    }

    let query = build_query(plan)?;
    Ok(diesel::debug_query::<Pg, _>(&query.limit(plan.limit).offset(plan.offset)).to_string())
}

fn ensure_entity(plan: &QueryPlan) -> Result<()> {
    match plan.entity {
        Entity::CpuMetrics => Ok(()),
        _ => Err(ServiceError::InvalidRequest(
            "entity not supported by cpu metrics query".into(),
        )),
    }
}

fn build_query(plan: &QueryPlan) -> Result<CpuQuery<'static>> {
    let mut query = base_query(plan)?;
    query = apply_ordering(query, &plan.order);
    Ok(query)
}

fn base_query(plan: &QueryPlan) -> Result<CpuQuery<'static>> {
    let mut query = cpu_metrics.into_boxed::<Pg>();

    if let Some(TimeRange { start, end }) = &plan.time_range {
        query = query.filter(col_timestamp.ge(*start).and(col_timestamp.le(*end)));
    }

    for filter in &plan.filters {
        query = apply_filter(query, filter)?;
    }

    Ok(query)
}

fn apply_filter<'a>(mut query: CpuQuery<'a>, filter: &Filter) -> Result<CpuQuery<'a>> {
    match filter.field.as_str() {
        "poller_id" => {
            query = apply_text_filter!(query, filter, col_poller_id)?;
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
        "cluster" => {
            query = apply_text_filter!(query, filter, col_cluster)?;
        }
        "label" => {
            query = apply_text_filter!(query, filter, col_label)?;
        }
        "core_id" => {
            let value = parse_i32(filter.value.as_scalar()?)?;
            query = apply_eq_filter!(
                query,
                filter,
                col_core_id,
                value,
                "core_id filter only supports equality"
            )?;
        }
        "usage_percent" => {
            let value = parse_f64(filter.value.as_scalar()?)?;
            query = apply_eq_filter!(
                query,
                filter,
                col_usage_percent,
                value,
                "usage_percent filter only supports equality"
            )?;
        }
        "frequency_hz" => {
            let value = parse_f64(filter.value.as_scalar()?)?;
            query = apply_eq_filter!(
                query,
                filter,
                col_frequency_hz,
                value,
                "frequency_hz filter only supports equality"
            )?;
        }
        _ => {}
    }

    Ok(query)
}

fn apply_ordering<'a>(mut query: CpuQuery<'a>, order: &[OrderClause]) -> CpuQuery<'a> {
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

fn apply_primary_order<'a>(query: CpuQuery<'a>, clause: &OrderClause) -> CpuQuery<'a> {
    match clause.field.as_str() {
        "timestamp" => match clause.direction {
            OrderDirection::Asc => query.order(col_timestamp.asc()),
            OrderDirection::Desc => query.order(col_timestamp.desc()),
        },
        "usage_percent" => match clause.direction {
            OrderDirection::Asc => query.order(col_usage_percent.asc()),
            OrderDirection::Desc => query.order(col_usage_percent.desc()),
        },
        "poller_id" => match clause.direction {
            OrderDirection::Asc => query.order(col_poller_id.asc()),
            OrderDirection::Desc => query.order(col_poller_id.desc()),
        },
        "device_id" => match clause.direction {
            OrderDirection::Asc => query.order(col_device_id.asc()),
            OrderDirection::Desc => query.order(col_device_id.desc()),
        },
        "host_id" => match clause.direction {
            OrderDirection::Asc => query.order(col_host_id.asc()),
            OrderDirection::Desc => query.order(col_host_id.desc()),
        },
        "partition" => match clause.direction {
            OrderDirection::Asc => query.order(col_partition.asc()),
            OrderDirection::Desc => query.order(col_partition.desc()),
        },
        "core_id" => match clause.direction {
            OrderDirection::Asc => query.order(col_core_id.asc()),
            OrderDirection::Desc => query.order(col_core_id.desc()),
        },
        _ => query,
    }
}

fn apply_secondary_order<'a>(query: CpuQuery<'a>, clause: &OrderClause) -> CpuQuery<'a> {
    match clause.field.as_str() {
        "timestamp" => match clause.direction {
            OrderDirection::Asc => diesel::QueryDsl::then_order_by(query, col_timestamp.asc()),
            OrderDirection::Desc => diesel::QueryDsl::then_order_by(query, col_timestamp.desc()),
        },
        "usage_percent" => match clause.direction {
            OrderDirection::Asc => diesel::QueryDsl::then_order_by(query, col_usage_percent.asc()),
            OrderDirection::Desc => {
                diesel::QueryDsl::then_order_by(query, col_usage_percent.desc())
            }
        },
        "poller_id" => match clause.direction {
            OrderDirection::Asc => diesel::QueryDsl::then_order_by(query, col_poller_id.asc()),
            OrderDirection::Desc => diesel::QueryDsl::then_order_by(query, col_poller_id.desc()),
        },
        "device_id" => match clause.direction {
            OrderDirection::Asc => diesel::QueryDsl::then_order_by(query, col_device_id.asc()),
            OrderDirection::Desc => diesel::QueryDsl::then_order_by(query, col_device_id.desc()),
        },
        "host_id" => match clause.direction {
            OrderDirection::Asc => diesel::QueryDsl::then_order_by(query, col_host_id.asc()),
            OrderDirection::Desc => diesel::QueryDsl::then_order_by(query, col_host_id.desc()),
        },
        "partition" => match clause.direction {
            OrderDirection::Asc => diesel::QueryDsl::then_order_by(query, col_partition.asc()),
            OrderDirection::Desc => diesel::QueryDsl::then_order_by(query, col_partition.desc()),
        },
        "core_id" => match clause.direction {
            OrderDirection::Asc => diesel::QueryDsl::then_order_by(query, col_core_id.asc()),
            OrderDirection::Desc => diesel::QueryDsl::then_order_by(query, col_core_id.desc()),
        },
        _ => query,
    }
}

async fn execute_stats(
    conn: &mut AsyncPgConnection,
    plan: &QueryPlan,
    spec: &CpuStatsSpec,
) -> Result<Vec<Value>> {
    let sql = build_stats_query(plan, spec)?;
    let mut query = sql_query(rewrite_placeholders(&sql.sql)).into_boxed::<Pg>();
    for bind in &sql.binds {
        query = bind.apply(query);
    }
    let rows: Vec<CpuStatsPayload> = query
        .load(conn)
        .await
        .map_err(|err| ServiceError::Internal(err.into()))?;
    Ok(rows.into_iter().filter_map(|row| row.payload).collect())
}

fn build_stats_query(plan: &QueryPlan, spec: &CpuStatsSpec) -> Result<CpuStatsSql> {
    let mut clauses = Vec::new();
    let mut binds = Vec::new();

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

    let mut sql = String::from("SELECT jsonb_build_object('device_id', device_id, '");
    sql.push_str(&spec.alias);
    sql.push_str("', AVG(usage_percent)) AS payload\nFROM cpu_metrics");
    if !clauses.is_empty() {
        sql.push_str("\nWHERE ");
        sql.push_str(&clauses.join(" AND "));
    }
    sql.push_str("\nGROUP BY device_id");
    sql.push_str(&build_stats_order_clause(plan, &spec.alias));
    sql.push_str(&format!("\nLIMIT {} OFFSET {}", plan.limit, plan.offset));

    Ok(CpuStatsSql { sql, binds })
}

fn build_stats_order_clause(plan: &QueryPlan, alias: &str) -> String {
    if plan.order.is_empty() {
        return "\nORDER BY AVG(usage_percent) DESC".to_string();
    }

    let mut parts = Vec::new();
    for clause in &plan.order {
        let column = if clause.field.eq_ignore_ascii_case(alias) {
            "AVG(usage_percent)"
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
        "\nORDER BY AVG(usage_percent) DESC".to_string()
    } else {
        format!("\nORDER BY {}", parts.join(", "))
    }
}

fn build_stats_filter_clause(filter: &Filter) -> Result<Option<(String, Vec<SqlBindValue>)>> {
    match filter.field.as_str() {
        "poller_id" => Ok(Some(build_text_clause("poller_id", filter)?)),
        "agent_id" => Ok(Some(build_text_clause("agent_id", filter)?)),
        "host_id" => Ok(Some(build_text_clause("host_id", filter)?)),
        "device_id" => Ok(Some(build_text_clause("device_id", filter)?)),
        "partition" => Ok(Some(build_text_clause("partition", filter)?)),
        "cluster" => Ok(Some(build_text_clause("cluster", filter)?)),
        "label" => Ok(Some(build_text_clause("label", filter)?)),
        "core_id" => Ok(Some(build_numeric_clause("core_id", filter, true)?)),
        "usage_percent" => Ok(Some(build_numeric_clause("usage_percent", filter, false)?)),
        "frequency_hz" => Ok(Some(build_numeric_clause("frequency_hz", filter, false)?)),
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
    };
    Ok((clause, binds))
}

fn build_numeric_clause(
    column: &str,
    filter: &Filter,
    integer: bool,
) -> Result<(String, Vec<SqlBindValue>)> {
    let mut binds = Vec::new();
    let clause = match filter.op {
        FilterOp::Eq => {
            if integer {
                binds.push(SqlBindValue::Int(parse_i32(filter.value.as_scalar()?)?));
            } else {
                binds.push(SqlBindValue::Float(parse_f64(filter.value.as_scalar()?)?));
            }
            format!("{column} = ?")
        }
        FilterOp::NotEq => {
            if integer {
                binds.push(SqlBindValue::Int(parse_i32(filter.value.as_scalar()?)?));
            } else {
                binds.push(SqlBindValue::Float(parse_f64(filter.value.as_scalar()?)?));
            }
            format!("{column} <> ?")
        }
        _ => {
            return Err(ServiceError::InvalidRequest(format!(
                "{column} filter only supports equality comparisons"
            )))
        }
    };

    Ok((clause, binds))
}

fn parse_stats_spec(raw: Option<&str>) -> Result<Option<CpuStatsSpec>> {
    let stats_raw = match raw {
        Some(value) if !value.trim().is_empty() => value.trim(),
        _ => return Ok(None),
    };

    if stats_raw.contains(',') {
        return Err(ServiceError::InvalidRequest(
            "cpu metrics stats only support a single expression".into(),
        ));
    }

    let (expr_segment, group_segment) = split_group_clause(stats_raw).ok_or_else(|| {
        ServiceError::InvalidRequest("stats expression must include 'by device_id'".into())
    })?;

    if !group_segment.eq_ignore_ascii_case("device_id") {
        return Err(ServiceError::InvalidRequest(
            "cpu metrics stats only support grouping by device_id".into(),
        ));
    }

    let (expr, alias_raw) = split_alias(&expr_segment)?;
    let alias = sanitize_alias(alias_raw)?;
    let expr_lower = expr.trim().to_lowercase();

    if !expr_lower.starts_with("avg(") || !expr_lower.ends_with(')') {
        return Err(ServiceError::InvalidRequest(
            "cpu metrics stats only support avg(usage_percent) expressions".into(),
        ));
    }

    let column = expr_lower
        .trim_start_matches("avg(")
        .trim_end_matches(')')
        .trim();

    if column != "usage_percent" {
        return Err(ServiceError::InvalidRequest(
            "cpu metrics stats only support avg(usage_percent)".into(),
        ));
    }

    Ok(Some(CpuStatsSpec { alias }))
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

fn parse_i32(raw: &str) -> Result<i32> {
    raw.parse::<i32>()
        .map_err(|_| ServiceError::InvalidRequest("value must be an integer".into()))
}

fn parse_f64(raw: &str) -> Result<f64> {
    raw.parse::<f64>()
        .map_err(|_| ServiceError::InvalidRequest("value must be numeric".into()))
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
    fn stats_query_matches_cpu_language_reference() {
        let plan = stats_plan(r#"avg(usage_percent) as avg_cpu by device_id"#, "demo-partition");
        let spec = parse_stats_spec(plan.stats.as_deref()).unwrap().unwrap();
        assert_eq!(spec.alias, "avg_cpu");

        let sql = build_stats_query(&plan, &spec).expect("stats SQL should build");
        assert!(
            sql.sql.contains("AVG(usage_percent)")
                && sql.sql.contains("GROUP BY device_id")
                && sql.sql.contains("'avg_cpu'")
                && sql.sql.contains("jsonb_build_object('device_id'"),
            "unexpected stats SQL: {}",
            sql.sql
        );
        assert_eq!(sql.binds.len(), 3, "expected time range + filter binds");
    }

    fn stats_plan(stats: &str, partition: &str) -> QueryPlan {
        let start = Utc.with_ymd_and_hms(2025, 1, 1, 0, 0, 0).unwrap();
        let end = start + ChronoDuration::hours(1);
        QueryPlan {
            entity: Entity::CpuMetrics,
            filters: vec![Filter {
                field: "partition".into(),
                op: FilterOp::Eq,
                value: FilterValue::Scalar(partition.to_string()),
            }],
            order: vec![OrderClause {
                field: "avg_cpu".into(),
                direction: OrderDirection::Desc,
            }],
            limit: 100,
            offset: 0,
            time_range: Some(TimeRange { start, end }),
            stats: Some(stats.to_string()),
        }
    }
}
