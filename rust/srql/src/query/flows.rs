//! Query execution for OCSF network_activity (flows) entity.

use super::{BindParam, QueryPlan};
use crate::{
    error::{Result, ServiceError},
    parser::{Entity, Filter, FilterOp, OrderClause, OrderDirection},
    schema::ocsf_network_activity::dsl::*,
    time::TimeRange,
};
use diesel::pg::Pg;
use diesel::prelude::*;
use diesel::query_builder::{AsQuery, BoxedSelectStatement, FromClause};
use diesel::PgTextExpressionMethods;
use diesel_async::{AsyncPgConnection, RunQueryDsl};
use serde::{Deserialize, Serialize};
use serde_json::Value;

type FlowsTable = crate::schema::ocsf_network_activity::table;
type FlowsFromClause = FromClause<FlowsTable>;
type FlowsQuery<'a> =
    BoxedSelectStatement<'a, <FlowsTable as AsQuery>::SqlType, FlowsFromClause, Pg>;

#[derive(Queryable, Selectable, Serialize, Deserialize)]
#[diesel(table_name = crate::schema::ocsf_network_activity)]
struct FlowRow {
    time: chrono::NaiveDateTime,
    class_uid: i32,
    category_uid: i32,
    activity_id: i32,
    type_uid: i32,
    severity_id: i32,
    start_time: Option<chrono::NaiveDateTime>,
    end_time: Option<chrono::NaiveDateTime>,
    src_endpoint_ip: Option<String>,
    src_endpoint_port: Option<i32>,
    src_as_number: Option<i32>,
    dst_endpoint_ip: Option<String>,
    dst_endpoint_port: Option<i32>,
    dst_as_number: Option<i32>,
    protocol_num: Option<i32>,
    protocol_name: Option<String>,
    tcp_flags: Option<i32>,
    bytes_total: i64,
    packets_total: i64,
    bytes_in: i64,
    bytes_out: i64,
    sampler_address: Option<String>,
    ocsf_payload: Value,
    partition: Option<String>,
    created_at: chrono::NaiveDateTime,
}

impl FlowRow {
    fn into_json(self) -> Value {
        serde_json::to_value(self).unwrap_or(Value::Null)
    }
}

pub(super) async fn execute(conn: &mut AsyncPgConnection, plan: &QueryPlan) -> Result<Vec<Value>> {
    ensure_entity(plan)?;

    // Handle stats aggregation queries separately
    if plan.stats.is_some() {
        return execute_stats(conn, plan).await;
    }

    let query = build_query(plan)?;
    let rows: Vec<FlowRow> = query
        .limit(plan.limit)
        .offset(plan.offset)
        .load(conn)
        .await
        .map_err(|err| ServiceError::Internal(err.into()))?;

    Ok(rows.into_iter().map(FlowRow::into_json).collect())
}

pub(super) fn to_sql_and_params(plan: &QueryPlan) -> Result<(String, Vec<BindParam>)> {
    ensure_entity(plan)?;

    // Handle stats aggregation queries separately
    if plan.stats.is_some() {
        return to_sql_and_params_stats(plan);
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
        Entity::Flows => Ok(()),
        _ => Err(ServiceError::InvalidRequest(
            "entity not supported by flows query".into(),
        )),
    }
}

fn build_query(plan: &QueryPlan) -> Result<FlowsQuery<'static>> {
    let mut query = ocsf_network_activity.into_boxed::<Pg>();

    // Apply time filter
    if let Some(TimeRange { start, end }) = &plan.time_range {
        query = query.filter(time.ge(start.naive_utc()).and(time.le(end.naive_utc())));
    }

    // Apply filters
    for filter in &plan.filters {
        query = apply_filter(query, filter)?;
    }

    // Apply ordering
    query = apply_ordering(query, &plan.order);

    Ok(query)
}

fn apply_filter<'a>(mut query: FlowsQuery<'a>, filter: &Filter) -> Result<FlowsQuery<'a>> {
    match filter.field.as_str() {
        "src_endpoint_ip" | "src_ip" => {
            query = apply_text_filter!(query, filter, src_endpoint_ip)?;
        }
        "dst_endpoint_ip" | "dst_ip" => {
            query = apply_text_filter!(query, filter, dst_endpoint_ip)?;
        }
        "protocol_name" => {
            query = apply_text_filter!(query, filter, protocol_name)?;
        }
        "sampler_address" => {
            query = apply_text_filter!(query, filter, sampler_address)?;
        }
        "protocol_num" | "proto" => {
            let value = filter
                .value
                .as_scalar()?
                .parse::<i32>()
                .map_err(|_| ServiceError::InvalidRequest("protocol_num must be an integer".into()))?;
            query = apply_eq_filter!(
                query,
                filter,
                protocol_num,
                value,
                "protocol_num filter only supports equality"
            )?;
        }
        "src_port" | "src_endpoint_port" => {
            let value = filter
                .value
                .as_scalar()?
                .parse::<i32>()
                .map_err(|_| ServiceError::InvalidRequest("src_port must be an integer".into()))?;
            query = apply_eq_filter!(
                query,
                filter,
                src_endpoint_port,
                value,
                "src_port filter only supports equality"
            )?;
        }
        "dst_port" | "dst_endpoint_port" => {
            let value = filter
                .value
                .as_scalar()?
                .parse::<i32>()
                .map_err(|_| ServiceError::InvalidRequest("dst_port must be an integer".into()))?;
            query = apply_eq_filter!(
                query,
                filter,
                dst_endpoint_port,
                value,
                "dst_port filter only supports equality"
            )?;
        }
        other => {
            return Err(ServiceError::InvalidRequest(format!(
                "unsupported filter field for flows: '{other}'"
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
        "src_endpoint_ip" | "src_ip" | "dst_endpoint_ip" | "dst_ip" | "protocol_name" | "sampler_address" => {
            collect_text_params(params, filter)
        }
        "protocol_num" | "proto" | "src_port" | "src_endpoint_port" | "dst_port" | "dst_endpoint_port" => {
            let value = filter
                .value
                .as_scalar()?
                .parse::<i32>()
                .map_err(|_| ServiceError::InvalidRequest(format!("{} must be an integer", filter.field)))?;
            params.push(BindParam::Int(value as i64));
            Ok(())
        }
        other => Err(ServiceError::InvalidRequest(format!(
            "unsupported filter field '{other}'"
        ))),
    }
}

fn apply_ordering<'a>(mut query: FlowsQuery<'a>, order: &[OrderClause]) -> FlowsQuery<'a> {
    let mut applied = false;
    for clause in order {
        query = if !applied {
            applied = true;
            apply_single_order(query, clause.field.as_str(), clause.direction)
        } else {
            apply_secondary_order(query, clause.field.as_str(), clause.direction)
        };
    }

    // Default ordering by time descending
    if !applied {
        query = query.order(time.desc());
    }

    query
}

fn apply_single_order<'a>(
    query: FlowsQuery<'a>,
    field: &str,
    direction: OrderDirection,
) -> FlowsQuery<'a> {
    match field {
        "time" => match direction {
            OrderDirection::Asc => query.order(time.asc()),
            OrderDirection::Desc => query.order(time.desc()),
        },
        "bytes_total" => match direction {
            OrderDirection::Asc => query.order(bytes_total.asc()),
            OrderDirection::Desc => query.order(bytes_total.desc()),
        },
        "packets_total" => match direction {
            OrderDirection::Asc => query.order(packets_total.asc()),
            OrderDirection::Desc => query.order(packets_total.desc()),
        },
        "bytes_in" => match direction {
            OrderDirection::Asc => query.order(bytes_in.asc()),
            OrderDirection::Desc => query.order(bytes_in.desc()),
        },
        "bytes_out" => match direction {
            OrderDirection::Asc => query.order(bytes_out.asc()),
            OrderDirection::Desc => query.order(bytes_out.desc()),
        },
        _ => query,
    }
}

fn apply_secondary_order<'a>(
    query: FlowsQuery<'a>,
    field: &str,
    direction: OrderDirection,
) -> FlowsQuery<'a> {
    match field {
        "time" => match direction {
            OrderDirection::Asc => query.then_order_by(time.asc()),
            OrderDirection::Desc => query.then_order_by(time.desc()),
        },
        "bytes_total" => match direction {
            OrderDirection::Asc => query.then_order_by(bytes_total.asc()),
            OrderDirection::Desc => query.then_order_by(bytes_total.desc()),
        },
        "packets_total" => match direction {
            OrderDirection::Asc => query.then_order_by(packets_total.asc()),
            OrderDirection::Desc => query.then_order_by(packets_total.desc()),
        },
        "bytes_in" => match direction {
            OrderDirection::Asc => query.then_order_by(bytes_in.asc()),
            OrderDirection::Desc => query.then_order_by(bytes_in.desc()),
        },
        "bytes_out" => match direction {
            OrderDirection::Asc => query.then_order_by(bytes_out.asc()),
            OrderDirection::Desc => query.then_order_by(bytes_out.desc()),
        },
        _ => query,
    }
}

// Stats aggregation support
async fn execute_stats(conn: &mut AsyncPgConnection, plan: &QueryPlan) -> Result<Vec<Value>> {
    let (sql, params) = to_sql_and_params_stats(plan)?;

    // Execute raw SQL query
    use diesel::sql_types::Text;

    #[derive(QueryableByName)]
    struct StatsRow {
        #[diesel(sql_type = Text)]
        result: String,
    }

    let rows: Vec<StatsRow> = diesel::sql_query(sql)
        .load(conn)
        .await
        .map_err(|err| ServiceError::Internal(err.into()))?;

    Ok(rows
        .into_iter()
        .map(|row| serde_json::from_str(&row.result).unwrap_or(Value::Null))
        .collect())
}

fn to_sql_and_params_stats(plan: &QueryPlan) -> Result<(String, Vec<BindParam>)> {
    let stats_expr = plan.stats.as_ref().ok_or_else(|| {
        ServiceError::InvalidRequest("stats expression required for aggregation".into())
    })?;

    // Parse stats expression: "sum(bytes_total) as total_bytes by src_endpoint_ip"
    let (agg_func, field, alias, group_by) = parse_stats_expr(stats_expr)?;

    // Build SQL query wrapped in jsonb_build_object to return as JSON
    let mut sql = String::from("SELECT jsonb_build_object(");

    if let Some(gb) = group_by {
        sql.push_str(&format!("'{}', {}, ", gb, gb));
    }

    sql.push_str(&format!("'{}', {}({})) as result", alias, agg_func.to_uppercase(), field));
    sql.push_str(" FROM ocsf_network_activity");

    let mut params = Vec::new();

    // Add WHERE clause for time filter
    if let Some(TimeRange { start, end }) = &plan.time_range {
        sql.push_str(" WHERE time >= $1 AND time <= $2");
        params.push(BindParam::timestamptz(*start));
        params.push(BindParam::timestamptz(*end));
    }

    // Add GROUP BY
    if let Some(gb) = group_by {
        sql.push_str(&format!(" GROUP BY {}", gb));
    }

    // Add ORDER BY
    if !plan.order.is_empty() {
        sql.push_str(" ORDER BY ");
        let order_parts: Vec<String> = plan
            .order
            .iter()
            .map(|o| {
                format!(
                    "{} {}",
                    o.field,
                    if matches!(o.direction, OrderDirection::Asc) {
                        "ASC"
                    } else {
                        "DESC"
                    }
                )
            })
            .collect();
        sql.push_str(&order_parts.join(", "));
    }

    // Add LIMIT
    sql.push_str(&format!(" LIMIT {}", plan.limit));

    Ok((sql, params))
}

fn parse_stats_expr(expr: &str) -> Result<(&str, &str, &str, Option<&str>)> {
    // Parse: "sum(bytes_total) as total_bytes by src_endpoint_ip"
    let parts: Vec<&str> = expr.split_whitespace().collect();

    if parts.len() < 3 {
        return Err(ServiceError::InvalidRequest(
            "stats expression must be like: sum(bytes_total) as total_bytes".into(),
        ));
    }

    // Extract function and field: sum(bytes_total)
    let func_part = parts[0];
    let (agg_func, field) = if let Some(open) = func_part.find('(') {
        if let Some(close) = func_part.find(')') {
            let func = &func_part[..open];
            let fld = &func_part[open + 1..close];
            (func, fld)
        } else {
            return Err(ServiceError::InvalidRequest("invalid stats expression".into()));
        }
    } else {
        return Err(ServiceError::InvalidRequest("invalid stats expression".into()));
    };

    // Extract alias
    let alias_idx = parts.iter().position(|&p| p == "as").ok_or_else(|| {
        ServiceError::InvalidRequest("stats expression must include 'as alias'".into())
    })?;

    if alias_idx + 1 >= parts.len() {
        return Err(ServiceError::InvalidRequest(
            "stats expression missing alias after 'as'".into(),
        ));
    }

    let alias = parts[alias_idx + 1];

    // Extract group by field
    let group_by = if let Some(by_idx) = parts.iter().position(|&p| p == "by") {
        if by_idx + 1 < parts.len() {
            Some(parts[by_idx + 1])
        } else {
            None
        }
    } else {
        None
    };

    Ok((agg_func, field, alias, group_by))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::parser::{Entity, Filter, FilterOp, FilterValue};
    use chrono::{Duration as ChronoDuration, TimeZone, Utc};

    #[test]
    fn test_parse_stats_expr() {
        let expr = "sum(bytes_total) as total_bytes by src_endpoint_ip";
        let (func, field, alias, group_by) = parse_stats_expr(expr).unwrap();
        assert_eq!(func, "sum");
        assert_eq!(field, "bytes_total");
        assert_eq!(alias, "total_bytes");
        assert_eq!(group_by, Some("src_endpoint_ip"));
    }

    #[test]
    fn test_parse_stats_expr_no_groupby() {
        let expr = "count(*) as total_flows";
        let (func, field, alias, group_by) = parse_stats_expr(expr).unwrap();
        assert_eq!(func, "count");
        assert_eq!(field, "*");
        assert_eq!(alias, "total_flows");
        assert_eq!(group_by, None);
    }

    #[test]
    fn unknown_filter_field_returns_error() {
        let start = Utc.with_ymd_and_hms(2025, 1, 1, 0, 0, 0).unwrap();
        let end = start + ChronoDuration::hours(1);
        let plan = QueryPlan {
            entity: Entity::Flows,
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
    fn builds_query_with_ip_filter() {
        let plan = QueryPlan {
            entity: Entity::Flows,
            filters: vec![Filter {
                field: "src_ip".into(),
                op: FilterOp::Eq,
                value: FilterValue::Scalar("10.0.0.1".to_string()),
            }],
            order: Vec::new(),
            limit: 50,
            offset: 0,
            time_range: None,
            stats: None,
            downsample: None,
            rollup_stats: None,
        };

        let result = build_query(&plan);
        assert!(result.is_ok(), "should build query with IP filter");
    }

    #[test]
    fn builds_query_with_port_filter() {
        let plan = QueryPlan {
            entity: Entity::Flows,
            filters: vec![Filter {
                field: "dst_port".into(),
                op: FilterOp::Eq,
                value: FilterValue::Scalar("443".to_string()),
            }],
            order: Vec::new(),
            limit: 50,
            offset: 0,
            time_range: None,
            stats: None,
            downsample: None,
            rollup_stats: None,
        };

        let result = build_query(&plan);
        assert!(result.is_ok(), "should build query with port filter");
    }
}
