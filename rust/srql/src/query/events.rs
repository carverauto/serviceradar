use super::QueryPlan;
use crate::{
    error::{Result, ServiceError},
    models::EventRow,
    parser::{Entity, Filter, FilterOp, OrderClause, OrderDirection},
    schema::events::dsl::{
        datacontenttype as col_datacontenttype, event_timestamp as col_event_timestamp,
        event_type as col_event_type, events, host as col_host, id as col_id, level as col_level,
        remote_addr as col_remote_addr, severity as col_severity,
        short_message as col_short_message, source as col_source, specversion as col_specversion,
        subject as col_subject, version as col_version,
    },
    time::TimeRange,
};
use diesel::pg::Pg;
use diesel::prelude::*;
use diesel::query_builder::{AsQuery, BoxedSelectStatement, FromClause};
use diesel::PgTextExpressionMethods;
use diesel_async::{AsyncPgConnection, RunQueryDsl};

type EventsTable = crate::schema::events::table;
type EventsFromClause = FromClause<EventsTable>;
type EventsQuery<'a> =
    BoxedSelectStatement<'a, <EventsTable as AsQuery>::SqlType, EventsFromClause, Pg>;

pub(super) async fn execute(
    conn: &mut AsyncPgConnection,
    plan: &QueryPlan,
) -> Result<Vec<serde_json::Value>> {
    ensure_entity(plan)?;
    let query = build_query(plan)?;
    let rows: Vec<EventRow> = query
        .limit(plan.limit)
        .offset(plan.offset)
        .load(conn)
        .await
        .map_err(|err| ServiceError::Internal(err.into()))?;

    Ok(rows.into_iter().map(EventRow::into_json).collect())
}

pub(super) fn to_debug_sql(plan: &QueryPlan) -> Result<String> {
    ensure_entity(plan)?;
    let query = build_query(plan)?;
    Ok(diesel::debug_query::<Pg, _>(&query.limit(plan.limit).offset(plan.offset)).to_string())
}

fn ensure_entity(plan: &QueryPlan) -> Result<()> {
    match plan.entity {
        Entity::Events => Ok(()),
        _ => Err(ServiceError::InvalidRequest(
            "entity not supported by events query".into(),
        )),
    }
}

fn build_query(plan: &QueryPlan) -> Result<EventsQuery<'static>> {
    let mut query = events.into_boxed::<Pg>();

    if let Some(TimeRange { start, end }) = &plan.time_range {
        query = query.filter(
            col_event_timestamp
                .ge(*start)
                .and(col_event_timestamp.le(*end)),
        );
    }

    for filter in &plan.filters {
        query = apply_filter(query, filter)?;
    }

    query = apply_ordering(query, &plan.order);
    Ok(query)
}

fn apply_filter<'a>(mut query: EventsQuery<'a>, filter: &Filter) -> Result<EventsQuery<'a>> {
    match filter.field.as_str() {
        "id" => {
            let value = filter.value.as_scalar()?.to_string();
            query = match filter.op {
                FilterOp::Eq => query.filter(col_id.eq(value)),
                FilterOp::NotEq => query.filter(col_id.ne(value)),
                FilterOp::Like => query.filter(col_id.ilike(value)),
                FilterOp::NotLike => query.filter(col_id.not_ilike(value)),
                FilterOp::In | FilterOp::NotIn => {
                    let values = filter.value.as_list()?.to_vec();
                    if values.is_empty() {
                        return Ok(query);
                    }
                    if matches!(filter.op, FilterOp::In) {
                        query.filter(col_id.eq_any(values))
                    } else {
                        query.filter(col_id.ne_all(values))
                    }
                }
            };
        }
        "type" => {
            let value = filter.value.as_scalar()?.to_string();
            query = match filter.op {
                FilterOp::Eq => query.filter(col_event_type.eq(value)),
                FilterOp::NotEq => query.filter(col_event_type.ne(value)),
                FilterOp::Like => query.filter(col_event_type.ilike(value)),
                FilterOp::NotLike => query.filter(col_event_type.not_ilike(value)),
                FilterOp::In | FilterOp::NotIn => {
                    let values = filter.value.as_list()?.to_vec();
                    if values.is_empty() {
                        return Ok(query);
                    }
                    if matches!(filter.op, FilterOp::In) {
                        query.filter(col_event_type.eq_any(values))
                    } else {
                        query.filter(col_event_type.ne_all(values))
                    }
                }
            };
        }
        "source" => {
            let value = filter.value.as_scalar()?.to_string();
            query = match filter.op {
                FilterOp::Eq => query.filter(col_source.eq(value)),
                FilterOp::NotEq => query.filter(col_source.ne(value)),
                FilterOp::Like => query.filter(col_source.ilike(value)),
                FilterOp::NotLike => query.filter(col_source.not_ilike(value)),
                FilterOp::In | FilterOp::NotIn => {
                    let values = filter.value.as_list()?.to_vec();
                    if values.is_empty() {
                        return Ok(query);
                    }
                    if matches!(filter.op, FilterOp::In) {
                        query.filter(col_source.eq_any(values))
                    } else {
                        query.filter(col_source.ne_all(values))
                    }
                }
            };
        }
        "subject" => {
            let value = filter.value.as_scalar()?.to_string();
            query = match filter.op {
                FilterOp::Eq => query.filter(col_subject.eq(value)),
                FilterOp::NotEq => query.filter(col_subject.ne(value)),
                FilterOp::Like => query.filter(col_subject.ilike(value)),
                FilterOp::NotLike => query.filter(col_subject.not_ilike(value)),
                FilterOp::In | FilterOp::NotIn => {
                    let values = filter.value.as_list()?.to_vec();
                    if values.is_empty() {
                        return Ok(query);
                    }
                    if matches!(filter.op, FilterOp::In) {
                        query.filter(col_subject.eq_any(values))
                    } else {
                        query.filter(col_subject.ne_all(values))
                    }
                }
            };
        }
        "datacontenttype" => {
            let value = filter.value.as_scalar()?.to_string();
            query = match filter.op {
                FilterOp::Eq => query.filter(col_datacontenttype.eq(value)),
                FilterOp::NotEq => query.filter(col_datacontenttype.ne(value)),
                FilterOp::Like => query.filter(col_datacontenttype.ilike(value)),
                FilterOp::NotLike => query.filter(col_datacontenttype.not_ilike(value)),
                FilterOp::In | FilterOp::NotIn => {
                    let values = filter.value.as_list()?.to_vec();
                    if values.is_empty() {
                        return Ok(query);
                    }
                    if matches!(filter.op, FilterOp::In) {
                        query.filter(col_datacontenttype.eq_any(values))
                    } else {
                        query.filter(col_datacontenttype.ne_all(values))
                    }
                }
            };
        }
        "remote_addr" => {
            let value = filter.value.as_scalar()?.to_string();
            query = match filter.op {
                FilterOp::Eq => query.filter(col_remote_addr.eq(value)),
                FilterOp::NotEq => query.filter(col_remote_addr.ne(value)),
                FilterOp::Like => query.filter(col_remote_addr.ilike(value)),
                FilterOp::NotLike => query.filter(col_remote_addr.not_ilike(value)),
                FilterOp::In | FilterOp::NotIn => {
                    let values = filter.value.as_list()?.to_vec();
                    if values.is_empty() {
                        return Ok(query);
                    }
                    if matches!(filter.op, FilterOp::In) {
                        query.filter(col_remote_addr.eq_any(values))
                    } else {
                        query.filter(col_remote_addr.ne_all(values))
                    }
                }
            };
        }
        "host" => {
            let value = filter.value.as_scalar()?.to_string();
            query = match filter.op {
                FilterOp::Eq => query.filter(col_host.eq(value)),
                FilterOp::NotEq => query.filter(col_host.ne(value)),
                FilterOp::Like => query.filter(col_host.ilike(value)),
                FilterOp::NotLike => query.filter(col_host.not_ilike(value)),
                FilterOp::In | FilterOp::NotIn => {
                    let values = filter.value.as_list()?.to_vec();
                    if values.is_empty() {
                        return Ok(query);
                    }
                    if matches!(filter.op, FilterOp::In) {
                        query.filter(col_host.eq_any(values))
                    } else {
                        query.filter(col_host.ne_all(values))
                    }
                }
            };
        }
        "specversion" => {
            let value = filter.value.as_scalar()?.to_string();
            query = match filter.op {
                FilterOp::Eq => query.filter(col_specversion.eq(value)),
                FilterOp::NotEq => query.filter(col_specversion.ne(value)),
                FilterOp::Like => query.filter(col_specversion.ilike(value)),
                FilterOp::NotLike => query.filter(col_specversion.not_ilike(value)),
                FilterOp::In | FilterOp::NotIn => {
                    let values = filter.value.as_list()?.to_vec();
                    if values.is_empty() {
                        return Ok(query);
                    }
                    if matches!(filter.op, FilterOp::In) {
                        query.filter(col_specversion.eq_any(values))
                    } else {
                        query.filter(col_specversion.ne_all(values))
                    }
                }
            };
        }
        "severity" => {
            let value = filter.value.as_scalar()?.to_string();
            query = match filter.op {
                FilterOp::Eq => query.filter(col_severity.eq(value)),
                FilterOp::NotEq => query.filter(col_severity.ne(value)),
                FilterOp::Like => query.filter(col_severity.ilike(value)),
                FilterOp::NotLike => query.filter(col_severity.not_ilike(value)),
                FilterOp::In | FilterOp::NotIn => {
                    let values = filter.value.as_list()?.to_vec();
                    if values.is_empty() {
                        return Ok(query);
                    }
                    if matches!(filter.op, FilterOp::In) {
                        query.filter(col_severity.eq_any(values))
                    } else {
                        query.filter(col_severity.ne_all(values))
                    }
                }
            };
        }
        "short_message" => {
            let value = filter.value.as_scalar()?.to_string();
            query = match filter.op {
                FilterOp::Eq => query.filter(col_short_message.eq(value)),
                FilterOp::NotEq => query.filter(col_short_message.ne(value)),
                FilterOp::Like => query.filter(col_short_message.ilike(value)),
                FilterOp::NotLike => query.filter(col_short_message.not_ilike(value)),
                FilterOp::In | FilterOp::NotIn => {
                    let values = filter.value.as_list()?.to_vec();
                    if values.is_empty() {
                        return Ok(query);
                    }
                    if matches!(filter.op, FilterOp::In) {
                        query.filter(col_short_message.eq_any(values))
                    } else {
                        query.filter(col_short_message.ne_all(values))
                    }
                }
            };
        }
        "version" => {
            let value = filter.value.as_scalar()?.to_string();
            query = match filter.op {
                FilterOp::Eq => query.filter(col_version.eq(value)),
                FilterOp::NotEq => query.filter(col_version.ne(value)),
                FilterOp::Like => query.filter(col_version.ilike(value)),
                FilterOp::NotLike => query.filter(col_version.not_ilike(value)),
                FilterOp::In | FilterOp::NotIn => {
                    let values = filter.value.as_list()?.to_vec();
                    if values.is_empty() {
                        return Ok(query);
                    }
                    if matches!(filter.op, FilterOp::In) {
                        query.filter(col_version.eq_any(values))
                    } else {
                        query.filter(col_version.ne_all(values))
                    }
                }
            };
        }
        "level" => {
            let value = parse_i32(filter.value.as_scalar()?)?;
            query = match filter.op {
                FilterOp::Eq => query.filter(col_level.eq(value)),
                FilterOp::NotEq => query.filter(col_level.ne(value)),
                _ => {
                    return Err(ServiceError::InvalidRequest(
                        "level only supports equality comparisons".into(),
                    ))
                }
            };
        }
        _ => {}
    }

    Ok(query)
}

fn apply_ordering<'a>(mut query: EventsQuery<'a>, order: &[OrderClause]) -> EventsQuery<'a> {
    let mut applied = false;
    for clause in order {
        query = if !applied {
            applied = true;
            match clause.field.as_str() {
                "event_timestamp" | "timestamp" => match clause.direction {
                    OrderDirection::Asc => query.order(col_event_timestamp.asc()),
                    OrderDirection::Desc => query.order(col_event_timestamp.desc()),
                },
                _ => query,
            }
        } else {
            match clause.field.as_str() {
                "event_timestamp" | "timestamp" => match clause.direction {
                    OrderDirection::Asc => query.then_order_by(col_event_timestamp.asc()),
                    OrderDirection::Desc => query.then_order_by(col_event_timestamp.desc()),
                },
                _ => query,
            }
        };
    }

    if !applied {
        query = query.order(col_event_timestamp.desc());
    }

    query
}

fn parse_i32(raw: &str) -> Result<i32> {
    raw.parse::<i32>()
        .map_err(|_| ServiceError::InvalidRequest(format!("invalid integer '{raw}'")))
}
