//! `in:rum` (also spelled `in:rum_beacons` and `in:rum_beacon`): Boomerang
//! Real User Monitoring beacons (`platform.rum_beacons`).
//!
//! Both CNPG (`query/rum_beacons.rs`) and StarRocks
//! (`query/starrocks/rum_beacons.rs`) share the filter vocabulary, numeric
//! bounds, sort vocabulary, and `stats:` grammar below so queries produce
//! identical schemas and aggregates on either backend.

use super::filters_common::{NumericComparison, NumericKind, NumericValue};
use super::mtr_hops::{StatsOrderKey, resolve_stats_order};
use super::{BindParam, QueryPlan, rewrite_placeholders};
use crate::{
    error::{Result, ServiceError},
    models::RumBeaconRow,
    parser::{Entity, Filter, FilterOp, OrderClause, OrderDirection},
    schema::rum_beacons::dsl::{
        as_org as col_as_org, asn as col_asn, beacon_id as col_beacon_id, browser as col_browser,
        canonical_origin as col_canonical_origin, cdn_cache_status as col_cdn_cache_status,
        cdn_edge_rtt_ms as col_cdn_edge_rtt_ms, cdn_origin_rtt_ms as col_cdn_origin_rtt_ms,
        cdn_pop as col_cdn_pop, cdn_provider as col_cdn_provider, city as col_city,
        client_ip as col_client_ip, client_ip_anonymized as col_client_ip_anonymized,
        cls as col_cls, connect_ms as col_connect_ms, country as col_country,
        created_at as col_created_at, device_type as col_device_type, dns_ms as col_dns_ms,
        dom_ready_ms as col_dom_ready_ms, environment as col_environment, fcp_ms as col_fcp_ms,
        has_error as col_has_error, host as col_host, http_status as col_http_status,
        initiator as col_initiator, inp_ms as col_inp_ms, js_errors as col_js_errors,
        lcp_ms as col_lcp_ms, metric_path as col_metric_path, observed_at as col_observed_at,
        os as col_os, page_group as col_page_group, page_load_ms as col_page_load_ms,
        path as col_path, prefix_tag as col_prefix_tag, rage_clicks as col_rage_clicks,
        referrer as col_referrer, region as col_region, rum_beacons, session_id as col_session_id,
        span_id as col_span_id, tls_ms as col_tls_ms, trace_id as col_trace_id,
        ttfb_ms as col_ttfb_ms, url as col_url, web_property_id as col_web_property_id,
    },
    time::TimeRange,
};
use diesel::PgTextExpressionMethods;
use diesel::pg::Pg;
use diesel::prelude::*;
use diesel::query_builder::{AsQuery, BoxedSelectStatement, FromClause};
use diesel_async::{AsyncPgConnection, RunQueryDsl};

const ENTITY: &str = "rum";

type RumTable = crate::schema::rum_beacons::table;
type RumFromClause = FromClause<RumTable>;
type RumQuery<'a> = BoxedSelectStatement<'a, <RumTable as AsQuery>::SqlType, RumFromClause, Pg>;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum RumTextColumn {
    WebPropertyId,
    BeaconId,
    CanonicalOrigin,
    Environment,
    Url,
    Host,
    Path,
    MetricPath,
    Referrer,
    PageGroup,
    Initiator,
    TraceId,
    SpanId,
    SessionId,
    DeviceType,
    Browser,
    Os,
    CdnProvider,
    CdnCacheStatus,
    CdnPop,
    ClientIp,
    Country,
    Region,
    City,
    AsOrg,
    PrefixTag,
}

impl RumTextColumn {
    pub(super) fn for_field(field: &str) -> Option<Self> {
        Some(match field {
            "web_property_id" => Self::WebPropertyId,
            "beacon_id" => Self::BeaconId,
            "canonical_origin" => Self::CanonicalOrigin,
            "environment" => Self::Environment,
            "url" => Self::Url,
            "host" => Self::Host,
            "path" => Self::Path,
            "metric_path" => Self::MetricPath,
            "referrer" => Self::Referrer,
            "page_group" => Self::PageGroup,
            "initiator" => Self::Initiator,
            "trace_id" => Self::TraceId,
            "span_id" => Self::SpanId,
            "session_id" => Self::SessionId,
            "device_type" => Self::DeviceType,
            "browser" => Self::Browser,
            "os" => Self::Os,
            "cdn_provider" => Self::CdnProvider,
            "cdn_cache_status" => Self::CdnCacheStatus,
            "cdn_pop" => Self::CdnPop,
            "client_ip" => Self::ClientIp,
            "country" => Self::Country,
            "region" => Self::Region,
            "city" => Self::City,
            "as_org" => Self::AsOrg,
            "prefix_tag" => Self::PrefixTag,
            _ => return None,
        })
    }

    pub(super) fn name(self) -> &'static str {
        match self {
            Self::WebPropertyId => "web_property_id",
            Self::BeaconId => "beacon_id",
            Self::CanonicalOrigin => "canonical_origin",
            Self::Environment => "environment",
            Self::Url => "url",
            Self::Host => "host",
            Self::Path => "path",
            Self::MetricPath => "metric_path",
            Self::Referrer => "referrer",
            Self::PageGroup => "page_group",
            Self::Initiator => "initiator",
            Self::TraceId => "trace_id",
            Self::SpanId => "span_id",
            Self::SessionId => "session_id",
            Self::DeviceType => "device_type",
            Self::Browser => "browser",
            Self::Os => "os",
            Self::CdnProvider => "cdn_provider",
            Self::CdnCacheStatus => "cdn_cache_status",
            Self::CdnPop => "cdn_pop",
            Self::ClientIp => "client_ip",
            Self::Country => "country",
            Self::Region => "region",
            Self::City => "city",
            Self::AsOrg => "as_org",
            Self::PrefixTag => "prefix_tag",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum RumBoolColumn {
    HasError,
    ClientIpAnonymized,
}

impl RumBoolColumn {
    pub(super) fn for_field(field: &str) -> Option<Self> {
        Some(match field {
            "has_error" => Self::HasError,
            "client_ip_anonymized" => Self::ClientIpAnonymized,
            _ => return None,
        })
    }

    pub(super) fn name(self) -> &'static str {
        match self {
            Self::HasError => "has_error",
            Self::ClientIpAnonymized => "client_ip_anonymized",
        }
    }
}

pub(super) const RUM_NUMERIC_FIELDS: &[(&str, NumericKind)] = &[
    ("lcp_ms", NumericKind::Float8),
    ("inp_ms", NumericKind::Float8),
    ("cls", NumericKind::Float8),
    ("fcp_ms", NumericKind::Float8),
    ("ttfb_ms", NumericKind::Float8),
    ("page_load_ms", NumericKind::Float8),
    ("dns_ms", NumericKind::Float8),
    ("connect_ms", NumericKind::Float8),
    ("tls_ms", NumericKind::Float8),
    ("dom_ready_ms", NumericKind::Float8),
    ("cdn_edge_rtt_ms", NumericKind::Float8),
    ("cdn_origin_rtt_ms", NumericKind::Float8),
    ("rage_clicks", NumericKind::Int4),
    ("js_errors", NumericKind::Int4),
    ("http_status", NumericKind::Int4),
    ("asn", NumericKind::Int4),
];

pub(super) fn numeric_comparison(
    filter: &Filter,
) -> Result<Option<(&'static str, NumericComparison)>> {
    RUM_NUMERIC_FIELDS
        .iter()
        .find(|(name, _)| *name == filter.field)
        .map(|&(name, kind)| Ok((name, NumericComparison::parse(filter, kind)?)))
        .transpose()
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum RumSortColumn {
    ObservedAt,
    CreatedAt,
    LcpMs,
    InpMs,
    Cls,
    FcpMs,
    TtfbMs,
    PageLoadMs,
    HttpStatus,
    JsErrors,
    RageClicks,
    CdnEdgeRttMs,
    CdnOriginRttMs,
}

impl RumSortColumn {
    pub(super) fn for_field(field: &str) -> Option<Self> {
        Some(match field {
            "observed_at" | "time" | "timestamp" => Self::ObservedAt,
            "created_at" => Self::CreatedAt,
            "lcp_ms" => Self::LcpMs,
            "inp_ms" => Self::InpMs,
            "cls" => Self::Cls,
            "fcp_ms" => Self::FcpMs,
            "ttfb_ms" => Self::TtfbMs,
            "page_load_ms" => Self::PageLoadMs,
            "http_status" => Self::HttpStatus,
            "js_errors" => Self::JsErrors,
            "rage_clicks" => Self::RageClicks,
            "cdn_edge_rtt_ms" => Self::CdnEdgeRttMs,
            "cdn_origin_rtt_ms" => Self::CdnOriginRttMs,
            _ => return None,
        })
    }

    pub(super) fn name(self) -> &'static str {
        match self {
            Self::ObservedAt => "observed_at",
            Self::CreatedAt => "created_at",
            Self::LcpMs => "lcp_ms",
            Self::InpMs => "inp_ms",
            Self::Cls => "cls",
            Self::FcpMs => "fcp_ms",
            Self::TtfbMs => "ttfb_ms",
            Self::PageLoadMs => "page_load_ms",
            Self::HttpStatus => "http_status",
            Self::JsErrors => "js_errors",
            Self::RageClicks => "rage_clicks",
            Self::CdnEdgeRttMs => "cdn_edge_rtt_ms",
            Self::CdnOriginRttMs => "cdn_origin_rtt_ms",
        }
    }
}

pub(super) fn unsupported_filter(field: &str) -> ServiceError {
    ServiceError::InvalidRequest(format!("unsupported filter field for {ENTITY}: '{field}'"))
}

pub(super) fn parse_bool(raw: &str) -> Result<bool> {
    super::mtr_traces::parse_bool(raw)
}

pub(super) async fn execute(
    conn: &mut AsyncPgConnection,
    plan: &QueryPlan,
) -> Result<Vec<serde_json::Value>> {
    ensure_entity(plan)?;
    refuse_unsupported_clauses(plan)?;

    if let Some(stats) = &plan.stats {
        let sql = build_stats_sql(plan, stats.as_raw())?;
        return execute_stats(conn, &sql).await;
    }

    let query = build_query(plan)?;
    let rows: Vec<RumBeaconRow> = query
        .select(RumBeaconRow::as_select())
        .limit(plan.limit)
        .offset(plan.offset)
        .load::<RumBeaconRow>(conn)
        .await
        .map_err(|err| ServiceError::Internal(err.into()))?;

    Ok(rows.into_iter().map(RumBeaconRow::into_json).collect())
}

pub(super) fn to_sql_and_params(plan: &QueryPlan) -> Result<(String, Vec<BindParam>)> {
    ensure_entity(plan)?;
    refuse_unsupported_clauses(plan)?;

    if let Some(stats) = &plan.stats {
        let sql = build_stats_sql(plan, stats.as_raw())?;
        let params = sql.binds.into_iter().map(bind_param_from_rum).collect();
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
    Ok((sql, params))
}

fn ensure_entity(plan: &QueryPlan) -> Result<()> {
    match plan.entity {
        Entity::RumBeacons => Ok(()),
        _ => Err(ServiceError::InvalidRequest(format!(
            "entity not supported by {ENTITY} query"
        ))),
    }
}

pub(super) fn refuse_unsupported_clauses(plan: &QueryPlan) -> Result<()> {
    if let Some(kind) = plan
        .rollup_stats
        .as_deref()
        .map(str::trim)
        .filter(|kind| !kind.is_empty())
    {
        return Err(ServiceError::InvalidRequest(format!(
            "rollup_stats:{kind} is not supported for {ENTITY}"
        )));
    }

    if plan.downsample.is_some() {
        return Err(ServiceError::InvalidRequest(format!(
            "bucket: is not supported for {ENTITY}; use stats:\"... by time:<duration>\""
        )));
    }

    if plan.other {
        return Err(ServiceError::InvalidRequest(
            "other:true is currently supported only for flow or timeseries stats".into(),
        ));
    }

    Ok(())
}

fn build_query(plan: &QueryPlan) -> Result<RumQuery<'static>> {
    let mut query = rum_beacons.into_boxed::<Pg>();

    if let Some(TimeRange { start, end }) = &plan.time_range {
        query = query.filter(col_observed_at.ge(*start).and(col_observed_at.lt(*end)));
    }

    for filter in &plan.filters {
        query = apply_filter(query, filter)?;
    }

    apply_ordering(query, &plan.order)
}

fn apply_filter<'a>(mut query: RumQuery<'a>, filter: &Filter) -> Result<RumQuery<'a>> {
    let field = filter.field.as_str();
    if let Some(bool_col) = RumBoolColumn::for_field(field) {
        let value = parse_bool(filter.value.as_scalar()?)?;
        return match (bool_col, &filter.op) {
            (RumBoolColumn::HasError, FilterOp::Eq) => Ok(query.filter(col_has_error.eq(value))),
            (RumBoolColumn::HasError, FilterOp::NotEq) => Ok(query.filter(col_has_error.ne(value))),
            (RumBoolColumn::ClientIpAnonymized, FilterOp::Eq) => {
                Ok(query.filter(col_client_ip_anonymized.eq(value)))
            }
            (RumBoolColumn::ClientIpAnonymized, FilterOp::NotEq) => {
                Ok(query.filter(col_client_ip_anonymized.ne(value)))
            }
            _ => Err(ServiceError::InvalidRequest(format!(
                "{field} only supports equality comparisons"
            ))),
        };
    }

    if let Some(col) = RumTextColumn::for_field(field) {
        query = match col {
            RumTextColumn::WebPropertyId => apply_text_filter!(query, filter, col_web_property_id)?,
            RumTextColumn::BeaconId => apply_text_filter!(query, filter, col_beacon_id)?,
            RumTextColumn::CanonicalOrigin => {
                apply_text_filter!(query, filter, col_canonical_origin)?
            }
            RumTextColumn::Environment => apply_text_filter!(query, filter, col_environment)?,
            RumTextColumn::Url => apply_text_filter!(query, filter, col_url)?,
            RumTextColumn::Host => apply_text_filter!(query, filter, col_host)?,
            RumTextColumn::Path => apply_text_filter!(query, filter, col_path)?,
            RumTextColumn::MetricPath => apply_text_filter!(query, filter, col_metric_path)?,
            RumTextColumn::Referrer => apply_text_filter!(query, filter, col_referrer)?,
            RumTextColumn::PageGroup => apply_text_filter!(query, filter, col_page_group)?,
            RumTextColumn::Initiator => apply_text_filter!(query, filter, col_initiator)?,
            RumTextColumn::TraceId => apply_text_filter!(query, filter, col_trace_id)?,
            RumTextColumn::SpanId => apply_text_filter!(query, filter, col_span_id)?,
            RumTextColumn::SessionId => apply_text_filter!(query, filter, col_session_id)?,
            RumTextColumn::DeviceType => apply_text_filter!(query, filter, col_device_type)?,
            RumTextColumn::Browser => apply_text_filter!(query, filter, col_browser)?,
            RumTextColumn::Os => apply_text_filter!(query, filter, col_os)?,
            RumTextColumn::CdnProvider => apply_text_filter!(query, filter, col_cdn_provider)?,
            RumTextColumn::CdnCacheStatus => {
                apply_text_filter!(query, filter, col_cdn_cache_status)?
            }
            RumTextColumn::CdnPop => apply_text_filter!(query, filter, col_cdn_pop)?,
            RumTextColumn::ClientIp => apply_text_filter!(query, filter, col_client_ip)?,
            RumTextColumn::Country => apply_text_filter!(query, filter, col_country)?,
            RumTextColumn::Region => apply_text_filter!(query, filter, col_region)?,
            RumTextColumn::City => apply_text_filter!(query, filter, col_city)?,
            RumTextColumn::AsOrg => apply_text_filter!(query, filter, col_as_org)?,
            RumTextColumn::PrefixTag => apply_text_filter!(query, filter, col_prefix_tag)?,
        };
        return Ok(query);
    }

    let Some((col_name, comparison)) = numeric_comparison(filter)? else {
        return Err(unsupported_filter(field));
    };

    apply_rum_numeric_filter(query, col_name, filter, comparison.value)
}

fn apply_rum_numeric_filter<'a>(
    query: RumQuery<'a>,
    col_name: &str,
    filter: &Filter,
    value: NumericValue,
) -> Result<RumQuery<'a>> {
    use NumericValue::{Float8, Int4};

    match (col_name, value) {
        ("lcp_ms", Float8(v)) => apply_ordered_filter!(query, filter, col_lcp_ms, v),
        ("inp_ms", Float8(v)) => apply_ordered_filter!(query, filter, col_inp_ms, v),
        ("cls", Float8(v)) => apply_ordered_filter!(query, filter, col_cls, v),
        ("fcp_ms", Float8(v)) => apply_ordered_filter!(query, filter, col_fcp_ms, v),
        ("ttfb_ms", Float8(v)) => apply_ordered_filter!(query, filter, col_ttfb_ms, v),
        ("page_load_ms", Float8(v)) => apply_ordered_filter!(query, filter, col_page_load_ms, v),
        ("dns_ms", Float8(v)) => apply_ordered_filter!(query, filter, col_dns_ms, v),
        ("connect_ms", Float8(v)) => apply_ordered_filter!(query, filter, col_connect_ms, v),
        ("tls_ms", Float8(v)) => apply_ordered_filter!(query, filter, col_tls_ms, v),
        ("dom_ready_ms", Float8(v)) => apply_ordered_filter!(query, filter, col_dom_ready_ms, v),
        ("cdn_edge_rtt_ms", Float8(v)) => {
            apply_ordered_filter!(query, filter, col_cdn_edge_rtt_ms, v)
        }
        ("cdn_origin_rtt_ms", Float8(v)) => {
            apply_ordered_filter!(query, filter, col_cdn_origin_rtt_ms, v)
        }
        ("rage_clicks", Int4(v)) => apply_ordered_filter!(query, filter, col_rage_clicks, v),
        ("js_errors", Int4(v)) => apply_ordered_filter!(query, filter, col_js_errors, v),
        ("http_status", Int4(v)) => apply_ordered_filter!(query, filter, col_http_status, v),
        ("asn", Int4(v)) => apply_ordered_filter!(query, filter, col_asn, v),
        (other, v) => Err(ServiceError::Internal(anyhow::anyhow!(
            "RUM_NUMERIC_FIELDS maps '{other}' to {v:?}, which has no column binding"
        ))),
    }
}

fn collect_filter_params(params: &mut Vec<BindParam>, filter: &Filter) -> Result<()> {
    let field = filter.field.as_str();
    if RumBoolColumn::for_field(field).is_some() {
        params.push(BindParam::Bool(parse_bool(filter.value.as_scalar()?)?));
        return Ok(());
    }
    if RumTextColumn::for_field(field).is_some() {
        match filter.op {
            FilterOp::Eq | FilterOp::NotEq | FilterOp::Like | FilterOp::NotLike => {
                params.push(BindParam::Text(filter.value.as_scalar()?.to_string()));
                return Ok(());
            }
            FilterOp::In | FilterOp::NotIn => {
                let values = filter.value.as_list()?.to_vec();
                if !values.is_empty() {
                    params.push(BindParam::TextArray(values));
                }
                return Ok(());
            }
            _ => {
                return Err(ServiceError::InvalidRequest(format!(
                    "unsupported operator for text filter: {:?}",
                    filter.op
                )));
            }
        }
    }
    match numeric_comparison(filter)? {
        Some((_, comparison)) => {
            params.push(comparison.value.bind_param());
            Ok(())
        }
        None => Err(unsupported_filter(field)),
    }
}

fn apply_ordering<'a>(mut query: RumQuery<'a>, order: &[OrderClause]) -> Result<RumQuery<'a>> {
    let mut recognized = 0usize;
    for clause in order {
        let Some(col) = RumSortColumn::for_field(clause.field.as_str()) else {
            continue;
        };
        query = apply_order_step(query, col, clause.direction, recognized == 0);
        recognized += 1;
    }

    if recognized == 0 {
        return Ok(query
            .order(col_observed_at.desc())
            .then_order_by(col_beacon_id.desc()));
    }

    let tie = order
        .iter()
        .find(|c| RumSortColumn::for_field(&c.field) == Some(RumSortColumn::ObservedAt))
        .map(|c| c.direction)
        .unwrap_or(order[0].direction);

    if !order
        .iter()
        .any(|c| RumSortColumn::for_field(&c.field) == Some(RumSortColumn::ObservedAt))
    {
        query = apply_order_step(query, RumSortColumn::ObservedAt, tie, false);
    }

    Ok(match tie {
        OrderDirection::Asc => query.then_order_by(col_beacon_id.asc()),
        OrderDirection::Desc => query.then_order_by(col_beacon_id.desc()),
    })
}

fn apply_order_step<'a>(
    query: RumQuery<'a>,
    col: RumSortColumn,
    dir: OrderDirection,
    primary: bool,
) -> RumQuery<'a> {
    macro_rules! order_col {
        ($c:expr) => {
            match (primary, dir) {
                (true, OrderDirection::Asc) => query.order($c.asc()),
                (true, OrderDirection::Desc) => query.order($c.desc()),
                (false, OrderDirection::Asc) => query.then_order_by($c.asc()),
                (false, OrderDirection::Desc) => query.then_order_by($c.desc()),
            }
        };
    }

    match col {
        RumSortColumn::ObservedAt => order_col!(col_observed_at),
        RumSortColumn::CreatedAt => order_col!(col_created_at),
        RumSortColumn::LcpMs => order_col!(col_lcp_ms),
        RumSortColumn::InpMs => order_col!(col_inp_ms),
        RumSortColumn::Cls => order_col!(col_cls),
        RumSortColumn::FcpMs => order_col!(col_fcp_ms),
        RumSortColumn::TtfbMs => order_col!(col_ttfb_ms),
        RumSortColumn::PageLoadMs => order_col!(col_page_load_ms),
        RumSortColumn::HttpStatus => order_col!(col_http_status),
        RumSortColumn::JsErrors => order_col!(col_js_errors),
        RumSortColumn::RageClicks => order_col!(col_rage_clicks),
        RumSortColumn::CdnEdgeRttMs => order_col!(col_cdn_edge_rtt_ms),
        RumSortColumn::CdnOriginRttMs => order_col!(col_cdn_origin_rtt_ms),
    }
}

// ─── stats ───────────────────────────────────────────────────────────────────

pub(crate) const RUM_AGGREGATABLE_COLUMNS: &[(&str, &str)] = &[
    ("lcp_ms", "lcp_ms"),
    ("inp_ms", "inp_ms"),
    ("cls", "cls"),
    ("fcp_ms", "fcp_ms"),
    ("ttfb_ms", "ttfb_ms"),
    ("page_load_ms", "page_load_ms"),
    ("dns_ms", "dns_ms"),
    ("connect_ms", "connect_ms"),
    ("tls_ms", "tls_ms"),
    ("dom_ready_ms", "dom_ready_ms"),
    ("cdn_edge_rtt_ms", "cdn_edge_rtt_ms"),
    ("cdn_origin_rtt_ms", "cdn_origin_rtt_ms"),
    ("rage_clicks", "rage_clicks"),
    ("js_errors", "js_errors"),
    ("http_status", "http_status"),
    ("has_error", "has_error::int"),
];

pub(crate) const RUM_GROUP_BY_FIELDS: &[&str] = &[
    "web_property_id",
    "canonical_origin",
    "environment",
    "host",
    "path",
    "metric_path",
    "page_group",
    "initiator",
    "device_type",
    "browser",
    "os",
    "cdn_provider",
    "cdn_cache_status",
    "cdn_pop",
    "country",
    "region",
    "city",
    "asn",
    "as_org",
    "prefix_tag",
    "has_error",
];

const RUM_BUCKET_ALIAS: &str = "bucket";

#[derive(Debug, Clone)]
struct RumStatsSql {
    sql: String,
    binds: Vec<RumStatsBind>,
}

#[derive(Debug, Clone)]
enum RumStatsBind {
    Text(String),
    Timestamp(chrono::DateTime<chrono::Utc>),
    Bool(bool),
    Numeric(NumericValue),
}

#[derive(Debug, Clone)]
struct RumAgg {
    expr: String,
    alias: String,
}

#[derive(Debug, Clone)]
pub(crate) enum RumGroupDim {
    Column(&'static str),
    TimeBucket { seconds: i64 },
}

impl RumGroupDim {
    fn expr(&self) -> String {
        match self {
            RumGroupDim::Column(col) => (*col).to_string(),
            RumGroupDim::TimeBucket { seconds } => {
                format!(
                    "to_timestamp(floor(extract(epoch from observed_at) / {seconds}) * {seconds})"
                )
            }
        }
    }

    pub(crate) fn alias(&self) -> &str {
        match self {
            RumGroupDim::Column(col) => col,
            RumGroupDim::TimeBucket { .. } => RUM_BUCKET_ALIAS,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum RumAggKind {
    CountRows,
    Column {
        function: &'static str,
        column: &'static str,
    },
    Percentile75 {
        column: &'static str,
    },
}

#[derive(Debug, Clone)]
pub(crate) struct ParsedRumAgg {
    pub(crate) kind: RumAggKind,
    pub(crate) alias: String,
}

pub(crate) fn pg_rum_column(column: &str) -> &'static str {
    RUM_AGGREGATABLE_COLUMNS
        .iter()
        .find(|(name, _)| *name == column)
        .map(|(_, sql)| *sql)
        .expect("RUM aggregation columns are validated against RUM_AGGREGATABLE_COLUMNS")
}

impl RumAgg {
    fn postgres(agg: &ParsedRumAgg) -> Self {
        let expr = match agg.kind {
            RumAggKind::CountRows => "COUNT(*)".to_string(),
            RumAggKind::Column { function, column } => {
                format!("{function}({})", pg_rum_column(column))
            }
            RumAggKind::Percentile75 { column } => {
                format!(
                    "percentile_cont(0.75) WITHIN GROUP (ORDER BY {})",
                    pg_rum_column(column)
                )
            }
        };
        Self {
            expr,
            alias: agg.alias.clone(),
        }
    }
}

pub(crate) fn parse_rum_stats(raw: &str) -> Result<(Vec<ParsedRumAgg>, Vec<RumGroupDim>)> {
    let lower = raw.to_ascii_lowercase();
    if let Some(pos) = lower.find(" by ") {
        let agg_part = raw[..pos].trim();
        let group_part = raw[pos + 4..].trim();
        let dims = parse_rum_group_dims(group_part)?;
        let aggs = parse_rum_aggs(agg_part)?;
        Ok((aggs, dims))
    } else {
        let aggs = parse_rum_aggs(raw.trim())?;
        Ok((aggs, Vec::new()))
    }
}

fn parse_rum_group_dims(part: &str) -> Result<Vec<RumGroupDim>> {
    let mut dims = Vec::new();
    for raw in part.split(',') {
        let token = raw.trim();
        if token.is_empty() {
            continue;
        }
        if let Some((key, value)) = token.split_once(':') {
            if !key.trim().eq_ignore_ascii_case("time") {
                return Err(ServiceError::InvalidRequest(format!(
                    "only the 'time' group dimension takes a duration; got '{token}'"
                )));
            }
            if dims
                .iter()
                .any(|d| matches!(d, RumGroupDim::TimeBucket { .. }))
            {
                return Err(ServiceError::InvalidRequest(
                    "only one time bucket dimension is supported".into(),
                ));
            }
            let seconds = crate::parser::parse_group_bucket_seconds(value.trim())?;
            dims.push(RumGroupDim::TimeBucket { seconds });
        } else {
            let lower = token.to_ascii_lowercase();
            let field = RUM_GROUP_BY_FIELDS
                .iter()
                .find(|&&f| f == lower.as_str())
                .copied()
                .ok_or_else(|| {
                    ServiceError::InvalidRequest(format!(
                        "unsupported group-by field '{token}' for rum stats; supported: {}",
                        RUM_GROUP_BY_FIELDS.join(", ")
                    ))
                })?;
            dims.push(RumGroupDim::Column(field));
        }
    }
    if dims.is_empty() {
        return Err(ServiceError::InvalidRequest(
            "rum stats 'by' clause requires at least one group dimension".into(),
        ));
    }
    Ok(dims)
}

fn parse_rum_aggs(part: &str) -> Result<Vec<ParsedRumAgg>> {
    let mut result = Vec::new();
    for expr in crate::parser::split_top_level_commas(part) {
        let expr = expr.trim();
        if expr.is_empty() {
            continue;
        }
        result.push(parse_rum_agg(expr)?);
    }
    if result.is_empty() {
        return Err(ServiceError::InvalidRequest(
            "rum stats requires at least one aggregation expression".into(),
        ));
    }
    Ok(result)
}

fn parse_rum_agg(expr: &str) -> Result<ParsedRumAgg> {
    let lower = expr.to_ascii_lowercase();
    let (call, alias) = match lower.find(" as ") {
        Some(pos) => (expr[..pos].trim(), expr[pos + 4..].trim()),
        None => (expr, ""),
    };
    let open = call.find('(').ok_or_else(|| {
        ServiceError::InvalidRequest(format!("expected aggregation like count(), got '{expr}'"))
    })?;
    let close = call.rfind(')').ok_or_else(|| {
        ServiceError::InvalidRequest(format!("unmatched parenthesis in '{expr}'"))
    })?;
    let func = call[..open].trim().to_ascii_lowercase();
    let arg = call[open + 1..close].trim();

    let (kind, default_alias) = match (func.as_str(), arg.is_empty()) {
        ("count", true) => (RumAggKind::CountRows, "count".to_string()),
        ("count", false) => {
            let column = validate_rum_agg_column(arg)?;
            (
                RumAggKind::Column {
                    function: "COUNT",
                    column,
                },
                format!("count_{arg}"),
            )
        }
        ("sum" | "avg" | "min" | "max", false) => {
            let column = validate_rum_agg_column(arg)?;
            let function = match func.as_str() {
                "sum" => "SUM",
                "avg" => "AVG",
                "min" => "MIN",
                _ => "MAX",
            };
            (
                RumAggKind::Column { function, column },
                format!("{func}_{arg}"),
            )
        }
        ("p75", false) => {
            let column = validate_rum_agg_column(arg)?;
            (RumAggKind::Percentile75 { column }, format!("p75_{arg}"))
        }
        _ => {
            return Err(ServiceError::InvalidRequest(format!(
                "unsupported rum aggregation '{expr}'"
            )));
        }
    };

    let clean_alias = if alias.is_empty() {
        default_alias
    } else {
        sanitize_alias(alias)?
    };

    Ok(ParsedRumAgg {
        kind,
        alias: clean_alias,
    })
}

fn validate_rum_agg_column(col: &str) -> Result<&'static str> {
    let lower = col.to_ascii_lowercase();
    RUM_AGGREGATABLE_COLUMNS
        .iter()
        .find(|(name, _)| *name == lower.as_str())
        .map(|(name, _)| *name)
        .ok_or_else(|| {
            ServiceError::InvalidRequest(format!(
                "unsupported column '{col}' for rum stats; supported: {}",
                RUM_AGGREGATABLE_COLUMNS
                    .iter()
                    .map(|(name, _)| *name)
                    .collect::<Vec<_>>()
                    .join(", ")
            ))
        })
}

fn sanitize_alias(raw: &str) -> Result<String> {
    let clean: String = raw
        .chars()
        .filter(|c| c.is_alphanumeric() || *c == '_')
        .collect();
    if clean.is_empty() || clean.starts_with(|c: char| c.is_ascii_digit()) {
        return Err(ServiceError::InvalidRequest(format!(
            "invalid alias '{raw}'"
        )));
    }
    Ok(clean)
}

fn build_stats_sql(plan: &QueryPlan, raw: &str) -> Result<RumStatsSql> {
    let (parsed, dims) = parse_rum_stats(raw)?;
    let aggs: Vec<RumAgg> = parsed.iter().map(RumAgg::postgres).collect();

    let mut clauses = Vec::new();
    let mut binds = Vec::new();

    if let Some(TimeRange { start, end }) = &plan.time_range {
        clauses.push("observed_at >= ?".into());
        binds.push(RumStatsBind::Timestamp(*start));
        clauses.push("observed_at < ?".into());
        binds.push(RumStatsBind::Timestamp(*end));
    }

    for filter in &plan.filters {
        let (clause, mut filter_binds) = build_rum_stats_filter(filter)?;
        clauses.push(clause);
        binds.append(&mut filter_binds);
    }

    let json_kv: Vec<String> = aggs
        .iter()
        .flat_map(|agg| [format!("'{}'", agg.alias), agg.expr.clone()])
        .chain(
            dims.iter()
                .flat_map(|dim| [format!("'{}'", dim.alias()), dim.expr()]),
        )
        .collect();

    let payload = format!("jsonb_build_object({})", json_kv.join(", "));
    let group_exprs: Vec<String> = dims.iter().map(RumGroupDim::expr).collect();

    let bucket = dims.iter().find_map(|dim| match dim {
        RumGroupDim::TimeBucket { .. } => Some(dim.expr()),
        RumGroupDim::Column(_) => None,
    });

    let mut body = format!("SELECT {payload} AS payload");
    if let Some(b) = &bucket {
        body.push_str(&format!(", {b} AS __bucket"));
    }
    body.push_str("\nFROM rum_beacons");
    if !clauses.is_empty() {
        body.push_str("\nWHERE ");
        body.push_str(&clauses.join(" AND "));
    }
    if !group_exprs.is_empty() {
        body.push_str(&format!("\nGROUP BY {}", group_exprs.join(", ")));
    }

    let sql = match &bucket {
        Some(_) => {
            body.push_str("\nORDER BY __bucket DESC");
            body.push_str(&format!("\nLIMIT {} OFFSET {}", plan.limit, plan.offset));
            format!("SELECT payload\nFROM (\n{body}\n) AS bucketed\nORDER BY __bucket ASC")
        }
        None => {
            if !dims.is_empty() {
                body.push_str(&build_stats_order_clause(plan, &aggs));
            }
            body.push_str(&format!("\nLIMIT {} OFFSET {}", plan.limit, plan.offset));
            body
        }
    };

    Ok(RumStatsSql { sql, binds })
}

fn build_stats_order_clause(plan: &QueryPlan, aggs: &[RumAgg]) -> String {
    let aliases: Vec<&str> = aggs.iter().map(|agg| agg.alias.as_str()).collect();
    let parts: Vec<String> = resolve_stats_order(&plan.order, &aliases, RUM_GROUP_BY_FIELDS)
        .into_iter()
        .map(|(key, direction)| {
            let expr = match key {
                StatsOrderKey::Agg(index) => aggs[index].expr.as_str(),
                StatsOrderKey::Group(field) => field,
            };
            let dir = match direction {
                OrderDirection::Asc => "ASC",
                OrderDirection::Desc => "DESC",
            };
            format!("{expr} {dir}")
        })
        .collect();

    if parts.is_empty() {
        String::new()
    } else {
        format!("\nORDER BY {}", parts.join(", "))
    }
}

fn build_rum_stats_filter(filter: &Filter) -> Result<(String, Vec<RumStatsBind>)> {
    let field = filter.field.as_str();
    if let Some(bool_col) = RumBoolColumn::for_field(field) {
        let value = parse_bool(filter.value.as_scalar()?)?;
        let op = match filter.op {
            FilterOp::Eq => "=",
            FilterOp::NotEq => "<>",
            _ => {
                return Err(ServiceError::InvalidRequest(format!(
                    "{field} only supports equality comparisons"
                )));
            }
        };
        return Ok((
            format!("{} {op} ?", bool_col.name()),
            vec![RumStatsBind::Bool(value)],
        ));
    }

    if let Some(col) = RumTextColumn::for_field(field) {
        let value = filter.value.as_scalar()?.to_string();
        let op = match filter.op {
            FilterOp::Eq => "=",
            FilterOp::NotEq => "<>",
            FilterOp::Like => "ILIKE",
            FilterOp::NotLike => "NOT ILIKE",
            _ => {
                return Err(ServiceError::InvalidRequest(format!(
                    "unsupported operator for '{field}' in rum stats"
                )));
            }
        };
        return Ok((
            format!("{} {op} ?", col.name()),
            vec![RumStatsBind::Text(value)],
        ));
    }

    match numeric_comparison(filter)? {
        Some((col, comparison)) => Ok((
            format!("{col} {} ?", comparison.op_sql),
            vec![RumStatsBind::Numeric(comparison.value)],
        )),
        None => Err(unsupported_filter(field)),
    }
}

fn bind_param_from_rum(bind: RumStatsBind) -> BindParam {
    match bind {
        RumStatsBind::Text(v) => BindParam::Text(v),
        RumStatsBind::Timestamp(v) => BindParam::timestamptz(v),
        RumStatsBind::Bool(v) => BindParam::Bool(v),
        RumStatsBind::Numeric(v) => v.bind_param(),
    }
}

async fn execute_stats(
    conn: &mut AsyncPgConnection,
    sql: &RumStatsSql,
) -> Result<Vec<serde_json::Value>> {
    use diesel::sql_query;
    use diesel::sql_types::{Bool, Text, Timestamptz};

    let mut q = sql_query(rewrite_placeholders(&sql.sql)).into_boxed::<Pg>();

    for bind in &sql.binds {
        q = match bind {
            RumStatsBind::Text(v) => q.bind::<Text, _>(v.clone()),
            RumStatsBind::Timestamp(v) => q.bind::<Timestamptz, _>(*v),
            RumStatsBind::Bool(v) => q.bind::<Bool, _>(*v),
            RumStatsBind::Numeric(v) => v.bind_sql_query(q),
        };
    }

    #[derive(Debug, diesel::QueryableByName)]
    #[diesel(check_for_backend(diesel::pg::Pg))]
    struct RumStatsPayload {
        #[diesel(sql_type = diesel::sql_types::Nullable<diesel::sql_types::Jsonb>)]
        payload: Option<crate::jsonb::DbJson>,
    }

    let rows: Vec<RumStatsPayload> = q
        .load::<RumStatsPayload>(conn)
        .await
        .map_err(|err| ServiceError::Internal(err.into()))?;

    Ok(rows
        .into_iter()
        .filter_map(|row| row.payload.map(|p| p.0))
        .collect())
}

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
            permitted_signals: None,
        };
        let ast = parse(query).expect("query should parse");
        build_query_plan(config.as_ref(), &request, ast).expect("query plan should build")
    }

    #[test]
    fn rum_entity_aliases_compile_rows_and_stats() {
        for spelling in ["rum", "rum_beacons", "rum_beacon"] {
            let row_plan = plan_for(&format!(
                "in:{spelling} web_property_id:01JWEBPROP0000000000000001 has_error:true lcp_ms:>1500 sort:observed_at:desc limit:25"
            ));
            let (sql, params) = to_sql_and_params(&row_plan).expect("row query compiles");
            assert!(sql.to_lowercase().contains("from \"rum_beacons\""), "{sql}");
            assert!(!params.is_empty());

            let stats_plan = plan_for(&format!(
                "in:{spelling} time:last_24h stats:\"count() as beacons, avg(lcp_ms) as avg_lcp by metric_path\" limit:10"
            ));
            let (stats_sql, _) = to_sql_and_params(&stats_plan).expect("stats query compiles");
            assert!(
                stats_sql.to_lowercase().contains("jsonb_build_object"),
                "{stats_sql}"
            );
        }
    }

    #[test]
    fn rum_validates_telemetry_trace_and_span_ids() {
        let config = Arc::new(crate::config::AppConfig::embedded(
            "postgres://localhost/serviceradar".to_string(),
        ));
        let bad_req = crate::query::QueryRequest {
            query: "in:rum trace_id:not-hex".to_string(),
            limit: None,
            cursor: None,
            direction: crate::query::QueryDirection::Next,
            mode: None,
            permitted_signals: None,
        };
        assert!(
            build_query_plan(config.as_ref(), &bad_req, parse(&bad_req.query).unwrap()).is_err()
        );
    }

    #[test]
    fn rum_compiles_p75_stats_for_cwv_and_cdn_breakdowns() {
        let summary = plan_for(
            "in:rum time:last_24h stats:\"count() as beacons, p75(lcp_ms) as p75_lcp_ms, p75(inp_ms) as p75_inp_ms, p75(cls) as p75_cls, p75(fcp_ms) as p75_fcp_ms, p75(ttfb_ms) as p75_ttfb_ms, sum(has_error) as error_beacons\" limit:1",
        );
        let (summary_sql, _) = to_sql_and_params(&summary).expect("p75 summary compiles");
        assert!(
            summary_sql.contains("percentile_cont(0.75) WITHIN GROUP (ORDER BY lcp_ms)"),
            "{summary_sql}"
        );
        assert!(
            summary_sql.contains("percentile_cont(0.75) WITHIN GROUP (ORDER BY inp_ms)"),
            "{summary_sql}"
        );
        assert!(summary_sql.contains("SUM(has_error::int)"), "{summary_sql}");

        let grouped = plan_for(
            "in:rum time:last_24h stats:\"count() as beacons, p75(cdn_edge_rtt_ms) as p75_edge_rtt_ms, p75(cdn_origin_rtt_ms) as p75_origin_rtt_ms by prefix_tag, asn, as_org\" sort:beacons:desc limit:100",
        );
        let (grouped_sql, _) = to_sql_and_params(&grouped).expect("p75 grouped compiles");
        assert!(
            grouped_sql.contains("GROUP BY prefix_tag, asn, as_org"),
            "{grouped_sql}"
        );
        assert!(
            grouped_sql.contains("ORDER BY COUNT(*) DESC"),
            "{grouped_sql}"
        );
    }
}
