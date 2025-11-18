use super::QueryPlan;
use crate::{
    error::{Result, ServiceError},
    models::PollerRow,
    parser::{Entity, Filter, FilterOp, OrderClause, OrderDirection},
    schema::pollers::dsl::{
        agent_count as col_agent_count, checker_count as col_checker_count,
        component_id as col_component_id, created_by as col_created_by,
        first_registered as col_first_registered, first_seen as col_first_seen,
        is_healthy as col_is_healthy, last_seen as col_last_seen, poller_id as col_poller_id,
        pollers, registration_source as col_registration_source,
        spiffe_identity as col_spiffe_identity, status as col_status, updated_at as col_updated_at,
    },
    time::TimeRange,
};
use diesel::pg::Pg;
use diesel::prelude::*;
use diesel::query_builder::{AsQuery, BoxedSelectStatement, FromClause};
use diesel::PgTextExpressionMethods;
use diesel_async::{AsyncPgConnection, RunQueryDsl};
use serde_json::Value;

type PollersTable = crate::schema::pollers::table;
type PollersFromClause = FromClause<PollersTable>;
type PollersQuery<'a> =
    BoxedSelectStatement<'a, <PollersTable as AsQuery>::SqlType, PollersFromClause, Pg>;

pub(super) async fn execute(conn: &mut AsyncPgConnection, plan: &QueryPlan) -> Result<Vec<Value>> {
    ensure_entity(plan)?;
    let query = build_query(plan)?;
    let rows: Vec<PollerRow> = query
        .limit(plan.limit)
        .offset(plan.offset)
        .load(conn)
        .await
        .map_err(|err| ServiceError::Internal(err.into()))?;

    Ok(rows.into_iter().map(PollerRow::into_json).collect())
}

pub(super) fn to_debug_sql(plan: &QueryPlan) -> Result<String> {
    ensure_entity(plan)?;
    let query = build_query(plan)?;
    Ok(diesel::debug_query::<Pg, _>(&query.limit(plan.limit).offset(plan.offset)).to_string())
}

fn ensure_entity(plan: &QueryPlan) -> Result<()> {
    match plan.entity {
        Entity::Pollers => Ok(()),
        _ => Err(ServiceError::InvalidRequest(
            "entity not supported by pollers query".into(),
        )),
    }
}

fn build_query(plan: &QueryPlan) -> Result<PollersQuery<'static>> {
    let mut query = pollers.into_boxed::<Pg>();

    if let Some(TimeRange { start, end }) = &plan.time_range {
        query = query.filter(col_last_seen.ge(*start).and(col_last_seen.le(*end)));
    }

    for filter in &plan.filters {
        query = apply_filter(query, filter)?;
    }

    query = apply_ordering(query, &plan.order);
    Ok(query)
}

fn apply_filter<'a>(mut query: PollersQuery<'a>, filter: &Filter) -> Result<PollersQuery<'a>> {
    match filter.field.as_str() {
        "poller_id" => {
            query = apply_text_filter!(query, filter, col_poller_id)?;
        }
        "status" => {
            query = apply_text_filter!(query, filter, col_status)?;
        }
        "component_id" => {
            query = apply_text_filter!(query, filter, col_component_id)?;
        }
        "registration_source" => {
            query = apply_text_filter!(query, filter, col_registration_source)?;
        }
        "spiffe_identity" => {
            query = apply_text_filter!(query, filter, col_spiffe_identity)?;
        }
        "created_by" => {
            query = apply_text_filter!(query, filter, col_created_by)?;
        }
        "is_healthy" => {
            let value = parse_bool(filter.value.as_scalar()?)?;
            match filter.op {
                FilterOp::Eq => query = query.filter(col_is_healthy.eq(value)),
                FilterOp::NotEq => query = query.filter(col_is_healthy.ne(value)),
                _ => {
                    return Err(ServiceError::InvalidRequest(
                        "is_healthy filter only supports equality".into(),
                    ))
                }
            }
        }
        _ => {}
    }

    Ok(query)
}

fn apply_ordering<'a>(mut query: PollersQuery<'a>, order: &[OrderClause]) -> PollersQuery<'a> {
    let mut applied = false;
    for clause in order {
        query = if !applied {
            applied = true;
            apply_single_order(query, clause.field.as_str(), clause.direction)
        } else {
            apply_secondary_order(query, clause.field.as_str(), clause.direction)
        };
    }

    if !applied {
        query = query.order(col_last_seen.desc());
    }

    query
}

fn apply_single_order<'a>(
    query: PollersQuery<'a>,
    field: &str,
    direction: OrderDirection,
) -> PollersQuery<'a> {
    match field {
        "last_seen" => match direction {
            OrderDirection::Asc => query.order(col_last_seen.asc()),
            OrderDirection::Desc => query.order(col_last_seen.desc()),
        },
        "first_seen" => match direction {
            OrderDirection::Asc => query.order(col_first_seen.asc()),
            OrderDirection::Desc => query.order(col_first_seen.desc()),
        },
        "first_registered" => match direction {
            OrderDirection::Asc => query.order(col_first_registered.asc()),
            OrderDirection::Desc => query.order(col_first_registered.desc()),
        },
        "poller_id" => match direction {
            OrderDirection::Asc => query.order(col_poller_id.asc()),
            OrderDirection::Desc => query.order(col_poller_id.desc()),
        },
        "status" => match direction {
            OrderDirection::Asc => query.order(col_status.asc()),
            OrderDirection::Desc => query.order(col_status.desc()),
        },
        "agent_count" => match direction {
            OrderDirection::Asc => query.order(col_agent_count.asc()),
            OrderDirection::Desc => query.order(col_agent_count.desc()),
        },
        "checker_count" => match direction {
            OrderDirection::Asc => query.order(col_checker_count.asc()),
            OrderDirection::Desc => query.order(col_checker_count.desc()),
        },
        "updated_at" => match direction {
            OrderDirection::Asc => query.order(col_updated_at.asc()),
            OrderDirection::Desc => query.order(col_updated_at.desc()),
        },
        _ => query,
    }
}

fn apply_secondary_order<'a>(
    query: PollersQuery<'a>,
    field: &str,
    direction: OrderDirection,
) -> PollersQuery<'a> {
    match field {
        "last_seen" => match direction {
            OrderDirection::Asc => query.then_order_by(col_last_seen.asc()),
            OrderDirection::Desc => query.then_order_by(col_last_seen.desc()),
        },
        "first_seen" => match direction {
            OrderDirection::Asc => query.then_order_by(col_first_seen.asc()),
            OrderDirection::Desc => query.then_order_by(col_first_seen.desc()),
        },
        "first_registered" => match direction {
            OrderDirection::Asc => query.then_order_by(col_first_registered.asc()),
            OrderDirection::Desc => query.then_order_by(col_first_registered.desc()),
        },
        "poller_id" => match direction {
            OrderDirection::Asc => query.then_order_by(col_poller_id.asc()),
            OrderDirection::Desc => query.then_order_by(col_poller_id.desc()),
        },
        "status" => match direction {
            OrderDirection::Asc => query.then_order_by(col_status.asc()),
            OrderDirection::Desc => query.then_order_by(col_status.desc()),
        },
        "agent_count" => match direction {
            OrderDirection::Asc => query.then_order_by(col_agent_count.asc()),
            OrderDirection::Desc => query.then_order_by(col_agent_count.desc()),
        },
        "checker_count" => match direction {
            OrderDirection::Asc => query.then_order_by(col_checker_count.asc()),
            OrderDirection::Desc => query.then_order_by(col_checker_count.desc()),
        },
        "updated_at" => match direction {
            OrderDirection::Asc => query.then_order_by(col_updated_at.asc()),
            OrderDirection::Desc => query.then_order_by(col_updated_at.desc()),
        },
        _ => query,
    }
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
