use super::{BindParam, QueryPlan};
use crate::{
    error::{Result, ServiceError},
    models::EventRow,
    parser::{Entity, Filter, OrderClause, OrderDirection},
    schema::ocsf_events::dsl::{
        activity_id as col_activity_id, activity_name as col_activity_name,
        category_uid as col_category_uid, class_uid as col_class_uid, id as col_id,
        log_level as col_log_level, log_name as col_log_name, log_provider as col_log_provider,
        message as col_message, ocsf_events, severity as col_severity,
        severity_id as col_severity_id, span_id as col_span_id, status as col_status,
        status_code as col_status_code, status_detail as col_status_detail,
        status_id as col_status_id, time as col_time, trace_id as col_trace_id,
        type_uid as col_type_uid,
    },
    time::TimeRange,
};
use diesel::pg::Pg;
use diesel::prelude::*;
use diesel::query_builder::{AsQuery, BoxedSelectStatement, FromClause};
use diesel::PgTextExpressionMethods;
use diesel_async::{AsyncPgConnection, RunQueryDsl};

type EventsTable = crate::schema::ocsf_events::table;
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
        .select(EventRow::as_select())
        .limit(plan.limit)
        .offset(plan.offset)
        .load::<EventRow>(conn)
        .await
        .map_err(|err| ServiceError::Internal(err.into()))?;

    Ok(rows.into_iter().map(EventRow::into_json).collect())
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
    let mut query = ocsf_events.into_boxed::<Pg>();

    if let Some(TimeRange { start, end }) = &plan.time_range {
        query = query.filter(col_time.ge(*start).and(col_time.le(*end)));
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
            query = apply_eq_filter!(
                query,
                filter,
                col_id,
                parse_uuid(filter.value.as_scalar()?)?,
                "id only supports equality comparisons"
            )?;
        }
        "class_uid" => {
            query = apply_eq_filter!(
                query,
                filter,
                col_class_uid,
                parse_i32(filter.value.as_scalar()?)?,
                "class_uid only supports equality comparisons"
            )?;
        }
        "category_uid" => {
            query = apply_eq_filter!(
                query,
                filter,
                col_category_uid,
                parse_i32(filter.value.as_scalar()?)?,
                "category_uid only supports equality comparisons"
            )?;
        }
        "type_uid" => {
            query = apply_eq_filter!(
                query,
                filter,
                col_type_uid,
                parse_i32(filter.value.as_scalar()?)?,
                "type_uid only supports equality comparisons"
            )?;
        }
        "activity_id" => {
            query = apply_eq_filter!(
                query,
                filter,
                col_activity_id,
                parse_i32(filter.value.as_scalar()?)?,
                "activity_id only supports equality comparisons"
            )?;
        }
        "activity_name" => {
            query = apply_text_filter!(query, filter, col_activity_name)?;
        }
        "severity_id" => {
            query = apply_eq_filter!(
                query,
                filter,
                col_severity_id,
                parse_i32(filter.value.as_scalar()?)?,
                "severity_id only supports equality comparisons"
            )?;
        }
        "severity" => {
            query = apply_text_filter!(query, filter, col_severity)?;
        }
        "message" | "short_message" => {
            query = apply_text_filter!(query, filter, col_message)?;
        }
        "log_name" => {
            query = apply_text_filter!(query, filter, col_log_name)?;
        }
        "log_provider" => {
            query = apply_text_filter!(query, filter, col_log_provider)?;
        }
        "log_level" => {
            query = apply_text_filter!(query, filter, col_log_level)?;
        }
        "status_id" => {
            query = apply_eq_filter!(
                query,
                filter,
                col_status_id,
                parse_i32(filter.value.as_scalar()?)?,
                "status_id only supports equality comparisons"
            )?;
        }
        "status" => {
            query = apply_text_filter!(query, filter, col_status)?;
        }
        "status_code" => {
            query = apply_text_filter!(query, filter, col_status_code)?;
        }
        "status_detail" => {
            query = apply_text_filter!(query, filter, col_status_detail)?;
        }
        "trace_id" => {
            query = apply_text_filter!(query, filter, col_trace_id)?;
        }
        "span_id" => {
            query = apply_text_filter!(query, filter, col_span_id)?;
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
        "activity_name" | "severity" | "message" | "short_message" | "log_name"
        | "log_provider" | "log_level" | "status" | "status_code" | "status_detail"
        | "trace_id" | "span_id" => collect_text_params(params, filter),
        "class_uid" | "category_uid" | "type_uid" | "activity_id" | "severity_id" | "status_id" => {
            params.push(BindParam::Int(i64::from(parse_i32(
                filter.value.as_scalar()?,
            )?)));
            Ok(())
        }
        "id" => {
            params.push(BindParam::Uuid(parse_uuid(filter.value.as_scalar()?)?));
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
                "time" | "event_timestamp" | "timestamp" => match clause.direction {
                    OrderDirection::Asc => query.order(col_time.asc()),
                    OrderDirection::Desc => query.order(col_time.desc()),
                },
                _ => query,
            }
        } else {
            match clause.field.as_str() {
                "time" | "event_timestamp" | "timestamp" => match clause.direction {
                    OrderDirection::Asc => query.then_order_by(col_time.asc()),
                    OrderDirection::Desc => query.then_order_by(col_time.desc()),
                },
                _ => query,
            }
        };
    }

    if !applied {
        query = query.order(col_time.desc());
    }

    query
}

fn parse_i32(raw: &str) -> Result<i32> {
    raw.parse::<i32>()
        .map_err(|_| ServiceError::InvalidRequest(format!("invalid integer '{raw}'")))
}

fn parse_uuid(raw: &str) -> Result<uuid::Uuid> {
    uuid::Uuid::parse_str(raw)
        .map_err(|_| ServiceError::InvalidRequest(format!("invalid uuid '{raw}'")))
}
