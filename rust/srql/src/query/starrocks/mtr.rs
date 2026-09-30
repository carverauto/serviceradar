//! `in:mtr_traces` and `in:mtr_hops` (and its `mtr_hop_stats` spelling) in the
//! StarRocks dialect.
//!
//! With the warehouse enabled EventWriter writes MTR only to
//! `serviceradar.mtr_traces` / `serviceradar.mtr_hops` (`priv/starrocks/0019`),
//! whose columns are those of the CNPG tables. This module answers the same
//! queries the CNPG builders (`query/mtr_hops.rs`, `query/mtr_traces.rs`) answer,
//! with the same numbers:
//!
//! * `stats:` is parsed by the CNPG builders' own dialect-neutral parsers, so
//!   both backends accept the same aggregations over the same columns; only
//!   the rendering differs. `loss_ratio` and `wavg` render the formulas CNPG
//!   uses (see `super::loss_ratio_sql` / `super::wavg_sql`).
//! * `by time:<duration>` buckets are `time_slice`, which floors to a grid
//!   anchored at midnight 0001-01-01. CNPG floors epoch seconds. The two grids
//!   coincide exactly when the width divides a day, so only those widths are
//!   accepted; any other width is refused rather than cut on different edges.
//! * Sorting resolves through `mtr_hops::resolve_stats_order`, the resolver the
//!   CNPG builders use, and every sort term carries Postgres's NULL placement
//!   (NULLS LAST ascending, NULLS FIRST descending) instead of StarRocks's.
//! * Time bounds are the half-open `[start, end)` CNPG binds, at microsecond
//!   precision, except the hour-servable `in:mtr_hops` stats described below.
//! * Filters follow the CNPG row path and stats path separately, because they
//!   differ: a row-listing negation keeps NULL rows, a stats negation drops
//!   them. A filter or operator CNPG refuses is refused here too, and so is
//!   anything else this module cannot express.
//!
//! A hop row carries its trace's `target_ip` and `device_id` and is stored at
//! its trace's `time`, so no shape here joins hops to traces.
//!
//! `in:mtr_hops` stats whose whole shape the hourly hop rollup
//! `mtr_hops_hourly` (`priv/starrocks/0025`) can re-aggregate -- every
//! aggregate a `loss_ratio(sent, received)` / `wavg(value, received)` /
//! `count()` over the columns it stores, every dimension and filter one it
//! carries, every time bucket a whole number of hours -- read the rollup when
//! the freshness gate allows, and the same shape recompiled against the raw
//! table (`translate_raw`) reads the same widened whole-hour window, so a
//! stale view can only cost the rollup, never change the answer. Anything
//! else (an `asn` or `asn_org` shape, a scalar column aggregate, an exact
//! unbucketed window) reads `mtr_hops` as before.

use super::super::filters_common::NumericValue;
use super::super::mtr_hops::{
    self, GroupDim, HopAggKind, ParsedHopAgg, StatsOrderKey, resolve_stats_order,
};
use super::super::mtr_traces::{self, ParsedTraceAgg, TraceAggKind, TraceGroupDim};
use super::super::{PaginationMeta, QueryPlan, TranslateResponse, types::BindParam};
use super::{
    floor_hour, loss_ratio_sql, pg_order_sql, rollup_stats_kind, sql_literal, text_filter_sql,
    wavg_sql,
};
use crate::{
    error::{Result, ServiceError},
    parser::{Entity, Filter, FilterOp, OrderClause, OrderDirection},
};

/// Row projection of `in:mtr_hops`, in the order and under the names of
/// `MtrHopRow::into_json`.
const HOP_ROW_COLUMNS: &[&str] = &[
    "time",
    "id",
    "trace_id",
    "target_ip",
    "device_id",
    "hop_number",
    "addr",
    "hostname",
    "ecmp_addrs",
    "asn",
    "asn_org",
    "mpls_labels",
    "sent",
    "received",
    "loss_pct",
    "last_us",
    "avg_us",
    "min_us",
    "max_us",
    "stddev_us",
    "jitter_us",
    "jitter_worst_us",
    "jitter_interarrival_us",
    "created_at",
    "reply_time_exceeded",
    "reply_unreachable",
    "reply_synack",
    "reply_rst",
];

/// Row projection of `in:mtr_traces`, in the order and under the names of
/// `MtrTraceRow::into_json`.
const TRACE_ROW_COLUMNS: &[&str] = &[
    "time",
    "id",
    "agent_id",
    "gateway_id",
    "check_id",
    "check_name",
    "device_id",
    "target",
    "target_ip",
    "target_reached",
    "total_hops",
    "protocol",
    "ip_version",
    "packet_size",
    "partition",
    "error",
    "created_at",
    "tcp_handshake_ttl",
    "tcp_handshake_attempts",
    "tcp_syn_sent",
    "tcp_synack_received",
    "tcp_rst_received",
    "tcp_syn_unanswered",
    "tcp_syn_drop_pct",
    "tcp_syn_retransmits",
    "tcp_answered_after_retx",
    "tcp_ack_mismatch",
    "tcp_synack_duplicates",
    "tcp_handshake_rtt_min_us",
    "tcp_handshake_rtt_avg_us",
    "tcp_handshake_rtt_max_us",
    "tcp_server_response_us",
];

/// Row sort fields CNPG accepts besides `time`/`timestamp`
/// (`mtr_hops::apply_primary_order`, `mtr_traces::apply_primary_order`).
const HOP_ROW_SORT_FIELDS: &[&str] = &[
    "hop_number",
    "addr",
    "asn",
    "asn_org",
    "loss_pct",
    "created_at",
];
const TRACE_ROW_SORT_FIELDS: &[&str] = &[
    "target",
    "target_ip",
    "agent_id",
    "protocol",
    "check_name",
    "device_id",
    "error",
    "target_reached",
    "total_hops",
    "created_at",
];

const HOP_TEXT_FIELDS: &[&str] = &["addr", "target_ip", "device_id", "hostname", "asn_org"];
const TRACE_TEXT_FIELDS: &[&str] = &[
    "target",
    "target_ip",
    "agent_id",
    "protocol",
    "check_name",
    "device_id",
    "error",
];

const SECONDS_PER_DAY: i64 = 86_400;
const HOURLY_GRAIN_SECONDS: i64 = 3_600;

/// The hourly hop rollup (`priv/starrocks/0025`). Its grain is the hour and the
/// dimensions below, so a query it serves widens its window to whole hours
/// and re-aggregates the stored sums; everything else reads `mtr_hops`.
const HOP_HOURLY_TABLE: &str = "mtr_hops_hourly";

/// Columns the hop rollup groups by besides `day`/`bucket`. `asn` and
/// `asn_org` are absent on purpose: they are GeoLite2-only and NULL for every
/// internal hop and private AS, so an AS-level rollup must not be presented as
/// fleet-wide; an asn-shaped query stays on the raw table, where the reader
/// sees the NULL groups it filters past.
const ROLLUP_DIMENSIONS: &[&str] = &["addr", "hop_number", "target_ip", "device_id"];

/// `wavg` value columns the rollup stores a received-weighted sum for.
const ROLLUP_WAVG_VALUES: &[&str] = &["avg_us", "min_us", "max_us", "jitter_us"];

#[derive(Clone, Copy)]
enum Table {
    Hops,
    Traces,
}

/// Which `mtr_hops` source a stats query reads: the raw table or the hourly
/// hop rollup.
#[derive(Clone, Copy, PartialEq)]
enum HopSource {
    Raw,
    Hourly,
}

impl Table {
    fn name(self) -> &'static str {
        match self {
            Table::Hops => "mtr_hops",
            Table::Traces => "mtr_traces",
        }
    }
}

pub(super) fn translate(
    plan: &QueryPlan,
    database: &str,
    allow_rollup: bool,
) -> Result<TranslateResponse> {
    let table = match plan.entity {
        Entity::MtrHops => Table::Hops,
        Entity::MtrTraces => Table::Traces,
        _ => {
            return Err(ServiceError::Internal(anyhow::anyhow!(
                "the StarRocks MTR dialect was handed {:?}",
                plan.entity
            )));
        }
    };
    refuse_unimplemented_features(plan, table)?;

    let stats = plan.stats.as_ref().map(|stats| stats.as_raw());
    // The hop stats parse is shared by the servability decision and the
    // rendering below, so it happens once, here.
    let hop_stats = match (&stats, table) {
        (Some(raw), Table::Hops) => Some(mtr_hops::parse_hop_stats(raw)?),
        _ => None,
    };
    // Whether the hourly hop rollup (`priv/starrocks/0025`) can re-aggregate
    // this stats shape, decided before any rendering. Like `hourly_rollup` for
    // the flows, this is a property of the query, not of the source: a shape
    // it can serve is scored on whole hours, so the window widens to them in
    // BOTH modes and the rollup-freshness gate cannot change the answer -- the
    // raw recompile (`allow_rollup` false) reads the same widened hours.
    let servable = hop_stats
        .as_ref()
        .is_some_and(|(aggs, dims)| hop_hourly_rollup(aggs, dims, &plan.filters));
    let source = if servable && allow_rollup {
        HopSource::Hourly
    } else {
        HopSource::Raw
    };
    let from = match (table, servable && allow_rollup) {
        (Table::Hops, true) => format!("{database}.{HOP_HOURLY_TABLE}"),
        _ => format!("{database}.{}", table.name()),
    };
    let time_column = if matches!((table, source), (Table::Hops, HopSource::Hourly)) {
        "bucket"
    } else {
        "time"
    };
    let (mut predicates, params) = time_bounds(plan, time_column, servable);
    if matches!((table, source), (Table::Hops, HopSource::Hourly)) {
        // `day` is the view's partition column; bound it so the scan skips the
        // days the window cannot touch, as the trace rollup reads do.
        if let Some(range) = &plan.time_range {
            predicates.push(format!(
                "`day` >= date_trunc('day', '{}')",
                range.start.format("%Y-%m-%d %H:%M:%S%.6f")
            ));
            predicates.push(format!(
                "`day` <= '{}'",
                range.end.format("%Y-%m-%d %H:%M:%S%.6f")
            ));
        }
    }
    for filter in &plan.filters {
        predicates.push(match (table, stats.is_some()) {
            (Table::Hops, false) => hop_row_filter(filter)?,
            (Table::Hops, true) => hop_stats_filter(filter)?,
            (Table::Traces, false) => trace_row_filter(filter)?,
            (Table::Traces, true) => trace_stats_filter(filter)?,
        });
    }
    let where_sql = if predicates.is_empty() {
        String::new()
    } else {
        format!(" WHERE {}", predicates.join(" AND "))
    };

    let sql = match (table, &stats) {
        (Table::Hops, Some(_)) => {
            let (aggs, dims) = hop_stats.expect("hop stats parsed above");
            let aggs = aggs
                .iter()
                .map(|agg| hop_agg(agg, source))
                .collect::<Vec<_>>();
            let dims = dims
                .iter()
                .map(|dim| hop_dim(dim, source))
                .collect::<Result<Vec<_>>>()?;
            stats_sql(
                plan,
                &from,
                &where_sql,
                &aggs,
                &dims,
                mtr_hops::GROUP_BY_FIELDS,
            )?
        }
        (Table::Traces, Some(raw)) => {
            let (aggs, dims) = mtr_traces::parse_trace_stats(raw)?;
            let aggs = aggs.iter().map(trace_agg).collect::<Result<Vec<_>>>()?;
            let dims = dims.iter().map(trace_dim).collect::<Result<Vec<_>>>()?;
            stats_sql(
                plan,
                &from,
                &where_sql,
                &aggs,
                &dims,
                mtr_traces::TRACE_GROUP_BY_FIELDS,
            )?
        }
        (Table::Hops, None) => rows_sql(plan, &from, &where_sql, HOP_ROW_COLUMNS, table)?,
        (Table::Traces, None) => rows_sql(plan, &from, &where_sql, TRACE_ROW_COLUMNS, table)?,
    };

    Ok(TranslateResponse {
        sql,
        params,
        pagination: PaginationMeta {
            next_cursor: None,
            prev_cursor: None,
            limit: Some(plan.limit),
        },
        viz: None,
    })
}

/// Plan clauses with no MTR translation on either backend. CNPG ignores
/// `rollup_stats:` for these entities and sends `bucket:` to a downsample
/// builder with no MTR table; here both are refused by name, so a caller sees
/// the failure instead of a result shaped like something else.
fn refuse_unimplemented_features(plan: &QueryPlan, table: Table) -> Result<()> {
    let entity = table.name();
    if plan.other {
        return Err(ServiceError::InvalidRequest(
            "other:true is currently supported only for flow or timeseries stats".into(),
        ));
    }
    if let Some(kind) = rollup_stats_kind(plan) {
        return Err(ServiceError::InvalidRequest(format!(
            "StarRocks does not implement rollup_stats:{kind} for {entity}"
        )));
    }
    if plan.downsample.is_some() {
        return Err(ServiceError::InvalidRequest(format!(
            "StarRocks does not implement bucket: for {entity}; \
             use stats:\"... by time:<duration>\""
        )));
    }
    Ok(())
}

fn quoted(column: &str) -> String {
    format!("`{column}`")
}

/// `[start, end)`, the bounds CNPG binds, as naive UTC `DATETIME` literals with
/// microseconds. No `time:` means no bound, as on CNPG. `hour_grained` says
/// the query is scored on whole hours because the hourly hop rollup can serve
/// it -- the lower bound floors to the hour and the upper bound is the next
/// hour after `end`, except an `end` already on an hour stays, so an aligned
/// window does not gain the following hour. Both the rollup and the raw
/// recompile bind these bounds. This is not the flows helper
/// `exclusive_hour_end`, which always adds an hour.
fn time_bounds(
    plan: &QueryPlan,
    time_column: &str,
    hour_grained: bool,
) -> (Vec<String>, Vec<BindParam>) {
    let Some(range) = &plan.time_range else {
        return (Vec::new(), Vec::new());
    };
    let literal = |value: chrono::DateTime<chrono::Utc>| {
        format!("'{}'", value.format("%Y-%m-%d %H:%M:%S%.6f"))
    };
    let (lower, upper) = if hour_grained {
        (floor_hour(range.start), hop_hour_upper(range.end))
    } else {
        (range.start, range.end)
    };
    (
        vec![
            format!("`{time_column}` >= {}", literal(lower)),
            format!("`{time_column}` < {}", literal(upper)),
        ],
        vec![BindParam::timestamptz(lower), BindParam::timestamptz(upper)],
    )
}

/// Exclusive end of an hour-grained hop window. An end already on an hour is
/// that hour; an end inside an hour rounds up so the partial hour is included.
/// `exclusive_hour_end` always adds an hour, which is the flows cagg bound and
/// would count one extra hour of hops here.
fn hop_hour_upper(value: chrono::DateTime<chrono::Utc>) -> chrono::DateTime<chrono::Utc> {
    let floored = floor_hour(value);
    if floored == value {
        floored
    } else {
        floored + chrono::Duration::hours(1)
    }
}

/// Whether the hourly hop rollup (`priv/starrocks/0025`) can re-aggregate this
/// stats shape by summing its stored columns. The view groups by
/// `(day, hour, target_ip, device_id, addr, hop_number)` and stores the probe
/// totals `loss_ratio(sent, received)` is a ratio of, a received-weighted sum
/// per `wavg` value column, and the hop count, so a query is servable exactly
/// when it is bucketed on whole hours (a scalar total over an exact window has
/// no bucket to absorb the rollup's hour grain -- the same rule that keeps the
/// flows rollup on the downsample path), every aggregate is one the stored
/// columns re-aggregate, and every dimension and filter names a carried one.
/// `asn`/`asn_org` are deliberately not carried (see `ROLLUP_DIMENSIONS`).
fn hop_hourly_rollup(aggs: &[ParsedHopAgg], dims: &[GroupDim], filters: &[Filter]) -> bool {
    let hour_bucket = |dim: &GroupDim| matches!(dim, GroupDim::TimeBucket { seconds } if seconds % HOURLY_GRAIN_SECONDS == 0);
    let agg_ok = aggs.iter().all(|agg| match &agg.kind {
        HopAggKind::LossRatio { sent, received } => sent == "sent" && received == "received",
        HopAggKind::Wavg { value, weight } => {
            weight == "received" && ROLLUP_WAVG_VALUES.contains(&value.as_str())
        }
        HopAggKind::CountRows => true,
        HopAggKind::Column { .. } => false,
    });
    let dim_ok = dims.iter().all(|dim| match dim {
        GroupDim::Column(column) => ROLLUP_DIMENSIONS.contains(column),
        GroupDim::TimeBucket { seconds } => seconds % HOURLY_GRAIN_SECONDS == 0,
    });
    let filter_ok = filters
        .iter()
        .all(|filter| ROLLUP_DIMENSIONS.contains(&filter.field.as_str()));
    agg_ok && dim_ok && filter_ok && dims.iter().any(hour_bucket)
}

fn numeric_literal(value: NumericValue) -> String {
    match value {
        NumericValue::Int4(v) => v.to_string(),
        NumericValue::Int8(v) => v.to_string(),
        NumericValue::Float8(v) => v.to_string(),
    }
}

fn ordered_op(op: &FilterOp) -> Option<&'static str> {
    Some(match op {
        FilterOp::Eq => "=",
        FilterOp::NotEq => "<>",
        FilterOp::Gt => ">",
        FilterOp::Gte => ">=",
        FilterOp::Lt => "<",
        FilterOp::Lte => "<=",
        _ => return None,
    })
}

fn parse_int(filter: &Filter) -> Result<i32> {
    let raw = filter.value.as_scalar()?;
    raw.parse().map_err(|_| {
        ServiceError::InvalidRequest(format!("{} must be an integer, got '{raw}'", filter.field))
    })
}

fn parse_trace_uuid(raw: &str) -> Result<uuid::Uuid> {
    uuid::Uuid::parse_str(raw).map_err(|_| {
        ServiceError::InvalidRequest(format!("trace_id must be a valid UUID, got '{raw}'"))
    })
}

fn unsupported_filter(table: Table, field: &str) -> ServiceError {
    ServiceError::InvalidRequest(format!(
        "unsupported filter field for {}: '{field}'",
        table.name()
    ))
}

/// `mtr_hops::apply_filter`: a text negation keeps NULL rows, `trace_id` is a
/// UUID compared exactly, `hop_number` takes equality only.
fn hop_row_filter(filter: &Filter) -> Result<String> {
    let field = filter.field.as_str();
    if HOP_TEXT_FIELDS.contains(&field) {
        return text_filter_sql(&quoted(field), filter, true);
    }
    match field {
        "trace_id" => {
            // The column is a UUID on CNPG, so any accepted spelling of the id
            // matches; the warehouse holds its canonical text.
            let uuid = parse_trace_uuid(filter.value.as_scalar()?)?;
            let op = match filter.op {
                FilterOp::Eq => "=",
                FilterOp::NotEq => "<>",
                _ => {
                    return Err(ServiceError::InvalidRequest(
                        "trace_id only supports equality comparisons".into(),
                    ));
                }
            };
            Ok(format!(
                "`trace_id` {op} {}",
                sql_literal(&uuid.to_string())
            ))
        }
        "asn" => {
            let asn = parse_int(filter)?;
            let op = ordered_op(&filter.op).ok_or_else(|| {
                ServiceError::InvalidRequest("asn supports equality and ordered comparisons".into())
            })?;
            Ok(format!("`asn` {op} {asn}"))
        }
        "hop_number" => {
            let hop = parse_int(filter)?;
            let op = match filter.op {
                FilterOp::Eq => "=",
                FilterOp::NotEq => "<>",
                _ => {
                    return Err(ServiceError::InvalidRequest(
                        "hop_number only supports equality comparisons".into(),
                    ));
                }
            };
            Ok(format!("`hop_number` {op} {hop}"))
        }
        other => match mtr_hops::reply_type_comparison(filter)? {
            Some((column, comparison)) => Ok(format!(
                "{} {} {}",
                quoted(column),
                comparison.op_sql,
                numeric_literal(comparison.value)
            )),
            None => Err(unsupported_filter(Table::Hops, other)),
        },
    }
}

/// `mtr_hops::build_stats_filter_clause`: a text negation drops NULL rows,
/// `trace_id` is compared as text, and `hop_number` takes ordered comparisons.
fn hop_stats_filter(filter: &Filter) -> Result<String> {
    let field = filter.field.as_str();
    if HOP_TEXT_FIELDS.contains(&field) {
        return text_filter_sql(&quoted(field), filter, false);
    }
    match field {
        "trace_id" => {
            parse_trace_uuid(filter.value.as_scalar()?)?;
            text_filter_sql("`trace_id`", filter, false)
        }
        "asn" | "hop_number" => {
            let value = parse_int(filter)?;
            let op = ordered_op(&filter.op).ok_or_else(|| {
                ServiceError::InvalidRequest(format!(
                    "{field} supports equality and ordered comparisons in stats queries"
                ))
            })?;
            Ok(format!("{} {op} {value}", quoted(field)))
        }
        other => match mtr_hops::reply_type_comparison(filter)? {
            Some((column, comparison)) => Ok(format!(
                "{} {} {}",
                quoted(column),
                comparison.op_sql,
                numeric_literal(comparison.value)
            )),
            None => Err(unsupported_filter(Table::Hops, other)),
        },
    }
}

fn target_reached_filter(filter: &Filter) -> Result<String> {
    let value = mtr_traces::parse_bool(filter.value.as_scalar()?)?;
    let op = match filter.op {
        FilterOp::Eq => "=",
        FilterOp::NotEq => "<>",
        _ => {
            return Err(ServiceError::InvalidRequest(
                "target_reached only supports equality comparisons".into(),
            ));
        }
    };
    Ok(format!(
        "`target_reached` {op} {}",
        if value { "TRUE" } else { "FALSE" }
    ))
}

fn handshake_filter(filter: &Filter) -> Result<String> {
    match mtr_traces::handshake_comparison(filter)? {
        Some((column, comparison)) => Ok(format!(
            "{} {} {}",
            quoted(column),
            comparison.op_sql,
            numeric_literal(comparison.value)
        )),
        None => Err(unsupported_filter(Table::Traces, &filter.field)),
    }
}

/// `mtr_traces::apply_filter`.
fn trace_row_filter(filter: &Filter) -> Result<String> {
    let field = filter.field.as_str();
    if TRACE_TEXT_FIELDS.contains(&field) {
        return text_filter_sql(&quoted(field), filter, true);
    }
    match field {
        "target_reached" => target_reached_filter(filter),
        _ => handshake_filter(filter),
    }
}

/// `mtr_traces::build_trace_stats_filter`: text filters take one value.
fn trace_stats_filter(filter: &Filter) -> Result<String> {
    let field = filter.field.as_str();
    if TRACE_TEXT_FIELDS.contains(&field) {
        filter.value.as_scalar()?;
        if !matches!(
            filter.op,
            FilterOp::Eq | FilterOp::NotEq | FilterOp::Like | FilterOp::NotLike
        ) {
            return Err(ServiceError::InvalidRequest(format!(
                "unsupported operator for '{field}' in mtr_traces stats"
            )));
        }
        return text_filter_sql(&quoted(field), filter, false);
    }
    match field {
        "target_reached" => target_reached_filter(filter),
        _ => handshake_filter(filter),
    }
}

/// `apply_ordering` of the CNPG row builders: the requested terms, then `time`
/// (unless requested) and `id`, both in the direction of the time term or, when
/// there is none, of the first term. With no sort, newest first.
fn rows_sql(
    plan: &QueryPlan,
    from: &str,
    where_sql: &str,
    columns: &[&str],
    table: Table,
) -> Result<String> {
    let allowed = match table {
        Table::Hops => HOP_ROW_SORT_FIELDS,
        Table::Traces => TRACE_ROW_SORT_FIELDS,
    };
    let is_time = |clause: &OrderClause| matches!(clause.field.as_str(), "time" | "timestamp");
    let order = if plan.order.is_empty() {
        vec![
            format!("`time` {}", pg_order_sql(OrderDirection::Desc)),
            format!("`id` {}", pg_order_sql(OrderDirection::Desc)),
        ]
    } else {
        let mut terms = Vec::with_capacity(plan.order.len() + 2);
        for clause in &plan.order {
            let column = if is_time(clause) {
                "time"
            } else if let Some(field) = allowed.iter().find(|field| **field == clause.field) {
                field
            } else {
                return Err(ServiceError::InvalidRequest(format!(
                    "unsupported sort field for {}: '{}'",
                    table.name(),
                    clause.field
                )));
            };
            terms.push(format!(
                "{} {}",
                quoted(column),
                pg_order_sql(clause.direction)
            ));
        }
        let tie = plan
            .order
            .iter()
            .find(|clause| is_time(clause))
            .map_or(plan.order[0].direction, |clause| clause.direction);
        if !plan.order.iter().any(is_time) {
            terms.push(format!("`time` {}", pg_order_sql(tie)));
        }
        terms.push(format!("`id` {}", pg_order_sql(tie)));
        terms
    };
    let select = columns
        .iter()
        .map(|column| quoted(column))
        .collect::<Vec<_>>()
        .join(", ");
    Ok(format!(
        "SELECT {select} FROM {from}{where_sql} ORDER BY {} LIMIT {} OFFSET {}",
        order.join(", "),
        plan.limit,
        plan.offset
    ))
}

/// One rendered aggregation: its SQL and its output column.
struct Agg {
    expr: String,
    alias: String,
}

/// One rendered grouping dimension. `column` is set for a column dimension and
/// names the column a `sort:` on it resolves to.
struct Dim {
    expr: String,
    alias: String,
    column: Option<&'static str>,
}

fn hop_agg(agg: &ParsedHopAgg, source: HopSource) -> Agg {
    let expr = match (&agg.kind, source) {
        (HopAggKind::LossRatio { sent, received }, HopSource::Raw) => {
            loss_ratio_sql(&quoted(sent), &quoted(received))
        }
        // The rollup stores the probe totals the ratio is of, so the same
        // formula over their sums re-aggregates it exactly across hours.
        (HopAggKind::LossRatio { .. }, HopSource::Hourly) =>
            "CASE WHEN COALESCE(SUM(sent_total), 0) > 0 THEN 100.0 * (CAST(SUM(sent_total) AS DOUBLE) - CAST(COALESCE(SUM(received_total), 0) AS DOUBLE)) / CAST(SUM(sent_total) AS DOUBLE) ELSE NULL END".to_string(),
        (HopAggKind::Wavg { value, weight }, HopSource::Raw) => {
            wavg_sql(&quoted(value), &quoted(weight))
        }
        // Likewise the received-weighted sums: `SUM(weighted) / SUM(weight)`
        // over hour rows is the raw `wavg` over their union.
        (HopAggKind::Wavg { value, .. }, HopSource::Hourly) => format!(
            "CASE WHEN SUM(COALESCE(received_total, 0)) > 0 THEN SUM({value}_weighted) / CAST(SUM(COALESCE(received_total, 0)) AS DOUBLE) ELSE NULL END"
        ),
        (HopAggKind::CountRows, HopSource::Raw) => "COUNT(*)".to_string(),
        (HopAggKind::CountRows, HopSource::Hourly) => "SUM(hop_count)".to_string(),
        // `hop_hourly_rollup` refuses this shape before choosing the rollup.
        (HopAggKind::Column { .. }, HopSource::Hourly) => unreachable!("column aggregate on the hop rollup"),
    };
    Agg {
        expr,
        alias: agg.alias.clone(),
    }
}

/// CNPG casts the one boolean aggregatable column to an integer so that
/// `avg(target_reached)` is the reached proportion; StarRocks needs the same
/// cast. Any other cast CNPG applies has no rendering here and is refused, so a
/// column added to `TRACE_AGGREGATABLE_COLUMNS` with a new cast cannot be
/// aggregated raw on this backend by accident.
fn trace_agg(agg: &ParsedTraceAgg) -> Result<Agg> {
    let expr = match agg.kind {
        TraceAggKind::CountRows => "COUNT(*)".to_string(),
        TraceAggKind::Column { function, column } => {
            let value = if mtr_traces::pg_trace_column(column) == column {
                quoted(column)
            } else if column == "target_reached" {
                "CAST(`target_reached` AS INT)".to_string()
            } else {
                return Err(ServiceError::NotImplemented(format!(
                    "starrocks_unsupported_stats: no StarRocks rendering for mtr_traces column {column}"
                )));
            };
            format!("{function}({value})")
        }
    };
    Ok(Agg {
        expr,
        alias: agg.alias.clone(),
    })
}

/// `time_slice` floors to a grid anchored at 0001-01-01 00:00:00 and CNPG
/// floors epoch seconds (`to_timestamp(floor(epoch / n) * n)`). Both anchors
/// fall on a UTC midnight, so the grids agree exactly when the width divides a
/// day, and only then.
fn time_bucket_sql(seconds: i64, source: HopSource) -> Result<String> {
    if seconds <= 0 || SECONDS_PER_DAY % seconds != 0 {
        return Err(ServiceError::InvalidRequest(format!(
            "StarRocks MTR time buckets must divide a day evenly; {seconds}s would cut \
             different bucket edges than CNPG"
        )));
    }
    let column = match source {
        HopSource::Raw => "`time`",
        HopSource::Hourly => "bucket",
    };
    Ok(format!("time_slice({column}, INTERVAL {seconds} SECOND)"))
}

fn hop_dim(dim: &GroupDim, source: HopSource) -> Result<Dim> {
    Ok(match dim {
        GroupDim::Column(column) => Dim {
            expr: quoted(column),
            alias: (*column).to_string(),
            column: Some(column),
        },
        GroupDim::TimeBucket { seconds } => Dim {
            // The rollup's `bucket` is already hour-floored, and a width that
            // divides a day cuts the same edges over an hour-floored value as
            // over the raw `time`, so the grid does not move with the source.
            expr: time_bucket_sql(*seconds, source)?,
            alias: dim.alias().to_string(),
            column: None,
        },
    })
}

fn trace_dim(dim: &TraceGroupDim) -> Result<Dim> {
    Ok(match dim {
        TraceGroupDim::Column(column) => Dim {
            expr: quoted(column),
            alias: (*column).to_string(),
            column: Some(column),
        },
        TraceGroupDim::TimeBucket { seconds } => Dim {
            expr: time_bucket_sql(*seconds, HopSource::Raw)?,
            alias: dim.alias().to_string(),
            column: None,
        },
    })
}

/// The grouped query, as the CNPG builders shape it: flat columns where CNPG
/// returns one `payload` object with the same keys. A bucketed query keeps the
/// newest `limit` buckets and returns them oldest first, whatever `sort:` says;
/// any other query sorts as `resolve_stats_order` resolves it.
fn stats_sql(
    plan: &QueryPlan,
    from: &str,
    where_sql: &str,
    aggs: &[Agg],
    dims: &[Dim],
    group_fields: &[&'static str],
) -> Result<String> {
    let select = aggs
        .iter()
        .map(|agg| format!("{} AS {}", agg.expr, quoted(&agg.alias)))
        .chain(
            dims.iter()
                .map(|dim| format!("{} AS {}", dim.expr, quoted(&dim.alias))),
        )
        .collect::<Vec<_>>()
        .join(", ");
    let group = dims
        .iter()
        .map(|dim| dim.expr.as_str())
        .collect::<Vec<_>>()
        .join(", ");
    let grouped = format!("SELECT {select} FROM {from}{where_sql} GROUP BY {group}");
    let page = format!("LIMIT {} OFFSET {}", plan.limit, plan.offset);

    if let Some(bucket) = dims.iter().find(|dim| dim.column.is_none()) {
        return Ok(format!(
            "SELECT * FROM ({grouped} ORDER BY {} DESC {page}) bucketed ORDER BY {} ASC",
            bucket.expr,
            quoted(&bucket.alias)
        ));
    }

    let aliases = aggs
        .iter()
        .map(|agg| agg.alias.as_str())
        .collect::<Vec<_>>();
    let mut terms = Vec::new();
    for (key, direction) in resolve_stats_order(&plan.order, &aliases, group_fields) {
        let expr = match key {
            StatsOrderKey::Agg(index) => aggs[index].expr.clone(),
            // Postgres refuses to sort a grouped query by a column it is not
            // grouped by; so does this.
            StatsOrderKey::Group(field) => dims
                .iter()
                .find(|dim| dim.column == Some(field))
                .map(|dim| dim.expr.clone())
                .ok_or_else(|| {
                    ServiceError::InvalidRequest(format!(
                        "stats ordering by '{field}' requires grouping by it"
                    ))
                })?,
        };
        terms.push(format!("{expr} {}", pg_order_sql(direction)));
    }
    let order = if terms.is_empty() {
        String::new()
    } else {
        format!(" ORDER BY {}", terms.join(", "))
    };
    Ok(format!("{grouped}{order} {page}"))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::parser;
    use crate::query::{QueryDirection, QueryRequest, build_query_plan};
    use chrono::{TimeZone, Utc};

    const DB: &str = "serviceradar";

    fn plan(query: &str) -> QueryPlan {
        let config = crate::config::AppConfig::embedded("postgres://example/db".to_string());
        let request = QueryRequest {
            query: query.to_string(),
            limit: None,
            cursor: None,
            direction: QueryDirection::Next,
            mode: Some("starrocks".into()),
            permitted_signals: None,
        };
        build_query_plan(&config, &request, parser::parse(query).expect("parse")).expect("plan")
    }

    fn compile(query: &str) -> String {
        super::super::translate(&plan(query), DB)
            .unwrap_or_else(|err| panic!("{query} must compile for StarRocks: {err}"))
            .sql
    }

    fn refused(query: &str) -> ServiceError {
        match super::super::translate(&plan(query), DB) {
            Ok(compiled) => panic!("{query} must be refused, compiled to: {}", compiled.sql),
            Err(err) => err,
        }
    }

    /// The CNPG half of the same query, through the entity builders that serve
    /// it when the warehouse is off.
    fn cnpg(query: &str) -> Result<String> {
        let plan = plan(query);
        match plan.entity {
            Entity::MtrHops => mtr_hops::to_sql_and_params(&plan),
            Entity::MtrTraces => mtr_traces::to_sql_and_params(&plan),
            _ => unreachable!("not an MTR query: {query}"),
        }
        .map(|(sql, _)| sql)
    }

    const LOSS: &str = "CASE WHEN COALESCE(SUM(`sent`), 0) > 0 THEN 100.0 * (CAST(SUM(`sent`) AS DOUBLE) - CAST(COALESCE(SUM(`received`), 0) AS DOUBLE)) / CAST(SUM(`sent`) AS DOUBLE) ELSE NULL END";
    const LATENCY: &str = "CASE WHEN SUM(COALESCE(`received`, 0)) > 0 THEN SUM(CAST(`avg_us` AS DOUBLE) * CAST(COALESCE(`received`, 0) AS DOUBLE)) / CAST(SUM(COALESCE(`received`, 0)) AS DOUBLE) ELSE NULL END";
    const LOSS_ROLLUP: &str = "CASE WHEN COALESCE(SUM(sent_total), 0) > 0 THEN 100.0 * (CAST(SUM(sent_total) AS DOUBLE) - CAST(COALESCE(SUM(received_total), 0) AS DOUBLE)) / CAST(SUM(sent_total) AS DOUBLE) ELSE NULL END";
    const LATENCY_ROLLUP: &str = "CASE WHEN SUM(COALESCE(received_total, 0)) > 0 THEN SUM(avg_us_weighted) / CAST(SUM(COALESCE(received_total, 0)) AS DOUBLE) ELSE NULL END";

    /// The live MTR path analytics panels (`priv/dashboards/mtr-path-analytics.json`)
    /// and the earlier panel set `mtr_hops.rs` keeps under test.
    const PANEL_QUERIES: &[&str] = &[
        "in:mtr_hops time:last_24h stats:loss_ratio(sent, received) as loss by addr sort:loss:desc limit:20",
        "in:mtr_hops time:last_24h stats:wavg(avg_us, received) as latency by addr sort:latency:desc limit:20",
        "in:mtr_hops time:last_24h asn:>0 stats:loss_ratio(sent, received) as loss by asn sort:loss:desc limit:20",
        "in:mtr_hops time:last_24h stats:loss_ratio(sent, received) as loss by time:1h limit:500",
        r#"in:mtr_hops time:last_24h stats:"loss_ratio(sent, received) as loss, count() as samples by hop_number" sort:hop_number:asc limit:40"#,
        r#"in:mtr_hops time:last_24h stats:"loss_ratio(sent, received) as loss, count() as traces by addr" sort:loss:desc limit:20"#,
        r#"in:mtr_traces time:last_24h stats:"count() as traces, avg(target_reached) as reach_rate by target_ip" sort:reach_rate:asc limit:25"#,
        r#"in:mtr_hops time:last_24h stats:"wavg(avg_us, received) as latency, count() as traces by addr" sort:latency:desc limit:20"#,
    ];

    #[test]
    fn every_dashboard_panel_compiles_on_both_backends() {
        for query in PANEL_QUERIES {
            let sql = compile(query);
            assert!(
                sql.contains(" FROM serviceradar.mtr_hops ")
                    || sql.contains(" FROM serviceradar.mtr_traces ")
                    || sql.contains(" FROM serviceradar.mtr_hops_hourly "),
                "{query}: {sql}"
            );
            assert!(sql.contains(" GROUP BY "), "{query}: {sql}");
            assert!(!sql.contains("::"), "no Postgres casts: {sql}");
            assert!(!sql.contains("jsonb"), "no Postgres payload: {sql}");
            cnpg(query).unwrap_or_else(|err| panic!("{query} must compile for CNPG: {err}"));
        }
    }

    #[test]
    fn loss_by_address_is_a_ratio_of_probe_totals_worst_first() {
        let sql = compile(PANEL_QUERIES[0]);
        assert!(sql.starts_with(&format!("SELECT {LOSS} AS `loss`, `addr` AS `addr` FROM serviceradar.mtr_hops WHERE `time` >= '")), "{sql}");
        assert!(
            sql.ends_with(&format!(
                " GROUP BY `addr` ORDER BY {LOSS} DESC NULLS FIRST LIMIT 20 OFFSET 0"
            )),
            "{sql}"
        );
        assert!(
            !sql.contains("loss_pct"),
            "loss must not average percentages: {sql}"
        );
    }

    #[test]
    fn latency_by_address_is_weighted_by_received_probes() {
        let sql = compile(PANEL_QUERIES[1]);
        assert!(sql.contains(&format!("{LATENCY} AS `latency`")), "{sql}");
        assert!(
            sql.contains(&format!("ORDER BY {LATENCY} DESC NULLS FIRST")),
            "{sql}"
        );
        assert!(!sql.contains("AVG("), "a weighted mean is not AVG: {sql}");
    }

    #[test]
    fn the_asn_panel_keeps_only_resolved_asns() {
        let sql = compile(PANEL_QUERIES[2]);
        assert!(sql.contains(" AND `asn` > 0 GROUP BY `asn` "), "{sql}");
    }

    #[test]
    fn the_trend_reads_the_hourly_rollup_over_its_bucket_column() {
        let sql = compile(PANEL_QUERIES[3]);
        let bucket = "time_slice(bucket, INTERVAL 3600 SECOND)";
        assert!(
            sql.starts_with(&format!(
                "SELECT * FROM (SELECT {LOSS_ROLLUP} AS `loss`, {bucket} AS `bucket` FROM serviceradar.mtr_hops_hourly WHERE `bucket` >= '"
            )),
            "{sql}"
        );
        assert!(
            sql.ends_with(&format!(
                " GROUP BY {bucket} ORDER BY {bucket} DESC LIMIT 500 OFFSET 0) bucketed ORDER BY `bucket` ASC"
            )),
            "{sql}"
        );
        // The partition column is bounded so the scan skips untouched days.
        assert!(sql.contains(" AND `day` >= date_trunc('day', '"), "{sql}");
        assert!(sql.contains(" AND `day` <= '"), "{sql}");
    }

    #[test]
    fn a_bucketed_query_ignores_sort_as_cnpg_does() {
        let sorted = compile(
            "in:mtr_hops time:last_24h stats:loss_ratio(sent, received) as loss by addr,time:1h sort:loss:asc limit:50",
        );
        assert!(!sorted.contains("NULLS"), "{sorted}");
        assert!(
            sorted.contains("ORDER BY time_slice(bucket, INTERVAL 3600 SECOND) DESC LIMIT 50"),
            "{sorted}"
        );
        assert!(sorted.contains(" GROUP BY `addr`, time_slice("), "{sorted}");
    }

    /// A shape the rollup serves is scored on whole hours in BOTH modes: the
    /// fresh read and the gate's raw recompile bind the same widened window,
    /// so staleness can only cost the rollup, never change the answer.
    #[test]
    fn an_hourly_shape_widens_to_whole_hours_in_both_modes() {
        let query = "in:mtr_hops stats:loss_ratio(sent, received) as loss by time:1h limit:500";
        let mut p = plan(query);
        p.time_range = Some(crate::time::TimeRange {
            start: Utc.with_ymd_and_hms(2026, 1, 1, 0, 30, 0).unwrap()
                + chrono::Duration::microseconds(123_456),
            end: Utc.with_ymd_and_hms(2026, 1, 2, 2, 45, 0).unwrap(),
        });
        let fresh = super::super::translate(&p, DB).expect("compile").sql;
        assert!(
            fresh.contains(
                " FROM serviceradar.mtr_hops_hourly WHERE `bucket` >= '2026-01-01 00:00:00.000000' AND `bucket` < '2026-01-02 03:00:00.000000'"
            ),
            "{fresh}"
        );
        let stale = super::super::translate_raw(&p, DB)
            .expect("compile raw")
            .sql;
        assert!(
            stale.contains(
                " FROM serviceradar.mtr_hops WHERE `time` >= '2026-01-01 00:00:00.000000' AND `time` < '2026-01-02 03:00:00.000000'"
            ),
            "{stale}"
        );
    }

    /// An end already on an hour stays. `exclusive_hour_end` would open the
    /// next hour, and hops in `[end, end+1h)` would change the ratio.
    #[test]
    fn an_hour_aligned_end_does_not_include_the_next_hour() {
        let query = "in:mtr_hops stats:loss_ratio(sent, received) as loss by time:1h limit:500";
        let mut p = plan(query);
        p.time_range = Some(crate::time::TimeRange {
            start: Utc.with_ymd_and_hms(2026, 1, 1, 0, 0, 0).unwrap(),
            end: Utc.with_ymd_and_hms(2026, 1, 2, 0, 0, 0).unwrap(),
        });
        let fresh = super::super::translate(&p, DB).expect("compile").sql;
        assert!(
            fresh.contains(
                " FROM serviceradar.mtr_hops_hourly WHERE `bucket` >= '2026-01-01 00:00:00.000000' AND `bucket` < '2026-01-02 00:00:00.000000'"
            ),
            "{fresh}"
        );
        assert!(
            !fresh.contains("`bucket` < '2026-01-02 01:00:00.000000'"),
            "{fresh}"
        );
        let stale = super::super::translate_raw(&p, DB)
            .expect("compile raw")
            .sql;
        assert!(
            stale.contains(
                " FROM serviceradar.mtr_hops WHERE `time` >= '2026-01-01 00:00:00.000000' AND `time` < '2026-01-02 00:00:00.000000'"
            ),
            "{stale}"
        );
        assert!(
            !stale.contains("`time` < '2026-01-02 01:00:00.000000'"),
            "{stale}"
        );
    }

    /// A scalar total over an exact window is not hour-grained: the rollup
    /// knows whole hours only, so the `by addr` panels keep the exact bounds.
    #[test]
    fn scalar_shapes_stay_on_the_raw_table_with_exact_bounds() {
        let sql = compile(PANEL_QUERIES[0]);
        assert!(
            sql.starts_with(&format!(
                "SELECT {LOSS} AS `loss`, `addr` AS `addr` FROM serviceradar.mtr_hops WHERE `time` >= '"
            )),
            "{sql}"
        );
    }

    #[test]
    fn asn_shapes_never_read_the_hop_rollup() {
        for query in [
            PANEL_QUERIES[2],
            "in:mtr_hops time:last_24h asn_org:%example% stats:count() as n by addr,time:1h limit:5",
        ] {
            let sql = compile(query);
            assert!(
                sql.contains(" FROM serviceradar.mtr_hops "),
                "asn is GeoLite2-only; its shapes stay raw: {sql}"
            );
        }
    }

    #[test]
    fn shapes_the_rollup_cannot_re_aggregate_stay_raw() {
        for query in [
            // A column aggregate the rollup stores no equivalent of.
            "in:mtr_hops time:last_24h stats:sum(sent) as v by addr,time:1h limit:5",
            "in:mtr_hops time:last_24h stats:avg(loss_pct) as v by addr,time:1h limit:5",
            // A filter outside the view's dimensions.
            "in:mtr_hops time:last_24h trace_id:8e1c1f3a-0000-4000-8000-000000000001 stats:count() as n by addr,time:1h limit:5",
            "in:mtr_hops time:last_24h reply_rst:>0 stats:count() as n by addr,time:1h limit:5",
            // A group the view does not carry.
            "in:mtr_hops time:last_24h stats:count() as n by hostname,time:1h limit:5",
            // Sub-hour buckets: the view knows whole hours only.
            "in:mtr_hops time:last_24h stats:loss_ratio(sent, received) as loss by addr,time:30m limit:5",
        ] {
            let sql = compile(query);
            assert!(
                sql.contains(" FROM serviceradar.mtr_hops "),
                "{query}: {sql}"
            );
        }
    }

    #[test]
    fn the_rollup_serves_every_wavg_value_column_by_its_stored_weighted_sum() {
        for column in ["avg_us", "min_us", "max_us", "jitter_us"] {
            let query = format!(
                "in:mtr_hops time:last_24h stats:wavg({column}, received) as v by addr,time:1h limit:5"
            );
            let sql = compile(&query);
            assert!(
                sql.contains(&format!(
                    "SUM({column}_weighted) / CAST(SUM(COALESCE(received_total, 0)) AS DOUBLE)"
                )),
                "{query}: {sql}"
            );
            assert!(
                sql.contains(" FROM serviceradar.mtr_hops_hourly "),
                "{query}: {sql}"
            );
        }
        // The latency panel's rolling spelling, over the rollup.
        let sql = compile(
            "in:mtr_hops time:last_24h stats:wavg(avg_us, received) as latency by time:1h limit:20",
        );
        assert!(sql.contains(LATENCY_ROLLUP), "{sql}");
        assert!(
            !sql.contains(LATENCY),
            "the raw formula stays on the raw table: {sql}"
        );
    }

    #[test]
    fn per_hop_loss_sorts_by_the_grouped_hop_number() {
        let sql = compile(PANEL_QUERIES[4]);
        assert!(
            sql.contains(&format!(
                "{LOSS} AS `loss`, COUNT(*) AS `samples`, `hop_number` AS `hop_number`"
            )),
            "{sql}"
        );
        assert!(
            sql.ends_with(
                " GROUP BY `hop_number` ORDER BY `hop_number` ASC NULLS LAST LIMIT 40 OFFSET 0"
            ),
            "{sql}"
        );
    }

    #[test]
    fn reach_rate_is_the_mean_of_the_reached_indicator_lowest_first() {
        let sql = compile(PANEL_QUERIES[6]);
        let reach = "AVG(CAST(`target_reached` AS INT))";
        assert!(
            sql.starts_with(&format!("SELECT COUNT(*) AS `traces`, {reach} AS `reach_rate`, `target_ip` AS `target_ip` FROM serviceradar.mtr_traces WHERE ")),
            "{sql}"
        );
        assert!(
            sql.ends_with(&format!(
                " GROUP BY `target_ip` ORDER BY {reach} ASC NULLS LAST LIMIT 25 OFFSET 0"
            )),
            "{sql}"
        );

        // CNPG sorts the same panel the same way.
        let pg = cnpg(PANEL_QUERIES[6])
            .expect("CNPG compiles")
            .to_lowercase();
        assert!(pg.contains("order by avg(target_reached::int) asc"), "{pg}");
    }

    #[test]
    fn time_bounds_are_half_open_to_the_microsecond() {
        let mut plan = plan("in:mtr_hops stats:count() as n by addr limit:5");
        plan.time_range = Some(crate::time::TimeRange {
            start: Utc.with_ymd_and_hms(2026, 1, 1, 0, 0, 0).unwrap()
                + chrono::Duration::microseconds(123_456),
            end: Utc.with_ymd_and_hms(2026, 1, 2, 0, 0, 0).unwrap(),
        });
        let compiled = super::super::translate(&plan, DB).expect("compile");
        assert!(
            compiled.sql.contains(
                " WHERE `time` >= '2026-01-01 00:00:00.123456' AND `time` < '2026-01-02 00:00:00.000000' GROUP BY "
            ),
            "{}",
            compiled.sql
        );
        assert_eq!(compiled.params.len(), 2);
    }

    #[test]
    fn no_time_filter_means_no_time_bound_as_on_cnpg() {
        let sql = compile("in:mtr_traces limit:5");
        assert!(!sql.contains("WHERE"), "{sql}");
    }

    #[test]
    fn hop_stats_alias_reads_the_hop_table() {
        let sql = compile("in:mtr_hop_stats time:last_1h stats:count() as n by addr limit:5");
        assert!(sql.contains(" FROM serviceradar.mtr_hops "), "{sql}");
    }

    #[test]
    fn bucket_widths_that_do_not_divide_a_day_are_refused() {
        for width in ["7m", "7d", "25h"] {
            let query = format!(
                "in:mtr_hops stats:loss_ratio(sent, received) as loss by time:{width} limit:5"
            );
            assert!(
                matches!(refused(&query), ServiceError::InvalidRequest(_)),
                "{query}"
            );
            cnpg(&query).unwrap_or_else(|err| panic!("{query} compiles on CNPG: {err}"));
        }
        for width in ["1m", "5m", "15m", "90m", "1h", "6h", "1d"] {
            compile(&format!(
                "in:mtr_traces stats:count() as n by time:{width} limit:5"
            ));
        }
    }

    #[test]
    fn plan_clauses_without_an_mtr_translation_are_refused() {
        for query in [
            "in:mtr_hops time:last_24h bucket:1h agg:avg",
            "in:mtr_traces time:last_24h rollup_stats:summary",
            "in:mtr_hops stats:count() as n limit:5",
        ] {
            assert!(
                matches!(refused(query), ServiceError::InvalidRequest(_)),
                "{query}"
            );
        }
    }

    #[test]
    fn hop_rows_project_every_column_cnpg_returns() {
        let row = crate::models::MtrHopRow {
            time: Utc.with_ymd_and_hms(2026, 1, 1, 0, 0, 0).unwrap(),
            id: uuid::Uuid::nil(),
            trace_id: uuid::Uuid::nil(),
            target_ip: None,
            device_id: None,
            hop_number: 1,
            addr: Some("192.0.2.1".into()),
            hostname: None,
            ecmp_addrs: None,
            asn: None,
            asn_org: None,
            mpls_labels: None,
            sent: 10,
            received: 9,
            loss_pct: 10.0,
            last_us: None,
            avg_us: None,
            min_us: None,
            max_us: None,
            stddev_us: None,
            jitter_us: None,
            jitter_worst_us: None,
            jitter_interarrival_us: None,
            created_at: Utc.with_ymd_and_hms(2026, 1, 1, 0, 0, 0).unwrap(),
            reply_time_exceeded: None,
            reply_unreachable: None,
            reply_synack: None,
            reply_rst: None,
        };
        let keys = row
            .into_json()
            .as_object()
            .unwrap()
            .keys()
            .cloned()
            .collect::<Vec<_>>();
        let mut expected = HOP_ROW_COLUMNS
            .iter()
            .map(|c| c.to_string())
            .collect::<Vec<_>>();
        expected.sort();
        assert_eq!(keys, expected);

        let sql = compile("in:mtr_hops time:last_1h limit:5");
        let select = HOP_ROW_COLUMNS
            .iter()
            .map(|c| format!("`{c}`"))
            .collect::<Vec<_>>()
            .join(", ");
        assert!(
            sql.starts_with(&format!(
                "SELECT {select} FROM serviceradar.mtr_hops WHERE "
            )),
            "{sql}"
        );
        assert!(
            sql.ends_with(
                " ORDER BY `time` DESC NULLS FIRST, `id` DESC NULLS FIRST LIMIT 5 OFFSET 0"
            ),
            "{sql}"
        );
    }

    #[test]
    fn trace_rows_project_every_column_cnpg_returns() {
        let row = crate::models::MtrTraceRow {
            time: Utc.with_ymd_and_hms(2026, 1, 1, 0, 0, 0).unwrap(),
            id: uuid::Uuid::nil(),
            agent_id: "agent-a".into(),
            gateway_id: None,
            check_id: None,
            check_name: None,
            device_id: None,
            target: "host01.example.com".into(),
            target_ip: "192.0.2.10".into(),
            target_reached: true,
            total_hops: 5,
            protocol: "icmp".into(),
            ip_version: 4,
            packet_size: None,
            partition: None,
            error: None,
            created_at: Utc.with_ymd_and_hms(2026, 1, 1, 0, 0, 0).unwrap(),
            tcp_handshake_ttl: None,
            tcp_handshake_attempts: None,
            tcp_syn_sent: None,
            tcp_synack_received: None,
            tcp_rst_received: None,
            tcp_syn_unanswered: None,
            tcp_syn_drop_pct: None,
            tcp_syn_retransmits: None,
            tcp_answered_after_retx: None,
            tcp_ack_mismatch: None,
            tcp_synack_duplicates: None,
            tcp_handshake_rtt_min_us: None,
            tcp_handshake_rtt_avg_us: None,
            tcp_handshake_rtt_max_us: None,
            tcp_server_response_us: None,
        };
        let keys = row
            .into_json()
            .as_object()
            .unwrap()
            .keys()
            .cloned()
            .collect::<Vec<_>>();
        let mut expected = TRACE_ROW_COLUMNS
            .iter()
            .map(|c| c.to_string())
            .collect::<Vec<_>>();
        expected.sort();
        assert_eq!(keys, expected);

        let sql = compile("in:mtr_traces time:last_1h limit:5");
        assert!(
            sql.contains("`partition`, `error`"),
            "reserved words are quoted: {sql}"
        );
    }

    #[test]
    fn row_order_appends_time_and_id_in_the_leading_direction() {
        let sql = compile("in:mtr_hops sort:hop_number:asc limit:30");
        assert!(
            sql.ends_with(" ORDER BY `hop_number` ASC NULLS LAST, `time` ASC NULLS LAST, `id` ASC NULLS LAST LIMIT 30 OFFSET 0"),
            "{sql}"
        );
        let sql = compile("in:mtr_traces sort:total_hops:desc,time:asc limit:3");
        assert!(
            sql.ends_with(" ORDER BY `total_hops` DESC NULLS FIRST, `time` ASC NULLS LAST, `id` ASC NULLS LAST LIMIT 3 OFFSET 0"),
            "{sql}"
        );
        assert!(matches!(
            refused("in:mtr_hops sort:sent:desc"),
            ServiceError::InvalidRequest(_)
        ));
    }

    #[test]
    fn row_negations_keep_null_rows_and_stats_negations_drop_them() {
        // CNPG's row builder writes `col IS NULL OR col <> v`; its stats builder
        // writes a bare `col <> v`.
        let rows = compile("in:mtr_hops !addr:192.0.2.1 limit:5");
        assert!(
            rows.contains("(`addr` IS NULL OR `addr` != '192.0.2.1')"),
            "{rows}"
        );
        let stats = compile("in:mtr_hops !addr:192.0.2.1 stats:count() as n by asn limit:5");
        assert!(
            stats.contains(" WHERE `addr` != '192.0.2.1' GROUP BY "),
            "{stats}"
        );

        let like = compile("in:mtr_traces target:%.Example.COM limit:5");
        assert!(
            like.contains("LOWER(`target`) LIKE '%.example.com'"),
            "ILIKE: {like}"
        );
    }

    #[test]
    fn device_scoped_panels_filter_on_the_attribution_columns() {
        let sql = compile(
            "in:mtr_hops time:last_24h target_ip:192.0.2.50 device_id:sr:device-a stats:loss_ratio(sent, received) as loss by addr limit:20",
        );
        assert!(
            sql.contains(
                " AND `target_ip` = '192.0.2.50' AND `device_id` = 'sr:device-a' GROUP BY "
            ),
            "{sql}"
        );
    }

    #[test]
    fn trace_id_is_matched_as_cnpg_matches_it() {
        let upper = "8E1C1F3A-0000-4000-8000-000000000001";
        let rows = compile(&format!("in:mtr_hops trace_id:{upper} limit:5"));
        assert!(
            rows.contains("`trace_id` = '8e1c1f3a-0000-4000-8000-000000000001'"),
            "{rows}"
        );
        // The stats builder compares `trace_id::text`, the raw value.
        let stats = compile(&format!(
            "in:mtr_hops trace_id:{upper} stats:count() as n by addr limit:5"
        ));
        assert!(
            stats.contains(&format!("`trace_id` = '{upper}'")),
            "{stats}"
        );
        assert!(matches!(
            refused("in:mtr_hops trace_id:not-a-uuid limit:5"),
            ServiceError::InvalidRequest(_)
        ));
    }

    #[test]
    fn target_reached_filters_honor_negation() {
        let rows = compile("in:mtr_traces !target_reached:true limit:5");
        assert!(rows.contains("`target_reached` <> TRUE"), "{rows}");
        let stats =
            compile("in:mtr_traces !target_reached:true stats:count() as n by target_ip limit:5");
        assert!(stats.contains("`target_reached` <> TRUE"), "{stats}");
        let pg = cnpg("in:mtr_traces !target_reached:true stats:count() as n by target_ip limit:5")
            .expect("CNPG compiles");
        assert!(pg.contains("target_reached <> $"), "{pg}");
    }

    #[test]
    fn numeric_filters_compare_typed_literals() {
        let sql = compile(
            "in:mtr_traces tcp_syn_drop_pct:>12.5 tcp_handshake_rtt_avg_us:>=3000000000 limit:5",
        );
        assert!(sql.contains("`tcp_syn_drop_pct` > 12.5"), "{sql}");
        assert!(
            sql.contains("`tcp_handshake_rtt_avg_us` >= 3000000000"),
            "{sql}"
        );
        let sql = compile("in:mtr_hops reply_rst:>0 stats:sum(reply_rst) as rsts by addr limit:5");
        assert!(sql.contains("`reply_rst` > 0"), "{sql}");
        assert!(sql.contains("SUM(`reply_rst`) AS `rsts`"), "{sql}");
    }

    #[test]
    fn hop_number_takes_ordered_comparisons_in_stats_only() {
        compile("in:mtr_hops hop_number:>2 stats:count() as n by addr limit:5");
        assert!(matches!(
            refused("in:mtr_hops hop_number:>2 limit:5"),
            ServiceError::InvalidRequest(_)
        ));
    }

    #[test]
    fn stats_sort_by_a_field_it_does_not_group_by_is_refused() {
        // Postgres rejects the same ORDER BY.
        assert!(matches!(
            refused("in:mtr_hops stats:count() as n by addr sort:asn:desc limit:5"),
            ServiceError::InvalidRequest(_)
        ));
    }

    /// Both backends accept and refuse the same MTR queries. The only
    /// intended differences are listed in `WAREHOUSE_ONLY_REFUSALS`.
    #[test]
    fn both_backends_accept_the_same_queries() {
        let mut corpus: Vec<String> = PANEL_QUERIES.iter().map(|q| q.to_string()).collect();
        for (column, _) in mtr_hops::AGGREGATABLE_COLUMNS {
            for func in ["sum", "avg", "min", "max", "count"] {
                corpus.push(format!(
                    "in:mtr_hops stats:{func}({column}) as v by addr limit:5"
                ));
            }
        }
        for (column, _) in mtr_traces::TRACE_AGGREGATABLE_COLUMNS {
            for func in ["sum", "avg", "min", "max", "count"] {
                corpus.push(format!(
                    "in:mtr_traces stats:{func}({column}) as v by target_ip limit:5"
                ));
            }
        }
        for field in mtr_hops::GROUP_BY_FIELDS {
            corpus.push(format!(
                "in:mtr_hops stats:count() as n by {field} sort:{field}:asc limit:5"
            ));
        }
        for field in mtr_traces::TRACE_GROUP_BY_FIELDS {
            corpus.push(format!(
                "in:mtr_traces stats:count() as n by {field},time:1h limit:5"
            ));
        }
        for field in mtr_hops::REPLY_TYPE_FIELDS {
            corpus.push(format!("in:mtr_hops {field}:>=1 limit:5"));
            corpus.push(format!(
                "in:mtr_hops {field}:<1 stats:count() as n by addr limit:5"
            ));
            corpus.push(format!("in:mtr_hops {field}:many limit:5"));
        }
        for (field, _) in mtr_traces::TRACE_HANDSHAKE_FIELDS {
            corpus.push(format!("in:mtr_traces {field}:>1 limit:5"));
            corpus.push(format!(
                "in:mtr_traces !{field}:1 stats:count() as n by target_ip limit:5"
            ));
            corpus.push(format!("in:mtr_traces {field}:(1,2) limit:5"));
        }
        for field in HOP_TEXT_FIELDS {
            for value in ["192.0.2.1", "%192.0.2%", "(192.0.2.1,198.51.100.1)"] {
                corpus.push(format!("in:mtr_hops {field}:{value} limit:5"));
                corpus.push(format!(
                    "in:mtr_hops !{field}:{value} stats:count() as n by asn limit:5"
                ));
            }
        }
        for field in TRACE_TEXT_FIELDS {
            for value in ["edge-a", "%edge%", "(edge-a,edge-b)"] {
                corpus.push(format!("in:mtr_traces {field}:{value} limit:5"));
                corpus.push(format!(
                    "in:mtr_traces !{field}:{value} stats:count() as n by agent_id limit:5"
                ));
            }
        }
        for sort in HOP_ROW_SORT_FIELDS
            .iter()
            .chain(&["time", "timestamp", "sent"])
        {
            corpus.push(format!("in:mtr_hops sort:{sort}:desc limit:5"));
        }
        for sort in TRACE_ROW_SORT_FIELDS
            .iter()
            .chain(&["time", "total_hops", "ip_version"])
        {
            corpus.push(format!("in:mtr_traces sort:{sort}:asc limit:5"));
        }
        corpus.extend(
            [
                "in:mtr_hops asn:>0 limit:5",
                "in:mtr_hops asn:%1% limit:5",
                "in:mtr_hops hop_number:3 limit:5",
                "in:mtr_hops hop_number:>3 limit:5",
                "in:mtr_hops hop_number:>=3 stats:count() as n by addr limit:5",
                "in:mtr_hops gateway_id:gw-a limit:5",
                "in:mtr_hops gateway_id:gw-a stats:count() as n by addr limit:5",
                "in:mtr_traces total_hops:5 stats:count() as n by target_ip limit:5",
                "in:mtr_traces target_reached:maybe limit:5",
                "in:mtr_traces target_reached:false stats:count() as n by target_ip limit:5",
                "in:mtr_hops stats:wavg(loss_pct, received) as v by addr limit:5",
                "in:mtr_hops stats:loss_ratio(sent, sent) as v by addr limit:5",
                "in:mtr_hops stats:loss_ratio(hop_number, received) as v by addr limit:5",
                "in:mtr_hops stats:avg(total_hops) as v by addr limit:5",
                "in:mtr_hops stats:avg(loss_pct) as v by hostname limit:5",
                "in:mtr_traces stats:loss_ratio(sent, received) as v by target_ip limit:5",
                "in:mtr_traces stats:count() as n by total_hops limit:5",
                "in:mtr_traces stats:sum() as n by target_ip limit:5",
                "in:mtr_hops stats:count() as n limit:5",
                "in:mtr_traces stats:count() as n by target_ip sort:unknown:asc limit:5",
                "in:mtr_hops stats:loss_ratio(sent, received) by addr limit:5",
                "in:mtr_hops stats:\"count() as n by addr,time:1h,time:5m\" limit:5",
            ]
            .map(String::from),
        );

        let mut mismatches = Vec::new();
        for query in &corpus {
            let warehouse = super::super::translate(&plan(query), DB);
            let relational = cnpg(query);
            if warehouse.is_ok() != relational.is_ok() {
                mismatches.push(format!(
                    "{query}\n  starrocks: {:?}\n  cnpg: {:?}",
                    warehouse.map(|c| c.sql),
                    relational
                ));
            }
        }
        assert!(mismatches.is_empty(), "{}", mismatches.join("\n"));
    }
}
