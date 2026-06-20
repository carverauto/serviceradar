macro_rules! apply_text_filter {
    ($query:expr, $filter:expr, $column:expr) => {{
        let __next = match $filter.op {
            crate::parser::FilterOp::Eq => {
                let value = $filter.value.as_scalar()?.to_string();
                $query.filter($column.eq(value))
            }
            crate::parser::FilterOp::NotEq => {
                let value = $filter.value.as_scalar()?.to_string();
                let column = $column;
                $query.filter(column.clone().is_null().or(column.ne(value)))
            }
            crate::parser::FilterOp::Like => {
                let value = $filter.value.as_scalar()?.to_string();
                $query.filter($column.ilike(value))
            }
            crate::parser::FilterOp::NotLike => {
                let value = $filter.value.as_scalar()?.to_string();
                let column = $column;
                $query.filter(column.clone().is_null().or(column.not_ilike(value)))
            }
            crate::parser::FilterOp::In => {
                let values = $filter.value.as_list()?.to_vec();
                if values.is_empty() {
                    $query
                } else {
                    $query.filter($column.eq_any(values))
                }
            }
            crate::parser::FilterOp::NotIn => {
                let values = $filter.value.as_list()?.to_vec();
                if values.is_empty() {
                    $query
                } else {
                    let column = $column;
                    $query.filter(column.clone().is_null().or(column.ne_all(values)))
                }
            }
            _ => {
                return Err(crate::error::ServiceError::InvalidRequest(format!(
                    "unsupported operator for text filter: {:?}",
                    $filter.op
                )));
            }
        };
        Ok::<_, crate::error::ServiceError>(__next)
    }};
}

macro_rules! apply_text_filter_no_lists {
    ($query:expr, $filter:expr, $column:expr, $error:expr) => {{
        let __next = match $filter.op {
            crate::parser::FilterOp::Eq => {
                let value = $filter.value.as_scalar()?.to_string();
                $query.filter($column.eq(value))
            }
            crate::parser::FilterOp::NotEq => {
                let value = $filter.value.as_scalar()?.to_string();
                let column = $column;
                $query.filter(column.clone().is_null().or(column.ne(value)))
            }
            crate::parser::FilterOp::Like => {
                let value = $filter.value.as_scalar()?.to_string();
                $query.filter($column.ilike(value))
            }
            crate::parser::FilterOp::NotLike => {
                let value = $filter.value.as_scalar()?.to_string();
                let column = $column;
                $query.filter(column.clone().is_null().or(column.not_ilike(value)))
            }
            crate::parser::FilterOp::In | crate::parser::FilterOp::NotIn => {
                return Err(crate::error::ServiceError::InvalidRequest($error.into()));
            }
            _ => {
                return Err(crate::error::ServiceError::InvalidRequest(format!(
                    "unsupported operator for text filter: {:?}",
                    $filter.op
                )));
            }
        };
        Ok::<_, crate::error::ServiceError>(__next)
    }};
}

macro_rules! apply_eq_filter {
    ($query:expr, $filter:expr, $column:expr, $value:expr, $error:expr) => {{
        let __value = $value;
        let __next = match $filter.op {
            crate::parser::FilterOp::Eq => $query.filter($column.eq(__value.clone())),
            crate::parser::FilterOp::NotEq => $query.filter($column.ne(__value)),
            _ => {
                return Err(crate::error::ServiceError::InvalidRequest($error.into()));
            }
        };
        Ok::<_, crate::error::ServiceError>(__next)
    }};
}

pub(crate) fn is_negated_membership_op(op: &crate::parser::FilterOp) -> bool {
    matches!(
        op,
        &crate::parser::FilterOp::NotEq | &crate::parser::FilterOp::NotIn
    )
}

/// Normalizes a MAC address value by stripping non-hex characters and lowercasing.
///
/// When `allow_wildcards` is true, `%` and `_` (SQL LIKE wildcards) are preserved.
/// E.g. `"0E-EA-14-32-D2-78"` → `"0eea1432d278"`, `"%0e:ea%"` → `"%0eea%"`.
pub(crate) fn normalize_mac_value(raw: &str, allow_wildcards: bool) -> Result<String> {
    let mut normalized = String::with_capacity(raw.len());

    for ch in raw.chars() {
        if ch.is_ascii_hexdigit() {
            normalized.push(ch.to_ascii_lowercase());
        } else if allow_wildcards && (ch == '%' || ch == '_') {
            normalized.push(ch);
        }
    }

    if normalized.is_empty() {
        return Err(ServiceError::InvalidRequest(
            "mac filter expects hex digits".into(),
        ));
    }

    Ok(normalized)
}

pub(super) fn build_other_rollup_sql(
    inner: &str,
    rank_order_sql: &str,
    top_json_parts: &[String],
    other_json_parts: &[String],
    output_alias: &str,
    limit: i64,
) -> String {
    let other_sort_rn = limit + 1;

    format!(
        "WITH grouped AS ({inner}), ranked AS (SELECT grouped.*, ROW_NUMBER() OVER ({rank_order_sql}) AS rn FROM grouped) SELECT {output_alias} FROM (SELECT rn AS sort_rn, jsonb_build_object({top_json_args}) AS {output_alias} FROM ranked WHERE rn <= {limit} UNION ALL SELECT {other_sort_rn} AS sort_rn, jsonb_build_object({other_json_args}) AS {output_alias} FROM ranked WHERE rn > {limit} HAVING COUNT(*) > 0) final ORDER BY sort_rn",
        top_json_args = top_json_parts.join(", "),
        other_json_args = other_json_parts.join(", "),
    )
}

mod addon_statuses;
mod agents;
mod alerts;
mod bmp_events;
mod capacity_forecasts;
mod cpu_metrics;
mod dashboard_service_views;
mod dashboards;
mod device_graph;
mod devices;
mod disk_metrics;
mod downsample;
mod endpoint_inventory_scans;
mod endpoint_package_catalog;
mod endpoint_packages;
mod events;
mod field_survey;
mod flows;
mod gateways;
mod graph_cypher;
mod interfaces;
mod logs;
mod memory_metrics;
mod otel_metric_points;
mod otel_metrics;
mod process_metrics;
mod services;
mod timeseries_metrics;
mod trace_summaries;
mod traces;
mod virtualization;
mod viz;
mod wifi_map;

use crate::{
    config::AppConfig,
    db::PgPool,
    error::{Result, ServiceError},
    pagination::{decode_cursor, encode_cursor},
    parser::{self, Entity, Filter, OrderClause, QueryAst},
    time::TimeRange,
};
use chrono::{Duration as ChronoDuration, Utc};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::sync::Arc;
use tracing::error;

const CAGG_ROUTING_THRESHOLD_HOURS: i64 = 6;
const CAGG_MAX_TIME_RANGE_DAYS: i64 = 395;

#[derive(Debug, Clone, Serialize)]
#[serde(tag = "t", content = "v", rename_all = "snake_case")]
pub enum BindParam {
    Text(String),
    TextArray(Vec<String>),
    IntArray(Vec<i64>),
    Bool(bool),
    Int(i64),
    Float(f64),
    Timestamptz(String),
    Uuid(uuid::Uuid),
}

impl BindParam {
    fn timestamptz(value: chrono::DateTime<Utc>) -> Self {
        Self::Timestamptz(value.to_rfc3339())
    }
}

#[derive(Clone)]
pub struct QueryEngine {
    pool: PgPool,
    config: Arc<AppConfig>,
}

impl QueryEngine {
    pub fn new(pool: PgPool, config: Arc<AppConfig>) -> Self {
        Self { pool, config }
    }

    pub fn config(&self) -> &AppConfig {
        &self.config
    }

    pub async fn execute_query(&self, request: QueryRequest) -> Result<QueryResponse> {
        let ast = parser::parse(&request.query)?;
        let plan = build_query_plan(&self.config, &request, ast)?;
        let mut conn = self.pool.get().await.map_err(|err| {
            error!(error = ?err, "failed to acquire database connection");
            ServiceError::Internal(anyhow::anyhow!("{err:?}"))
        })?;

        let results = if plan.downsample.is_some() {
            downsample::execute(&mut conn, &plan).await?
        } else {
            match plan.entity {
                Entity::Agents => agents::execute(&mut conn, &plan).await?,
                Entity::AddonStatuses => addon_statuses::execute(&mut conn, &plan).await?,
                Entity::EndpointInventoryScans => {
                    endpoint_inventory_scans::execute(&mut conn, &plan).await?
                }
                Entity::EndpointPackageCatalog => {
                    endpoint_package_catalog::execute(&mut conn, &plan).await?
                }
                Entity::EndpointPackages => endpoint_packages::execute(&mut conn, &plan).await?,
                Entity::Devices => devices::execute(&mut conn, &plan).await?,
                Entity::DeviceGraph => device_graph::execute(&mut conn, &plan).await?,
                Entity::GraphCypher => {
                    graph_cypher::execute(&mut conn, &plan, &self.config.age_graph_name).await?
                }
                Entity::Events
                | Entity::SecurityFindings
                | Entity::ScanActivity
                | Entity::DnsActivity => events::execute(&mut conn, &plan).await?,
                Entity::BmpEvents => bmp_events::execute(&mut conn, &plan).await?,
                Entity::CapacityForecasts => capacity_forecasts::execute(&mut conn, &plan).await?,
                Entity::FieldSurveySessions
                | Entity::FieldSurveyRasters
                | Entity::FieldSurveyArtifacts
                | Entity::FieldSurveyRfObservations
                | Entity::FieldSurveyPoseSamples
                | Entity::FieldSurveyRfPoseMatches
                | Entity::FieldSurveySpectrumObservations => {
                    field_survey::execute(&mut conn, &plan).await?
                }
                Entity::WifiSites
                | Entity::WifiSiteSnapshots
                | Entity::WifiAccessPoints
                | Entity::WifiControllers
                | Entity::WifiRadiusGroups
                | Entity::WifiFleetHistory
                | Entity::WifiSiteReferences => wifi_map::execute(&mut conn, &plan).await?,
                Entity::Flows | Entity::AttributedFlows => flows::execute(&mut conn, &plan).await?,
                Entity::Interfaces => interfaces::execute(&mut conn, &plan).await?,
                Entity::Logs => logs::execute(&mut conn, &plan).await?,
                Entity::Gateways => gateways::execute(&mut conn, &plan).await?,
                Entity::OtelMetrics => otel_metrics::execute(&mut conn, &plan).await?,
                Entity::OtelMetricPoints => otel_metric_points::execute(&mut conn, &plan).await?,
                Entity::RperfMetrics
                | Entity::TimeseriesMetrics
                | Entity::TimeseriesMetricInterfaceHourly
                | Entity::SnmpMetrics => timeseries_metrics::execute(&mut conn, &plan).await?,
                Entity::CpuMetrics => cpu_metrics::execute(&mut conn, &plan).await?,
                Entity::MemoryMetrics => memory_metrics::execute(&mut conn, &plan).await?,
                Entity::DiskMetrics => disk_metrics::execute(&mut conn, &plan).await?,
                Entity::ProcessMetrics => process_metrics::execute(&mut conn, &plan).await?,
                Entity::Services => services::execute(&mut conn, &plan).await?,
                Entity::ServiceAvailability
                | Entity::MonitoredServices
                | Entity::SloEvaluations => {
                    dashboard_service_views::execute(&mut conn, &plan).await?
                }
                Entity::Dashboards => dashboards::execute(&mut conn, &plan).await?,
                Entity::TraceSummaries => trace_summaries::execute(&mut conn, &plan).await?,
                Entity::Traces => traces::execute(&mut conn, &plan).await?,
                Entity::Alerts => alerts::execute(&mut conn, &plan).await?,
                Entity::VirtualizationClusters
                | Entity::VirtualizationHosts
                | Entity::VirtualizationGuests
                | Entity::VirtualizationDatastores
                | Entity::VirtualizationHostDisks
                | Entity::VirtualizationNetworkInterfaces
                | Entity::VirtualizationStorageSystems => {
                    virtualization::execute(&mut conn, &plan).await?
                }
            }
        };

        let pagination = self.build_pagination(&plan, results.len() as i64);
        Ok(QueryResponse {
            results,
            pagination,
            error: None,
        })
    }

    pub async fn translate(&self, request: TranslateRequest) -> Result<TranslateResponse> {
        translate_request(self.config(), QueryRequest::from(request))
    }

    fn build_pagination(&self, plan: &QueryPlan, fetched: i64) -> PaginationMeta {
        let next_offset = plan.offset.saturating_add(plan.limit);
        let next_cursor = if fetched >= plan.limit && next_offset <= self.config.max_cursor_offset {
            Some(encode_cursor(next_offset, &self.config.cursor_secret))
        } else {
            None
        };

        let prev_cursor = if plan.offset > 0 {
            let prev = plan.offset.saturating_sub(plan.limit);
            Some(encode_cursor(prev, &self.config.cursor_secret))
        } else {
            None
        };

        PaginationMeta {
            next_cursor,
            prev_cursor,
            limit: Some(plan.limit),
        }
    }
}

fn build_query_plan(
    config: &AppConfig,
    request: &QueryRequest,
    ast: QueryAst,
) -> Result<QueryPlan> {
    let requested_limit = request.limit.or(ast.limit);
    if ast.other {
        validate_other_rollup_request(&ast, requested_limit, request.cursor.as_deref())?;
    }

    let limit = determine_limit(config, requested_limit);
    let offset = request
        .cursor
        .as_deref()
        .map(|cursor| decode_cursor(cursor, &config.cursor_secret, config.max_cursor_offset))
        .transpose()?
        .unwrap_or(0)
        .max(0);
    let max_time_range_days = max_time_range_days_for_ast(&ast);
    let now = Utc::now();
    let time_range = ast
        .time_filter
        .map(|spec| spec.resolve_with_max_days(now, max_time_range_days))
        .transpose()?;
    let time_range = default_time_range_for_entity(&ast.entity, time_range, now);

    let (filters, order, downsample) =
        normalize_device_aliases(&ast.entity, ast.filters, ast.order, ast.downsample);
    let (filters, include_deleted) = extract_include_deleted(filters)?;
    let filters = normalize_telemetry_id_filters(&ast.entity, filters)?;

    Ok(QueryPlan {
        entity: ast.entity,
        filters,
        order,
        limit,
        offset,
        time_range,
        stats: ast.stats,
        downsample,
        rollup_stats: ast.rollup_stats,
        other: ast.other,
        include_deleted,
    })
}

fn validate_other_rollup_request(
    ast: &QueryAst,
    requested_limit: Option<i64>,
    cursor: Option<&str>,
) -> Result<()> {
    if !matches!(
        ast.entity,
        Entity::Flows
            | Entity::AttributedFlows
            | Entity::TimeseriesMetrics
            | Entity::SnmpMetrics
            | Entity::RperfMetrics
    ) {
        return Err(ServiceError::InvalidRequest(
            "other:true is currently supported only for flow or timeseries stats".into(),
        ));
    }

    ast.stats.as_ref().ok_or_else(|| {
        ServiceError::InvalidRequest("other:true requires a grouped stats query".into())
    })?;

    if requested_limit.is_none() {
        return Err(ServiceError::InvalidRequest(
            "other:true requires an explicit limit".into(),
        ));
    }

    if ast.order.is_empty() {
        return Err(ServiceError::InvalidRequest(
            "other:true requires an explicit sort".into(),
        ));
    }

    if cursor.is_some() {
        return Err(ServiceError::InvalidRequest(
            "other:true does not support cursor pagination".into(),
        ));
    }

    Ok(())
}

fn default_time_range_for_entity(
    entity: &Entity,
    time_range: Option<TimeRange>,
    now: chrono::DateTime<Utc>,
) -> Option<TimeRange> {
    match (entity, time_range) {
        (Entity::Logs, None) => Some(TimeRange {
            start: now - ChronoDuration::hours(24),
            end: now,
        }),
        (_, range) => range,
    }
}

fn determine_limit(config: &AppConfig, candidate: Option<i64>) -> i64 {
    let default = config.default_limit;
    let max = config.max_limit;
    let limit = candidate.unwrap_or(default).max(1);
    if max <= 0 {
        limit
    } else {
        limit.min(max)
    }
}

fn normalize_device_aliases(
    entity: &Entity,
    filters: Vec<crate::parser::Filter>,
    order: Vec<crate::parser::OrderClause>,
    downsample: Option<crate::parser::DownsampleSpec>,
) -> (
    Vec<crate::parser::Filter>,
    Vec<crate::parser::OrderClause>,
    Option<crate::parser::DownsampleSpec>,
) {
    let filters = filters
        .into_iter()
        .map(|mut filter| {
            if let Some(mapped) = normalize_device_field(entity, &filter.field) {
                filter.field = mapped;
            }
            filter
        })
        .collect();

    let order = order
        .into_iter()
        .map(|mut clause| {
            if let Some(mapped) = normalize_device_field(entity, &clause.field) {
                clause.field = mapped;
            }
            clause
        })
        .collect();

    let downsample = downsample.map(|mut spec| {
        if let Some(series) = spec.series.as_mut() {
            if let Some(mapped) = normalize_device_field(entity, series) {
                *series = mapped;
            }
        }
        spec
    });

    (filters, order, downsample)
}

pub(super) fn supports_hourly_cagg(entity: &Entity) -> bool {
    matches!(
        entity,
        Entity::CpuMetrics
            | Entity::MemoryMetrics
            | Entity::DiskMetrics
            | Entity::ProcessMetrics
            | Entity::TimeseriesMetrics
            | Entity::TimeseriesMetricInterfaceHourly
            | Entity::SnmpMetrics
            | Entity::RperfMetrics
            | Entity::Flows
    )
}

pub(super) fn cagg_table_for_entity(entity: &Entity) -> Option<&'static str> {
    match entity {
        Entity::CpuMetrics => Some("cpu_metrics_hourly"),
        Entity::MemoryMetrics => Some("memory_metrics_hourly"),
        Entity::DiskMetrics => Some("disk_metrics_hourly"),
        Entity::ProcessMetrics => Some("process_metrics_hourly"),
        Entity::TimeseriesMetrics | Entity::SnmpMetrics | Entity::RperfMetrics => {
            Some("timeseries_metrics_hourly")
        }
        Entity::TimeseriesMetricInterfaceHourly => Some("timeseries_metrics_interface_hourly"),
        Entity::Flows => Some("ocsf_network_activity_5m_traffic"),
        _ => None,
    }
}

pub(super) fn cagg_column_for_entity(
    entity: &Entity,
    agg_fn: &str,
    field: &str,
) -> Option<&'static str> {
    let agg = agg_fn.trim().to_ascii_lowercase();
    let field = field.trim().to_ascii_lowercase();

    match entity {
        Entity::CpuMetrics => match (agg.as_str(), field.as_str()) {
            ("avg", "usage_percent") => Some("avg_usage_percent"),
            ("max", "usage_percent") => Some("max_usage_percent"),
            _ => None,
        },
        Entity::MemoryMetrics => match (agg.as_str(), field.as_str()) {
            ("avg", "usage_percent") => Some("avg_usage_percent"),
            ("max", "usage_percent") => Some("max_usage_percent"),
            ("avg", "used_bytes") => Some("avg_used_bytes"),
            ("avg", "available_bytes") => Some("avg_available_bytes"),
            _ => None,
        },
        Entity::DiskMetrics => match (agg.as_str(), field.as_str()) {
            ("avg", "usage_percent") => Some("avg_usage_percent"),
            ("max", "usage_percent") => Some("max_usage_percent"),
            ("avg", "used_bytes") => Some("avg_used_bytes"),
            ("avg", "available_bytes") => Some("avg_available_bytes"),
            _ => None,
        },
        Entity::ProcessMetrics => match (agg.as_str(), field.as_str()) {
            ("avg", "cpu_usage") => Some("avg_cpu_usage"),
            ("max", "cpu_usage") => Some("max_cpu_usage"),
            ("avg", "memory_usage") => Some("avg_memory_usage"),
            ("max", "memory_usage") => Some("max_memory_usage"),
            _ => None,
        },
        Entity::TimeseriesMetrics
        | Entity::TimeseriesMetricInterfaceHourly
        | Entity::SnmpMetrics
        | Entity::RperfMetrics => match (agg.as_str(), field.as_str()) {
            ("avg", "value") => Some("avg_value"),
            ("min", "value") => Some("min_value"),
            ("max", "value") => Some("max_value"),
            ("avg", "rate_per_second") | ("avg", "avg_rate_per_second") => {
                Some("avg_rate_per_second")
            }
            _ => None,
        },
        Entity::Flows => match (agg.as_str(), field.as_str()) {
            ("sum", "bytes_total") => Some("bytes_total"),
            ("sum", "packets_total") => Some("packets_total"),
            ("count", "*") => Some("flow_count"),
            _ => None,
        },
        _ => None,
    }
}

fn is_hourly_cagg_eligible_query(entity: &Entity, has_stats: bool, has_downsample: bool) -> bool {
    supports_hourly_cagg(entity) && (has_stats || has_downsample)
}

fn max_time_range_days_for_ast(ast: &QueryAst) -> i64 {
    if matches!(ast.entity, Entity::TimeseriesMetricInterfaceHourly)
        || is_hourly_cagg_eligible_query(&ast.entity, ast.stats.is_some(), ast.downsample.is_some())
    {
        CAGG_MAX_TIME_RANGE_DAYS
    } else {
        90
    }
}

pub(super) fn should_route_to_hourly_cagg(
    entity: &Entity,
    time_range: Option<&TimeRange>,
    has_stats: bool,
    has_downsample: bool,
) -> bool {
    if !is_hourly_cagg_eligible_query(entity, has_stats, has_downsample) {
        return false;
    }

    let Some(time_range) = time_range else {
        return false;
    };

    time_range
        .end
        .signed_duration_since(time_range.start)
        .ge(&ChronoDuration::hours(CAGG_ROUTING_THRESHOLD_HOURS))
}

pub(super) fn should_route_plan_to_hourly_cagg(plan: &QueryPlan) -> bool {
    should_route_to_hourly_cagg(
        &plan.entity,
        plan.time_range.as_ref(),
        plan.stats.is_some(),
        plan.downsample.is_some(),
    )
}

pub(super) fn hourly_cagg_lower_bound_clause(time_col: &str) -> String {
    format!("{time_col} >= time_bucket('1 hour', ?::timestamptz)")
}

pub(super) fn hourly_cagg_upper_bound_clause(time_col: &str) -> String {
    format!("{time_col} < time_bucket('1 hour', ?::timestamptz) + INTERVAL '1 hour'")
}

fn extract_include_deleted(filters: Vec<Filter>) -> Result<(Vec<Filter>, bool)> {
    let mut include_deleted = false;
    let mut remaining = Vec::with_capacity(filters.len());

    for filter in filters {
        if filter.field.eq_ignore_ascii_case("include_deleted") {
            if !matches!(filter.op, crate::parser::FilterOp::Eq) {
                return Err(ServiceError::InvalidRequest(
                    "include_deleted only supports equality".into(),
                ));
            }

            let raw = filter.value.as_scalar()?;
            include_deleted = parse_bool_str(raw)?;
        } else {
            remaining.push(filter);
        }
    }

    Ok((remaining, include_deleted))
}

fn parse_bool_str(value: &str) -> Result<bool> {
    match value.to_lowercase().as_str() {
        "true" | "1" | "yes" | "y" => Ok(true),
        "false" | "0" | "no" | "n" => Ok(false),
        _ => Err(ServiceError::InvalidRequest(format!(
            "invalid boolean value '{value}'"
        ))),
    }
}

/// Observability entities whose trace/span identifier filters follow the
/// canonical OTel id contract (32-char lowercase hex trace ids, 16-char
/// lowercase hex span ids).
fn entity_uses_telemetry_ids(entity: &Entity) -> bool {
    matches!(
        entity,
        Entity::Traces | Entity::Logs | Entity::OtelMetrics | Entity::TraceSummaries
    )
}

/// Returns `(canonical_field_name, expected_hex_length)` for telemetry id
/// filter fields on observability entities.
fn telemetry_id_spec(entity: &Entity, field: &str) -> Option<(&'static str, usize)> {
    if !entity_uses_telemetry_ids(entity) {
        return None;
    }
    match field {
        "trace_id" => Some(("trace_id", 32)),
        "span_id" => Some(("span_id", 16)),
        "parent_span_id" => Some(("parent_span_id", 16)),
        "root_span_id" => Some(("root_span_id", 16)),
        _ => None,
    }
}

/// Normalizes trace/span id filter values on observability entities before
/// SQL generation: case-folds hex input to lowercase and rejects values that
/// are not well-formed ids (32-char hex for trace ids, 16-char hex for span
/// ids). Empty values are rejected so a query errors loudly instead of
/// silently matching nothing. LIKE patterns are case-folded and restricted to
/// hex digits plus SQL wildcards.
fn normalize_telemetry_id_filters(entity: &Entity, filters: Vec<Filter>) -> Result<Vec<Filter>> {
    filters
        .into_iter()
        .map(|mut filter| {
            let Some((field, len)) = telemetry_id_spec(entity, filter.field.as_str()) else {
                return Ok(filter);
            };

            match filter.op {
                crate::parser::FilterOp::Eq
                | crate::parser::FilterOp::NotEq
                | crate::parser::FilterOp::In
                | crate::parser::FilterOp::NotIn => {
                    filter.value = match filter.value {
                        crate::parser::FilterValue::Scalar(value) => {
                            crate::parser::FilterValue::Scalar(normalize_telemetry_id_value(
                                field, len, &value,
                            )?)
                        }
                        crate::parser::FilterValue::List(values) => {
                            crate::parser::FilterValue::List(
                                values
                                    .iter()
                                    .map(|value| normalize_telemetry_id_value(field, len, value))
                                    .collect::<Result<Vec<_>>>()?,
                            )
                        }
                    };
                }
                crate::parser::FilterOp::Like | crate::parser::FilterOp::NotLike => {
                    if let crate::parser::FilterValue::Scalar(value) = &filter.value {
                        filter.value = crate::parser::FilterValue::Scalar(
                            normalize_telemetry_id_pattern(field, len, value)?,
                        );
                    }
                }
                // Other operators are rejected downstream by the per-entity
                // text-filter handling; leave the value untouched here.
                _ => {}
            }

            Ok(filter)
        })
        .collect()
}

fn normalize_telemetry_id_value(field: &str, len: usize, raw: &str) -> Result<String> {
    let value = raw.trim().to_ascii_lowercase();
    if value.is_empty() {
        return Err(ServiceError::InvalidRequest(format!(
            "{field} filter value must not be empty; expected a {len}-character hex string"
        )));
    }
    if value.len() != len || !value.bytes().all(|b| b.is_ascii_hexdigit()) {
        return Err(ServiceError::InvalidRequest(format!(
            "invalid {field} '{raw}': expected a {len}-character hex string"
        )));
    }
    Ok(value)
}

fn normalize_telemetry_id_pattern(field: &str, len: usize, raw: &str) -> Result<String> {
    let pattern = raw.trim().to_ascii_lowercase();
    if pattern.is_empty() {
        return Err(ServiceError::InvalidRequest(format!(
            "{field} filter value must not be empty; expected a {len}-character hex string"
        )));
    }
    if !pattern
        .bytes()
        .all(|b| b.is_ascii_hexdigit() || b == b'%' || b == b'_')
    {
        return Err(ServiceError::InvalidRequest(format!(
            "invalid {field} pattern '{raw}': expected hex digits (optionally with % or _ wildcards); full ids are {len}-character hex strings"
        )));
    }
    Ok(pattern)
}

fn normalize_device_field(entity: &Entity, field: &str) -> Option<String> {
    // Agents have their own uid field, don't remap
    if matches!(entity, Entity::Agents) {
        return None;
    }
    if field.eq_ignore_ascii_case("uid") && !matches!(entity, Entity::Devices) {
        Some("device_id".to_string())
    } else if field.eq_ignore_ascii_case("device_id") && matches!(entity, Entity::Devices) {
        Some("uid".to_string())
    } else {
        None
    }
}

pub(super) fn max_dollar_placeholder(sql: &str) -> usize {
    let bytes = sql.as_bytes();
    let mut max = 0usize;
    let mut i = 0usize;

    while i < bytes.len() {
        if bytes[i] != b'$' {
            i += 1;
            continue;
        }

        i += 1;
        if i >= bytes.len() || !bytes[i].is_ascii_digit() {
            continue;
        }

        let mut value = 0usize;
        while i < bytes.len() && bytes[i].is_ascii_digit() {
            value = value * 10 + (bytes[i] - b'0') as usize;
            i += 1;
        }

        max = max.max(value);
    }

    max
}

pub(super) fn reconcile_limit_offset_binds(
    sql: &str,
    params: &mut Vec<BindParam>,
    limit: i64,
    offset: i64,
) -> Result<()> {
    let expected = max_dollar_placeholder(sql);
    let current = params.len();
    if expected < current {
        return Err(ServiceError::Internal(anyhow::anyhow!(
            "sql expects {expected} binds but {current} were collected"
        )));
    }

    match expected.saturating_sub(current) {
        0 => Ok(()),
        1 => {
            params.push(BindParam::Int(limit));
            Ok(())
        }
        2 => {
            params.push(BindParam::Int(limit));
            params.push(BindParam::Int(offset));
            Ok(())
        }
        extra => Err(ServiceError::Internal(anyhow::anyhow!(
            "unexpected bind arity gap: {extra}"
        ))),
    }
}

pub(super) fn diesel_sql<T>(query: &T) -> Result<String>
where
    T: diesel::query_builder::QueryFragment<diesel::pg::Pg>,
{
    use diesel::query_builder::QueryBuilder as _;

    let backend = diesel::pg::Pg;
    let mut query_builder = <diesel::pg::Pg as diesel::backend::Backend>::QueryBuilder::default();
    diesel::query_builder::QueryFragment::<diesel::pg::Pg>::to_sql(
        query,
        &mut query_builder,
        &backend,
    )
    .map_err(|err| {
        error!(error = ?err, "failed to serialize diesel SQL");
        ServiceError::Internal(anyhow::anyhow!("failed to serialize SQL"))
    })?;

    Ok(query_builder.finish())
}

#[cfg(any(test, debug_assertions))]
pub(super) fn diesel_bind_count<T>(query: &T) -> Result<usize>
where
    T: diesel::query_builder::QueryFragment<diesel::pg::Pg>,
{
    let rendered = diesel::debug_query::<diesel::pg::Pg, _>(query).to_string();
    let marker = "-- binds:";
    let binds = rendered
        .split_once(marker)
        .map(|(_, suffix)| suffix.trim())
        .ok_or_else(|| ServiceError::Internal(anyhow::anyhow!("missing binds marker")))?;

    count_debug_binds_list(binds).ok_or_else(|| {
        ServiceError::Internal(anyhow::anyhow!("failed to parse diesel debug bind list"))
    })
}

#[cfg(any(test, debug_assertions))]
fn count_debug_binds_list(binds: &str) -> Option<usize> {
    let bytes = binds.as_bytes();
    let mut i = 0usize;
    while i < bytes.len() && bytes[i].is_ascii_whitespace() {
        i += 1;
    }

    if i >= bytes.len() || bytes[i] != b'[' {
        return None;
    }

    let mut bracket_depth = 0i32;
    let mut paren_depth = 0i32;
    let mut brace_depth = 0i32;
    let mut in_string = false;
    let mut escape = false;
    let mut in_item = false;
    let mut count = 0usize;

    for &b in bytes[i..].iter() {
        if in_string {
            if escape {
                escape = false;
                continue;
            }

            if b == b'\\' {
                escape = true;
                continue;
            }

            if b == b'"' {
                in_string = false;
            }

            continue;
        }

        match b {
            b'"' => {
                if bracket_depth == 1 && !in_item && brace_depth == 0 && paren_depth == 0 {
                    in_item = true;
                }
                in_string = true;
            }
            b'[' => {
                if bracket_depth == 1 && !in_item && brace_depth == 0 && paren_depth == 0 {
                    in_item = true;
                }
                bracket_depth += 1;
                if bracket_depth == 1 {
                    in_item = false;
                }
            }
            b']' => {
                if bracket_depth == 1 && in_item {
                    count += 1;
                    in_item = false;
                }
                bracket_depth -= 1;
                if bracket_depth <= 0 {
                    break;
                }
            }
            b'{' => {
                if bracket_depth == 1 && !in_item && brace_depth == 0 && paren_depth == 0 {
                    in_item = true;
                }
                brace_depth += 1
            }
            b'}' => brace_depth -= 1,
            b'(' => {
                if bracket_depth == 1 && !in_item && brace_depth == 0 && paren_depth == 0 {
                    in_item = true;
                }
                paren_depth += 1
            }
            b')' => paren_depth -= 1,
            b',' => {
                if bracket_depth == 1 && brace_depth == 0 && paren_depth == 0 && in_item {
                    count += 1;
                    in_item = false;
                }
            }
            b if b.is_ascii_whitespace() => {}
            _ => {
                if bracket_depth == 1 && !in_item {
                    in_item = true;
                }
            }
        }
    }

    Some(count)
}

pub fn translate_request(config: &AppConfig, request: QueryRequest) -> Result<TranslateResponse> {
    let ast = parser::parse(&request.query)?;
    let plan = build_query_plan(config, &request, ast)?;
    let viz = viz::meta_for_plan(&plan);

    let (sql, params) = if plan.downsample.is_some() {
        downsample::to_sql_and_params(&plan)?
    } else {
        match plan.entity {
            Entity::Agents => agents::to_sql_and_params(&plan)?,
            Entity::AddonStatuses => addon_statuses::to_sql_and_params(&plan)?,
            Entity::EndpointInventoryScans => endpoint_inventory_scans::to_sql_and_params(&plan)?,
            Entity::EndpointPackageCatalog => endpoint_package_catalog::to_sql_and_params(&plan)?,
            Entity::EndpointPackages => endpoint_packages::to_sql_and_params(&plan)?,
            Entity::Devices => devices::to_sql_and_params(&plan)?,
            Entity::DeviceGraph => device_graph::to_sql_and_params(&plan)?,
            Entity::GraphCypher => graph_cypher::to_sql_and_params(&plan, &config.age_graph_name)?,
            Entity::Events
            | Entity::SecurityFindings
            | Entity::ScanActivity
            | Entity::DnsActivity => events::to_sql_and_params(&plan)?,
            Entity::BmpEvents => bmp_events::to_sql_and_params(&plan)?,
            Entity::CapacityForecasts => capacity_forecasts::to_sql_and_params(&plan)?,
            Entity::FieldSurveySessions
            | Entity::FieldSurveyRasters
            | Entity::FieldSurveyArtifacts
            | Entity::FieldSurveyRfObservations
            | Entity::FieldSurveyPoseSamples
            | Entity::FieldSurveyRfPoseMatches
            | Entity::FieldSurveySpectrumObservations => field_survey::to_sql_and_params(&plan)?,
            Entity::WifiSites
            | Entity::WifiSiteSnapshots
            | Entity::WifiAccessPoints
            | Entity::WifiControllers
            | Entity::WifiRadiusGroups
            | Entity::WifiFleetHistory
            | Entity::WifiSiteReferences => wifi_map::to_sql_and_params(&plan)?,
            Entity::Flows | Entity::AttributedFlows => flows::to_sql_and_params(&plan)?,
            Entity::Interfaces => interfaces::to_sql_and_params(&plan)?,
            Entity::Logs => logs::to_sql_and_params(&plan)?,
            Entity::Gateways => gateways::to_sql_and_params(&plan)?,
            Entity::OtelMetrics => otel_metrics::to_sql_and_params(&plan)?,
            Entity::OtelMetricPoints => otel_metric_points::to_sql_and_params(&plan)?,
            Entity::RperfMetrics
            | Entity::TimeseriesMetrics
            | Entity::TimeseriesMetricInterfaceHourly
            | Entity::SnmpMetrics => timeseries_metrics::to_sql_and_params(&plan)?,
            Entity::CpuMetrics => cpu_metrics::to_sql_and_params(&plan)?,
            Entity::MemoryMetrics => memory_metrics::to_sql_and_params(&plan)?,
            Entity::DiskMetrics => disk_metrics::to_sql_and_params(&plan)?,
            Entity::ProcessMetrics => process_metrics::to_sql_and_params(&plan)?,
            Entity::Services => services::to_sql_and_params(&plan)?,
            Entity::ServiceAvailability | Entity::MonitoredServices | Entity::SloEvaluations => {
                dashboard_service_views::to_sql_and_params(&plan)?
            }
            Entity::Dashboards => dashboards::to_sql_and_params(&plan)?,
            Entity::TraceSummaries => trace_summaries::to_sql_and_params(&plan)?,
            Entity::Traces => traces::to_sql_and_params(&plan)?,
            Entity::Alerts => alerts::to_sql_and_params(&plan)?,
            Entity::VirtualizationClusters
            | Entity::VirtualizationHosts
            | Entity::VirtualizationGuests
            | Entity::VirtualizationDatastores
            | Entity::VirtualizationHostDisks
            | Entity::VirtualizationNetworkInterfaces
            | Entity::VirtualizationStorageSystems => virtualization::to_sql_and_params(&plan)?,
        }
    };

    let next_offset = plan.offset.saturating_add(plan.limit);
    let next_cursor = if next_offset <= config.max_cursor_offset {
        Some(encode_cursor(next_offset, &config.cursor_secret))
    } else {
        None
    };
    let prev_cursor = if plan.offset > 0 {
        Some(encode_cursor(
            plan.offset.saturating_sub(plan.limit),
            &config.cursor_secret,
        ))
    } else {
        None
    };

    Ok(TranslateResponse {
        sql,
        params,
        pagination: PaginationMeta {
            next_cursor,
            prev_cursor,
            limit: Some(plan.limit),
        },
        viz,
    })
}

#[cfg(test)]
mod tests;

#[derive(Debug, Clone)]
pub struct QueryPlan {
    pub entity: Entity,
    pub filters: Vec<Filter>,
    pub order: Vec<OrderClause>,
    pub limit: i64,
    pub offset: i64,
    pub time_range: Option<TimeRange>,
    pub stats: Option<crate::parser::StatsSpec>,
    pub downsample: Option<crate::parser::DownsampleSpec>,
    /// Rollup stats type for querying pre-computed CAGGs (e.g., "severity", "summary", "availability")
    pub rollup_stats: Option<String>,
    pub other: bool,
    pub include_deleted: bool,
}

#[derive(Debug, Clone, Deserialize, Serialize, Default)]
#[serde(rename_all = "lowercase")]
pub enum QueryDirection {
    #[default]
    Next,
    Prev,
}

#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct QueryRequest {
    pub query: String,
    #[serde(default)]
    pub limit: Option<i64>,
    #[serde(default)]
    pub cursor: Option<String>,
    #[serde(default)]
    pub direction: QueryDirection,
    #[serde(default)]
    pub mode: Option<String>,
}

#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct TranslateRequest {
    pub query: String,
    #[serde(default)]
    pub limit: Option<i64>,
    #[serde(default)]
    pub cursor: Option<String>,
    #[serde(default)]
    pub direction: QueryDirection,
    #[serde(default)]
    pub mode: Option<String>,
}

impl From<TranslateRequest> for QueryRequest {
    fn from(request: TranslateRequest) -> Self {
        Self {
            query: request.query,
            limit: request.limit,
            cursor: request.cursor,
            direction: request.direction,
            mode: request.mode,
        }
    }
}

#[derive(Debug, Clone, Serialize, Default)]
pub struct PaginationMeta {
    pub next_cursor: Option<String>,
    pub prev_cursor: Option<String>,
    pub limit: Option<i64>,
}

#[derive(Debug, Clone, Serialize, Default)]
pub struct QueryResponse {
    pub results: Vec<Value>,
    pub pagination: PaginationMeta,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
}

#[derive(Debug, Clone, Serialize)]
pub struct TranslateResponse {
    pub sql: String,
    #[serde(skip_serializing_if = "Vec::is_empty", default)]
    pub params: Vec<BindParam>,
    pub pagination: PaginationMeta,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub viz: Option<viz::VizMeta>,
}
