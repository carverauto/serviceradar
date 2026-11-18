//! `in:declarative_check_results` - materialized per-target declarative check verdicts.
//!
//! Joins `declarative_check_instances` with `declarative_checks` so callers can
//! filter, group, sort, and read by `check_slug`, `check_name`, and `state`
//! without knowing check UUIDs.

mod stats;

use super::{BindParam, QueryPlan, bind_sql_param, rewrite_placeholders};
use crate::{
    error::{Result, ServiceError},
    models::DeclarativeCheckResultRow,
    parser::{Entity, Filter, FilterOp, OrderClause, OrderDirection},
    schema::{declarative_check_instances, declarative_checks},
    time::{TimeRange, parse_time_value},
};
use chrono::{DateTime, Utc};
use diesel::dsl::sql;
use diesel::expression::SqlLiteral;
use diesel::pg::Pg;
use diesel::prelude::*;
use diesel::query_builder::{BoxedSelectStatement, FromClause};
use diesel::sql_types::Text;
use diesel_async::{AsyncPgConnection, RunQueryDsl};
use stats::{StatsPayload, build_stats_query, parse_stats_spec};
use uuid::Uuid;

type ResultsJoin = diesel::helper_types::InnerJoinQuerySource<
    declarative_check_instances::table,
    declarative_checks::table,
>;
type ResultsFromClause = FromClause<ResultsJoin>;

/// Joined `declarative_checks` columns are aliased explicitly so Rust row
/// serialization and Elixir `Postgrex.Result` column names return identical keys.
type SelectTuple = (
    declarative_check_instances::id,
    declarative_check_instances::check_id,
    SqlLiteral<Text>,
    SqlLiteral<Text>,
    SqlLiteral<Text>,
    declarative_check_instances::target_key,
    declarative_check_instances::target_kind,
    declarative_check_instances::device_uid,
    declarative_check_instances::service_target_id,
    declarative_check_instances::verdict,
    declarative_check_instances::status,
    declarative_check_instances::summary,
    declarative_check_instances::node_snapshots,
    declarative_check_instances::evaluated_at,
    declarative_check_instances::changed_at,
);
type ResultsQuery<'a> =
    BoxedSelectStatement<'a, diesel::dsl::SqlTypeOf<SelectTuple>, ResultsFromClause, Pg>;

#[derive(Debug, Clone)]
pub(super) enum TimestampBound {
    Comparison(DateTime<Utc>),
    Range {
        start: DateTime<Utc>,
        end: DateTime<Utc>,
        negated: bool,
    },
}

/// Column order must match `DeclarativeCheckResultRow`'s field order.
fn select_tuple() -> SelectTuple {
    (
        declarative_check_instances::id,
        declarative_check_instances::check_id,
        sql::<Text>("declarative_checks.slug AS check_slug"),
        sql::<Text>("declarative_checks.name AS check_name"),
        sql::<Text>("declarative_checks.state AS state"),
        declarative_check_instances::target_key,
        declarative_check_instances::target_kind,
        declarative_check_instances::device_uid,
        declarative_check_instances::service_target_id,
        declarative_check_instances::verdict,
        declarative_check_instances::status,
        declarative_check_instances::summary,
        declarative_check_instances::node_snapshots,
        declarative_check_instances::evaluated_at,
        declarative_check_instances::changed_at,
    )
}

pub(super) async fn execute(
    conn: &mut AsyncPgConnection,
    plan: &QueryPlan,
) -> Result<Vec<serde_json::Value>> {
    ensure_entity(plan)?;
    let now = Utc::now();

    if let Some(spec) = parse_stats_spec(plan.stats.as_ref().map(|s| s.as_raw()))? {
        let built = build_stats_query(plan, &spec, now)?;
        let sql = rewrite_placeholders(&built.sql);
        let mut query = diesel::sql_query(sql).into_boxed();
        for param in built.params {
            query = bind_sql_param(query, param)?;
        }
        let rows: Vec<StatsPayload> = query
            .load(conn)
            .await
            .map_err(|err| ServiceError::Internal(err.into()))?;
        return Ok(rows
            .into_iter()
            .filter_map(|row| row.payload.map(serde_json::Value::from))
            .collect());
    }

    let rows: Vec<DeclarativeCheckResultRow> = build_query(plan, now)?
        .limit(plan.limit)
        .offset(plan.offset)
        .load::<DeclarativeCheckResultRow>(conn)
        .await
        .map_err(|err| ServiceError::Internal(err.into()))?;

    Ok(rows
        .into_iter()
        .map(DeclarativeCheckResultRow::into_json)
        .collect())
}

pub(super) fn to_sql_and_params(plan: &QueryPlan) -> Result<(String, Vec<BindParam>)> {
    ensure_entity(plan)?;
    let now = Utc::now();

    if let Some(spec) = parse_stats_spec(plan.stats.as_ref().map(|s| s.as_raw()))? {
        let built = build_stats_query(plan, &spec, now)?;
        return Ok((rewrite_placeholders(&built.sql), built.params));
    }

    let query = build_query(plan, now)?
        .limit(plan.limit)
        .offset(plan.offset);
    let sql = super::diesel_sql(&query)?;

    let mut params = Vec::new();
    if let Some(TimeRange { start, end }) = &plan.time_range {
        params.push(BindParam::timestamptz(*start));
        params.push(BindParam::timestamptz(*end));
    }

    for filter in &plan.filters {
        collect_filter_params(&mut params, filter, now)?;
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
        Entity::DeclarativeCheckResults => Ok(()),
        _ => Err(ServiceError::InvalidRequest(
            "entity not supported by declarative check results query".into(),
        )),
    }
}

fn build_query(plan: &QueryPlan, now: DateTime<Utc>) -> Result<ResultsQuery<'static>> {
    let mut query = declarative_check_instances::table
        .inner_join(declarative_checks::table)
        .select(select_tuple())
        .into_boxed::<Pg>();

    if let Some(TimeRange { start, end }) = &plan.time_range {
        query = query.filter(
            declarative_check_instances::evaluated_at
                .ge(*start)
                .and(declarative_check_instances::evaluated_at.le(*end)),
        );
    }

    for filter in &plan.filters {
        query = apply_filter(query, filter, now)?;
    }

    Ok(apply_ordering(query, &plan.order))
}

fn apply_filter<'a>(
    mut query: ResultsQuery<'a>,
    filter: &Filter,
    now: DateTime<Utc>,
) -> Result<ResultsQuery<'a>> {
    match filter.field.as_str() {
        "check" | "check_slug" | "slug" => {
            query = apply_text_filter!(query, filter, declarative_checks::slug)?;
        }
        "check_name" | "name" => {
            query = apply_text_filter!(query, filter, declarative_checks::name)?;
        }
        "state" | "check_state" => {
            query = apply_text_filter!(query, filter, declarative_checks::state)?;
        }
        "check_id" => {
            let check_id = parse_check_uuid(filter)?;
            query = apply_eq_filter!(
                query,
                filter,
                declarative_check_instances::check_id,
                check_id,
                "check_id filter only supports equality"
            )?;
        }
        "target_key" | "target" => {
            query = apply_text_filter!(query, filter, declarative_check_instances::target_key)?;
        }
        "target_kind" => {
            query = apply_text_filter!(query, filter, declarative_check_instances::target_kind)?;
        }
        "device_uid" | "device" | "device_id" | "uid" => {
            query = apply_text_filter!(query, filter, declarative_check_instances::device_uid)?;
        }
        "service_target_id" => {
            query = apply_text_filter!(
                query,
                filter,
                declarative_check_instances::service_target_id
            )?;
        }
        "verdict" => {
            query = apply_text_filter!(query, filter, declarative_check_instances::verdict)?;
        }
        "status" => {
            query = apply_text_filter!(query, filter, declarative_check_instances::status)?;
        }
        "evaluated_at" => {
            query = match parse_timestamp_bound(filter, now)? {
                TimestampBound::Comparison(ts) => apply_ordered_filter!(
                    query,
                    filter,
                    declarative_check_instances::evaluated_at,
                    ts
                )?,
                TimestampBound::Range {
                    start,
                    end,
                    negated: false,
                } => query.filter(
                    declarative_check_instances::evaluated_at
                        .ge(start)
                        .and(declarative_check_instances::evaluated_at.le(end)),
                ),
                TimestampBound::Range {
                    start,
                    end,
                    negated: true,
                } => query.filter(
                    declarative_check_instances::evaluated_at
                        .lt(start)
                        .or(declarative_check_instances::evaluated_at.gt(end)),
                ),
            };
        }
        "changed_at" => {
            query = match parse_timestamp_bound(filter, now)? {
                TimestampBound::Comparison(ts) => apply_ordered_filter!(
                    query,
                    filter,
                    declarative_check_instances::changed_at,
                    ts
                )?,
                TimestampBound::Range {
                    start,
                    end,
                    negated: false,
                } => query.filter(
                    declarative_check_instances::changed_at
                        .ge(start)
                        .and(declarative_check_instances::changed_at.le(end)),
                ),
                TimestampBound::Range {
                    start,
                    end,
                    negated: true,
                } => query.filter(
                    declarative_check_instances::changed_at
                        .lt(start)
                        .or(declarative_check_instances::changed_at.gt(end)),
                ),
            };
        }
        other => {
            return Err(ServiceError::InvalidRequest(format!(
                "unsupported filter field '{other}' for declarative check results"
            )));
        }
    }

    Ok(query)
}

/// Mirrors `apply_filter` so bind types and order stay identical.
fn collect_filter_params(
    params: &mut Vec<BindParam>,
    filter: &Filter,
    now: DateTime<Utc>,
) -> Result<()> {
    match filter.field.as_str() {
        "check" | "check_slug" | "slug" | "check_name" | "name" | "state" | "check_state"
        | "target_key" | "target" | "target_kind" | "device_uid" | "device" | "device_id"
        | "uid" | "service_target_id" | "verdict" | "status" => collect_text_params(params, filter),
        "check_id" => {
            if !matches!(filter.op, FilterOp::Eq | FilterOp::NotEq) {
                return Err(ServiceError::InvalidRequest(
                    "check_id filter only supports equality".into(),
                ));
            }
            let check_id = parse_check_uuid(filter)?;
            params.push(BindParam::Uuid(check_id));
            Ok(())
        }
        "evaluated_at" | "changed_at" => match parse_timestamp_bound(filter, now)? {
            TimestampBound::Comparison(ts) => {
                params.push(BindParam::timestamptz(ts));
                Ok(())
            }
            TimestampBound::Range { start, end, .. } => {
                params.push(BindParam::timestamptz(start));
                params.push(BindParam::timestamptz(end));
                Ok(())
            }
        },
        other => Err(ServiceError::InvalidRequest(format!(
            "unsupported filter field '{other}' for declarative check results"
        ))),
    }
}

pub(super) fn parse_check_uuid(filter: &Filter) -> Result<Uuid> {
    let raw = filter.value.as_scalar()?;
    Uuid::parse_str(raw.trim())
        .map_err(|_| ServiceError::InvalidRequest(format!("invalid UUID for check_id '{raw}'")))
}

pub(super) fn parse_timestamp_bound(filter: &Filter, now: DateTime<Utc>) -> Result<TimestampBound> {
    match filter.op {
        FilterOp::Eq
        | FilterOp::NotEq
        | FilterOp::Gt
        | FilterOp::Gte
        | FilterOp::Lt
        | FilterOp::Lte => {
            let raw = filter.value.as_scalar()?;
            if let Ok(dt) = DateTime::parse_from_rfc3339(raw.trim()) {
                return Ok(TimestampBound::Comparison(dt.with_timezone(&Utc)));
            }
            if matches!(filter.op, FilterOp::Eq | FilterOp::NotEq)
                && let Ok(spec) = parse_time_value(raw)
            {
                let range = spec.resolve(now)?;
                return Ok(TimestampBound::Range {
                    start: range.start,
                    end: range.end,
                    negated: matches!(filter.op, FilterOp::NotEq),
                });
            }
            Err(ServiceError::InvalidRequest(format!(
                "expected RFC3339 timestamp or relative time range for {}, got '{raw}'",
                filter.field
            )))
        }
        FilterOp::In | FilterOp::NotIn => {
            let values = filter.value.as_list()?;
            if values.len() != 2 {
                return Err(ServiceError::InvalidRequest(format!(
                    "{} range filter requires [start,end] timestamps",
                    filter.field
                )));
            }
            let start = DateTime::parse_from_rfc3339(values[0].trim())
                .map(|dt| dt.with_timezone(&Utc))
                .map_err(|_| {
                    ServiceError::InvalidRequest(format!(
                        "expected RFC3339 start timestamp for {}, got '{}'",
                        filter.field, values[0]
                    ))
                })?;
            let end = DateTime::parse_from_rfc3339(values[1].trim())
                .map(|dt| dt.with_timezone(&Utc))
                .map_err(|_| {
                    ServiceError::InvalidRequest(format!(
                        "expected RFC3339 end timestamp for {}, got '{}'",
                        filter.field, values[1]
                    ))
                })?;
            if start > end {
                return Err(ServiceError::InvalidRequest(format!(
                    "{} start timestamp must be before end timestamp",
                    filter.field
                )));
            }
            Ok(TimestampBound::Range {
                start,
                end,
                negated: matches!(filter.op, FilterOp::NotIn),
            })
        }
        _ => Err(ServiceError::InvalidRequest(format!(
            "{} filter does not support that comparison",
            filter.field
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
            let values = filter.value.as_list()?.to_vec();
            if values.is_empty() {
                return Ok(());
            }
            params.push(BindParam::TextArray(values));
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
        return query
            .order(declarative_check_instances::evaluated_at.desc())
            .then_order_by(declarative_check_instances::id.desc());
    }

    let mut query = query;
    for (index, clause) in order.iter().enumerate() {
        query = apply_order_clause(query, clause, index == 0);
    }
    query.then_order_by(declarative_check_instances::id.desc())
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
        "device_uid" | "device" | "device_id" | "uid" => {
            order_by!(declarative_check_instances::device_uid)
        }
        "target_key" | "target" => order_by!(declarative_check_instances::target_key),
        "target_kind" => order_by!(declarative_check_instances::target_kind),
        "verdict" => order_by!(declarative_check_instances::verdict),
        "status" => order_by!(declarative_check_instances::status),
        "changed_at" => order_by!(declarative_check_instances::changed_at),
        "evaluated_at" => order_by!(declarative_check_instances::evaluated_at),
        "check_id" => order_by!(declarative_check_instances::check_id),
        "check" | "check_slug" | "slug" => order_by!(declarative_checks::slug),
        "check_name" | "name" => order_by!(declarative_checks::name),
        "state" | "check_state" => order_by!(declarative_checks::state),
        _ => order_by!(declarative_check_instances::evaluated_at),
    }
}
