//! Query execution for the sweep group diagnostics entity (issue 4167).

use super::{BindParam, QueryPlan};
use crate::{
    error::{Result, ServiceError},
    models::SweepGroupRow,
    parser::{Entity, Filter, FilterOp, OrderClause, OrderDirection},
    schema::sweep_groups::dsl::{
        agent_ids as col_agent_ids, enabled as col_enabled, name as col_name,
        partition as col_partition, profile_id as col_profile_id,
        schedule_type as col_schedule_type, sweep_groups, updated_at as col_updated_at,
    },
    time::TimeRange,
};
use diesel::PgTextExpressionMethods;
use diesel::pg::Pg;
use diesel::prelude::*;
use diesel::query_builder::{AsQuery, BoxedSelectStatement, FromClause};
use diesel_async::{AsyncPgConnection, RunQueryDsl};
use serde_json::Value;

type SweepGroupsTable = crate::schema::sweep_groups::table;
type SweepGroupsFromClause = FromClause<SweepGroupsTable>;
type SweepGroupsQuery<'a> =
    BoxedSelectStatement<'a, <SweepGroupsTable as AsQuery>::SqlType, SweepGroupsFromClause, Pg>;

pub(super) async fn execute(conn: &mut AsyncPgConnection, plan: &QueryPlan) -> Result<Vec<Value>> {
    ensure_entity(plan)?;
    let query = build_query(plan)?;
    let rows: Vec<SweepGroupRow> = query
        .select(SweepGroupRow::as_select())
        .limit(plan.limit)
        .offset(plan.offset)
        .load::<SweepGroupRow>(conn)
        .await
        .map_err(|err| ServiceError::Internal(err.into()))?;

    Ok(rows.into_iter().map(SweepGroupRow::into_json).collect())
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
        Entity::SweepGroups => Ok(()),
        _ => Err(ServiceError::InvalidRequest(
            "entity not supported by sweep_groups query".into(),
        )),
    }
}

fn build_query(plan: &QueryPlan) -> Result<SweepGroupsQuery<'static>> {
    let mut query = sweep_groups.into_boxed::<Pg>();

    if let Some(TimeRange { start, end }) = &plan.time_range {
        query = query.filter(col_updated_at.ge(*start).and(col_updated_at.le(*end)));
    }

    for filter in &plan.filters {
        query = apply_filter(query, filter)?;
    }

    query = apply_ordering(query, &plan.order);
    Ok(query)
}

fn apply_filter<'a>(
    mut query: SweepGroupsQuery<'a>,
    filter: &Filter,
) -> Result<SweepGroupsQuery<'a>> {
    match filter.field.as_str() {
        "name" => {
            query = apply_text_filter!(query, filter, col_name)?;
        }
        "partition" => {
            query = apply_text_filter!(query, filter, col_partition)?;
        }
        "schedule_type" => {
            query = apply_text_filter!(query, filter, col_schedule_type)?;
        }
        "enabled" => {
            let value = parse_bool(filter.value.as_scalar()?)?;
            match filter.op {
                FilterOp::Eq => query = query.filter(col_enabled.eq(value)),
                FilterOp::NotEq => query = query.filter(col_enabled.ne(value)),
                _ => {
                    return Err(ServiceError::InvalidRequest(
                        "enabled filter only supports equality".into(),
                    ));
                }
            }
        }
        "profile_id" => {
            query = apply_eq_filter!(
                query,
                filter,
                col_profile_id,
                parse_uuid(filter.value.as_scalar()?)?,
                "profile_id filter only supports equality"
            )?;
        }
        "agent_id" => {
            // agent_id filters against the agent_ids array (a group can be
            // assigned to more than one agent); equality on the legacy
            // scalar column would silently miss multi-agent groups.
            let values = match &filter.value {
                crate::parser::FilterValue::List(items) => items.clone(),
                crate::parser::FilterValue::Scalar(v) => vec![v.clone()],
            };
            if !values.is_empty() {
                match filter.op {
                    FilterOp::In | FilterOp::Eq => {
                        query = query.filter(col_agent_ids.overlaps_with(values));
                    }
                    FilterOp::NotIn | FilterOp::NotEq => {
                        query = query.filter(diesel::dsl::not(col_agent_ids.overlaps_with(values)));
                    }
                    _ => {
                        return Err(ServiceError::InvalidRequest(
                            "agent_id filter only supports equality/containment".into(),
                        ));
                    }
                }
            }
        }
        other => {
            return Err(ServiceError::InvalidRequest(format!(
                "unsupported filter field for sweep_groups: '{other}'"
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
        "name" | "partition" | "schedule_type" => collect_text_params(params, filter),
        "enabled" => {
            let value = parse_bool(filter.value.as_scalar()?)?;
            params.push(BindParam::Bool(value));
            Ok(())
        }
        "profile_id" => {
            params.push(BindParam::Uuid(parse_uuid(filter.value.as_scalar()?)?));
            Ok(())
        }
        "agent_id" => {
            let values = match &filter.value {
                crate::parser::FilterValue::List(items) => items.clone(),
                crate::parser::FilterValue::Scalar(v) => vec![v.clone()],
            };
            if !values.is_empty() {
                params.push(BindParam::TextArray(values));
            }
            Ok(())
        }
        other => Err(ServiceError::InvalidRequest(format!(
            "unsupported filter field '{other}'"
        ))),
    }
}

fn parse_bool(raw: &str) -> Result<bool> {
    match raw.to_lowercase().as_str() {
        "true" | "1" | "yes" => Ok(true),
        "false" | "0" | "no" => Ok(false),
        _ => Err(ServiceError::InvalidRequest(format!(
            "invalid boolean value '{raw}'"
        ))),
    }
}

fn parse_uuid(raw: &str) -> Result<uuid::Uuid> {
    uuid::Uuid::parse_str(raw)
        .map_err(|_| ServiceError::InvalidRequest(format!("invalid uuid '{raw}'")))
}

fn apply_ordering<'a>(
    mut query: SweepGroupsQuery<'a>,
    order: &[OrderClause],
) -> SweepGroupsQuery<'a> {
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
        query = query.order(col_name.asc());
    }

    query
}

fn apply_single_order<'a>(
    query: SweepGroupsQuery<'a>,
    field: &str,
    direction: OrderDirection,
) -> SweepGroupsQuery<'a> {
    match field {
        "name" => match direction {
            OrderDirection::Asc => query.order(col_name.asc()),
            OrderDirection::Desc => query.order(col_name.desc()),
        },
        "updated_at" => match direction {
            OrderDirection::Asc => query.order(col_updated_at.asc()),
            OrderDirection::Desc => query.order(col_updated_at.desc()),
        },
        "partition" => match direction {
            OrderDirection::Asc => query.order(col_partition.asc()),
            OrderDirection::Desc => query.order(col_partition.desc()),
        },
        "enabled" => match direction {
            OrderDirection::Asc => query.order(col_enabled.asc()),
            OrderDirection::Desc => query.order(col_enabled.desc()),
        },
        "schedule_type" => match direction {
            OrderDirection::Asc => query.order(col_schedule_type.asc()),
            OrderDirection::Desc => query.order(col_schedule_type.desc()),
        },
        _ => query,
    }
}

fn apply_secondary_order<'a>(
    query: SweepGroupsQuery<'a>,
    field: &str,
    direction: OrderDirection,
) -> SweepGroupsQuery<'a> {
    match field {
        "name" => match direction {
            OrderDirection::Asc => query.then_order_by(col_name.asc()),
            OrderDirection::Desc => query.then_order_by(col_name.desc()),
        },
        "updated_at" => match direction {
            OrderDirection::Asc => query.then_order_by(col_updated_at.asc()),
            OrderDirection::Desc => query.then_order_by(col_updated_at.desc()),
        },
        "partition" => match direction {
            OrderDirection::Asc => query.then_order_by(col_partition.asc()),
            OrderDirection::Desc => query.then_order_by(col_partition.desc()),
        },
        "enabled" => match direction {
            OrderDirection::Asc => query.then_order_by(col_enabled.asc()),
            OrderDirection::Desc => query.then_order_by(col_enabled.desc()),
        },
        "schedule_type" => match direction {
            OrderDirection::Asc => query.then_order_by(col_schedule_type.asc()),
            OrderDirection::Desc => query.then_order_by(col_schedule_type.desc()),
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
            entity: Entity::SweepGroups,
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
    fn builds_query_with_name_and_partition_filters() {
        for field in ["name", "partition", "schedule_type"] {
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
    fn builds_query_with_enabled_filter() {
        let plan = plan_with(vec![Filter {
            field: "enabled".into(),
            op: FilterOp::Eq,
            value: FilterValue::Scalar("true".to_string()),
        }]);
        assert!(
            build_query(&plan).is_ok(),
            "should build query with enabled filter"
        );
    }

    #[test]
    fn builds_query_with_profile_id_filter() {
        let plan = plan_with(vec![Filter {
            field: "profile_id".into(),
            op: FilterOp::Eq,
            value: FilterValue::Scalar(uuid::Uuid::nil().to_string()),
        }]);
        assert!(
            build_query(&plan).is_ok(),
            "should build query with profile_id filter"
        );
    }

    #[test]
    fn builds_query_with_agent_id_filter_against_array() {
        let plan = plan_with(vec![Filter {
            field: "agent_id".into(),
            op: FilterOp::Eq,
            value: FilterValue::Scalar("agent-01".to_string()),
        }]);
        assert!(
            build_query(&plan).is_ok(),
            "should build query with agent_id filter"
        );
    }

    #[test]
    fn unknown_filter_field_returns_error() {
        let plan = plan_with(vec![Filter {
            field: "cron_expression".into(),
            op: FilterOp::Eq,
            value: FilterValue::Scalar("* * * * *".to_string()),
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
