mod filters;
mod order;
mod query;
mod rollup;
mod types;

use self::{
    filters::collect_filter_params,
    query::build_query,
    rollup::{
        bind_param_from_rollup, build_rollup_stats_query, rewrite_placeholders, EventsRollupPayload,
    },
};
use super::{BindParam, QueryPlan};
use crate::{
    error::{Result, ServiceError},
    models::EventRow,
    parser::Entity,
    time::TimeRange,
};
use diesel::prelude::*;
use diesel_async::{AsyncPgConnection, RunQueryDsl};

pub(super) async fn execute(
    conn: &mut AsyncPgConnection,
    plan: &QueryPlan,
) -> Result<Vec<serde_json::Value>> {
    ensure_entity(plan)?;

    if let Some(rollup_sql) = build_rollup_stats_query(plan)? {
        let query = rollup_sql.to_boxed_query();
        let rows: Vec<EventsRollupPayload> = query
            .load::<EventsRollupPayload>(conn)
            .await
            .map_err(|err| ServiceError::Internal(err.into()))?;

        return Ok(rows
            .into_iter()
            .filter_map(|row| row.payload.map(serde_json::Value::from))
            .collect());
    }

    let query = build_query(plan)?;
    let rows: Vec<EventRow> = query
        .select(EventRow::as_select())
        .limit(plan.limit)
        .offset(plan.offset)
        .load::<EventRow>(conn)
        .await
        .map_err(|err| ServiceError::Internal(err.into()))?;

    Ok(rows.into_iter().map(EventRow::into_json).collect())
}

pub(super) fn to_sql_and_params(plan: &QueryPlan) -> Result<(String, Vec<BindParam>)> {
    ensure_entity(plan)?;

    if let Some(rollup_sql) = build_rollup_stats_query(plan)? {
        let sql = rewrite_placeholders(&rollup_sql.sql);
        let params = rollup_sql
            .binds
            .into_iter()
            .map(bind_param_from_rollup)
            .collect();
        return Ok((sql, params));
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
        Entity::Events | Entity::SecurityFindings | Entity::ScanActivity | Entity::DnsActivity => {
            Ok(())
        }
        _ => Err(ServiceError::InvalidRequest(
            "entity not supported by events query".into(),
        )),
    }
}
