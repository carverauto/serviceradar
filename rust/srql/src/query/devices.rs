mod filters;
mod order;
mod stats;

use self::{
    filters::{
        apply_default_active_filter, apply_filter, collect_filter_params, has_deleted_filter,
        should_apply_default_active_filter,
    },
    order::apply_ordering,
    stats::{
        DeviceStatsPayload, bind_param_from_device_stats, build_grouped_stats_query,
        build_rollup_stats_query, build_stats_query, parse_stats_spec, rewrite_placeholders,
    },
};
use super::{BindParam, QueryPlan};
use crate::{
    error::{Result, ServiceError},
    models::DeviceRow,
    parser::Entity,
    schema::ocsf_devices::dsl::{
        deleted_at as col_deleted_at, last_seen_time as col_last_seen_time, ocsf_devices,
    },
    time::TimeRange,
};
use diesel::pg::Pg;
use diesel::prelude::*;
use diesel::query_builder::{AsQuery, BoxedSelectStatement, FromClause};
use diesel::sql_types::BigInt;
use diesel_async::{AsyncPgConnection, RunQueryDsl};

type OcsfDevicesTable = crate::schema::ocsf_devices::table;
type DeviceFromClause = FromClause<OcsfDevicesTable>;
type DeviceQuery<'a> =
    BoxedSelectStatement<'a, <OcsfDevicesTable as AsQuery>::SqlType, DeviceFromClause, Pg>;
type DeviceStatsQuery<'a> = BoxedSelectStatement<'a, BigInt, DeviceFromClause, Pg>;

pub(super) async fn execute(
    conn: &mut AsyncPgConnection,
    plan: &QueryPlan,
) -> Result<Vec<serde_json::Value>> {
    ensure_entity(plan)?;

    if let Some(rollup_sql) = build_rollup_stats_query(plan)? {
        let rows: Vec<DeviceStatsPayload> = diesel::sql_query(&rollup_sql.sql)
            .load::<DeviceStatsPayload>(conn)
            .await
            .map_err(|err| ServiceError::Internal(err.into()))?;
        return Ok(rows
            .into_iter()
            .filter_map(|row| row.payload.map(serde_json::Value::from))
            .collect());
    }

    if let Some(spec) = parse_stats_spec(plan.stats.as_ref().map(|s| s.as_raw()))? {
        // Check if this is a grouped stats query
        if !spec.group_fields.is_empty() {
            let grouped_sql = build_grouped_stats_query(plan, &spec)?;
            // The grouped-stats builder emits `?` placeholders; Postgres wants
            // `$n`. Diesel's .bind() supplies the values but never rewrites the
            // SQL text, so this has to happen here as well as in
            // to_sql_and_params -- otherwise every *filtered* grouped query is
            // a syntax error at execution while translation-only tests pass.
            let sql = rewrite_placeholders(&grouped_sql.sql);
            let mut query = diesel::sql_query(sql).into_boxed();
            for bind in grouped_sql.binds {
                query = bind.apply(query);
            }
            let rows: Vec<DeviceStatsPayload> = query
                .load::<DeviceStatsPayload>(conn)
                .await
                .map_err(|err| ServiceError::Internal(err.into()))?;
            return Ok(rows
                .into_iter()
                .filter_map(|row| row.payload.map(serde_json::Value::from))
                .collect());
        }

        // Simple count (ungrouped)
        let query = build_stats_query(plan, &spec)?;
        let values: Vec<i64> = query
            .load(conn)
            .await
            .map_err(|err| ServiceError::Internal(err.into()))?;
        let count = values.into_iter().next().unwrap_or(0);
        return Ok(vec![serde_json::json!({ spec.alias: count })]);
    }

    let query = build_query(plan)?;
    let rows: Vec<DeviceRow> = query
        .select(DeviceRow::as_select())
        .limit(plan.limit)
        .offset(plan.offset)
        .load::<DeviceRow>(conn)
        .await
        .map_err(|err| ServiceError::Internal(err.into()))?;

    Ok(rows.into_iter().map(DeviceRow::into_json).collect())
}

pub(super) fn to_sql_and_params(plan: &QueryPlan) -> Result<(String, Vec<BindParam>)> {
    ensure_entity(plan)?;

    if let Some(rollup_sql) = build_rollup_stats_query(plan)? {
        return Ok((rollup_sql.sql, Vec::new()));
    }

    if let Some(spec) = parse_stats_spec(plan.stats.as_ref().map(|s| s.as_raw()))? {
        // Check if this is a grouped stats query
        if !spec.group_fields.is_empty() {
            let grouped_sql = build_grouped_stats_query(plan, &spec)?;
            let sql = rewrite_placeholders(&grouped_sql.sql);
            let params: Vec<BindParam> = grouped_sql
                .binds
                .into_iter()
                .map(bind_param_from_device_stats)
                .collect();
            return Ok((sql, params));
        }

        // Simple count (ungrouped)
        let query = build_stats_query(plan, &spec)?;
        let sql = super::diesel_sql(&query)?;

        let mut params = Vec::new();

        if let Some(TimeRange { start, end }) = &plan.time_range {
            params.push(BindParam::timestamptz(*start));
            params.push(BindParam::timestamptz(*end));
        }

        for filter in &plan.filters {
            collect_filter_params(&mut params, filter)?;
        }

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
        Entity::Devices => Ok(()),
        _ => Err(ServiceError::InvalidRequest(
            "entity not supported by devices query".into(),
        )),
    }
}

fn build_query(plan: &QueryPlan) -> Result<DeviceQuery<'static>> {
    let mut query = ocsf_devices.into_boxed::<Pg>();

    if !plan.include_deleted && !has_deleted_filter(&plan.filters) {
        query = query.filter(col_deleted_at.is_null());
    }

    if should_apply_default_active_filter(&plan.filters)? {
        query = apply_default_active_filter(query);
    }

    if let Some(TimeRange { start, end }) = &plan.time_range {
        query = query.filter(
            col_last_seen_time
                .ge(*start)
                .and(col_last_seen_time.le(*end)),
        );
    }

    for filter in &plan.filters {
        query = apply_filter(query, filter)?;
    }

    query = apply_ordering(query, &plan.order);
    Ok(query)
}
