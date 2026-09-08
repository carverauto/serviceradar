mod filters;
mod metadata;
mod rollup;
mod stats;
mod stats_clauses;
mod stats_expr;
mod time;
mod topn;

use self::{
    filters::{apply_filter, collect_filter_params},
    rollup::build_rollup_stats_query,
    stats::{LogsStatsPayload, bind_param_from_stats, build_stats_query, rewrite_placeholders},
    time::{apply_ordering, effective_timestamp_expr},
};
use super::{BindParam, QueryPlan};
use crate::{
    error::{Result, ServiceError},
    models::LogRow,
    parser::Entity,
    schema::logs::dsl::logs,
    time::TimeRange,
};
use diesel::pg::Pg;
use diesel::prelude::*;
use diesel::query_builder::{AsQuery, BoxedSelectStatement, FromClause};
use diesel_async::{AsyncPgConnection, RunQueryDsl};
use serde_json::Value;

type LogsTable = crate::schema::logs::table;
type LogsFromClause = FromClause<LogsTable>;
type LogsQuery<'a> = BoxedSelectStatement<'a, <LogsTable as AsQuery>::SqlType, LogsFromClause, Pg>;

const MAX_LIST_FILTER_VALUES: usize = 200;

/// Every category-bearing severity text understood by the log cards. Text in
/// this set is authoritative; numeric severity is only a fallback for absent
/// or unrecognized text.
pub(super) const RECOGNIZED_SEVERITY_TEXTS: &[&str] = &[
    "fatal",
    "critical",
    "emergency",
    "alert",
    "error",
    "err",
    "warning",
    "warn",
    "info",
    "information",
    "informational",
    "notice",
    "debug",
    "trace",
    "severity_number_fatal",
    "severity_number_fatal2",
    "severity_number_fatal3",
    "severity_number_fatal4",
    "severity_number_error",
    "severity_number_error2",
    "severity_number_error3",
    "severity_number_error4",
    "severity_number_warn",
    "severity_number_warn2",
    "severity_number_warn3",
    "severity_number_warn4",
    "severity_number_info",
    "severity_number_info2",
    "severity_number_info3",
    "severity_number_info4",
    "severity_number_debug",
    "severity_number_debug2",
    "severity_number_debug3",
    "severity_number_debug4",
    "severity_number_trace",
    "severity_number_trace2",
    "severity_number_trace3",
    "severity_number_trace4",
];

pub(super) async fn execute(conn: &mut AsyncPgConnection, plan: &QueryPlan) -> Result<Vec<Value>> {
    ensure_entity(plan)?;

    // Handle rollup_stats queries against pre-computed CAGGs
    if let Some(rollup_sql) = build_rollup_stats_query(plan)? {
        let query = rollup_sql.to_boxed_query();
        let rows: Vec<LogsStatsPayload> = query
            .load::<LogsStatsPayload>(conn)
            .await
            .map_err(|err| ServiceError::Internal(err.into()))?;
        return Ok(rows
            .into_iter()
            .filter_map(|row| row.payload.map(serde_json::Value::from))
            .collect());
    }

    if let Some(stats_sql) = build_stats_query(plan)? {
        let query = stats_sql.to_boxed_query();
        let rows: Vec<LogsStatsPayload> = query
            .load::<LogsStatsPayload>(conn)
            .await
            .map_err(|err| ServiceError::Internal(err.into()))?;
        return Ok(rows
            .into_iter()
            .filter_map(|row| row.payload.map(serde_json::Value::from))
            .collect());
    }

    if let Some(query) = topn::build(plan)? {
        let rows = query.load(conn).await?;
        return Ok(rows.into_iter().map(LogRow::into_json).collect());
    }

    let query = build_query(plan)?;
    let rows: Vec<LogRow> = query
        .limit(plan.limit)
        .offset(plan.offset)
        .load(conn)
        .await
        .map_err(|err| ServiceError::Internal(err.into()))?;

    Ok(rows.into_iter().map(LogRow::into_json).collect())
}

pub(super) fn to_sql_and_params(plan: &QueryPlan) -> Result<(String, Vec<BindParam>)> {
    ensure_entity(plan)?;

    // Handle rollup_stats queries against pre-computed CAGGs
    if let Some(rollup_sql) = build_rollup_stats_query(plan)? {
        let sql = rewrite_placeholders(&rollup_sql.sql);
        let params = rollup_sql
            .binds
            .into_iter()
            .map(bind_param_from_stats)
            .collect();
        return Ok((sql, params));
    }

    if let Some(stats_sql) = build_stats_query(plan)? {
        let sql = rewrite_placeholders(&stats_sql.sql);
        let params = stats_sql
            .binds
            .into_iter()
            .map(bind_param_from_stats)
            .collect();
        return Ok((sql, params));
    }

    if let Some(query) = topn::build(plan)? {
        return Ok(query.into_parts());
    }

    let query = build_query(plan)?;
    let sql = super::diesel_sql(&query.limit(plan.limit).offset(plan.offset))?;

    let mut params = collect_base_params(plan)?;
    params.push(BindParam::Int(plan.limit));
    params.push(BindParam::Int(plan.offset));

    Ok((sql, params))
}

fn collect_base_params(plan: &QueryPlan) -> Result<Vec<BindParam>> {
    let mut params = Vec::new();
    if let Some(TimeRange { start, end }) = &plan.time_range {
        params.push(BindParam::timestamptz(*start));
        params.push(BindParam::timestamptz(*end));
    }

    let severity_any = severity_match_any(plan);
    let mut deferred_text = None;
    let mut deferred_numeric = None;

    for filter in &plan.filters {
        match filter.field.as_str() {
            "severity_match" if severity_any => {}
            "severity_text" | "severity" | "level" if severity_any => deferred_text = Some(filter),
            "severity_number" if severity_any => deferred_numeric = Some(filter),
            _ => collect_filter_params(&mut params, filter)?,
        }
    }

    if severity_any {
        let (Some(text_filter), Some(number_filter)) = (deferred_text, deferred_numeric) else {
            return Err(ServiceError::InvalidRequest(
                "severity_match:any requires severity and severity_number filters".into(),
            ));
        };
        collect_filter_params(&mut params, text_filter)?;
        params.push(BindParam::TextArray(
            RECOGNIZED_SEVERITY_TEXTS
                .iter()
                .map(|value| (*value).to_string())
                .collect(),
        ));
        collect_filter_params(&mut params, number_filter)?;
    }

    Ok(params)
}

fn ensure_entity(plan: &QueryPlan) -> Result<()> {
    match plan.entity {
        Entity::Logs => Ok(()),
        _ => Err(ServiceError::InvalidRequest(
            "entity not supported by logs query".into(),
        )),
    }
}

fn build_query(plan: &QueryPlan) -> Result<LogsQuery<'static>> {
    let mut query = logs.into_boxed::<Pg>();

    if let Some(TimeRange { start, end }) = &plan.time_range {
        query = query.filter(
            effective_timestamp_expr()
                .ge(*start)
                .and(effective_timestamp_expr().le(*end)),
        );
    }

    let severity_any = severity_match_any(plan);
    let mut severity_text = None;
    let mut severity_number = None;

    for filter in &plan.filters {
        match filter.field.as_str() {
            "severity_match" if severity_any => {}
            "severity_text" | "severity" | "level" if severity_any => severity_text = Some(filter),
            "severity_number" if severity_any => severity_number = Some(filter),
            _ => query = apply_filter(query, filter)?,
        }
    }

    if severity_any {
        query = filters::apply_severity_any_filter(query, severity_text, severity_number)?;
    }

    query = apply_ordering(query, &plan.order);
    Ok(query)
}

fn severity_match_any(plan: &QueryPlan) -> bool {
    plan.filters.iter().any(|filter| {
        filter.field == "severity_match"
            && matches!(filter.op, crate::parser::FilterOp::Eq)
            && matches!(filter.value.as_scalar(), Ok("any"))
    })
}

fn enforce_list_limit(field: &str, len: usize) -> Result<()> {
    if len > MAX_LIST_FILTER_VALUES {
        return Err(ServiceError::InvalidRequest(format!(
            "{field} filters support at most {MAX_LIST_FILTER_VALUES} values"
        )));
    }
    Ok(())
}

#[cfg(test)]
mod test_support {
    use super::QueryPlan;
    use crate::parser::{Entity, Filter, FilterOp, FilterValue};
    use crate::time::TimeRange;
    use chrono::{Duration as ChronoDuration, TimeZone, Utc};

    pub(super) fn data_plan(filters: Vec<Filter>) -> QueryPlan {
        let start = Utc.with_ymd_and_hms(2025, 1, 1, 0, 0, 0).unwrap();
        let end = start + ChronoDuration::hours(24);
        QueryPlan {
            entity: Entity::Logs,
            filters,
            order: Vec::new(),
            limit: 100,
            offset: 0,
            time_range: Some(TimeRange { start, end }),
            stats: None,
            downsample: None,
            rollup_stats: None,
            other: false,
            include_deleted: false,
        }
    }

    pub(super) fn scalar_filter(field: &str, op: FilterOp, value: &str) -> Filter {
        Filter {
            field: field.into(),
            op,
            value: FilterValue::Scalar(value.to_string()),
        }
    }
}
