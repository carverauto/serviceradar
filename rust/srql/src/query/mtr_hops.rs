use super::{BindParam, QueryPlan};
use crate::{
    error::{Result, ServiceError},
    models::MtrHopRow,
    parser::{Entity, Filter, FilterOp, OrderClause, OrderDirection},
    schema::mtr_hops::dsl::{
        addr as col_addr, asn as col_asn, asn_org as col_asn_org, created_at as col_created_at,
        hop_number as col_hop_number, hostname as col_hostname, id as col_id,
        loss_pct as col_loss_pct, mtr_hops, time as col_time, trace_id as col_trace_id,
    },
    time::TimeRange,
};
use chrono::{DateTime, Utc};
use diesel::pg::Pg;
use diesel::prelude::*;
use diesel::query_builder::{AsQuery, BoxedSelectStatement, FromClause};
use diesel_async::{AsyncPgConnection, RunQueryDsl};

type MtrHopsTable = crate::schema::mtr_hops::table;
type MtrHopsFromClause = FromClause<MtrHopsTable>;
type MtrHopsQuery<'a> =
    BoxedSelectStatement<'a, <MtrHopsTable as AsQuery>::SqlType, MtrHopsFromClause, Pg>;

// ─── stats SQL helpers ────────────────────────────────────────────────────────

/// Aggregatable numeric columns and their SQL names in platform.mtr_hops.
const AGGREGATABLE_COLUMNS: &[(&str, &str)] = &[
    ("loss_pct", "loss_pct"),
    ("avg_us", "avg_us"),
    ("min_us", "min_us"),
    ("max_us", "max_us"),
    ("jitter_us", "jitter_us"),
    ("sent", "sent"),
    ("received", "received"),
];

/// Valid grouping fields for stats queries.
const GROUP_BY_FIELDS: &[&str] = &["addr", "asn", "asn_org", "hop_number"];

/// Columns `wavg` may average. `loss_pct` is excluded deliberately: a weighted
/// mean of percentages is still a mean of ratios, and `loss_ratio` is the
/// correct aggregate for loss.
const WAVG_VALUE_COLUMNS: &[&str] = &["avg_us", "min_us", "max_us", "jitter_us"];

/// Columns that may weight a `wavg` or denominate a `loss_ratio`: the probe
/// counters, which are the only columns carrying sample size.
const PROBE_COUNT_COLUMNS: &[&str] = &["sent", "received"];

/// Projection alias for the time-bucket group dimension.
const BUCKET_ALIAS: &str = "bucket";

/// One aggregation in a stats projection, carried as a complete SQL expression
/// so single- and two-argument functions are represented uniformly.
#[derive(Debug, Clone)]
struct HopAgg {
    expr: String,
    alias: String,
}

/// One grouping dimension: a validated column, or a time bucket.
#[derive(Debug, Clone)]
enum GroupDim {
    Column(&'static str),
    TimeBucket { seconds: i64 },
}

impl GroupDim {
    /// SQL expression to group by and project.
    fn expr(&self) -> String {
        match self {
            GroupDim::Column(col) => (*col).to_string(),
            // Epoch-floor bucketing, matching the form the downsample builder
            // already emits, so arbitrary durations work rather than only the
            // named units `date_trunc` accepts.
            GroupDim::TimeBucket { seconds } => {
                format!("to_timestamp(floor(extract(epoch from time) / {seconds}) * {seconds})")
            }
        }
    }

    /// Key this dimension appears under in the JSON payload.
    fn alias(&self) -> &str {
        match self {
            GroupDim::Column(col) => col,
            GroupDim::TimeBucket { .. } => BUCKET_ALIAS,
        }
    }
}

#[derive(Debug, Clone)]
struct HopStatsSql {
    sql: String,
    binds: Vec<HopStatsBindValue>,
}

#[derive(Debug, Clone)]
enum HopStatsBindValue {
    Text(String),
    TextArray(Vec<String>),
    Timestamp(DateTime<Utc>),
    Int(i32),
}

impl HopStatsBindValue {
    fn apply<'a>(
        &self,
        query: diesel::query_builder::BoxedSqlQuery<'a, Pg, diesel::query_builder::SqlQuery>,
    ) -> diesel::query_builder::BoxedSqlQuery<'a, Pg, diesel::query_builder::SqlQuery> {
        use diesel::sql_types::{Array, Int4, Text, Timestamptz};
        match self {
            HopStatsBindValue::Text(v) => query.bind::<Text, _>(v.clone()),
            HopStatsBindValue::TextArray(v) => query.bind::<Array<Text>, _>(v.clone()),
            HopStatsBindValue::Timestamp(v) => query.bind::<Timestamptz, _>(*v),
            HopStatsBindValue::Int(v) => query.bind::<Int4, _>(*v),
        }
    }
}

#[derive(Debug, diesel::QueryableByName)]
#[diesel(check_for_backend(diesel::pg::Pg))]
struct HopStatsPayload {
    #[diesel(sql_type = diesel::sql_types::Nullable<diesel::sql_types::Jsonb>)]
    payload: Option<crate::jsonb::DbJson>,
}

// ─── public interface ─────────────────────────────────────────────────────────

pub(super) async fn execute(
    conn: &mut AsyncPgConnection,
    plan: &QueryPlan,
) -> Result<Vec<serde_json::Value>> {
    ensure_entity(plan)?;

    if let Some(stats) = &plan.stats {
        let sql = build_stats_sql(plan, stats.as_raw())?;
        return execute_stats(conn, &sql).await;
    }

    let query = build_query(plan)?;
    let rows: Vec<MtrHopRow> = query
        .select(MtrHopRow::as_select())
        .limit(plan.limit)
        .offset(plan.offset)
        .load::<MtrHopRow>(conn)
        .await
        .map_err(|e| ServiceError::Internal(e.into()))?;

    Ok(rows.into_iter().map(MtrHopRow::into_json).collect())
}

pub(super) fn to_sql_and_params(plan: &QueryPlan) -> Result<(String, Vec<BindParam>)> {
    ensure_entity(plan)?;

    if let Some(stats) = &plan.stats {
        let sql = build_stats_sql(plan, stats.as_raw())?;
        let params = sql.binds.into_iter().map(bind_param_from_hop).collect();
        return Ok((rewrite_placeholders(&sql.sql), params));
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

// ─── entity guard ─────────────────────────────────────────────────────────────

fn ensure_entity(plan: &QueryPlan) -> Result<()> {
    match plan.entity {
        Entity::MtrHops => Ok(()),
        _ => Err(ServiceError::InvalidRequest(
            "entity not supported by mtr_hops query".into(),
        )),
    }
}

// ─── row query ───────────────────────────────────────────────────────────────

fn build_query(plan: &QueryPlan) -> Result<MtrHopsQuery<'static>> {
    let mut query = mtr_hops.into_boxed::<Pg>();

    if let Some(TimeRange { start, end }) = &plan.time_range {
        query = query.filter(col_time.ge(*start).and(col_time.lt(*end)));
    }

    for filter in &plan.filters {
        query = apply_filter(query, filter)?;
    }

    apply_ordering(query, &plan.order)
}

fn apply_filter<'a>(mut query: MtrHopsQuery<'a>, filter: &Filter) -> Result<MtrHopsQuery<'a>> {
    match filter.field.as_str() {
        "addr" => query = apply_text_filter!(query, filter, col_addr)?,
        "hostname" => query = apply_text_filter!(query, filter, col_hostname)?,
        "asn_org" => query = apply_text_filter!(query, filter, col_asn_org)?,
        "trace_id" => query = apply_trace_id_filter(query, filter)?,
        "asn" => query = apply_asn_filter(query, filter)?,
        "hop_number" => query = apply_hop_number_filter(query, filter)?,
        other => {
            return Err(ServiceError::InvalidRequest(format!(
                "unsupported filter field for mtr_hops: '{other}'"
            )));
        }
    }
    Ok(query)
}

fn apply_trace_id_filter<'a>(query: MtrHopsQuery<'a>, filter: &Filter) -> Result<MtrHopsQuery<'a>> {
    let raw = filter.value.as_scalar()?;
    let uuid = uuid::Uuid::parse_str(raw).map_err(|_| {
        ServiceError::InvalidRequest(format!("trace_id must be a valid UUID, got '{raw}'"))
    })?;
    match filter.op {
        FilterOp::Eq => Ok(query.filter(col_trace_id.eq(uuid))),
        FilterOp::NotEq => Ok(query.filter(col_trace_id.ne(uuid))),
        _ => Err(ServiceError::InvalidRequest(
            "trace_id only supports equality comparisons".into(),
        )),
    }
}

fn apply_asn_filter<'a>(query: MtrHopsQuery<'a>, filter: &Filter) -> Result<MtrHopsQuery<'a>> {
    let raw = filter.value.as_scalar()?;
    let asn: i32 = raw.parse().map_err(|_| {
        ServiceError::InvalidRequest(format!("asn must be an integer, got '{raw}'"))
    })?;
    match filter.op {
        FilterOp::Eq => Ok(query.filter(col_asn.eq(asn))),
        FilterOp::NotEq => Ok(query.filter(col_asn.ne(asn))),
        // `asn` is populated only by a GeoLite2 lookup, so it is NULL for any
        // hop the database does not resolve — every internal address, and every
        // private AS. `asn:>0` is how a caller restricts a query to resolved
        // ASNs, since NULL fails the comparison.
        FilterOp::Gt => Ok(query.filter(col_asn.gt(asn))),
        FilterOp::Gte => Ok(query.filter(col_asn.ge(asn))),
        FilterOp::Lt => Ok(query.filter(col_asn.lt(asn))),
        FilterOp::Lte => Ok(query.filter(col_asn.le(asn))),
        _ => Err(ServiceError::InvalidRequest(
            "asn supports equality and ordered comparisons".into(),
        )),
    }
}

fn apply_hop_number_filter<'a>(
    query: MtrHopsQuery<'a>,
    filter: &Filter,
) -> Result<MtrHopsQuery<'a>> {
    let raw = filter.value.as_scalar()?;
    let n: i32 = raw.parse().map_err(|_| {
        ServiceError::InvalidRequest(format!("hop_number must be an integer, got '{raw}'"))
    })?;
    match filter.op {
        FilterOp::Eq => Ok(query.filter(col_hop_number.eq(n))),
        FilterOp::NotEq => Ok(query.filter(col_hop_number.ne(n))),
        _ => Err(ServiceError::InvalidRequest(
            "hop_number only supports equality comparisons".into(),
        )),
    }
}

fn collect_filter_params(params: &mut Vec<BindParam>, filter: &Filter) -> Result<()> {
    match filter.field.as_str() {
        "addr" | "hostname" | "asn_org" => collect_text_params(params, filter),
        "trace_id" => {
            let raw = filter.value.as_scalar()?;
            let uuid = uuid::Uuid::parse_str(raw).map_err(|_| {
                ServiceError::InvalidRequest(format!("trace_id must be a valid UUID, got '{raw}'"))
            })?;
            params.push(BindParam::Uuid(uuid));
            Ok(())
        }
        "asn" | "hop_number" => {
            let raw = filter.value.as_scalar()?;
            let n: i32 = raw.parse().map_err(|_| {
                ServiceError::InvalidRequest(format!(
                    "{} must be an integer, got '{raw}'",
                    filter.field
                ))
            })?;
            params.push(BindParam::Int(n.into()));
            Ok(())
        }
        other => Err(ServiceError::InvalidRequest(format!(
            "unsupported filter field for mtr_hops: '{other}'"
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
            if !values.is_empty() {
                params.push(BindParam::TextArray(values));
            }
            Ok(())
        }
        _ => Err(ServiceError::InvalidRequest(format!(
            "unsupported operator for text filter: {:?}",
            filter.op
        ))),
    }
}

fn apply_ordering<'a>(
    mut query: MtrHopsQuery<'a>,
    order: &[OrderClause],
) -> Result<MtrHopsQuery<'a>> {
    if order.is_empty() {
        return Ok(query.order(col_time.desc()).then_order_by(col_id.desc()));
    }
    for (i, clause) in order.iter().enumerate() {
        query = if i == 0 {
            apply_primary_order(query, clause)?
        } else {
            apply_secondary_order(query, clause)?
        };
    }
    let tie_dir = order
        .iter()
        .find(|c| matches!(c.field.as_str(), "time" | "timestamp"))
        .map(|c| c.direction)
        .unwrap_or(order[0].direction);
    let has_time = order
        .iter()
        .any(|c| matches!(c.field.as_str(), "time" | "timestamp"));
    if !has_time {
        query = match tie_dir {
            OrderDirection::Asc => query.then_order_by(col_time.asc()),
            OrderDirection::Desc => query.then_order_by(col_time.desc()),
        };
    }
    query = match tie_dir {
        OrderDirection::Asc => query.then_order_by(col_id.asc()),
        OrderDirection::Desc => query.then_order_by(col_id.desc()),
    };
    Ok(query)
}

fn apply_primary_order<'a>(
    query: MtrHopsQuery<'a>,
    clause: &OrderClause,
) -> Result<MtrHopsQuery<'a>> {
    Ok(match clause.field.as_str() {
        "time" | "timestamp" => match clause.direction {
            OrderDirection::Asc => query.order(col_time.asc()),
            OrderDirection::Desc => query.order(col_time.desc()),
        },
        "hop_number" => match clause.direction {
            OrderDirection::Asc => query.order(col_hop_number.asc()),
            OrderDirection::Desc => query.order(col_hop_number.desc()),
        },
        "addr" => match clause.direction {
            OrderDirection::Asc => query.order(col_addr.asc()),
            OrderDirection::Desc => query.order(col_addr.desc()),
        },
        "asn" => match clause.direction {
            OrderDirection::Asc => query.order(col_asn.asc()),
            OrderDirection::Desc => query.order(col_asn.desc()),
        },
        "asn_org" => match clause.direction {
            OrderDirection::Asc => query.order(col_asn_org.asc()),
            OrderDirection::Desc => query.order(col_asn_org.desc()),
        },
        "loss_pct" => match clause.direction {
            OrderDirection::Asc => query.order(col_loss_pct.asc()),
            OrderDirection::Desc => query.order(col_loss_pct.desc()),
        },
        "created_at" => match clause.direction {
            OrderDirection::Asc => query.order(col_created_at.asc()),
            OrderDirection::Desc => query.order(col_created_at.desc()),
        },
        other => {
            return Err(ServiceError::InvalidRequest(format!(
                "unsupported sort field for mtr_hops: '{other}'"
            )));
        }
    })
}

fn apply_secondary_order<'a>(
    query: MtrHopsQuery<'a>,
    clause: &OrderClause,
) -> Result<MtrHopsQuery<'a>> {
    Ok(match clause.field.as_str() {
        "time" | "timestamp" => match clause.direction {
            OrderDirection::Asc => query.then_order_by(col_time.asc()),
            OrderDirection::Desc => query.then_order_by(col_time.desc()),
        },
        "hop_number" => match clause.direction {
            OrderDirection::Asc => query.then_order_by(col_hop_number.asc()),
            OrderDirection::Desc => query.then_order_by(col_hop_number.desc()),
        },
        "addr" => match clause.direction {
            OrderDirection::Asc => query.then_order_by(col_addr.asc()),
            OrderDirection::Desc => query.then_order_by(col_addr.desc()),
        },
        "asn" => match clause.direction {
            OrderDirection::Asc => query.then_order_by(col_asn.asc()),
            OrderDirection::Desc => query.then_order_by(col_asn.desc()),
        },
        "asn_org" => match clause.direction {
            OrderDirection::Asc => query.then_order_by(col_asn_org.asc()),
            OrderDirection::Desc => query.then_order_by(col_asn_org.desc()),
        },
        "loss_pct" => match clause.direction {
            OrderDirection::Asc => query.then_order_by(col_loss_pct.asc()),
            OrderDirection::Desc => query.then_order_by(col_loss_pct.desc()),
        },
        "created_at" => match clause.direction {
            OrderDirection::Asc => query.then_order_by(col_created_at.asc()),
            OrderDirection::Desc => query.then_order_by(col_created_at.desc()),
        },
        other => {
            return Err(ServiceError::InvalidRequest(format!(
                "unsupported sort field for mtr_hops: '{other}'"
            )));
        }
    })
}

// ─── stats query ─────────────────────────────────────────────────────────────

async fn execute_stats(
    conn: &mut AsyncPgConnection,
    sql: &HopStatsSql,
) -> Result<Vec<serde_json::Value>> {
    use diesel::sql_query;
    use diesel_async::RunQueryDsl;

    let mut q = sql_query(rewrite_placeholders(&sql.sql)).into_boxed::<Pg>();
    for bind in &sql.binds {
        q = bind.apply(q);
    }
    let rows: Vec<HopStatsPayload> = q
        .load::<HopStatsPayload>(conn)
        .await
        .map_err(|e| ServiceError::Internal(e.into()))?;

    Ok(rows
        .into_iter()
        .filter_map(|r| r.payload.map(|p| p.0))
        .collect())
}

fn build_stats_sql(plan: &QueryPlan, raw: &str) -> Result<HopStatsSql> {
    let (agg_part, group_part) = split_group_clause(raw).ok_or_else(|| {
        ServiceError::InvalidRequest(
            "mtr_hops stats expression must include 'by <field>' — e.g. \
             stats:avg(loss_pct) as avg_loss by addr"
                .into(),
        )
    })?;

    let dims = parse_group_dims(group_part.trim())?;
    let aggs = parse_agg_expressions(agg_part.trim())?;

    let mut clauses: Vec<String> = Vec::new();
    let mut binds: Vec<HopStatsBindValue> = Vec::new();

    if let Some(TimeRange { start, end }) = &plan.time_range {
        clauses.push("time >= ?".into());
        binds.push(HopStatsBindValue::Timestamp(*start));
        clauses.push("time < ?".into());
        binds.push(HopStatsBindValue::Timestamp(*end));
    }

    for filter in &plan.filters {
        if let Some((clause, mut filt_binds)) = build_stats_filter_clause(filter)? {
            clauses.push(clause);
            binds.append(&mut filt_binds);
        }
    }

    // Build jsonb payload with agg expressions embedded inline so the query is
    // self-contained without a subquery or repeated alias references.
    let json_kv: Vec<String> = aggs
        .iter()
        .flat_map(|agg| [format!("'{}'", agg.alias), agg.expr.clone()])
        .chain(
            dims.iter()
                .flat_map(|dim| [format!("'{}'", dim.alias()), dim.expr()]),
        )
        .collect();
    let payload_expr = format!("jsonb_build_object({})", json_kv.join(", "));

    let group_exprs: Vec<String> = dims.iter().map(GroupDim::expr).collect();
    let bucket_expr = dims.iter().find_map(|dim| match dim {
        GroupDim::TimeBucket { .. } => Some(dim.expr()),
        GroupDim::Column(_) => None,
    });

    let mut body = format!("SELECT {payload_expr} AS payload");
    if let Some(bucket) = &bucket_expr {
        // Projected so the outer query can re-sort ascending after truncation.
        body.push_str(&format!(", {bucket} AS __bucket"));
    }
    body.push_str("\nFROM mtr_hops");
    if !clauses.is_empty() {
        body.push_str("\nWHERE ");
        body.push_str(&clauses.join(" AND "));
    }
    body.push_str(&format!("\nGROUP BY {}", group_exprs.join(", ")));

    let sql = match &bucket_expr {
        // A bucketed result must keep the NEWEST buckets when `limit:` truncates
        // and still render oldest-first. Truncating on an ascending sort is the
        // defect recorded in downsample/sql.rs: a 30-day chart at a 5m bucket
        // silently stopped two weeks back because the oldest buckets were kept.
        Some(_) => {
            body.push_str("\nORDER BY __bucket DESC");
            body.push_str(&format!("\nLIMIT {} OFFSET {}", plan.limit, plan.offset));
            format!("SELECT payload\nFROM (\n{body}\n) AS bucketed\nORDER BY __bucket ASC")
        }
        None => {
            body.push_str(&build_stats_order_clause(plan, &aggs));
            body.push_str(&format!("\nLIMIT {} OFFSET {}", plan.limit, plan.offset));
            body
        }
    };

    Ok(HopStatsSql { sql, binds })
}

/// Parse the `by` clause into grouping dimensions.
///
/// Accepts a comma-separated mix of validated columns and at most one
/// `time:<duration>` bucket.
fn parse_group_dims(part: &str) -> Result<Vec<GroupDim>> {
    let mut dims: Vec<GroupDim> = Vec::new();

    for raw in part.split(',') {
        let token = raw.trim();
        if token.is_empty() {
            continue;
        }

        if let Some((key, value)) = token.split_once(':') {
            let key = key.trim().to_ascii_lowercase();
            if key != "time" {
                return Err(ServiceError::InvalidRequest(format!(
                    "only the 'time' group dimension takes a duration; got '{token}'"
                )));
            }
            if dims
                .iter()
                .any(|d| matches!(d, GroupDim::TimeBucket { .. }))
            {
                return Err(ServiceError::InvalidRequest(
                    "only one time bucket dimension is supported".into(),
                ));
            }
            let seconds = crate::parser::parse_group_bucket_seconds(value.trim())?;
            dims.push(GroupDim::TimeBucket { seconds });
        } else {
            dims.push(GroupDim::Column(validate_group_field(token)?));
        }
    }

    if dims.is_empty() {
        return Err(ServiceError::InvalidRequest(
            "mtr_hops stats requires at least one group dimension".into(),
        ));
    }

    Ok(dims)
}

fn parse_agg_expressions(part: &str) -> Result<Vec<HopAgg>> {
    // Comma-separated expressions like:
    //   avg(loss_pct) as avg_loss, loss_ratio(sent, received) as loss
    //
    // A two-argument call contains a comma of its own, so the split has to
    // respect parentheses; splitting on every comma would tear
    // `loss_ratio(sent, received)` into two unparseable halves.
    let mut result = Vec::new();
    for expr in crate::parser::split_top_level_commas(part) {
        let expr = expr.trim();
        if expr.is_empty() {
            continue;
        }
        result.push(parse_single_agg(expr)?);
    }
    if result.is_empty() {
        return Err(ServiceError::InvalidRequest(
            "mtr_hops stats requires at least one aggregation expression".into(),
        ));
    }
    Ok(result)
}

fn parse_single_agg(expr: &str) -> Result<HopAgg> {
    let lower = expr.to_ascii_lowercase();

    // Try to match "func(args) as alias"
    let (func_and_args, alias) = if let Some(pos) = lower.find(" as ") {
        (&expr[..pos], expr[pos + 4..].trim())
    } else {
        (expr, "")
    };

    let (func_name, args) = parse_func_call(func_and_args.trim())?;
    let func_lower = func_name.to_ascii_lowercase();

    let arg_list: Vec<&str> = args.split(',').map(str::trim).collect();

    match func_lower.as_str() {
        "loss_ratio" | "wavg" => {
            let [first, second] = arg_list.as_slice() else {
                return Err(ServiceError::InvalidRequest(format!(
                    "{func_lower} requires exactly two arguments — e.g. \
                     {}",
                    if func_lower == "loss_ratio" {
                        "loss_ratio(sent, received)"
                    } else {
                        "wavg(avg_us, received)"
                    }
                )));
            };

            let expr_sql = if func_lower == "loss_ratio" {
                build_loss_ratio_expr(first, second)?
            } else {
                build_wavg_expr(first, second)?
            };

            let alias = if alias.is_empty() {
                func_lower.clone()
            } else {
                sanitize_identifier(alias)?
            };

            Ok(HopAgg {
                expr: expr_sql,
                alias,
            })
        }
        _ => {
            if arg_list.len() != 1 {
                return Err(ServiceError::InvalidRequest(format!(
                    "aggregation '{func_lower}' takes a single column, got {} arguments",
                    arg_list.len()
                )));
            }
            let field_name = arg_list[0];
            let func_sql = agg_func_sql(&func_name)?;
            let col = validate_agg_column(field_name)?;
            let alias = if alias.is_empty() {
                format!("{}_{}", func_lower, col)
            } else {
                sanitize_identifier(alias)?
            };

            Ok(HopAgg {
                expr: format!("{func_sql}({col})"),
                alias,
            })
        }
    }
}

/// `loss_ratio(sent, received)` as a ratio of sums.
///
/// A mean of per-hop percentages is a different number whenever the hops in a
/// group sent unequal probe counts, which is the normal case: one hop that sent
/// a single lost probe would otherwise weigh as much as one that sent five
/// hundred cleanly. The CASE guard yields NULL for a group that sent nothing, so
/// "no measurement" stays distinguishable from "no loss".
fn build_loss_ratio_expr(sent: &str, received: &str) -> Result<String> {
    let sent_col = validate_named_column(sent, PROBE_COUNT_COLUMNS, "loss_ratio numerator")?;
    let recv_col = validate_named_column(received, PROBE_COUNT_COLUMNS, "loss_ratio denominator")?;

    if sent_col == recv_col {
        return Err(ServiceError::InvalidRequest(
            "loss_ratio requires two different probe-count columns — e.g. \
             loss_ratio(sent, received)"
                .into(),
        ));
    }

    Ok(format!(
        "CASE WHEN COALESCE(SUM({sent_col}), 0) > 0 THEN \
         100.0 * (SUM({sent_col})::numeric - COALESCE(SUM({recv_col}), 0)::numeric) \
         / SUM({sent_col})::numeric ELSE NULL END"
    ))
}

/// `wavg(value, weight)` as a weight-weighted mean.
///
/// An `avg_us` derived from one returned packet is not comparable to one derived
/// from a hundred, so weighting by the probe count is what makes hop latencies
/// summable across a group. A NULL weight contributes nothing rather than
/// voiding the group; a zero total weight yields NULL.
fn build_wavg_expr(value: &str, weight: &str) -> Result<String> {
    let value_col = validate_named_column(value, WAVG_VALUE_COLUMNS, "wavg value")?;
    let weight_col = validate_named_column(weight, PROBE_COUNT_COLUMNS, "wavg weight")?;

    Ok(format!(
        "CASE WHEN SUM(COALESCE({weight_col}, 0)) > 0 THEN \
         SUM({value_col}::numeric * COALESCE({weight_col}, 0)::numeric) \
         / SUM(COALESCE({weight_col}, 0))::numeric ELSE NULL END"
    ))
}

fn validate_named_column(col: &str, allowed: &[&str], role: &str) -> Result<String> {
    let lower = col.trim().to_ascii_lowercase();
    if allowed.contains(&lower.as_str()) {
        Ok(lower)
    } else {
        Err(ServiceError::InvalidRequest(format!(
            "unsupported column '{col}' as {role} for mtr_hops; supported: {}",
            allowed.join(", ")
        )))
    }
}

fn parse_func_call(s: &str) -> Result<(String, String)> {
    let lower = s.to_ascii_lowercase();
    // match func(field)
    let open = lower.find('(').ok_or_else(|| {
        ServiceError::InvalidRequest(format!(
            "expected aggregation like avg(loss_pct), got '{s}'"
        ))
    })?;
    let close = lower
        .rfind(')')
        .ok_or_else(|| ServiceError::InvalidRequest(format!("unmatched parenthesis in '{s}'")))?;
    let func = s[..open].trim().to_string();
    let field = s[open + 1..close].trim().to_string();
    Ok((func, field))
}

fn agg_func_sql(func: &str) -> Result<String> {
    match func.to_ascii_lowercase().as_str() {
        "avg" => Ok("AVG".into()),
        "min" => Ok("MIN".into()),
        "max" => Ok("MAX".into()),
        "sum" => Ok("SUM".into()),
        "count" => Ok("COUNT".into()),
        other => Err(ServiceError::InvalidRequest(format!(
            "unsupported aggregation function '{other}' for mtr_hops; \
             use avg, min, max, sum, count, loss_ratio, or wavg"
        ))),
    }
}

fn validate_agg_column(col: &str) -> Result<String> {
    let lower = col.to_ascii_lowercase();
    AGGREGATABLE_COLUMNS
        .iter()
        .find(|(name, _)| *name == lower.as_str())
        .map(|(_, sql_name)| sql_name.to_string())
        .ok_or_else(|| {
            ServiceError::InvalidRequest(format!(
                "unsupported column '{col}' for mtr_hops stats; \
                 supported: loss_pct, avg_us, min_us, max_us, jitter_us, sent, received"
            ))
        })
}

fn validate_group_field(field: &str) -> Result<&'static str> {
    let lower = field.to_ascii_lowercase();
    GROUP_BY_FIELDS
        .iter()
        .find(|&&f| f == lower.as_str())
        .copied()
        .ok_or_else(|| {
            ServiceError::InvalidRequest(format!(
                "unsupported group-by field '{field}' for mtr_hops stats; \
                 supported: addr, asn, asn_org, hop_number"
            ))
        })
}

fn sanitize_identifier(s: &str) -> Result<String> {
    let clean: String = s
        .chars()
        .filter(|c| c.is_alphanumeric() || *c == '_')
        .collect();
    if clean.is_empty() || clean.starts_with(|c: char| c.is_ascii_digit()) {
        return Err(ServiceError::InvalidRequest(format!("invalid alias '{s}'")));
    }
    Ok(clean)
}

fn split_group_clause(raw: &str) -> Option<(&str, &str)> {
    // Find " by " case-insensitively
    let lower = raw.to_ascii_lowercase();
    let pos = lower.find(" by ")?;
    Some((&raw[..pos], &raw[pos + 4..]))
}

fn build_stats_order_clause(plan: &QueryPlan, aggs: &[HopAgg]) -> String {
    // Default: sort by the first agg expression descending.
    let default_expr = aggs.first().map(|agg| agg.expr.clone());

    if plan.order.is_empty() {
        return default_expr
            .map(|e| format!("\nORDER BY {e} DESC"))
            .unwrap_or_default();
    }

    let mut parts = Vec::new();
    for clause in &plan.order {
        let expr = if let Some(agg) = aggs
            .iter()
            .find(|agg| agg.alias.eq_ignore_ascii_case(&clause.field))
        {
            agg.expr.clone()
        } else if GROUP_BY_FIELDS
            .iter()
            .any(|&f| f.eq_ignore_ascii_case(&clause.field))
        {
            clause.field.clone()
        } else {
            continue;
        };
        let dir = match clause.direction {
            OrderDirection::Asc => "ASC",
            OrderDirection::Desc => "DESC",
        };
        parts.push(format!("{expr} {dir}"));
    }

    if parts.is_empty() {
        default_expr
            .map(|e| format!("\nORDER BY {e} DESC"))
            .unwrap_or_default()
    } else {
        format!("\nORDER BY {}", parts.join(", "))
    }
}

fn build_stats_filter_clause(filter: &Filter) -> Result<Option<(String, Vec<HopStatsBindValue>)>> {
    match filter.field.as_str() {
        "addr" => Ok(Some(build_text_clause("addr", filter)?)),
        "hostname" => Ok(Some(build_text_clause("hostname", filter)?)),
        "asn_org" => Ok(Some(build_text_clause("asn_org", filter)?)),
        "trace_id" => {
            let raw = filter.value.as_scalar()?;
            uuid::Uuid::parse_str(raw).map_err(|_| {
                ServiceError::InvalidRequest(format!("trace_id must be a valid UUID, got '{raw}'"))
            })?;
            Ok(Some(build_text_clause("trace_id::text", filter)?))
        }
        "asn" | "hop_number" => {
            let raw = filter.value.as_scalar()?;
            let n: i32 = raw.parse().map_err(|_| {
                ServiceError::InvalidRequest(format!(
                    "{} must be an integer, got '{raw}'",
                    filter.field
                ))
            })?;
            // Ordered comparisons matter for `asn` specifically: the column is
            // populated only by a GeoLite2 lookup, which resolves public ASNs
            // for public addresses and returns nothing for an internal hop. A
            // panel restricted to resolved ASNs says so with `asn:>0` — NULL
            // fails the comparison — rather than the group-by silently dropping
            // unresolved hops into a single bucket.
            let clause = match filter.op {
                FilterOp::Eq => format!("{} = ?", filter.field),
                FilterOp::NotEq => format!("{} <> ?", filter.field),
                FilterOp::Gt => format!("{} > ?", filter.field),
                FilterOp::Gte => format!("{} >= ?", filter.field),
                FilterOp::Lt => format!("{} < ?", filter.field),
                FilterOp::Lte => format!("{} <= ?", filter.field),
                _ => {
                    return Err(ServiceError::InvalidRequest(format!(
                        "{} supports equality and ordered comparisons in stats queries",
                        filter.field
                    )));
                }
            };
            Ok(Some((clause, vec![HopStatsBindValue::Int(n)])))
        }
        _ => Ok(None),
    }
}

fn build_text_clause(col: &str, filter: &Filter) -> Result<(String, Vec<HopStatsBindValue>)> {
    let mut binds = Vec::new();
    let clause = match filter.op {
        FilterOp::Eq => {
            binds.push(HopStatsBindValue::Text(
                filter.value.as_scalar()?.to_string(),
            ));
            format!("{col} = ?")
        }
        FilterOp::NotEq => {
            binds.push(HopStatsBindValue::Text(
                filter.value.as_scalar()?.to_string(),
            ));
            format!("{col} <> ?")
        }
        FilterOp::Like => {
            binds.push(HopStatsBindValue::Text(
                filter.value.as_scalar()?.to_string(),
            ));
            format!("{col} ILIKE ?")
        }
        FilterOp::NotLike => {
            binds.push(HopStatsBindValue::Text(
                filter.value.as_scalar()?.to_string(),
            ));
            format!("NOT ({col} ILIKE ?)")
        }
        FilterOp::In => {
            let values = filter.value.as_list()?.to_vec();
            if values.is_empty() {
                return Ok(("1=0".into(), Vec::new()));
            }
            binds.push(HopStatsBindValue::TextArray(values));
            format!("{col} = ANY(?)")
        }
        FilterOp::NotIn => {
            let values = filter.value.as_list()?.to_vec();
            if values.is_empty() {
                return Ok(("1=1".into(), Vec::new()));
            }
            binds.push(HopStatsBindValue::TextArray(values));
            format!("{col} <> ALL(?)")
        }
        _ => {
            return Err(ServiceError::InvalidRequest(format!(
                "text filter {col} does not support operator {:?}",
                filter.op
            )));
        }
    };
    Ok((clause, binds))
}

// Rewrite ? placeholders to $N for PostgreSQL.
fn rewrite_placeholders(sql: &str) -> String {
    let mut out = String::with_capacity(sql.len() + 16);
    let mut n = 1usize;
    for ch in sql.chars() {
        if ch == '?' {
            out.push('$');
            out.push_str(&n.to_string());
            n += 1;
        } else {
            out.push(ch);
        }
    }
    out
}

fn bind_param_from_hop(value: HopStatsBindValue) -> BindParam {
    match value {
        HopStatsBindValue::Text(v) => BindParam::Text(v),
        HopStatsBindValue::TextArray(v) => BindParam::TextArray(v),
        HopStatsBindValue::Timestamp(v) => BindParam::timestamptz(v),
        HopStatsBindValue::Int(v) => BindParam::Int(v.into()),
    }
}

// ─── tests ────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{parser::parse, query::build_query_plan};
    use std::sync::Arc;

    fn plan_for(query: &str) -> QueryPlan {
        let config = Arc::new(crate::config::AppConfig::embedded(
            "postgres://localhost/serviceradar".to_string(),
        ));
        let request = crate::query::QueryRequest {
            query: query.to_string(),
            limit: None,
            cursor: None,
            direction: crate::query::QueryDirection::Next,
            mode: None,
        };
        let ast = parse(query).expect("query should parse");
        build_query_plan(config.as_ref(), &request, ast).expect("plan should build")
    }

    #[test]
    fn time_range_predicate_is_half_open() {
        let plan = plan_for(
            "in:mtr_hops time:[2026-01-01T00:00:00Z,2026-01-02T00:00:00Z] sort:hop_number:asc limit:5",
        );
        let (sql, _) = to_sql_and_params(&plan).expect("SQL should translate");
        let lower = sql.to_lowercase();
        assert!(lower.contains("\"mtr_hops\".\"time\" >= $1"), "{sql}");
        assert!(lower.contains("\"mtr_hops\".\"time\" < $2"), "{sql}");
    }

    #[test]
    fn addr_filter_goes_into_where_clause() {
        let plan = plan_for("in:mtr_hops addr:192.0.2.1 limit:10");
        let (sql, params) = to_sql_and_params(&plan).expect("SQL should translate");
        let lower = sql.to_lowercase();
        assert!(lower.contains("\"mtr_hops\".\"addr\""), "{sql}");
        assert!(
            params
                .iter()
                .any(|p| matches!(p, BindParam::Text(v) if v == "192.0.2.1")),
            "addr bind not found: {params:?}"
        );
    }

    #[test]
    fn unsupported_filter_field_is_rejected() {
        let plan = plan_for("in:mtr_hops device_id:some-device limit:10");
        let result = to_sql_and_params(&plan);
        assert!(
            matches!(result, Err(ServiceError::InvalidRequest(_))),
            "device_id filter should be rejected"
        );
    }

    #[test]
    fn stats_by_addr_produces_group_and_json_payload() {
        let plan = plan_for(
            "in:mtr_hops time:last_24h stats:avg(loss_pct) as avg_loss by addr sort:avg_loss:desc limit:50",
        );
        let (sql, _) = to_sql_and_params(&plan).expect("stats SQL should translate");
        let lower = sql.to_lowercase();
        assert!(lower.contains("avg(loss_pct)"), "{sql}");
        assert!(lower.contains("group by addr"), "{sql}");
        assert!(lower.contains("avg_loss"), "{sql}");
        assert!(lower.contains("jsonb_build_object"), "{sql}");
    }

    #[test]
    fn stats_by_asn_is_supported() {
        let plan =
            plan_for("in:mtr_hops time:last_6h stats:avg(avg_us) as avg_latency by asn limit:20");
        let (sql, _) = to_sql_and_params(&plan).expect("stats SQL should translate");
        let lower = sql.to_lowercase();
        assert!(lower.contains("avg(avg_us)"), "{sql}");
        assert!(lower.contains("group by asn"), "{sql}");
    }

    #[test]
    fn unsupported_group_field_is_rejected() {
        let plan = plan_for("in:mtr_hops stats:avg(loss_pct) as v by device_id limit:10");
        let result = to_sql_and_params(&plan);
        assert!(
            matches!(result, Err(ServiceError::InvalidRequest(_))),
            "grouping by device_id should be rejected"
        );
    }

    #[test]
    fn unsupported_agg_column_is_rejected() {
        let plan = plan_for("in:mtr_hops stats:avg(total_hops) as v by addr limit:10");
        let result = to_sql_and_params(&plan);
        assert!(
            matches!(result, Err(ServiceError::InvalidRequest(_))),
            "agg on total_hops should be rejected"
        );
    }

    #[test]
    fn hop_number_sort_asc_uses_asc_tie_break() {
        let plan = plan_for("in:mtr_hops sort:hop_number:asc limit:30");
        let (sql, _) = to_sql_and_params(&plan).expect("SQL should translate");
        let lower = sql.to_lowercase();
        assert!(
            lower.contains("order by \"mtr_hops\".\"hop_number\" asc"),
            "{sql}"
        );
    }

    #[test]
    fn loss_ratio_is_a_ratio_of_sums_not_a_mean_of_ratios() {
        let plan = plan_for(
            "in:mtr_hops time:last_24h stats:loss_ratio(sent, received) as loss by addr limit:20",
        );
        let (sql, _) = to_sql_and_params(&plan).expect("SQL should translate");
        let lower = sql.to_lowercase();

        assert!(lower.contains("sum(sent)"), "{sql}");
        assert!(lower.contains("sum(received)"), "{sql}");
        assert!(
            !lower.contains("avg(loss_pct)"),
            "loss must not be an average of percentages: {sql}"
        );
    }

    #[test]
    fn loss_ratio_yields_null_when_nothing_was_sent() {
        let plan =
            plan_for("in:mtr_hops stats:loss_ratio(sent, received) as loss by addr limit:20");
        let (sql, _) = to_sql_and_params(&plan).expect("SQL should translate");
        let lower = sql.to_lowercase();

        // A group that sent no probes has no measurement, which is a different
        // state from measured zero loss.
        assert!(lower.contains("case when"), "{sql}");
        assert!(lower.contains("else null end"), "{sql}");
    }

    #[test]
    fn wavg_weights_by_the_probe_count() {
        let plan = plan_for("in:mtr_hops stats:wavg(avg_us, received) as latency by addr limit:20");
        let (sql, _) = to_sql_and_params(&plan).expect("SQL should translate");
        let lower = sql.to_lowercase();

        assert!(
            lower.contains("sum(avg_us::numeric * coalesce(received, 0)"),
            "{sql}"
        );
        assert!(lower.contains("sum(coalesce(received, 0))"), "{sql}");
        assert!(
            !lower.contains("avg(avg_us)"),
            "weighted latency must not compile to a plain AVG: {sql}"
        );
    }

    #[test]
    fn two_argument_aggregations_reject_a_single_argument() {
        for query in [
            "in:mtr_hops stats:wavg(avg_us) as latency by addr limit:10",
            "in:mtr_hops stats:loss_ratio(sent) as loss by addr limit:10",
        ] {
            let result = to_sql_and_params(&plan_for(query));
            assert!(
                matches!(result, Err(ServiceError::InvalidRequest(_))),
                "{query} should be rejected"
            );
        }
    }

    #[test]
    fn two_argument_aggregations_reject_unsupported_column_pairings() {
        for query in [
            // hop_number is not a probe counter.
            "in:mtr_hops stats:loss_ratio(hop_number, received) as loss by addr limit:10",
            // A weighted mean of a percentage is still a mean of ratios.
            "in:mtr_hops stats:wavg(loss_pct, received) as loss by addr limit:10",
            // Same column on both sides is not a ratio.
            "in:mtr_hops stats:loss_ratio(sent, sent) as loss by addr limit:10",
        ] {
            let result = to_sql_and_params(&plan_for(query));
            assert!(
                matches!(result, Err(ServiceError::InvalidRequest(_))),
                "{query} should be rejected"
            );
        }
    }

    #[test]
    fn plain_avg_still_compiles_to_avg() {
        // The new aggregates must not redefine the old ones.
        let plan = plan_for("in:mtr_hops stats:avg(loss_pct) as avg_loss by addr limit:20");
        let (sql, _) = to_sql_and_params(&plan).expect("SQL should translate");
        assert!(sql.to_lowercase().contains("avg(loss_pct)"), "{sql}");
    }

    #[test]
    fn time_bucket_dimension_groups_by_bucket_and_column() {
        let plan = plan_for(
            "in:mtr_hops time:last_24h stats:loss_ratio(sent, received) as loss by addr,time:1h limit:200",
        );
        let (sql, _) = to_sql_and_params(&plan).expect("SQL should translate");
        let lower = sql.to_lowercase();

        assert!(lower.contains("extract(epoch from time) / 3600"), "{sql}");
        assert!(lower.contains("group by"), "{sql}");
        assert!(lower.contains("addr"), "{sql}");
        assert!(lower.contains("'bucket'"), "{sql}");
    }

    #[test]
    fn bucketed_limit_keeps_newest_buckets_and_renders_ascending() {
        // The defect this guards is recorded in downsample/sql.rs: truncating on
        // an ascending sort kept the OLDEST buckets, so a long chart silently
        // stopped short of the present.
        let plan = plan_for(
            "in:mtr_hops time:last_30d stats:loss_ratio(sent, received) as loss by addr,time:5m sort:time:desc limit:100",
        );
        let (sql, _) = to_sql_and_params(&plan).expect("SQL should translate");
        let lower = sql.to_lowercase();

        let inner = lower
            .find("order by __bucket desc")
            .expect(&format!("inner truncation must be descending: {sql}"));
        let outer = lower
            .find("order by __bucket asc")
            .expect(&format!("outer render must be ascending: {sql}"));
        assert!(
            inner < outer,
            "descending truncation must happen inside the ascending render: {sql}"
        );
    }

    #[test]
    fn duration_on_a_non_time_dimension_is_rejected() {
        // Refused by the tokenizer, before an entity builder is reached: a colon
        // in the `by` token otherwise means a following clause was swallowed.
        let result = crate::parser::parse(
            "in:mtr_hops stats:loss_ratio(sent, received) as loss by addr:1h limit:10",
        );
        assert!(
            result.is_err(),
            "a duration on a non-time dimension should be rejected"
        );
    }

    #[test]
    fn stats_group_by_still_refuses_a_swallowed_clause() {
        // The guard relaxed for `time:` must keep catching an omitted group field.
        let result = crate::parser::parse("in:mtr_hops stats:count() as n by limit:10");
        assert!(
            result.is_err(),
            "an omitted group-by field must still be refused"
        );
    }

    #[test]
    fn two_argument_aggregation_survives_comma_splitting_alongside_another_agg() {
        // Splitting the projection on every comma would tear
        // `loss_ratio(sent, received)` in half. Multiple aggregations are quoted,
        // which is the existing idiom for a projection containing spaces.
        let plan = plan_for(
            "in:mtr_hops stats:\"loss_ratio(sent, received) as loss, avg(avg_us) as lat by addr\" limit:20",
        );
        let (sql, _) = to_sql_and_params(&plan).expect("SQL should translate");
        let lower = sql.to_lowercase();

        assert!(lower.contains("'loss'"), "{sql}");
        assert!(lower.contains("'lat'"), "{sql}");
        assert!(lower.contains("avg(avg_us)"), "{sql}");
        assert!(lower.contains("sum(sent)"), "{sql}");
    }
}
