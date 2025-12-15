use super::{BindParam, QueryPlan};
use crate::{
    error::{Result, ServiceError},
    models::ServiceStatusRow,
    parser::{Entity, Filter, FilterOp, OrderClause, OrderDirection},
    schema::service_status::dsl::{
        agent_id as col_agent_id, available as col_available, message as col_message,
        partition as col_partition, poller_id as col_poller_id, service_name as col_service_name,
        service_status, service_type as col_service_type, timestamp as col_timestamp,
    },
    time::TimeRange,
};
use diesel::pg::Pg;
use diesel::prelude::*;
use diesel::query_builder::{AsQuery, BoxedSelectStatement, FromClause};
use diesel::PgTextExpressionMethods;
use diesel_async::{AsyncPgConnection, RunQueryDsl};

use serde_json::Value;

type ServiceStatusTable = crate::schema::service_status::table;
type ServiceStatusFromClause = FromClause<ServiceStatusTable>;
type ServicesQuery<'a> =
    BoxedSelectStatement<'a, <ServiceStatusTable as AsQuery>::SqlType, ServiceStatusFromClause, Pg>;

pub(super) async fn execute(conn: &mut AsyncPgConnection, plan: &QueryPlan) -> Result<Vec<Value>> {
    ensure_entity(plan)?;
    let query = build_query(plan)?;
    let rows: Vec<ServiceStatusRow> = query
        .limit(plan.limit)
        .offset(plan.offset)
        .load(conn)
        .await
        .map_err(|err| ServiceError::Internal(err.into()))?;

    Ok(rows.into_iter().map(ServiceStatusRow::into_json).collect())
}

pub(super) fn to_debug_sql(plan: &QueryPlan) -> Result<String> {
    ensure_entity(plan)?;
    let query = build_query(plan)?;
    Ok(diesel::debug_query::<Pg, _>(&query.limit(plan.limit).offset(plan.offset)).to_string())
}

pub(super) fn to_sql_and_params(plan: &QueryPlan) -> Result<(String, Vec<BindParam>)> {
    ensure_entity(plan)?;
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

fn apply_filter<'a>(mut query: ServicesQuery<'a>, filter: &Filter) -> Result<ServicesQuery<'a>> {
    match filter.field.as_str() {
        "service_name" | "name" => {
            query = apply_text_filter!(query, filter, col_service_name)?;
        }
        "service_type" | "type" => {
            query = apply_text_filter!(query, filter, col_service_type)?;
        }
        "poller_id" => {
            query = apply_text_filter!(query, filter, col_poller_id)?;
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
        "service_name" | "name" | "service_type" | "type" | "poller_id" | "agent_id"
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
