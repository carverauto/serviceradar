use super::{BindParam, QueryPlan};
use crate::{
    error::{Result, ServiceError},
    models::AlertRow,
    parser::{Entity, Filter, OrderClause, OrderDirection},
    schema::alerts::dsl::{
        acknowledged_by as col_acknowledged_by, agent_uid as col_agent_uid, alerts,
        comparison as col_comparison, description as col_description, device_uid as col_device_uid,
        escalation_reason as col_escalation_reason, id as col_id, metric_name as col_metric_name,
        resolved_by as col_resolved_by, severity as col_severity, source_id as col_source_id,
        source_type as col_source_type, status as col_status, title as col_title,
        triggered_at as col_triggered_at,
    },
    time::TimeRange,
};
use diesel::pg::Pg;
use diesel::prelude::*;
use diesel::query_builder::{AsQuery, BoxedSelectStatement, FromClause};
use diesel::PgTextExpressionMethods;
use diesel_async::{AsyncPgConnection, RunQueryDsl};
use uuid::Uuid;

type AlertsTable = crate::schema::alerts::table;
type AlertsFromClause = FromClause<AlertsTable>;
type AlertsQuery<'a> =
    BoxedSelectStatement<'a, <AlertsTable as AsQuery>::SqlType, AlertsFromClause, Pg>;

pub(super) async fn execute(
    conn: &mut AsyncPgConnection,
    plan: &QueryPlan,
) -> Result<Vec<serde_json::Value>> {
    ensure_entity(plan)?;
    let query = build_query(plan)?;
    let rows: Vec<AlertRow> = query
        .limit(plan.limit)
        .offset(plan.offset)
        .load(conn)
        .await
        .map_err(|err| ServiceError::Internal(err.into()))?;

    Ok(rows.into_iter().map(AlertRow::into_json).collect())
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
        Entity::Alerts => Ok(()),
        _ => Err(ServiceError::InvalidRequest(
            "entity not supported by alerts query".into(),
        )),
    }
}

fn build_query(plan: &QueryPlan) -> Result<AlertsQuery<'static>> {
    let mut query = alerts.into_boxed::<Pg>();

    // Use triggered_at for time-based filtering (primary timestamp for alerts)
    if let Some(TimeRange { start, end }) = &plan.time_range {
        query = query.filter(col_triggered_at.ge(*start).and(col_triggered_at.le(*end)));
    }

    for filter in &plan.filters {
        query = apply_filter(query, filter)?;
    }

    query = apply_ordering(query, &plan.order);
    Ok(query)
}

fn apply_filter<'a>(mut query: AlertsQuery<'a>, filter: &Filter) -> Result<AlertsQuery<'a>> {
    match filter.field.as_str() {
        "id" => {
            let value = filter.value.as_scalar()?;
            let uuid = Uuid::parse_str(value)
                .map_err(|_| ServiceError::InvalidRequest("id must be a valid UUID".into()))?;
            query = match filter.op {
                crate::parser::FilterOp::Eq => query.filter(col_id.eq(uuid)),
                crate::parser::FilterOp::NotEq => query.filter(col_id.ne(uuid)),
                _ => {
                    return Err(ServiceError::InvalidRequest(
                        "id filter only supports equality comparisons".into(),
                    ))
                }
            };
        }
        "title" => {
            query = apply_text_filter!(query, filter, col_title)?;
        }
        "description" => {
            query = apply_text_filter!(query, filter, col_description)?;
        }
        "severity" => {
            query = apply_text_filter!(query, filter, col_severity)?;
        }
        "status" => {
            query = apply_text_filter!(query, filter, col_status)?;
        }
        "source_type" => {
            query = apply_text_filter!(query, filter, col_source_type)?;
        }
        "source_id" => {
            query = apply_text_filter!(query, filter, col_source_id)?;
        }
        "device_uid" => {
            query = apply_text_filter!(query, filter, col_device_uid)?;
        }
        "agent_uid" => {
            query = apply_text_filter!(query, filter, col_agent_uid)?;
        }
        "metric_name" => {
            query = apply_text_filter!(query, filter, col_metric_name)?;
        }
        "comparison" => {
            query = apply_text_filter!(query, filter, col_comparison)?;
        }
        "acknowledged_by" => {
            query = apply_text_filter!(query, filter, col_acknowledged_by)?;
        }
        "resolved_by" => {
            query = apply_text_filter!(query, filter, col_resolved_by)?;
        }
        "escalation_reason" => {
            query = apply_text_filter!(query, filter, col_escalation_reason)?;
        }
        other => {
            return Err(ServiceError::InvalidRequest(format!(
                "unsupported filter field for alerts: '{other}'"
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
        "id" => {
            let value = filter.value.as_scalar()?;
            let uuid = Uuid::parse_str(value)
                .map_err(|_| ServiceError::InvalidRequest("id must be a valid UUID".into()))?;
            params.push(BindParam::Uuid(uuid));
            Ok(())
        }
        "title" | "description" | "severity" | "status" | "source_type" | "source_id"
        | "device_uid" | "agent_uid" | "metric_name" | "comparison" | "acknowledged_by"
        | "resolved_by" | "escalation_reason" => collect_text_params(params, filter),
        other => Err(ServiceError::InvalidRequest(format!(
            "unsupported filter field for alerts: '{other}'"
        ))),
    }
}

fn apply_ordering<'a>(mut query: AlertsQuery<'a>, order: &[OrderClause]) -> AlertsQuery<'a> {
    let mut applied = false;
    for clause in order {
        query = if !applied {
            applied = true;
            match clause.field.as_str() {
                "triggered_at" | "timestamp" => match clause.direction {
                    OrderDirection::Asc => query.order(col_triggered_at.asc()),
                    OrderDirection::Desc => query.order(col_triggered_at.desc()),
                },
                "severity" => match clause.direction {
                    OrderDirection::Asc => query.order(col_severity.asc()),
                    OrderDirection::Desc => query.order(col_severity.desc()),
                },
                "status" => match clause.direction {
                    OrderDirection::Asc => query.order(col_status.asc()),
                    OrderDirection::Desc => query.order(col_status.desc()),
                },
                "title" => match clause.direction {
                    OrderDirection::Asc => query.order(col_title.asc()),
                    OrderDirection::Desc => query.order(col_title.desc()),
                },
                _ => query,
            }
        } else {
            match clause.field.as_str() {
                "triggered_at" | "timestamp" => match clause.direction {
                    OrderDirection::Asc => query.then_order_by(col_triggered_at.asc()),
                    OrderDirection::Desc => query.then_order_by(col_triggered_at.desc()),
                },
                "severity" => match clause.direction {
                    OrderDirection::Asc => query.then_order_by(col_severity.asc()),
                    OrderDirection::Desc => query.then_order_by(col_severity.desc()),
                },
                "status" => match clause.direction {
                    OrderDirection::Asc => query.then_order_by(col_status.asc()),
                    OrderDirection::Desc => query.then_order_by(col_status.desc()),
                },
                "title" => match clause.direction {
                    OrderDirection::Asc => query.then_order_by(col_title.asc()),
                    OrderDirection::Desc => query.then_order_by(col_title.desc()),
                },
                _ => query,
            }
        };
    }

    // Default ordering: newest alerts first
    if !applied {
        query = query.order(col_triggered_at.desc());
    }

    query
}
