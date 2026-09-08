//! Query execution for the per-agent native add-on status entity (issue 3425).

use super::{BindParam, QueryPlan};
use crate::{
    error::{Result, ServiceError},
    models::AddonStatusRow,
    parser::{Entity, Filter, FilterOp, OrderClause, OrderDirection},
    schema::addon_statuses::dsl::{
        addon_id as col_addon_id, addon_statuses, agent_uid as col_agent_uid, arch as col_arch,
        last_health_at as col_last_health_at, reported_at as col_reported_at, state as col_state,
        version as col_version,
    },
    time::TimeRange,
};
use diesel::PgTextExpressionMethods;
use diesel::pg::Pg;
use diesel::prelude::*;
use diesel::query_builder::{AsQuery, BoxedSelectStatement, FromClause};
use diesel_async::{AsyncPgConnection, RunQueryDsl};
use serde_json::Value;

type AddonStatusesTable = crate::schema::addon_statuses::table;
type AddonStatusesFromClause = FromClause<AddonStatusesTable>;
type AddonStatusesQuery<'a> =
    BoxedSelectStatement<'a, <AddonStatusesTable as AsQuery>::SqlType, AddonStatusesFromClause, Pg>;

pub(super) async fn execute(conn: &mut AsyncPgConnection, plan: &QueryPlan) -> Result<Vec<Value>> {
    ensure_entity(plan)?;
    let query = build_query(plan)?;
    let rows: Vec<AddonStatusRow> = query
        .select(AddonStatusRow::as_select())
        .limit(plan.limit)
        .offset(plan.offset)
        .load::<AddonStatusRow>(conn)
        .await
        .map_err(|err| ServiceError::Internal(err.into()))?;

    Ok(rows.into_iter().map(AddonStatusRow::into_json).collect())
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
        Entity::AddonStatuses => Ok(()),
        _ => Err(ServiceError::InvalidRequest(
            "entity not supported by addon_statuses query".into(),
        )),
    }
}

fn build_query(plan: &QueryPlan) -> Result<AddonStatusesQuery<'static>> {
    let mut query = addon_statuses.into_boxed::<Pg>();

    if let Some(TimeRange { start, end }) = &plan.time_range {
        query = query.filter(col_reported_at.ge(*start).and(col_reported_at.le(*end)));
    }

    for filter in &plan.filters {
        query = apply_filter(query, filter)?;
    }

    query = apply_ordering(query, &plan.order);
    Ok(query)
}

fn apply_filter<'a>(
    mut query: AddonStatusesQuery<'a>,
    filter: &Filter,
) -> Result<AddonStatusesQuery<'a>> {
    match filter.field.as_str() {
        "agent_uid" => {
            query = apply_text_filter!(query, filter, col_agent_uid)?;
        }
        "addon_id" => {
            query = apply_text_filter!(query, filter, col_addon_id)?;
        }
        "state" => {
            query = apply_text_filter!(query, filter, col_state)?;
        }
        "version" => {
            query = apply_text_filter!(query, filter, col_version)?;
        }
        "arch" => {
            query = apply_text_filter!(query, filter, col_arch)?;
        }
        other => {
            return Err(ServiceError::InvalidRequest(format!(
                "unsupported filter field for addon_statuses: '{other}'"
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
        "agent_uid" | "addon_id" | "state" | "version" | "arch" => {
            collect_text_params(params, filter)
        }
        other => Err(ServiceError::InvalidRequest(format!(
            "unsupported filter field '{other}'"
        ))),
    }
}

fn apply_ordering<'a>(
    mut query: AddonStatusesQuery<'a>,
    order: &[OrderClause],
) -> AddonStatusesQuery<'a> {
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
        query = query.order(col_reported_at.desc());
    }

    query
}

fn apply_single_order<'a>(
    query: AddonStatusesQuery<'a>,
    field: &str,
    direction: OrderDirection,
) -> AddonStatusesQuery<'a> {
    match field {
        "reported_at" => match direction {
            OrderDirection::Asc => query.order(col_reported_at.asc()),
            OrderDirection::Desc => query.order(col_reported_at.desc()),
        },
        "last_health_at" => match direction {
            OrderDirection::Asc => query.order(col_last_health_at.asc()),
            OrderDirection::Desc => query.order(col_last_health_at.desc()),
        },
        "agent_uid" => match direction {
            OrderDirection::Asc => query.order(col_agent_uid.asc()),
            OrderDirection::Desc => query.order(col_agent_uid.desc()),
        },
        "addon_id" => match direction {
            OrderDirection::Asc => query.order(col_addon_id.asc()),
            OrderDirection::Desc => query.order(col_addon_id.desc()),
        },
        "state" => match direction {
            OrderDirection::Asc => query.order(col_state.asc()),
            OrderDirection::Desc => query.order(col_state.desc()),
        },
        _ => query,
    }
}

fn apply_secondary_order<'a>(
    query: AddonStatusesQuery<'a>,
    field: &str,
    direction: OrderDirection,
) -> AddonStatusesQuery<'a> {
    match field {
        "reported_at" => match direction {
            OrderDirection::Asc => query.then_order_by(col_reported_at.asc()),
            OrderDirection::Desc => query.then_order_by(col_reported_at.desc()),
        },
        "last_health_at" => match direction {
            OrderDirection::Asc => query.then_order_by(col_last_health_at.asc()),
            OrderDirection::Desc => query.then_order_by(col_last_health_at.desc()),
        },
        "agent_uid" => match direction {
            OrderDirection::Asc => query.then_order_by(col_agent_uid.asc()),
            OrderDirection::Desc => query.then_order_by(col_agent_uid.desc()),
        },
        "addon_id" => match direction {
            OrderDirection::Asc => query.then_order_by(col_addon_id.asc()),
            OrderDirection::Desc => query.then_order_by(col_addon_id.desc()),
        },
        "state" => match direction {
            OrderDirection::Asc => query.then_order_by(col_state.asc()),
            OrderDirection::Desc => query.then_order_by(col_state.desc()),
        },
        _ => query,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::parser::{Filter, FilterOp, FilterValue};

    fn plan_with(filters: Vec<Filter>) -> QueryPlan {
        QueryPlan {
            entity: Entity::AddonStatuses,
            filters,
            order: Vec::new(),
            limit: 100,
            offset: 0,
            time_range: None,
            stats: None,
            downsample: None,
            rollup_stats: None,
            other: false,
            include_deleted: false,
        }
    }

    #[test]
    fn builds_query_with_agent_and_state_filters() {
        for field in ["agent_uid", "addon_id", "state", "version", "arch"] {
            let plan = plan_with(vec![Filter {
                field: field.into(),
                op: FilterOp::Eq,
                value: FilterValue::Scalar("x".to_string()),
            }]);
            assert!(
                build_query(&plan).is_ok(),
                "should build query with {field} filter"
            );
        }
    }

    #[test]
    fn unknown_filter_field_returns_error() {
        let plan = plan_with(vec![Filter {
            field: "pid".into(),
            op: FilterOp::Eq,
            value: FilterValue::Scalar("1".to_string()),
        }]);

        match build_query(&plan) {
            Err(err) => assert!(
                err.to_string().contains("unsupported filter field"),
                "unexpected error: {err}"
            ),
            Ok(_) => panic!("expected error for unsupported filter field"),
        }
    }
}
