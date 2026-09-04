//! Query execution for the sweep scan profile entity (issue 4167).

use super::{BindParam, QueryPlan};
use crate::{
    error::{Result, ServiceError},
    models::SweepProfileRow,
    parser::{Entity, Filter, FilterOp, OrderClause, OrderDirection},
    schema::sweep_profiles::dsl::{
        admin_only as col_admin_only, enabled as col_enabled, name as col_name, sweep_profiles,
        updated_at as col_updated_at,
    },
    time::TimeRange,
};
use diesel::PgTextExpressionMethods;
use diesel::pg::Pg;
use diesel::prelude::*;
use diesel::query_builder::{AsQuery, BoxedSelectStatement, FromClause};
use diesel_async::{AsyncPgConnection, RunQueryDsl};
use serde_json::Value;

type SweepProfilesTable = crate::schema::sweep_profiles::table;
type SweepProfilesFromClause = FromClause<SweepProfilesTable>;
type SweepProfilesQuery<'a> =
    BoxedSelectStatement<'a, <SweepProfilesTable as AsQuery>::SqlType, SweepProfilesFromClause, Pg>;

pub(super) async fn execute(conn: &mut AsyncPgConnection, plan: &QueryPlan) -> Result<Vec<Value>> {
    ensure_entity(plan)?;
    let query = build_query(plan)?;
    let rows: Vec<SweepProfileRow> = query
        .select(SweepProfileRow::as_select())
        .limit(plan.limit)
        .offset(plan.offset)
        .load::<SweepProfileRow>(conn)
        .await
        .map_err(|err| ServiceError::Internal(err.into()))?;

    Ok(rows.into_iter().map(SweepProfileRow::into_json).collect())
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
        Entity::SweepProfiles => Ok(()),
        _ => Err(ServiceError::InvalidRequest(
            "entity not supported by sweep_profiles query".into(),
        )),
    }
}

fn build_query(plan: &QueryPlan) -> Result<SweepProfilesQuery<'static>> {
    let mut query = sweep_profiles.into_boxed::<Pg>();

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
    mut query: SweepProfilesQuery<'a>,
    filter: &Filter,
) -> Result<SweepProfilesQuery<'a>> {
    match filter.field.as_str() {
        "name" => {
            query = apply_text_filter!(query, filter, col_name)?;
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
        "admin_only" => {
            let value = parse_bool(filter.value.as_scalar()?)?;
            match filter.op {
                FilterOp::Eq => query = query.filter(col_admin_only.eq(value)),
                FilterOp::NotEq => query = query.filter(col_admin_only.ne(value)),
                _ => {
                    return Err(ServiceError::InvalidRequest(
                        "admin_only filter only supports equality".into(),
                    ));
                }
            }
        }
        other => {
            return Err(ServiceError::InvalidRequest(format!(
                "unsupported filter field for sweep_profiles: '{other}'"
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
        "name" => collect_text_params(params, filter),
        "enabled" | "admin_only" => {
            params.push(BindParam::Bool(parse_bool(filter.value.as_scalar()?)?));
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

fn apply_ordering<'a>(
    mut query: SweepProfilesQuery<'a>,
    order: &[OrderClause],
) -> SweepProfilesQuery<'a> {
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
    query: SweepProfilesQuery<'a>,
    field: &str,
    direction: OrderDirection,
) -> SweepProfilesQuery<'a> {
    match field {
        "name" => match direction {
            OrderDirection::Asc => query.order(col_name.asc()),
            OrderDirection::Desc => query.order(col_name.desc()),
        },
        "updated_at" => match direction {
            OrderDirection::Asc => query.order(col_updated_at.asc()),
            OrderDirection::Desc => query.order(col_updated_at.desc()),
        },
        "enabled" => match direction {
            OrderDirection::Asc => query.order(col_enabled.asc()),
            OrderDirection::Desc => query.order(col_enabled.desc()),
        },
        "admin_only" => match direction {
            OrderDirection::Asc => query.order(col_admin_only.asc()),
            OrderDirection::Desc => query.order(col_admin_only.desc()),
        },
        _ => query,
    }
}

fn apply_secondary_order<'a>(
    query: SweepProfilesQuery<'a>,
    field: &str,
    direction: OrderDirection,
) -> SweepProfilesQuery<'a> {
    match field {
        "name" => match direction {
            OrderDirection::Asc => query.then_order_by(col_name.asc()),
            OrderDirection::Desc => query.then_order_by(col_name.desc()),
        },
        "updated_at" => match direction {
            OrderDirection::Asc => query.then_order_by(col_updated_at.asc()),
            OrderDirection::Desc => query.then_order_by(col_updated_at.desc()),
        },
        "enabled" => match direction {
            OrderDirection::Asc => query.then_order_by(col_enabled.asc()),
            OrderDirection::Desc => query.then_order_by(col_enabled.desc()),
        },
        "admin_only" => match direction {
            OrderDirection::Asc => query.then_order_by(col_admin_only.asc()),
            OrderDirection::Desc => query.then_order_by(col_admin_only.desc()),
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
            entity: Entity::SweepProfiles,
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
    fn builds_query_with_name_filter() {
        let plan = plan_with(vec![Filter {
            field: "name".into(),
            op: FilterOp::Eq,
            value: FilterValue::Scalar("default".to_string()),
        }]);
        assert!(
            build_query(&plan).is_ok(),
            "should build query with name filter"
        );
    }

    #[test]
    fn builds_query_with_enabled_and_admin_only_filters() {
        for field in ["enabled", "admin_only"] {
            let plan = plan_with(vec![Filter {
                field: field.into(),
                op: FilterOp::Eq,
                value: FilterValue::Scalar("true".to_string()),
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
            field: "timeout".into(),
            op: FilterOp::Eq,
            value: FilterValue::Scalar("3s".to_string()),
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
