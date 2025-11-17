use super::QueryPlan;
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
use diesel::pg::Pg;
use diesel::prelude::*;
use diesel::query_builder::{AsQuery, BoxedSelectStatement, FromClause};
use diesel::PgTextExpressionMethods;
use diesel_async::{AsyncPgConnection, RunQueryDsl};

type LogsTable = crate::schema::logs::table;
type LogsFromClause = FromClause<LogsTable>;
type LogsQuery<'a> = BoxedSelectStatement<'a, <LogsTable as AsQuery>::SqlType, LogsFromClause, Pg>;

pub(super) async fn execute(
    conn: &mut AsyncPgConnection,
    plan: &QueryPlan,
) -> Result<Vec<serde_json::Value>> {
    ensure_entity(plan)?;
    let query = build_query(plan)?;
    let rows: Vec<LogRow> = query
        .limit(plan.limit)
        .offset(plan.offset)
        .load(conn)
        .await
        .map_err(|err| ServiceError::Internal(err.into()))?;

    Ok(rows.into_iter().map(LogRow::into_json).collect())
}

pub(super) fn to_debug_sql(plan: &QueryPlan) -> Result<String> {
    ensure_entity(plan)?;
    let query = build_query(plan)?;
    Ok(diesel::debug_query::<Pg, _>(&query.limit(plan.limit).offset(plan.offset)).to_string())
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

fn apply_filter<'a>(mut query: LogsQuery<'a>, filter: &Filter) -> Result<LogsQuery<'a>> {
    match filter.field.as_str() {
        "trace_id" => {
            let value = filter.value.as_scalar()?.to_string();
            query = match filter.op {
                FilterOp::Eq => query.filter(col_trace_id.eq(value)),
                FilterOp::NotEq => query.filter(col_trace_id.ne(value)),
                FilterOp::Like => query.filter(col_trace_id.ilike(value)),
                FilterOp::NotLike => query.filter(col_trace_id.not_ilike(value)),
                FilterOp::In | FilterOp::NotIn => {
                    let values = filter.value.as_list()?.to_vec();
                    if values.is_empty() {
                        return Ok(query);
                    }
                    if matches!(filter.op, FilterOp::In) {
                        query.filter(col_trace_id.eq_any(values))
                    } else {
                        query.filter(col_trace_id.ne_all(values))
                    }
                }
            };
        }
        "span_id" => {
            let value = filter.value.as_scalar()?.to_string();
            query = match filter.op {
                FilterOp::Eq => query.filter(col_span_id.eq(value)),
                FilterOp::NotEq => query.filter(col_span_id.ne(value)),
                FilterOp::Like => query.filter(col_span_id.ilike(value)),
                FilterOp::NotLike => query.filter(col_span_id.not_ilike(value)),
                FilterOp::In | FilterOp::NotIn => {
                    let values = filter.value.as_list()?.to_vec();
                    if values.is_empty() {
                        return Ok(query);
                    }
                    if matches!(filter.op, FilterOp::In) {
                        query.filter(col_span_id.eq_any(values))
                    } else {
                        query.filter(col_span_id.ne_all(values))
                    }
                }
            };
        }
        "service_name" => {
            let value = filter.value.as_scalar()?.to_string();
            query = match filter.op {
                FilterOp::Eq => query.filter(col_service_name.eq(value)),
                FilterOp::NotEq => query.filter(col_service_name.ne(value)),
                FilterOp::Like => query.filter(col_service_name.ilike(value)),
                FilterOp::NotLike => query.filter(col_service_name.not_ilike(value)),
                FilterOp::In | FilterOp::NotIn => {
                    let values = filter.value.as_list()?.to_vec();
                    if values.is_empty() {
                        return Ok(query);
                    }
                    if matches!(filter.op, FilterOp::In) {
                        query.filter(col_service_name.eq_any(values))
                    } else {
                        query.filter(col_service_name.ne_all(values))
                    }
                }
            };
        }
        "service_version" => {
            let value = filter.value.as_scalar()?.to_string();
            query = match filter.op {
                FilterOp::Eq => query.filter(col_service_version.eq(value)),
                FilterOp::NotEq => query.filter(col_service_version.ne(value)),
                FilterOp::Like => query.filter(col_service_version.ilike(value)),
                FilterOp::NotLike => query.filter(col_service_version.not_ilike(value)),
                FilterOp::In | FilterOp::NotIn => {
                    let values = filter.value.as_list()?.to_vec();
                    if values.is_empty() {
                        return Ok(query);
                    }
                    if matches!(filter.op, FilterOp::In) {
                        query.filter(col_service_version.eq_any(values))
                    } else {
                        query.filter(col_service_version.ne_all(values))
                    }
                }
            };
        }
        "service_instance" => {
            let value = filter.value.as_scalar()?.to_string();
            query = match filter.op {
                FilterOp::Eq => query.filter(col_service_instance.eq(value)),
                FilterOp::NotEq => query.filter(col_service_instance.ne(value)),
                FilterOp::Like => query.filter(col_service_instance.ilike(value)),
                FilterOp::NotLike => query.filter(col_service_instance.not_ilike(value)),
                FilterOp::In | FilterOp::NotIn => {
                    let values = filter.value.as_list()?.to_vec();
                    if values.is_empty() {
                        return Ok(query);
                    }
                    if matches!(filter.op, FilterOp::In) {
                        query.filter(col_service_instance.eq_any(values))
                    } else {
                        query.filter(col_service_instance.ne_all(values))
                    }
                }
            };
        }
        "scope_name" => {
            let value = filter.value.as_scalar()?.to_string();
            query = match filter.op {
                FilterOp::Eq => query.filter(col_scope_name.eq(value)),
                FilterOp::NotEq => query.filter(col_scope_name.ne(value)),
                FilterOp::Like => query.filter(col_scope_name.ilike(value)),
                FilterOp::NotLike => query.filter(col_scope_name.not_ilike(value)),
                FilterOp::In | FilterOp::NotIn => {
                    let values = filter.value.as_list()?.to_vec();
                    if values.is_empty() {
                        return Ok(query);
                    }
                    if matches!(filter.op, FilterOp::In) {
                        query.filter(col_scope_name.eq_any(values))
                    } else {
                        query.filter(col_scope_name.ne_all(values))
                    }
                }
            };
        }
        "scope_version" => {
            let value = filter.value.as_scalar()?.to_string();
            query = match filter.op {
                FilterOp::Eq => query.filter(col_scope_version.eq(value)),
                FilterOp::NotEq => query.filter(col_scope_version.ne(value)),
                FilterOp::Like => query.filter(col_scope_version.ilike(value)),
                FilterOp::NotLike => query.filter(col_scope_version.not_ilike(value)),
                FilterOp::In | FilterOp::NotIn => {
                    let values = filter.value.as_list()?.to_vec();
                    if values.is_empty() {
                        return Ok(query);
                    }
                    if matches!(filter.op, FilterOp::In) {
                        query.filter(col_scope_version.eq_any(values))
                    } else {
                        query.filter(col_scope_version.ne_all(values))
                    }
                }
            };
        }
        "severity_text" | "severity" | "level" => {
            let value = filter.value.as_scalar()?.to_string();
            query = match filter.op {
                FilterOp::Eq => query.filter(col_severity_text.eq(value)),
                FilterOp::NotEq => query.filter(col_severity_text.ne(value)),
                FilterOp::Like => query.filter(col_severity_text.ilike(value)),
                FilterOp::NotLike => query.filter(col_severity_text.not_ilike(value)),
                FilterOp::In | FilterOp::NotIn => {
                    let values = filter.value.as_list()?.to_vec();
                    if values.is_empty() {
                        return Ok(query);
                    }
                    if matches!(filter.op, FilterOp::In) {
                        query.filter(col_severity_text.eq_any(values))
                    } else {
                        query.filter(col_severity_text.ne_all(values))
                    }
                }
            };
        }
        "body" => {
            let value = filter.value.as_scalar()?.to_string();
            query = match filter.op {
                FilterOp::Eq => query.filter(col_body.eq(value)),
                FilterOp::NotEq => query.filter(col_body.ne(value)),
                FilterOp::Like => query.filter(col_body.ilike(value)),
                FilterOp::NotLike => query.filter(col_body.not_ilike(value)),
                FilterOp::In | FilterOp::NotIn => {
                    let values = filter.value.as_list()?.to_vec();
                    if values.is_empty() {
                        return Ok(query);
                    }
                    if matches!(filter.op, FilterOp::In) {
                        query.filter(col_body.eq_any(values))
                    } else {
                        query.filter(col_body.ne_all(values))
                    }
                }
            };
        }
        "severity_number" => {
            let value = filter.value.as_scalar()?.parse::<i32>().map_err(|_| {
                ServiceError::InvalidRequest("severity_number must be an integer".into())
            })?;
            query = match filter.op {
                FilterOp::Eq => query.filter(col_severity_number.eq(value)),
                FilterOp::NotEq => query.filter(col_severity_number.ne(value)),
                _ => {
                    return Err(ServiceError::InvalidRequest(
                        "severity_number only supports equality comparisons".into(),
                    ))
                }
            };
        }
        _ => {}
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
