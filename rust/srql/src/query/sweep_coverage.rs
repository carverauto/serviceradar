//! Query execution for the daily sweep coverage rollup entity (issue 4167).

use super::{BindParam, QueryPlan};
use crate::{
    error::{Result, ServiceError},
    models::SweepCoverageRow,
    parser::{Entity, Filter, FilterOp, OrderClause, OrderDirection},
    schema::sweep_coverage_daily::dsl::{
        agent_id as col_agent_id, day as col_day, device_uid as col_device_uid, ip as col_ip,
        sweep_coverage_daily, sweep_group_id as col_sweep_group_id,
    },
    time::TimeRange,
};
use diesel::PgTextExpressionMethods;
use diesel::pg::Pg;
use diesel::prelude::*;
use diesel::query_builder::{AsQuery, BoxedSelectStatement, FromClause};
use diesel_async::{AsyncPgConnection, RunQueryDsl};
use serde_json::Value;

type SweepCoverageTable = crate::schema::sweep_coverage_daily::table;
type SweepCoverageFromClause = FromClause<SweepCoverageTable>;
type SweepCoverageQuery<'a> =
    BoxedSelectStatement<'a, <SweepCoverageTable as AsQuery>::SqlType, SweepCoverageFromClause, Pg>;

pub(super) async fn execute(conn: &mut AsyncPgConnection, plan: &QueryPlan) -> Result<Vec<Value>> {
    ensure_entity(plan)?;
    let query = build_query(plan)?;
    let rows: Vec<SweepCoverageRow> = query
        .select(SweepCoverageRow::as_select())
        .limit(plan.limit)
        .offset(plan.offset)
        .load::<SweepCoverageRow>(conn)
        .await
        .map_err(|err| ServiceError::Internal(err.into()))?;

    Ok(rows.into_iter().map(SweepCoverageRow::into_json).collect())
}

pub(super) fn to_sql_and_params(plan: &QueryPlan) -> Result<(String, Vec<BindParam>)> {
    ensure_entity(plan)?;
    let query = build_query(plan)?.limit(plan.limit).offset(plan.offset);
    let sql = super::diesel_sql(&query)?;

    let mut params = Vec::new();

    // `day` is a real `date` column (there is no `date_trunc` anywhere in
    // rust/srql), so the time-range bounds are narrowed from timestamps to
    // dates rather than compared as timestamptz.
    if let Some(TimeRange { start, end }) = &plan.time_range {
        params.push(BindParam::date(start.date_naive()));
        params.push(BindParam::date(end.date_naive()));
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
        Entity::SweepCoverage => Ok(()),
        _ => Err(ServiceError::InvalidRequest(
            "entity not supported by sweep_coverage query".into(),
        )),
    }
}

fn build_query(plan: &QueryPlan) -> Result<SweepCoverageQuery<'static>> {
    let mut query = sweep_coverage_daily.into_boxed::<Pg>();

    if let Some(TimeRange { start, end }) = &plan.time_range {
        query = query.filter(
            col_day
                .ge(start.date_naive())
                .and(col_day.le(end.date_naive())),
        );
    }

    for filter in &plan.filters {
        query = apply_filter(query, filter)?;
    }

    query = apply_ordering(query, &plan.order);
    Ok(query)
}

fn apply_filter<'a>(
    mut query: SweepCoverageQuery<'a>,
    filter: &Filter,
) -> Result<SweepCoverageQuery<'a>> {
    match filter.field.as_str() {
        "device_uid" => {
            query = apply_text_filter!(query, filter, col_device_uid)?;
        }
        "ip" => {
            query = apply_text_filter!(query, filter, col_ip)?;
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
        other => {
            return Err(ServiceError::InvalidRequest(format!(
                "unsupported filter field for sweep_coverage: '{other}'"
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
        "device_uid" | "ip" | "agent_id" => collect_text_params(params, filter),
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
    mut query: SweepCoverageQuery<'a>,
    order: &[OrderClause],
) -> SweepCoverageQuery<'a> {
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
        query = query.order(col_day.desc());
    }

    query
}

fn apply_single_order<'a>(
    query: SweepCoverageQuery<'a>,
    field: &str,
    direction: OrderDirection,
) -> SweepCoverageQuery<'a> {
    match field {
        "day" => match direction {
            OrderDirection::Asc => query.order(col_day.asc()),
            OrderDirection::Desc => query.order(col_day.desc()),
        },
        "device_uid" => match direction {
            OrderDirection::Asc => query.order(col_device_uid.asc()),
            OrderDirection::Desc => query.order(col_device_uid.desc()),
        },
        "ip" => match direction {
            OrderDirection::Asc => query.order(col_ip.asc()),
            OrderDirection::Desc => query.order(col_ip.desc()),
        },
        "agent_id" => match direction {
            OrderDirection::Asc => query.order(col_agent_id.asc()),
            OrderDirection::Desc => query.order(col_agent_id.desc()),
        },
        "sweep_group_id" => match direction {
            OrderDirection::Asc => query.order(col_sweep_group_id.asc()),
            OrderDirection::Desc => query.order(col_sweep_group_id.desc()),
        },
        _ => query,
    }
}

fn apply_secondary_order<'a>(
    query: SweepCoverageQuery<'a>,
    field: &str,
    direction: OrderDirection,
) -> SweepCoverageQuery<'a> {
    match field {
        "day" => match direction {
            OrderDirection::Asc => query.then_order_by(col_day.asc()),
            OrderDirection::Desc => query.then_order_by(col_day.desc()),
        },
        "device_uid" => match direction {
            OrderDirection::Asc => query.then_order_by(col_device_uid.asc()),
            OrderDirection::Desc => query.then_order_by(col_device_uid.desc()),
        },
        "ip" => match direction {
            OrderDirection::Asc => query.then_order_by(col_ip.asc()),
            OrderDirection::Desc => query.then_order_by(col_ip.desc()),
        },
        "agent_id" => match direction {
            OrderDirection::Asc => query.then_order_by(col_agent_id.asc()),
            OrderDirection::Desc => query.then_order_by(col_agent_id.desc()),
        },
        "sweep_group_id" => match direction {
            OrderDirection::Asc => query.then_order_by(col_sweep_group_id.asc()),
            OrderDirection::Desc => query.then_order_by(col_sweep_group_id.desc()),
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
            entity: Entity::SweepCoverage,
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
        for field in ["device_uid", "ip", "agent_id"] {
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
    fn builds_query_with_time_range_against_day() {
        let mut plan = plan_with(vec![]);
        let now = chrono::Utc::now();
        plan.time_range = Some(TimeRange {
            start: now - chrono::Duration::days(7),
            end: now,
        });
        assert!(
            build_query(&plan).is_ok(),
            "should build query with day time-range filter"
        );

        let (_, params) = to_sql_and_params(&plan).expect("should build sql and params");
        assert!(
            params
                .iter()
                .any(|param| matches!(param, BindParam::Date(_))),
            "expected a Date bind for the day time-range filter"
        );
    }

    #[test]
    fn unknown_filter_field_returns_error() {
        let plan = plan_with(vec![Filter {
            field: "execution_count".into(),
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
