//! Query execution for the sweep host result entity (issue 4167).

use super::{BindParam, QueryPlan};
use crate::{
    error::{Result, ServiceError},
    models::SweepResultRow,
    parser::{Entity, Filter, FilterOp, OrderClause, OrderDirection},
    schema::sweep_host_results::dsl::{
        agent_id as col_agent_id, device_id as col_device_id, execution_id as col_execution_id,
        hostname as col_hostname, inserted_at as col_inserted_at, ip as col_ip,
        status as col_status, sweep_group_id as col_sweep_group_id, sweep_host_results,
    },
    time::TimeRange,
};
use diesel::PgTextExpressionMethods;
use diesel::pg::Pg;
use diesel::prelude::*;
use diesel::query_builder::{BoxedSelectStatement, FromClause};
use diesel_async::{AsyncPgConnection, RunQueryDsl};
use serde_json::Value;

type SweepResultsTable = crate::schema::sweep_host_results::table;
type SweepResultsFromClause = FromClause<SweepResultsTable>;
// `AsSelect<SweepResultRow, Pg>` (not `<Table as AsQuery>::SqlType`) because
// `build_query` now selects `SweepResultRow::as_select()` itself so
// `to_sql_and_params` and `execute` share exactly the same column set
// (issue 4167 review finding 2).
type SweepResultsQuery<'a> =
    BoxedSelectStatement<'a, diesel::dsl::AsSelect<SweepResultRow, Pg>, SweepResultsFromClause, Pg>;

pub(super) async fn execute(conn: &mut AsyncPgConnection, plan: &QueryPlan) -> Result<Vec<Value>> {
    ensure_entity(plan)?;
    let rows: Vec<SweepResultRow> = build_query(plan)?
        .limit(plan.limit)
        .offset(plan.offset)
        .load::<SweepResultRow>(conn)
        .await
        .map_err(|err| ServiceError::Internal(err.into()))?;

    Ok(rows.into_iter().map(SweepResultRow::into_json).collect())
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
        Entity::SweepResults => Ok(()),
        _ => Err(ServiceError::InvalidRequest(
            "entity not supported by sweep_results query".into(),
        )),
    }
}

fn build_query(plan: &QueryPlan) -> Result<SweepResultsQuery<'static>> {
    // `build_query` selects here (rather than in `execute` alone) so
    // `to_sql_and_params` — the query the web-ng/core Elixir executors
    // actually run — and `execute`'s Diesel-typed load agree on exactly the
    // same column set (issue 4167 review finding 2).
    let mut query = sweep_host_results
        .select(SweepResultRow::as_select())
        .into_boxed::<Pg>();

    if let Some(TimeRange { start, end }) = &plan.time_range {
        query = query.filter(col_inserted_at.ge(*start).and(col_inserted_at.le(*end)));
    }

    for filter in &plan.filters {
        query = apply_filter(query, filter)?;
    }

    query = apply_ordering(query, &plan.order);
    Ok(query)
}

fn apply_filter<'a>(
    mut query: SweepResultsQuery<'a>,
    filter: &Filter,
) -> Result<SweepResultsQuery<'a>> {
    match filter.field.as_str() {
        "ip" => {
            query = apply_text_filter!(query, filter, col_ip)?;
        }
        "hostname" => {
            query = apply_text_filter!(query, filter, col_hostname)?;
        }
        "status" => {
            query = apply_text_filter!(query, filter, col_status)?;
        }
        "device_id" => {
            query = apply_text_filter!(query, filter, col_device_id)?;
        }
        "agent_id" => {
            query = apply_text_filter!(query, filter, col_agent_id)?;
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
        "execution_id" => {
            query = apply_eq_filter!(
                query,
                filter,
                col_execution_id,
                parse_uuid(filter.value.as_scalar()?)?,
                "execution_id filter only supports equality"
            )?;
        }
        other => {
            return Err(ServiceError::InvalidRequest(format!(
                "unsupported filter field for sweep_results: '{other}'"
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
        "ip" | "hostname" | "status" | "device_id" | "agent_id" => {
            collect_text_params(params, filter)
        }
        "sweep_group_id" | "execution_id" => {
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
    mut query: SweepResultsQuery<'a>,
    order: &[OrderClause],
) -> SweepResultsQuery<'a> {
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
        query = query.order(col_inserted_at.desc());
    }

    query
}

fn apply_single_order<'a>(
    query: SweepResultsQuery<'a>,
    field: &str,
    direction: OrderDirection,
) -> (SweepResultsQuery<'a>, bool) {
    match field {
        "inserted_at" => (
            match direction {
                OrderDirection::Asc => query.order(col_inserted_at.asc()),
                OrderDirection::Desc => query.order(col_inserted_at.desc()),
            },
            true,
        ),
        "ip" => (
            match direction {
                OrderDirection::Asc => query.order(col_ip.asc()),
                OrderDirection::Desc => query.order(col_ip.desc()),
            },
            true,
        ),
        "hostname" => (
            match direction {
                OrderDirection::Asc => query.order(col_hostname.asc()),
                OrderDirection::Desc => query.order(col_hostname.desc()),
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
        "device_id" => (
            match direction {
                OrderDirection::Asc => query.order(col_device_id.asc()),
                OrderDirection::Desc => query.order(col_device_id.desc()),
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
        "sweep_group_id" => (
            match direction {
                OrderDirection::Asc => query.order(col_sweep_group_id.asc()),
                OrderDirection::Desc => query.order(col_sweep_group_id.desc()),
            },
            true,
        ),
        "execution_id" => (
            match direction {
                OrderDirection::Asc => query.order(col_execution_id.asc()),
                OrderDirection::Desc => query.order(col_execution_id.desc()),
            },
            true,
        ),
        _ => (query, false),
    }
}

fn apply_secondary_order<'a>(
    query: SweepResultsQuery<'a>,
    field: &str,
    direction: OrderDirection,
) -> (SweepResultsQuery<'a>, bool) {
    match field {
        "inserted_at" => (
            match direction {
                OrderDirection::Asc => query.then_order_by(col_inserted_at.asc()),
                OrderDirection::Desc => query.then_order_by(col_inserted_at.desc()),
            },
            true,
        ),
        "ip" => (
            match direction {
                OrderDirection::Asc => query.then_order_by(col_ip.asc()),
                OrderDirection::Desc => query.then_order_by(col_ip.desc()),
            },
            true,
        ),
        "hostname" => (
            match direction {
                OrderDirection::Asc => query.then_order_by(col_hostname.asc()),
                OrderDirection::Desc => query.then_order_by(col_hostname.desc()),
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
        "device_id" => (
            match direction {
                OrderDirection::Asc => query.then_order_by(col_device_id.asc()),
                OrderDirection::Desc => query.then_order_by(col_device_id.desc()),
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
        "sweep_group_id" => (
            match direction {
                OrderDirection::Asc => query.then_order_by(col_sweep_group_id.asc()),
                OrderDirection::Desc => query.then_order_by(col_sweep_group_id.desc()),
            },
            true,
        ),
        "execution_id" => (
            match direction {
                OrderDirection::Asc => query.then_order_by(col_execution_id.asc()),
                OrderDirection::Desc => query.then_order_by(col_execution_id.desc()),
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
            entity: Entity::SweepResults,
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
    fn builds_query_with_text_filters() {
        for field in ["ip", "hostname", "status", "device_id", "agent_id"] {
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
    fn builds_query_with_uuid_filters() {
        for field in ["sweep_group_id", "execution_id"] {
            let plan = plan_with(vec![Filter {
                field: field.into(),
                op: FilterOp::Eq,
                value: FilterValue::Scalar(uuid::Uuid::nil().to_string()),
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
            field: "open_ports".into(),
            op: FilterOp::Eq,
            value: FilterValue::Scalar("22".to_string()),
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
            sql.contains("ORDER BY \"sweep_host_results\".\"inserted_at\" DESC"),
            "expected default ORDER BY to survive an unrecognized sort field: {sql}"
        );
    }
}
