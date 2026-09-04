//! Query execution for the sweep group execution entity (issue 4167).

use super::{BindParam, QueryPlan};
use crate::{
    error::{Result, ServiceError},
    models::SweepExecutionRow,
    parser::{Entity, Filter, FilterOp, OrderClause, OrderDirection},
    schema::sweep_group_executions::dsl::{
        agent_id as col_agent_id, config_version as col_config_version,
        started_at as col_started_at, status as col_status, sweep_group_executions,
        sweep_group_id as col_sweep_group_id,
    },
    time::TimeRange,
};
use diesel::PgTextExpressionMethods;
use diesel::pg::Pg;
use diesel::prelude::*;
use diesel::query_builder::{BoxedSelectStatement, FromClause};
use diesel_async::{AsyncPgConnection, RunQueryDsl};
use serde_json::Value;

type SweepExecutionsTable = crate::schema::sweep_group_executions::table;
type SweepExecutionsFromClause = FromClause<SweepExecutionsTable>;
// `AsSelect<SweepExecutionRow, Pg>` (not `<Table as AsQuery>::SqlType`)
// because `build_query` now selects `SweepExecutionRow::as_select()` itself
// so `to_sql_and_params` and `execute` share exactly the same column set
// (issue 4167 review finding 2).
type SweepExecutionsQuery<'a> = BoxedSelectStatement<
    'a,
    diesel::dsl::AsSelect<SweepExecutionRow, Pg>,
    SweepExecutionsFromClause,
    Pg,
>;

pub(super) async fn execute(conn: &mut AsyncPgConnection, plan: &QueryPlan) -> Result<Vec<Value>> {
    ensure_entity(plan)?;
    let rows: Vec<SweepExecutionRow> = build_query(plan)?
        .limit(plan.limit)
        .offset(plan.offset)
        .load::<SweepExecutionRow>(conn)
        .await
        .map_err(|err| ServiceError::Internal(err.into()))?;

    Ok(rows.into_iter().map(SweepExecutionRow::into_json).collect())
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
        Entity::SweepExecutions => Ok(()),
        _ => Err(ServiceError::InvalidRequest(
            "entity not supported by sweep_executions query".into(),
        )),
    }
}

fn build_query(plan: &QueryPlan) -> Result<SweepExecutionsQuery<'static>> {
    // `build_query` selects here (rather than in `execute` alone) so
    // `to_sql_and_params` — the query the web-ng/core Elixir executors
    // actually run — and `execute`'s Diesel-typed load agree on exactly the
    // same column set (issue 4167 review finding 2).
    let mut query = sweep_group_executions
        .select(SweepExecutionRow::as_select())
        .into_boxed::<Pg>();

    if let Some(TimeRange { start, end }) = &plan.time_range {
        query = query.filter(col_started_at.ge(*start).and(col_started_at.le(*end)));
    }

    for filter in &plan.filters {
        query = apply_filter(query, filter)?;
    }

    query = apply_ordering(query, &plan.order);
    Ok(query)
}

fn apply_filter<'a>(
    mut query: SweepExecutionsQuery<'a>,
    filter: &Filter,
) -> Result<SweepExecutionsQuery<'a>> {
    match filter.field.as_str() {
        "status" => {
            query = apply_text_filter!(query, filter, col_status)?;
        }
        "agent_id" => {
            query = apply_text_filter!(query, filter, col_agent_id)?;
        }
        "config_version" => {
            query = apply_text_filter!(query, filter, col_config_version)?;
        }
        "sweep_group_id" => {
            query = apply_eq_filter!(
                query,
                filter,
                col_sweep_group_id,
                parse_uuid(filter.value.as_scalar()?)?,
                "sweep_group_id filter only supports equality"
            )?;
        }
        other => {
            return Err(ServiceError::InvalidRequest(format!(
                "unsupported filter field for sweep_executions: '{other}'"
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
        "status" | "agent_id" | "config_version" => collect_text_params(params, filter),
        "sweep_group_id" => {
            params.push(BindParam::Uuid(parse_uuid(filter.value.as_scalar()?)?));
            Ok(())
        }
        other => Err(ServiceError::InvalidRequest(format!(
            "unsupported filter field '{other}'"
        ))),
    }
}

fn parse_uuid(raw: &str) -> Result<uuid::Uuid> {
    uuid::Uuid::parse_str(raw)
        .map_err(|_| ServiceError::InvalidRequest(format!("invalid uuid '{raw}'")))
}

fn apply_ordering<'a>(
    mut query: SweepExecutionsQuery<'a>,
    order: &[OrderClause],
) -> SweepExecutionsQuery<'a> {
    let mut applied = false;
    for clause in order {
        let (next_query, matched) = if !applied {
            apply_single_order(query, clause.field.as_str(), clause.direction)
        } else {
            apply_secondary_order(query, clause.field.as_str(), clause.direction)
        };
        query = next_query;
        applied = applied || matched;
    }

    // An unrecognized sort field must not disable ordering entirely: fall
    // back to the default so `sort:bogus` still yields deterministic,
    // pagination-safe results instead of unspecified row order.
    if !applied {
        query = query.order(col_started_at.desc());
    }

    query
}

fn apply_single_order<'a>(
    query: SweepExecutionsQuery<'a>,
    field: &str,
    direction: OrderDirection,
) -> (SweepExecutionsQuery<'a>, bool) {
    match field {
        "started_at" => (
            match direction {
                OrderDirection::Asc => query.order(col_started_at.asc()),
                OrderDirection::Desc => query.order(col_started_at.desc()),
            },
            true,
        ),
        "status" => (
            match direction {
                OrderDirection::Asc => query.order(col_status.asc()),
                OrderDirection::Desc => query.order(col_status.desc()),
            },
            true,
        ),
        "agent_id" => (
            match direction {
                OrderDirection::Asc => query.order(col_agent_id.asc()),
                OrderDirection::Desc => query.order(col_agent_id.desc()),
            },
            true,
        ),
        "config_version" => (
            match direction {
                OrderDirection::Asc => query.order(col_config_version.asc()),
                OrderDirection::Desc => query.order(col_config_version.desc()),
            },
            true,
        ),
        "sweep_group_id" => (
            match direction {
                OrderDirection::Asc => query.order(col_sweep_group_id.asc()),
                OrderDirection::Desc => query.order(col_sweep_group_id.desc()),
            },
            true,
        ),
        _ => (query, false),
    }
}

fn apply_secondary_order<'a>(
    query: SweepExecutionsQuery<'a>,
    field: &str,
    direction: OrderDirection,
) -> (SweepExecutionsQuery<'a>, bool) {
    match field {
        "started_at" => (
            match direction {
                OrderDirection::Asc => query.then_order_by(col_started_at.asc()),
                OrderDirection::Desc => query.then_order_by(col_started_at.desc()),
            },
            true,
        ),
        "status" => (
            match direction {
                OrderDirection::Asc => query.then_order_by(col_status.asc()),
                OrderDirection::Desc => query.then_order_by(col_status.desc()),
            },
            true,
        ),
        "agent_id" => (
            match direction {
                OrderDirection::Asc => query.then_order_by(col_agent_id.asc()),
                OrderDirection::Desc => query.then_order_by(col_agent_id.desc()),
            },
            true,
        ),
        "config_version" => (
            match direction {
                OrderDirection::Asc => query.then_order_by(col_config_version.asc()),
                OrderDirection::Desc => query.then_order_by(col_config_version.desc()),
            },
            true,
        ),
        "sweep_group_id" => (
            match direction {
                OrderDirection::Asc => query.then_order_by(col_sweep_group_id.asc()),
                OrderDirection::Desc => query.then_order_by(col_sweep_group_id.desc()),
            },
            true,
        ),
        _ => (query, false),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::parser::{Filter, FilterOp, FilterValue};

    fn plan_with(filters: Vec<Filter>) -> QueryPlan {
        QueryPlan {
            entity: Entity::SweepExecutions,
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
    fn builds_query_with_status_agent_and_config_version_filters() {
        for field in ["status", "agent_id", "config_version"] {
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
    fn builds_query_with_sweep_group_id_filter() {
        let plan = plan_with(vec![Filter {
            field: "sweep_group_id".into(),
            op: FilterOp::Eq,
            value: FilterValue::Scalar(uuid::Uuid::nil().to_string()),
        }]);
        assert!(
            build_query(&plan).is_ok(),
            "should build query with sweep_group_id filter"
        );
    }

    #[test]
    fn unknown_filter_field_returns_error() {
        let plan = plan_with(vec![Filter {
            field: "duration_ms".into(),
            op: FilterOp::Eq,
            value: FilterValue::Scalar("100".to_string()),
        }]);

        match build_query(&plan) {
            Err(err) => assert!(
                err.to_string().contains("unsupported filter field"),
                "unexpected error: {err}"
            ),
            Ok(_) => panic!("expected error for unsupported filter field"),
        }
    }

    #[test]
    fn unknown_sort_field_falls_back_to_default_order() {
        let mut plan = plan_with(vec![]);
        plan.order = vec![OrderClause {
            field: "bogus".into(),
            direction: OrderDirection::Desc,
        }];

        let (sql, _) = to_sql_and_params(&plan).expect("should build sql for unknown sort field");
        assert!(
            sql.contains("ORDER BY \"sweep_group_executions\".\"started_at\" DESC"),
            "expected default ORDER BY to survive an unrecognized sort field: {sql}"
        );
    }
}
