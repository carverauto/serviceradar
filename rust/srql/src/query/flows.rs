//! Query execution for OCSF network_activity (flows) entity.

mod expressions;
mod filters;
mod literals;
mod order;
mod params;
mod query;
mod row;
mod scope;
mod snmp;
mod stats;

#[cfg(test)]
mod tests;

pub(super) use self::expressions::*;
use self::{
    filters::apply_filter,
    literals::{
        near_exists_sql, normalize_cidr_literal, normalize_device_uid_literal,
        normalize_near_literal, tag_any_contains_sql, tag_contains_sql, NearSide,
    },
    order::apply_ordering,
    params::collect_filter_params,
    query::build_query,
    row::{FlowRow, FlowRowLegacy},
    scope::flow_device_scope_expr,
    snmp::apply_snmp_index_filter,
    stats::{execute_stats, to_sql_and_params_stats},
};
use super::{BindParam, QueryPlan};
use crate::{
    error::{Result, ServiceError},
    parser::{Entity, Filter, FilterOp, OrderClause, OrderDirection},
    schema::ocsf_network_activity::dsl::*,
    time::TimeRange,
};
use diesel::PgTextExpressionMethods;
use diesel::dsl::{not, sql};
use diesel::pg::Pg;
use diesel::prelude::*;
use diesel::query_builder::{AsQuery, BoxedSelectStatement, FromClause};
use diesel::sql_types::{Bool, Text};
use diesel_async::{AsyncPgConnection, RunQueryDsl};
use serde_json::Value;

type FlowsTable = crate::schema::ocsf_network_activity::table;
type FlowsFromClause = FromClause<FlowsTable>;
type FlowsQuery<'a> =
    BoxedSelectStatement<'a, <FlowsTable as AsQuery>::SqlType, FlowsFromClause, Pg>;

pub(super) async fn execute(conn: &mut AsyncPgConnection, plan: &QueryPlan) -> Result<Vec<Value>> {
    ensure_entity(plan)?;

    if plan.stats.is_some() {
        return execute_stats(conn, plan).await;
    }

    // Prefer the full projection (includes prefix-tag columns). If the
    // migration has not been applied yet, fall back so plain in:flows stays up.
    match load_flow_rows_full(conn, plan).await {
        Ok(rows) => Ok(rows),
        Err(err) if is_missing_prefix_tag_column_error(&err) => {
            load_flow_rows_legacy(conn, plan).await
        }
        Err(err) => Err(err),
    }
}

async fn load_flow_rows_full(
    conn: &mut AsyncPgConnection,
    plan: &QueryPlan,
) -> Result<Vec<Value>> {
    let rows: Vec<FlowRow> = build_query(plan)?
        .select(FlowRow::as_select())
        .limit(plan.limit)
        .offset(plan.offset)
        .load::<FlowRow>(conn)
        .await
        .map_err(|err| ServiceError::Internal(err.into()))?;
    Ok(rows.into_iter().map(FlowRow::into_json).collect())
}

async fn load_flow_rows_legacy(
    conn: &mut AsyncPgConnection,
    plan: &QueryPlan,
) -> Result<Vec<Value>> {
    let rows: Vec<FlowRowLegacy> = build_query(plan)?
        .select(FlowRowLegacy::as_select())
        .limit(plan.limit)
        .offset(plan.offset)
        .load::<FlowRowLegacy>(conn)
        .await
        .map_err(|err| ServiceError::Internal(err.into()))?;
    Ok(rows.into_iter().map(FlowRowLegacy::into_json).collect())
}

fn is_missing_prefix_tag_column_error(err: &ServiceError) -> bool {
    let msg = err.to_string().to_ascii_lowercase();
    msg.contains("src_prefix_tags")
        || msg.contains("dst_prefix_tags")
        || msg.contains("src_prefix_tags_source")
        || msg.contains("dst_prefix_tags_source")
}

pub(super) fn to_sql_and_params(plan: &QueryPlan) -> Result<(String, Vec<BindParam>)> {
    ensure_entity(plan)?;

    if plan.stats.is_some() {
        return to_sql_and_params_stats(plan);
    }

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
        Entity::Flows | Entity::AttributedFlows => Ok(()),
        _ => Err(ServiceError::InvalidRequest(
            "entity not supported by flows query".into(),
        )),
    }
}
