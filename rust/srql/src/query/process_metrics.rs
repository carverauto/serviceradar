use super::QueryPlan;
use crate::{
    error::{Result, ServiceError},
    models::ProcessMetricRow,
    parser::{Entity, Filter, FilterOp, OrderClause, OrderDirection},
    schema::process_metrics::dsl::{
        agent_id as col_agent_id, cpu_usage as col_cpu_usage, device_id as col_device_id,
        host_id as col_host_id, memory_usage as col_memory_usage, name as col_name,
        partition as col_partition, pid as col_pid, poller_id as col_poller_id, process_metrics,
        start_time as col_start_time, status as col_status, timestamp as col_timestamp,
    },
    time::TimeRange,
};
use diesel::pg::Pg;
use diesel::prelude::*;
use diesel::query_builder::{AsQuery, BoxedSelectStatement, FromClause};
use diesel::PgTextExpressionMethods;
use diesel::QueryDsl;
use diesel_async::{AsyncPgConnection, RunQueryDsl};
use serde_json::Value;

type ProcessTable = crate::schema::process_metrics::table;
type ProcessFromClause = FromClause<ProcessTable>;
type ProcessQuery<'a> =
    BoxedSelectStatement<'a, <ProcessTable as AsQuery>::SqlType, ProcessFromClause, Pg>;

pub(super) async fn execute(conn: &mut AsyncPgConnection, plan: &QueryPlan) -> Result<Vec<Value>> {
    ensure_entity(plan)?;
    let query = build_query(plan)?;
    let rows: Vec<ProcessMetricRow> = query
        .limit(plan.limit)
        .offset(plan.offset)
        .load(conn)
        .await
        .map_err(|err| ServiceError::Internal(err.into()))?;

    Ok(rows.into_iter().map(ProcessMetricRow::into_json).collect())
}

pub(super) fn to_debug_sql(plan: &QueryPlan) -> Result<String> {
    ensure_entity(plan)?;
    let query = build_query(plan)?;
    Ok(diesel::debug_query::<Pg, _>(&query.limit(plan.limit).offset(plan.offset)).to_string())
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

fn apply_filter<'a>(mut query: ProcessQuery<'a>, filter: &Filter) -> Result<ProcessQuery<'a>> {
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

#[cfg(test)]
mod tests {
    use super::*;
    use crate::parser::FilterValue;
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
        };

        let err = build_query(&plan).err().expect("expected error");
        assert!(matches!(err, ServiceError::InvalidRequest(_)));
    }
}
