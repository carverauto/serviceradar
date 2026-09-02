use super::{BindParam, QueryPlan};
use crate::{
    error::{Result, ServiceError},
    models::SourceFactDisagreementRow,
    parser::{Entity, Filter, FilterOp, OrderClause, OrderDirection},
    schema::source_fact_disagreements::dsl::{
        configuration_conflict as col_configuration_conflict, device_uid as col_device_uid,
        fact_key as col_fact_key, last_detected_at as col_last_detected_at,
        source_fact_disagreements, status as col_status,
    },
    time::TimeRange,
};
use diesel::PgTextExpressionMethods;
use diesel::pg::Pg;
use diesel::prelude::*;
use diesel::query_builder::{AsQuery, BoxedSelectStatement, FromClause};
use diesel_async::{AsyncPgConnection, RunQueryDsl};
use serde_json::Value;

type DisagreementsTable = crate::schema::source_fact_disagreements::table;
type DisagreementsFromClause = FromClause<DisagreementsTable>;
type DisagreementsQuery<'a> =
    BoxedSelectStatement<'a, <DisagreementsTable as AsQuery>::SqlType, DisagreementsFromClause, Pg>;

pub(super) async fn execute(conn: &mut AsyncPgConnection, plan: &QueryPlan) -> Result<Vec<Value>> {
    ensure_entity(plan)?;
    let query = build_query(plan)?;
    let rows: Vec<SourceFactDisagreementRow> = query
        .select(SourceFactDisagreementRow::as_select())
        .limit(plan.limit)
        .offset(plan.offset)
        .load::<SourceFactDisagreementRow>(conn)
        .await
        .map_err(|err| ServiceError::Internal(err.into()))?;

    Ok(rows
        .into_iter()
        .map(SourceFactDisagreementRow::into_json)
        .collect())
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
    Ok((sql, params))
}

fn ensure_entity(plan: &QueryPlan) -> Result<()> {
    match plan.entity {
        Entity::SourceFactDisagreements => Ok(()),
        _ => Err(ServiceError::InvalidRequest(
            "entity not supported by source_fact_disagreements query".into(),
        )),
    }
}

fn build_query(plan: &QueryPlan) -> Result<DisagreementsQuery<'static>> {
    let mut query = source_fact_disagreements.into_boxed::<Pg>();

    if let Some(TimeRange { start, end }) = &plan.time_range {
        query = query.filter(
            col_last_detected_at
                .ge(*start)
                .and(col_last_detected_at.le(*end)),
        );
    }

    for filter in &plan.filters {
        query = apply_filter(query, filter)?;
    }

    query = apply_ordering(query, &plan.order);
    Ok(query)
}

fn apply_filter<'a>(
    mut query: DisagreementsQuery<'a>,
    filter: &Filter,
) -> Result<DisagreementsQuery<'a>> {
    match filter.field.as_str() {
        "device_uid" | "device" => {
            query = apply_text_filter!(query, filter, col_device_uid)?;
        }
        "fact_key" => {
            query = apply_text_filter!(query, filter, col_fact_key)?;
        }
        "status" => {
            query = apply_text_filter!(query, filter, col_status)?;
        }
        "configuration_conflict" => {
            let value = filter.value.as_scalar()?.eq_ignore_ascii_case("true")
                || filter.value.as_scalar()? == "1";
            query = match filter.op {
                FilterOp::Eq => query.filter(col_configuration_conflict.eq(value)),
                FilterOp::NotEq => query.filter(col_configuration_conflict.ne(value)),
                _ => {
                    return Err(ServiceError::InvalidRequest(
                        "configuration_conflict only supports equality".into(),
                    ));
                }
            };
        }
        other => {
            return Err(ServiceError::InvalidRequest(format!(
                "unsupported filter field for source_fact_disagreements: '{other}'"
            )));
        }
    }

    Ok(query)
}

fn collect_filter_params(params: &mut Vec<BindParam>, filter: &Filter) -> Result<()> {
    match filter.field.as_str() {
        "device_uid" | "device" | "fact_key" | "status" => collect_text_params(params, filter),
        "configuration_conflict" => {
            let value = filter.value.as_scalar()?.eq_ignore_ascii_case("true")
                || filter.value.as_scalar()? == "1";
            params.push(BindParam::Bool(value));
            Ok(())
        }
        other => Err(ServiceError::InvalidRequest(format!(
            "unsupported filter field '{other}'"
        ))),
    }
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

fn apply_ordering<'a>(
    mut query: DisagreementsQuery<'a>,
    order: &[OrderClause],
) -> DisagreementsQuery<'a> {
    let mut applied = false;
    for clause in order {
        query = apply_single_order(query, clause.field.as_str(), clause.direction);
        applied = true;
    }

    if !applied {
        query = query.order(col_last_detected_at.desc());
    }

    query
}

fn apply_single_order<'a>(
    query: DisagreementsQuery<'a>,
    field: &str,
    direction: OrderDirection,
) -> DisagreementsQuery<'a> {
    match field {
        "last_detected_at" => match direction {
            OrderDirection::Asc => query.order(col_last_detected_at.asc()),
            OrderDirection::Desc => query.order(col_last_detected_at.desc()),
        },
        "fact_key" => match direction {
            OrderDirection::Asc => query.order(col_fact_key.asc()),
            OrderDirection::Desc => query.order(col_fact_key.desc()),
        },
        "status" => match direction {
            OrderDirection::Asc => query.order(col_status.asc()),
            OrderDirection::Desc => query.order(col_status.desc()),
        },
        _ => query,
    }
}
