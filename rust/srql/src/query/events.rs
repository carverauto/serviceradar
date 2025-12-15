use super::{BindParam, QueryPlan};
use crate::{
    error::{Result, ServiceError},
    models::EventRow,
    parser::{Entity, Filter, OrderClause, OrderDirection},
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
            query = apply_text_filter!(query, filter, col_id)?;
        }
        "type" => {
            query = apply_text_filter!(query, filter, col_event_type)?;
        }
        "source" => {
            query = apply_text_filter!(query, filter, col_source)?;
        }
        "subject" => {
            query = apply_text_filter!(query, filter, col_subject)?;
        }
        "datacontenttype" => {
            query = apply_text_filter!(query, filter, col_datacontenttype)?;
        }
        "remote_addr" => {
            query = apply_text_filter!(query, filter, col_remote_addr)?;
        }
        "host" => {
            query = apply_text_filter!(query, filter, col_host)?;
        }
        "specversion" => {
            query = apply_text_filter!(query, filter, col_specversion)?;
        }
        "severity" => {
            query = apply_text_filter!(query, filter, col_severity)?;
        }
        "short_message" => {
            query = apply_text_filter!(query, filter, col_short_message)?;
        }
        "version" => {
            query = apply_text_filter!(query, filter, col_version)?;
        }
        "level" => {
            query = apply_eq_filter!(
                query,
                filter,
                col_level,
                parse_i32(filter.value.as_scalar()?)?,
                "level only supports equality comparisons"
            )?;
        }
        other => {
            return Err(ServiceError::InvalidRequest(format!(
                "unsupported filter field for events: '{other}'"
            )));
        }
    }

    Ok(query)
}

fn collect_text_params(params: &mut Vec<BindParam>, filter: &Filter) -> Result<()> {
    match filter.op {
        crate::parser::FilterOp::Eq
        | crate::parser::FilterOp::NotEq
        | crate::parser::FilterOp::Like
        | crate::parser::FilterOp::NotLike => {
            params.push(BindParam::Text(filter.value.as_scalar()?.to_string()));
            Ok(())
        }
        crate::parser::FilterOp::In | crate::parser::FilterOp::NotIn => {
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
        "id" | "type" | "source" | "subject" | "datacontenttype" | "remote_addr" | "host"
        | "specversion" | "severity" | "short_message" | "version" => {
            collect_text_params(params, filter)
        }
        "level" => {
            params.push(BindParam::Int(i64::from(parse_i32(
                filter.value.as_scalar()?,
            )?)));
            Ok(())
        }
        other => Err(ServiceError::InvalidRequest(format!(
            "unsupported filter field for events: '{other}'"
        ))),
    }
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
