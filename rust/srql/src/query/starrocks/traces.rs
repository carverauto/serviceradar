//! `in:traces` (spans; also `otel_traces`, `trace_spans`) and
//! `in:otel_trace_summaries` (also `trace_summaries`, `traces_summaries`) in
//! the StarRocks dialect.
//!
//! With the warehouse enabled EventWriter writes spans only to
//! `serviceradar.otel_traces` and `RefreshTraceSummariesWorker` derives
//! `serviceradar.otel_trace_summaries` from them (`priv/starrocks/0022`), with
//! the CNPG tables' column names. This module answers the queries the CNPG
//! builders (`query/traces.rs`, `query/trace_summaries.rs`) answer, with the
//! same rows:
//!
//! * Listings project exactly the columns the CNPG builders select, in their
//!   order: every `otel_traces` column for spans, the summary builder's select
//!   list for summaries.
//! * Time bounds are the closed `[start, end]` CNPG binds for listings and
//!   summary stats, and the half-open `[start, end)` over `bucket` it binds for
//!   rollups, at microsecond precision.
//! * Filters, operators and sort fields are the CNPG builders' own, including
//!   their NULL handling, which differs by builder: a span text negation keeps
//!   NULL rows, a summary or rollup one drops them. `service_name` on
//!   summaries is membership in `service_set`, as on CNPG. A field or operator
//!   CNPG refuses is refused here too.
//! * `rollup_stats:summary` and `rollup_stats:red` read the `traces_stats_5m`
//!   and `spans_red_1h` views with the CNPG aggregation over their buckets,
//!   including its percentile of per-bucket percentiles; `translate_raw`
//!   computes the same buckets from `otel_traces` when a view is behind.
//! * Summary `stats:` uses the CNPG parser, so both accept the same
//!   expressions; it is one row of the aliased values, as on CNPG.
//! * Sort terms carry Postgres's NULL placement, and listings break ties on
//!   the key, where CNPG leaves ties in no particular order.

use super::super::trace_summaries::{self, StatsExprKind};
use super::super::traces;
use super::super::{PaginationMeta, QueryPlan, TranslateResponse, types::BindParam};
use super::{literal_list, pg_order_sql, sql_literal, text_predicate, text_predicate_on};
use crate::{
    error::{Result, ServiceError},
    parser::{Entity, Filter, FilterOp, OrderDirection},
};
use chrono::{DateTime, Duration, Utc};

/// Every column of the CNPG `otel_traces` table, in `schema::otel_traces`
/// order: what the CNPG span listing selects.
const SPAN_ROW_COLUMNS: &[&str] = &[
    "timestamp",
    "trace_id",
    "span_id",
    "parent_span_id",
    "trace_state",
    "name",
    "kind",
    "start_time_unix_nano",
    "end_time_unix_nano",
    "service_name",
    "service_version",
    "service_instance",
    "service_namespace",
    "deployment_environment",
    "scope_name",
    "scope_version",
    "scope_attributes",
    "status_code",
    "status_message",
    "attributes",
    "resource_attributes",
    "events",
    "links",
    "dropped_attributes_count",
    "dropped_events_count",
    "dropped_links_count",
    "created_at",
    "ingest_identity",
    "ingest_agent_id",
    "ingest_partition",
];

/// The CNPG summary listing's select list.
const SUMMARY_ROW_COLUMNS: &[&str] = &[
    "timestamp",
    "trace_id",
    "root_span_id",
    "root_span_name",
    "root_service_name",
    "root_service_namespace",
    "deployment_environment",
    "root_span_kind",
    "start_time_unix_nano",
    "end_time_unix_nano",
    "duration_ms",
    "status_code",
    "status_message",
    "service_set",
    "span_count",
    "error_count",
];

/// Text filter fields of spans and their columns (`traces::apply_filter`).
const SPAN_TEXT_FIELDS: &[(&str, &str)] = &[
    ("trace_id", "trace_id"),
    ("span_id", "span_id"),
    ("parent_span_id", "parent_span_id"),
    ("service_name", "service_name"),
    ("service.name", "service_name"),
    ("service_namespace", "service_namespace"),
    ("service.namespace", "service_namespace"),
    ("deployment_environment", "deployment_environment"),
    ("deployment.environment", "deployment_environment"),
    ("service_version", "service_version"),
    ("service_instance", "service_instance"),
    ("scope_name", "scope_name"),
    ("scope_version", "scope_version"),
    ("name", "name"),
    ("span_name", "name"),
    ("status_message", "status_message"),
    ("ingest_identity", "ingest_identity"),
    ("ingest_agent_id", "ingest_agent_id"),
    ("ingest_partition", "ingest_partition"),
];

/// Text filter fields of summaries (`trace_summaries::build_filters_clause_raw`).
const SUMMARY_TEXT_FIELDS: &[(&str, &str)] = &[
    ("trace_id", "trace_id"),
    ("root_span_id", "root_span_id"),
    ("root_span_name", "root_span_name"),
    ("root_service_name", "root_service_name"),
    ("root_service_namespace", "root_service_namespace"),
    ("deployment_environment", "deployment_environment"),
    ("deployment.environment", "deployment_environment"),
];

/// Microsecond `DATETIME` literal, the precision both backends store.
fn instant(value: DateTime<Utc>) -> String {
    format!("'{}'", value.format("%Y-%m-%d %H:%M:%S%.6f"))
}

fn quoted(column: &str) -> String {
    format!("`{column}`")
}

fn column_for(fields: &[(&str, &'static str)], field: &str) -> Option<&'static str> {
    fields
        .iter()
        .find(|(name, _)| *name == field)
        .map(|(_, column)| *column)
}

fn response(plan: &QueryPlan, sql: String) -> TranslateResponse {
    let params = plan
        .time_range
        .as_ref()
        .map(|range| {
            vec![
                BindParam::timestamptz(range.start),
                BindParam::timestamptz(range.end),
            ]
        })
        .unwrap_or_default();
    TranslateResponse {
        sql,
        params,
        pagination: PaginationMeta {
            next_cursor: None,
            prev_cursor: None,
            limit: Some(plan.limit),
        },
        viz: None,
    }
}

pub(super) fn translate(
    plan: &QueryPlan,
    database: &str,
    allow_rollup: bool,
) -> Result<TranslateResponse> {
    let sql = match plan.entity {
        Entity::Traces => {
            traces::refuse_unsupported_clauses(plan)?;
            match rollup_kind(plan) {
                Some(kind) => rollup_sql(plan, database, kind, allow_rollup)?,
                None => span_rows_sql(plan, database)?,
            }
        }
        Entity::TraceSummaries => {
            trace_summaries::refuse_unsupported_clauses(plan)?;
            match plan
                .stats
                .as_ref()
                .map(|stats| stats.as_raw().trim())
                .filter(|raw| !raw.is_empty())
            {
                Some(raw) => summary_stats_sql(plan, database, raw)?,
                None => summary_rows_sql(plan, database)?,
            }
        }
        _ => {
            return Err(ServiceError::Internal(anyhow::anyhow!(
                "the StarRocks traces dialect was handed {:?}",
                plan.entity
            )));
        }
    };
    Ok(response(plan, sql))
}

fn rollup_kind(plan: &QueryPlan) -> Option<&str> {
    plan.rollup_stats
        .as_deref()
        .map(str::trim)
        .filter(|kind| !kind.is_empty())
}

fn where_sql(predicates: &[String]) -> String {
    if predicates.is_empty() {
        String::new()
    } else {
        format!(" WHERE {}", predicates.join(" AND "))
    }
}

fn closed_time_bounds(plan: &QueryPlan) -> Vec<String> {
    plan.time_range
        .as_ref()
        .map(|range| {
            vec![
                format!("`timestamp` >= {}", instant(range.start)),
                format!("`timestamp` <= {}", instant(range.end)),
            ]
        })
        .unwrap_or_default()
}

// ---------------------------------------------------------------------------
// Spans

/// `status_code` / `kind` on spans: equality, negation (which drops NULL rows,
/// as Diesel's `<>` does) and lists; an empty list filters nothing.
fn span_int_predicate(column: &str, filter: &Filter) -> Result<Option<String>> {
    let (scalar_error, list_error, op_error) = if column == "status_code" {
        (
            "status_code must be an integer",
            "status_code list must be integers",
            "status_code filter only supports equality or list comparisons",
        )
    } else {
        (
            "span kind must be an integer",
            "span kind list must be integers",
            "kind filter only supports equality comparisons",
        )
    };
    let column = quoted(column);
    match filter.op {
        FilterOp::Eq | FilterOp::NotEq => {
            let value = filter
                .value
                .as_scalar()?
                .parse::<i32>()
                .map_err(|_| ServiceError::InvalidRequest(scalar_error.into()))?;
            let op = if matches!(filter.op, FilterOp::Eq) {
                "="
            } else {
                "<>"
            };
            Ok(Some(format!("{column} {op} {value}")))
        }
        FilterOp::In | FilterOp::NotIn => {
            let values = filter
                .value
                .as_list()?
                .iter()
                .map(|value| value.parse::<i32>())
                .collect::<std::result::Result<Vec<_>, _>>()
                .map_err(|_| ServiceError::InvalidRequest(list_error.into()))?;
            if values.is_empty() {
                return Ok(None);
            }
            let list = values
                .iter()
                .map(i32::to_string)
                .collect::<Vec<_>>()
                .join(", ");
            let op = if matches!(filter.op, FilterOp::In) {
                "IN"
            } else {
                "NOT IN"
            };
            Ok(Some(format!("{column} {op} ({list})")))
        }
        _ => Err(ServiceError::InvalidRequest(op_error.into())),
    }
}

fn span_filter(filter: &Filter) -> Result<Option<String>> {
    let field = filter.field.as_str();
    if let Some(column) = column_for(SPAN_TEXT_FIELDS, field) {
        return text_predicate(column, filter, true);
    }
    match field {
        "status_code" => span_int_predicate("status_code", filter),
        "kind" | "span_kind" => span_int_predicate("kind", filter),
        other => Err(ServiceError::InvalidRequest(format!(
            "unsupported filter field for traces: '{other}'"
        ))),
    }
}

/// `traces::apply_ordering`: the requested terms; with none, span start order
/// when the query pins trace ids and newest first otherwise. Ties then break on
/// the key, in the direction of the first term.
fn span_rows_sql(plan: &QueryPlan, database: &str) -> Result<String> {
    let mut predicates = closed_time_bounds(plan);
    for filter in &plan.filters {
        predicates.extend(span_filter(filter)?);
    }
    let mut terms = Vec::with_capacity(plan.order.len() + 3);
    for clause in &plan.order {
        let column = traces::row_sort_column(clause.field.as_str())?;
        terms.push(format!(
            "{} {}",
            quoted(column),
            pg_order_sql(clause.direction)
        ));
    }
    let tie = if plan.order.is_empty() {
        if traces::has_trace_id_equality(plan) {
            terms.push(format!(
                "`start_time_unix_nano` {}",
                pg_order_sql(OrderDirection::Asc)
            ));
            OrderDirection::Asc
        } else {
            terms.push(format!(
                "`timestamp` {}",
                pg_order_sql(OrderDirection::Desc)
            ));
            OrderDirection::Desc
        }
    } else {
        plan.order[0].direction
    };
    for key in ["trace_id", "span_id", "timestamp"] {
        let key_sql = quoted(key);
        if !terms
            .iter()
            .any(|term| term.starts_with(&format!("{key_sql} ")))
        {
            terms.push(format!("{key_sql} {}", pg_order_sql(tie)));
        }
    }
    let select = SPAN_ROW_COLUMNS
        .iter()
        .map(|column| quoted(column))
        .collect::<Vec<_>>()
        .join(", ");
    Ok(format!(
        "SELECT {select} FROM {database}.otel_traces{} ORDER BY {} LIMIT {} OFFSET {}",
        where_sql(&predicates),
        terms.join(", "),
        plan.limit,
        plan.offset
    ))
}

// ---------------------------------------------------------------------------
// Rollups

struct Rollup {
    view: &'static str,
    width: Duration,
    /// The raw-table bucket expression, as the view computes `bucket`.
    bucket_sql: &'static str,
    /// Per-bucket aggregates, exactly as the view defines them.
    per_bucket: &'static str,
    /// Raw-table form of each grouping column, as the view computes it.
    groups: &'static [(&'static str, &'static str)],
    /// Raw rows the view aggregates.
    scope: Option<&'static str>,
    /// The CNPG aggregation over the view's buckets, as named columns.
    select: &'static str,
}

const SUMMARY_ROLLUP: Rollup = Rollup {
    view: "traces_stats_5m",
    width: Duration::minutes(5),
    bucket_sql: "time_slice(`timestamp`, INTERVAL 5 MINUTE)",
    per_bucket: "COUNT(*) AS total_count, \
        SUM(CASE WHEN status_code = 2 THEN 1 ELSE 0 END) AS error_count, \
        AVG(CAST(`end_time_unix_nano` - `start_time_unix_nano` AS DOUBLE) / 1000000.0) AS avg_duration_ms, \
        percentile_cont(CAST(`end_time_unix_nano` - `start_time_unix_nano` AS DOUBLE) / 1000000.0, 0.95) AS p95_duration_ms",
    groups: &[("service_name", "`service_name`")],
    scope: Some("`parent_span_id` IS NULL"),
    select: "COALESCE(SUM(total_count), 0) AS total, \
        COALESCE(SUM(error_count), 0) AS errors, \
        COALESCE(AVG(avg_duration_ms), 0) AS avg_duration_ms, \
        COALESCE(percentile_cont(p95_duration_ms, 0.95), 0) AS p95_duration_ms",
};

const RED_ROLLUP: Rollup = Rollup {
    view: "spans_red_1h",
    width: Duration::hours(1),
    bucket_sql: "date_trunc('hour', `timestamp`)",
    per_bucket: "COUNT(*) AS total_count, \
        SUM(CASE WHEN status_code = 2 THEN 1 ELSE 0 END) AS error_count, \
        SUM(CASE WHEN CAST(`end_time_unix_nano` - `start_time_unix_nano` AS DOUBLE) / 1000000.0 > 100 THEN 1 ELSE 0 END) AS slow_count, \
        AVG(CAST(`end_time_unix_nano` - `start_time_unix_nano` AS DOUBLE) / 1000000.0) AS avg_duration_ms, \
        percentile_cont(CAST(`end_time_unix_nano` - `start_time_unix_nano` AS DOUBLE) / 1000000.0, 0.5) AS p50_duration_ms, \
        percentile_cont(CAST(`end_time_unix_nano` - `start_time_unix_nano` AS DOUBLE) / 1000000.0, 0.95) AS p95_duration_ms, \
        MAX(CAST(`end_time_unix_nano` - `start_time_unix_nano` AS DOUBLE) / 1000000.0) AS max_duration_ms",
    groups: &[
        ("service_name", "COALESCE(`service_name`, '')"),
        ("service_namespace", "COALESCE(`service_namespace`, '')"),
        (
            "deployment_environment",
            "COALESCE(`deployment_environment`, '')",
        ),
    ],
    scope: None,
    select: "COALESCE(SUM(total_count), 0) AS total, \
        COALESCE(SUM(error_count), 0) AS errors, \
        COALESCE(SUM(slow_count), 0) AS slow, \
        CASE WHEN COALESCE(SUM(total_count), 0) > 0 \
            THEN CAST(SUM(error_count) AS DOUBLE) / CAST(SUM(total_count) AS DOUBLE) * 100.0 \
            ELSE 0 END AS error_rate, \
        CASE WHEN COALESCE(SUM(total_count), 0) > 0 \
            THEN SUM(avg_duration_ms * total_count) / CAST(SUM(total_count) AS DOUBLE) \
            ELSE 0 END AS avg_duration_ms, \
        COALESCE(percentile_cont(p50_duration_ms, 0.5), 0) AS p50_duration_ms, \
        COALESCE(percentile_cont(p95_duration_ms, 0.95), 0) AS p95_duration_ms, \
        COALESCE(MAX(max_duration_ms), 0) AS max_duration_ms",
};

/// `traces::build_*_rollup_stats`. The view serves it when fresh; otherwise
/// (`allow_rollup` false) the same buckets are computed from `otel_traces`.
fn rollup_sql(plan: &QueryPlan, database: &str, kind: &str, allow_rollup: bool) -> Result<String> {
    let rollup = match kind {
        "summary" => &SUMMARY_ROLLUP,
        "red" => &RED_ROLLUP,
        other => {
            return Err(ServiceError::InvalidRequest(format!(
                "unsupported rollup_stats type for traces: '{other}' (supported: summary, red)"
            )));
        }
    };
    let mut filters = Vec::new();
    for filter in &plan.filters {
        let column = traces::rollup_filter_column(kind, filter.field.as_str())?;
        filters.push((column, filter));
    }

    let source = if allow_rollup {
        let mut predicates = Vec::new();
        if let Some(range) = &plan.time_range {
            predicates.push(format!("`bucket` >= {}", instant(range.start)));
            predicates.push(format!("`bucket` < {}", instant(range.end)));
            // `day` is the view's partition column; bound it so the scan skips
            // the days the window cannot touch.
            predicates.push(format!(
                "`day` >= date_trunc('day', {})",
                instant(range.start)
            ));
            predicates.push(format!("`day` <= {}", instant(range.end)));
        }
        for (column, filter) in &filters {
            predicates.extend(text_predicate(column, filter, false)?);
        }
        format!("{database}.{}{}", rollup.view, where_sql(&predicates))
    } else {
        raw_rollup_source(plan, database, rollup, &filters)?
    };
    Ok(format!("SELECT {} FROM {source}", rollup.select))
}

/// The view's buckets computed from `otel_traces`, restricted as the view read
/// would be: a bucket is in the window when it starts in `[start, end)`, and
/// the group filters apply to the columns as the view computes them.
fn raw_rollup_source(
    plan: &QueryPlan,
    database: &str,
    rollup: &Rollup,
    filters: &[(&'static str, &Filter)],
) -> Result<String> {
    let mut predicates = Vec::new();
    if let Some(scope) = rollup.scope {
        predicates.push(scope.to_string());
    }
    if let Some(range) = &plan.time_range {
        // A row in a bucket that starts in `[start, end)` is itself in
        // `[start, end + width)`; these bounds only let the scan skip days.
        predicates.push(format!("`timestamp` >= {}", instant(range.start)));
        predicates.push(format!(
            "`timestamp` < {}",
            instant(range.end + rollup.width)
        ));
        predicates.push(format!("{} >= {}", rollup.bucket_sql, instant(range.start)));
        predicates.push(format!("{} < {}", rollup.bucket_sql, instant(range.end)));
    }
    for (column, filter) in filters {
        let expr = rollup
            .groups
            .iter()
            .find(|(name, _)| name == column)
            .map(|(_, expr)| *expr)
            .ok_or_else(|| {
                ServiceError::Internal(anyhow::anyhow!("rollup has no group column {column}"))
            })?;
        predicates.extend(text_predicate_on(expr, filter, false)?);
    }
    let groups = rollup
        .groups
        .iter()
        .map(|(_, expr)| *expr)
        .collect::<Vec<_>>()
        .join(", ");
    Ok(format!(
        "(SELECT {} AS bucket, {groups}, {} FROM {database}.otel_traces{} GROUP BY {}, {groups}) raw_buckets",
        rollup.bucket_sql,
        rollup.per_bucket,
        where_sql(&predicates),
        rollup.bucket_sql,
    ))
}

// ---------------------------------------------------------------------------
// Summaries

/// `trace_summaries::add_text_condition`: negations drop NULL rows, and an
/// empty `IN` list matches nothing (an empty `NOT IN` filters nothing).
fn summary_text_predicate(column: &str, filter: &Filter) -> Result<Option<String>> {
    if matches!(filter.op, FilterOp::In) && filter.value.as_list()?.is_empty() {
        return Ok(Some("FALSE".into()));
    }
    text_predicate(column, filter, false)
}

/// `trace_summaries::add_service_set_condition`: membership in `service_set`.
/// A negation reads a NULL set as empty, so the row is kept.
fn service_set_predicate(filter: &Filter) -> Result<Option<String>> {
    let array =
        |values: &[String]| format!("[{}]", literal_list(values.iter().map(String::as_str)));
    Ok(Some(match filter.op {
        FilterOp::Eq => format!(
            "array_contains(`service_set`, {})",
            sql_literal(filter.value.as_scalar()?)
        ),
        FilterOp::NotEq => format!(
            "NOT COALESCE(array_contains(`service_set`, {}), FALSE)",
            sql_literal(filter.value.as_scalar()?)
        ),
        FilterOp::In => {
            let values = filter.value.as_list()?;
            if values.is_empty() {
                "FALSE".into()
            } else {
                format!("arrays_overlap(`service_set`, {})", array(values))
            }
        }
        FilterOp::NotIn => {
            let values = filter.value.as_list()?;
            if values.is_empty() {
                return Ok(None);
            }
            format!(
                "NOT COALESCE(arrays_overlap(`service_set`, {}), FALSE)",
                array(values)
            )
        }
        FilterOp::Like | FilterOp::NotLike => {
            return Err(ServiceError::InvalidRequest(
                "service_name on otel_trace_summaries matches exact service names; \
                 wildcards are not supported (use root_service_name for pattern matches \
                 on the root span)"
                    .into(),
            ));
        }
        _ => {
            return Err(ServiceError::InvalidRequest(format!(
                "service_name filter does not support operator {:?}",
                filter.op
            )));
        }
    }))
}

fn comparison_op(column: &str, op: &FilterOp) -> Result<&'static str> {
    Ok(match op {
        FilterOp::Eq => "=",
        FilterOp::NotEq => "<>",
        FilterOp::Gt => ">",
        FilterOp::Gte => ">=",
        FilterOp::Lt => "<",
        FilterOp::Lte => "<=",
        _ => {
            return Err(ServiceError::InvalidRequest(format!(
                "{column} filter only supports equality or numeric comparisons"
            )));
        }
    })
}

fn summary_filter(filter: &Filter) -> Result<Option<String>> {
    let field = filter.field.as_str();
    if let Some(column) = column_for(SUMMARY_TEXT_FIELDS, field) {
        return summary_text_predicate(column, filter);
    }
    Ok(Some(match field {
        "service_name" => return service_set_predicate(filter),
        "status_code" | "root_span_kind" => {
            let op = match filter.op {
                FilterOp::Eq => "=",
                FilterOp::NotEq => "<>",
                _ => {
                    return Err(ServiceError::InvalidRequest(format!(
                        "{field} filter only supports equality"
                    )));
                }
            };
            let value = trace_summaries::parse_i32(filter)?;
            format!("{} {op} {value}", quoted(field))
        }
        "span_count" | "error_count" => {
            let op = comparison_op(field, &filter.op)?;
            let value = trace_summaries::parse_i64(filter)?;
            format!("{} {op} {value}", quoted(field))
        }
        "duration_ms" => {
            let op = comparison_op(field, &filter.op)?;
            let value = trace_summaries::parse_f64(filter)?;
            format!("`duration_ms` {op} {value:?}")
        }
        other => {
            return Err(ServiceError::InvalidRequest(format!(
                "unsupported filter field '{other}'"
            )));
        }
    }))
}

fn summary_predicates(plan: &QueryPlan) -> Result<Vec<String>> {
    let mut predicates = closed_time_bounds(plan);
    for filter in &plan.filters {
        predicates.extend(summary_filter(filter)?);
    }
    Ok(predicates)
}

/// `trace_summaries::build_order_clause`, newest first by default, ties broken
/// on `trace_id`.
fn summary_rows_sql(plan: &QueryPlan, database: &str) -> Result<String> {
    let predicates = summary_predicates(plan)?;
    let mut terms = Vec::with_capacity(plan.order.len() + 1);
    for clause in &plan.order {
        let column = trace_summaries::row_sort_column(clause.field.as_str())?;
        terms.push(format!(
            "{} {}",
            quoted(column),
            pg_order_sql(clause.direction)
        ));
    }
    let tie = plan
        .order
        .first()
        .map_or(OrderDirection::Desc, |clause| clause.direction);
    if terms.is_empty() {
        terms.push(format!(
            "`timestamp` {}",
            pg_order_sql(OrderDirection::Desc)
        ));
    }
    terms.push(format!("`trace_id` {}", pg_order_sql(tie)));
    let select = SUMMARY_ROW_COLUMNS
        .iter()
        .map(|column| quoted(column))
        .collect::<Vec<_>>()
        .join(", ");
    Ok(format!(
        "SELECT {select} FROM {database}.otel_trace_summaries{} ORDER BY {} LIMIT {} OFFSET {}",
        where_sql(&predicates),
        terms.join(", "),
        plan.limit,
        plan.offset
    ))
}

/// `trace_summaries::build_stats_select`: one row of the aliased values.
fn summary_stats_sql(plan: &QueryPlan, database: &str, raw: &str) -> Result<String> {
    let exprs = trace_summaries::parse_stats(raw)?;
    let mut columns = Vec::with_capacity(exprs.len());
    for expr in &exprs {
        let sql = match &expr.kind {
            StatsExprKind::Count => "COUNT(*)".to_string(),
            StatsExprKind::StatusCompare { comparator, value } => format!(
                "COALESCE(SUM(CASE WHEN COALESCE(`status_code`, 0) {} {value} THEN 1 ELSE 0 END), 0)",
                comparator.sql()
            ),
            StatsExprKind::DurationCompare {
                comparator,
                threshold,
            } => format!(
                "COALESCE(SUM(CASE WHEN COALESCE(`duration_ms`, 0) {} {threshold:?} THEN 1 ELSE 0 END), 0)",
                comparator.sql()
            ),
        };
        columns.push(format!("{sql} AS {}", quoted(&expr.alias)));
    }
    Ok(format!(
        "SELECT {} FROM {database}.otel_trace_summaries{}",
        columns.join(", "),
        where_sql(&summary_predicates(plan)?)
    ))
}

#[cfg(test)]
mod tests;
