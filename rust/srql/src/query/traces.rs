use super::{BindParam, QueryPlan};
use crate::{
    error::{Result, ServiceError},
    models::TraceSpanRow,
    parser::{Entity, Filter, FilterOp, OrderClause, OrderDirection},
    schema::otel_traces::dsl::{
        end_time_unix_nano as col_end, kind as col_kind, name as col_name, otel_traces,
        parent_span_id as col_parent_span_id, scope_name as col_scope_name,
        scope_version as col_scope_version, service_instance as col_service_instance,
        service_name as col_service_name, service_version as col_service_version,
        span_id as col_span_id, start_time_unix_nano as col_start, status_code as col_status_code,
        status_message as col_status_message, timestamp as col_timestamp, trace_id as col_trace_id,
    },
    time::TimeRange,
};
use diesel::pg::Pg;
use diesel::prelude::*;
use diesel::query_builder::{AsQuery, BoxedSelectStatement, FromClause};
use diesel::PgTextExpressionMethods;
use diesel_async::{AsyncPgConnection, RunQueryDsl};

type TracesTable = crate::schema::otel_traces::table;
type TracesFromClause = FromClause<TracesTable>;
type TracesQuery<'a> =
    BoxedSelectStatement<'a, <TracesTable as AsQuery>::SqlType, TracesFromClause, Pg>;

pub(super) async fn execute(
    conn: &mut AsyncPgConnection,
    plan: &QueryPlan,
) -> Result<Vec<serde_json::Value>> {
    ensure_entity(plan)?;
    let query = build_query(plan)?;
    let rows: Vec<TraceSpanRow> = query
        .limit(plan.limit)
        .offset(plan.offset)
        .load(conn)
        .await
        .map_err(|err| ServiceError::Internal(err.into()))?;

    Ok(rows.into_iter().map(TraceSpanRow::into_json).collect())
}

pub(super) fn to_debug_sql(plan: &QueryPlan) -> Result<String> {
    ensure_entity(plan)?;
    let query = build_query(plan)?;
    Ok(diesel::debug_query::<Pg, _>(&query.limit(plan.limit).offset(plan.offset)).to_string())
}

pub(super) fn to_sql_and_params(plan: &QueryPlan) -> Result<(String, Vec<BindParam>)> {
    ensure_entity(plan)?;
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
        Entity::Traces => Ok(()),
        _ => Err(ServiceError::InvalidRequest(
            "entity not supported by traces query".into(),
        )),
    }
}

fn build_query(plan: &QueryPlan) -> Result<TracesQuery<'static>> {
    let mut query = otel_traces.into_boxed::<Pg>();

    if let Some(TimeRange { start, end }) = &plan.time_range {
        query = query.filter(col_timestamp.ge(*start).and(col_timestamp.le(*end)));
    }

    for filter in &plan.filters {
        query = apply_filter(query, filter)?;
    }

    query = apply_ordering(query, &plan.order);
    Ok(query)
}

fn apply_filter<'a>(mut query: TracesQuery<'a>, filter: &Filter) -> Result<TracesQuery<'a>> {
    match filter.field.as_str() {
        "trace_id" => {
            query = apply_text_filter!(query, filter, col_trace_id)?;
        }
        "span_id" => {
            query = apply_text_filter!(query, filter, col_span_id)?;
        }
        "parent_span_id" => {
            query = apply_text_filter!(query, filter, col_parent_span_id)?;
        }
        "service_name" | "service.name" => {
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
        "name" | "span_name" => {
            query = apply_text_filter!(query, filter, col_name)?;
        }
        "status_message" => {
            query = apply_text_filter!(query, filter, col_status_message)?;
        }
        "status_code" => {
            query = apply_status_code_filter(query, filter)?;
        }
        "kind" | "span_kind" => {
            query = apply_kind_filter(query, filter)?;
        }
        other => {
            return Err(ServiceError::InvalidRequest(format!(
                "unsupported filter field for traces: '{other}'"
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

fn collect_i32_list(params: &mut Vec<BindParam>, filter: &Filter, err: &str) -> Result<()> {
    let values: Vec<i32> = filter
        .value
        .as_list()?
        .iter()
        .map(|v| v.parse::<i32>())
        .collect::<std::result::Result<Vec<_>, _>>()
        .map_err(|_| ServiceError::InvalidRequest(err.into()))?;
    if values.is_empty() {
        return Ok(());
    }
    params.push(BindParam::IntArray(
        values.into_iter().map(i64::from).collect(),
    ));
    Ok(())
}

fn collect_filter_params(params: &mut Vec<BindParam>, filter: &Filter) -> Result<()> {
    match filter.field.as_str() {
        "trace_id" | "span_id" | "parent_span_id" | "service_name" | "service.name"
        | "service_version" | "service_instance" | "scope_name" | "scope_version" | "name"
        | "span_name" | "status_message" => collect_text_params(params, filter),
        "status_code" => match filter.op {
            FilterOp::Eq | FilterOp::NotEq => {
                let value = filter.value.as_scalar()?.parse::<i32>().map_err(|_| {
                    ServiceError::InvalidRequest("status_code must be an integer".into())
                })?;
                params.push(BindParam::Int(i64::from(value)));
                Ok(())
            }
            FilterOp::In | FilterOp::NotIn => {
                collect_i32_list(params, filter, "status_code list must be integers")
            }
            _ => Err(ServiceError::InvalidRequest(
                "status_code filter only supports equality or list comparisons".into(),
            )),
        },
        "kind" | "span_kind" => match filter.op {
            FilterOp::Eq | FilterOp::NotEq => {
                let value = filter.value.as_scalar()?.parse::<i32>().map_err(|_| {
                    ServiceError::InvalidRequest("span kind must be an integer".into())
                })?;
                params.push(BindParam::Int(i64::from(value)));
                Ok(())
            }
            FilterOp::In | FilterOp::NotIn => {
                collect_i32_list(params, filter, "span kind list must be integers")
            }
            _ => Err(ServiceError::InvalidRequest(
                "kind filter only supports equality comparisons".into(),
            )),
        },
        other => Err(ServiceError::InvalidRequest(format!(
            "unsupported filter field for traces: '{other}'"
        ))),
    }
}

fn apply_status_code_filter<'a>(
    mut query: TracesQuery<'a>,
    filter: &Filter,
) -> Result<TracesQuery<'a>> {
    match filter.op {
        FilterOp::Eq | FilterOp::NotEq => {
            let value = filter.value.as_scalar()?.parse::<i32>().map_err(|_| {
                ServiceError::InvalidRequest("status_code must be an integer".into())
            })?;
            query = match filter.op {
                FilterOp::Eq => query.filter(col_status_code.eq(value)),
                FilterOp::NotEq => query.filter(col_status_code.ne(value)),
                _ => unreachable!(),
            };
            Ok(query)
        }
        FilterOp::In | FilterOp::NotIn => {
            let values: Vec<i32> = filter
                .value
                .as_list()?
                .iter()
                .map(|v| v.parse::<i32>())
                .collect::<std::result::Result<Vec<_>, _>>()
                .map_err(|_| {
                    ServiceError::InvalidRequest("status_code list must be integers".into())
                })?;
            if values.is_empty() {
                return Ok(query);
            }
            query = match filter.op {
                FilterOp::In => query.filter(col_status_code.eq_any(values)),
                FilterOp::NotIn => query.filter(col_status_code.ne_all(values)),
                _ => unreachable!(),
            };
            Ok(query)
        }
        _ => Err(ServiceError::InvalidRequest(
            "status_code filter only supports equality or list comparisons".into(),
        )),
    }
}

fn apply_kind_filter<'a>(mut query: TracesQuery<'a>, filter: &Filter) -> Result<TracesQuery<'a>> {
    match filter.op {
        FilterOp::Eq | FilterOp::NotEq => {
            let value =
                filter.value.as_scalar()?.parse::<i32>().map_err(|_| {
                    ServiceError::InvalidRequest("span kind must be an integer".into())
                })?;
            query = match filter.op {
                FilterOp::Eq => query.filter(col_kind.eq(value)),
                FilterOp::NotEq => query.filter(col_kind.ne(value)),
                _ => unreachable!(),
            };
            Ok(query)
        }
        FilterOp::In | FilterOp::NotIn => {
            let values: Vec<i32> = filter
                .value
                .as_list()?
                .iter()
                .map(|v| v.parse::<i32>())
                .collect::<std::result::Result<Vec<_>, _>>()
                .map_err(|_| {
                    ServiceError::InvalidRequest("span kind list must be integers".into())
                })?;
            if values.is_empty() {
                return Ok(query);
            }
            query = match filter.op {
                FilterOp::In => query.filter(col_kind.eq_any(values)),
                FilterOp::NotIn => query.filter(col_kind.ne_all(values)),
                _ => unreachable!(),
            };
            Ok(query)
        }
        _ => Err(ServiceError::InvalidRequest(
            "kind filter only supports equality comparisons".into(),
        )),
    }
}

fn apply_ordering<'a>(mut query: TracesQuery<'a>, order: &[OrderClause]) -> TracesQuery<'a> {
    let mut applied = false;
    for clause in order {
        query = if !applied {
            applied = true;
            match clause.field.as_str() {
                "timestamp" => match clause.direction {
                    OrderDirection::Asc => query.order(col_timestamp.asc()),
                    OrderDirection::Desc => query.order(col_timestamp.desc()),
                },
                "start_time_unix_nano" => match clause.direction {
                    OrderDirection::Asc => query.order(col_start.asc()),
                    OrderDirection::Desc => query.order(col_start.desc()),
                },
                "end_time_unix_nano" => match clause.direction {
                    OrderDirection::Asc => query.order(col_end.asc()),
                    OrderDirection::Desc => query.order(col_end.desc()),
                },
                "service_name" => match clause.direction {
                    OrderDirection::Asc => query.order(col_service_name.asc()),
                    OrderDirection::Desc => query.order(col_service_name.desc()),
                },
                _ => {
                    applied = false;
                    query
                }
            }
        } else {
            match clause.field.as_str() {
                "timestamp" => match clause.direction {
                    OrderDirection::Asc => query.then_order_by(col_timestamp.asc()),
                    OrderDirection::Desc => query.then_order_by(col_timestamp.desc()),
                },
                "start_time_unix_nano" => match clause.direction {
                    OrderDirection::Asc => query.then_order_by(col_start.asc()),
                    OrderDirection::Desc => query.then_order_by(col_start.desc()),
                },
                "end_time_unix_nano" => match clause.direction {
                    OrderDirection::Asc => query.then_order_by(col_end.asc()),
                    OrderDirection::Desc => query.then_order_by(col_end.desc()),
                },
                "service_name" => match clause.direction {
                    OrderDirection::Asc => query.then_order_by(col_service_name.asc()),
                    OrderDirection::Desc => query.then_order_by(col_service_name.desc()),
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
            entity: Entity::Traces,
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
