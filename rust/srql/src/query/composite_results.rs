//! `in:composite_results` — per-device composite check verdicts.
//!
//! Unlike the `composite.<slug>` device filter, this entity defines its own
//! `FromClause`, so it joins `composite_checks` directly rather than using a
//! correlated subquery. The join is what lets a caller filter and read by slug
//! without knowing check ids.

use super::{BindParam, QueryPlan};
use crate::{
    error::{Result, ServiceError},
    models::CompositeResultRow,
    parser::{Entity, Filter, FilterOp, OrderClause, OrderDirection},
    schema::{composite_checks, device_composite_check_results},
    time::TimeRange,
};
use diesel::pg::Pg;
use diesel::prelude::*;
use diesel::query_builder::{BoxedSelectStatement, FromClause};
use diesel_async::{AsyncPgConnection, RunQueryDsl};

type ResultsJoin = diesel::helper_types::InnerJoinQuerySource<
    device_composite_check_results::table,
    composite_checks::table,
>;
type ResultsFromClause = FromClause<ResultsJoin>;
type SelectTuple = (
    device_composite_check_results::device_uid,
    device_composite_check_results::check_id,
    composite_checks::slug,
    composite_checks::name,
    device_composite_check_results::verdict,
    device_composite_check_results::status,
    device_composite_check_results::matched_rule_id,
    device_composite_check_results::inputs,
    device_composite_check_results::evaluated_at,
    device_composite_check_results::changed_at,
);
type ResultsQuery<'a> =
    BoxedSelectStatement<'a, diesel::dsl::SqlTypeOf<SelectTuple>, ResultsFromClause, Pg>;

/// Column order must match `CompositeResultRow`'s field order.
fn select_tuple() -> SelectTuple {
    (
        device_composite_check_results::device_uid,
        device_composite_check_results::check_id,
        composite_checks::slug,
        composite_checks::name,
        device_composite_check_results::verdict,
        device_composite_check_results::status,
        device_composite_check_results::matched_rule_id,
        device_composite_check_results::inputs,
        device_composite_check_results::evaluated_at,
        device_composite_check_results::changed_at,
    )
}

pub(super) async fn execute(
    conn: &mut AsyncPgConnection,
    plan: &QueryPlan,
) -> Result<Vec<serde_json::Value>> {
    ensure_entity(plan)?;

    let rows: Vec<CompositeResultRow> = build_query(plan)?
        .limit(plan.limit)
        .offset(plan.offset)
        .load::<CompositeResultRow>(conn)
        .await
        .map_err(|err| ServiceError::Internal(err.into()))?;

    Ok(rows
        .into_iter()
        .map(CompositeResultRow::into_json)
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
        Entity::CompositeResults => Ok(()),
        _ => Err(ServiceError::InvalidRequest(
            "entity not supported by composite results query".into(),
        )),
    }
}

fn build_query(plan: &QueryPlan) -> Result<ResultsQuery<'static>> {
    let mut query = device_composite_check_results::table
        .inner_join(composite_checks::table)
        .select(select_tuple())
        .into_boxed::<Pg>();

    if let Some(TimeRange { start, end }) = &plan.time_range {
        query = query.filter(
            device_composite_check_results::evaluated_at
                .ge(*start)
                .and(device_composite_check_results::evaluated_at.le(*end)),
        );
    }

    for filter in &plan.filters {
        query = apply_filter(query, filter)?;
    }

    Ok(apply_ordering(query, &plan.order))
}

fn apply_filter<'a>(mut query: ResultsQuery<'a>, filter: &Filter) -> Result<ResultsQuery<'a>> {
    match filter.field.as_str() {
        // `check` reads naturally in a query; `check_slug` is the explicit form.
        "check" | "check_slug" | "slug" => {
            query = apply_text_filter!(query, filter, composite_checks::slug)?;
        }
        "check_name" => {
            query = apply_text_filter!(query, filter, composite_checks::name)?;
        }
        "verdict" => {
            query = apply_text_filter!(query, filter, device_composite_check_results::verdict)?;
        }
        "status" => {
            query = apply_text_filter!(query, filter, device_composite_check_results::status)?;
        }
        "device_uid" | "device" | "uid" => {
            query = apply_text_filter!(query, filter, device_composite_check_results::device_uid)?;
        }
        other => {
            return Err(ServiceError::InvalidRequest(format!(
                "unsupported filter field '{other}' for composite results"
            )));
        }
    }

    Ok(query)
}

/// Mirrors `apply_filter`. A field handled in one and not the other produces a
/// bind mismatch at query time; the `diesel_bind_count` assertion in
/// `to_sql_and_params` catches it in test and debug builds.
fn collect_filter_params(params: &mut Vec<BindParam>, filter: &Filter) -> Result<()> {
    match filter.field.as_str() {
        "check" | "check_slug" | "slug" | "check_name" | "verdict" | "status" | "device_uid"
        | "device" | "uid" => collect_text_params(params, filter),
        other => Err(ServiceError::InvalidRequest(format!(
            "unsupported filter field '{other}' for composite results"
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
            for value in filter.value.as_list()? {
                params.push(BindParam::Text(value.to_string()));
            }
            Ok(())
        }
        _ => Err(ServiceError::InvalidRequest(format!(
            "{} filter does not support that comparison",
            filter.field
        ))),
    }
}

fn apply_ordering<'a>(query: ResultsQuery<'a>, order: &[OrderClause]) -> ResultsQuery<'a> {
    if order.is_empty() {
        return query.order(device_composite_check_results::evaluated_at.desc());
    }

    let mut query = query;
    for (index, clause) in order.iter().enumerate() {
        query = apply_order_clause(query, clause, index == 0);
    }
    query
}

fn apply_order_clause<'a>(
    query: ResultsQuery<'a>,
    clause: &OrderClause,
    first: bool,
) -> ResultsQuery<'a> {
    macro_rules! order_by {
        ($column:expr) => {{
            match (first, clause.direction) {
                (true, OrderDirection::Asc) => query.order($column.asc()),
                (true, OrderDirection::Desc) => query.order($column.desc()),
                (false, OrderDirection::Asc) => query.then_order_by($column.asc()),
                (false, OrderDirection::Desc) => query.then_order_by($column.desc()),
            }
        }};
    }

    match clause.field.as_str() {
        "device_uid" | "device" | "uid" => {
            order_by!(device_composite_check_results::device_uid)
        }
        "verdict" => order_by!(device_composite_check_results::verdict),
        "status" => order_by!(device_composite_check_results::status),
        "changed_at" => order_by!(device_composite_check_results::changed_at),
        "check" | "check_slug" | "slug" => order_by!(composite_checks::slug),
        // Unknown sort fields fall back to the default rather than erroring, so
        // a stale saved query keeps working.
        _ => order_by!(device_composite_check_results::evaluated_at),
    }
}
