use super::QueryPlan;
use crate::{
    parser::{Entity, QueryAst},
    time::TimeRange,
};
use chrono::{Duration as ChronoDuration, Utc};
use std::sync::OnceLock;

const CAGG_ROUTING_THRESHOLD_HOURS: i64 = 6;
const CAGG_MAX_TIME_RANGE_DAYS: i64 = 395;
/// Mirrors the deployed TimescaleDB retention policies on the raw hypertables
/// the hourly CAGGs roll up: 7 days for the high-volume metric tables
/// (cpu/disk/memory/process/timeseries) and for raw flows. Set
/// `SRQL_RAW_TELEMETRY_RETENTION_HOURS` when those policies change.
const DEFAULT_RAW_TELEMETRY_RETENTION_HOURS: i64 = 168;

/// Hours of raw data the deployment retains on the metric and flow
/// hypertables. Read once per process from
/// `SRQL_RAW_TELEMETRY_RETENTION_HOURS`; an unparsable or non-positive value
/// falls back to the default with a warning rather than disabling the
/// retention routing arm silently.
fn raw_telemetry_retention_hours() -> i64 {
    static OVERRIDE: OnceLock<i64> = OnceLock::new();
    *OVERRIDE.get_or_init(|| {
        let Ok(raw) = std::env::var("SRQL_RAW_TELEMETRY_RETENTION_HOURS") else {
            return DEFAULT_RAW_TELEMETRY_RETENTION_HOURS;
        };
        match raw.trim().parse::<i64>() {
            Ok(hours) if hours >= 1 => hours,
            _ => {
                tracing::warn!(
                    value = %raw,
                    fallback = DEFAULT_RAW_TELEMETRY_RETENTION_HOURS,
                    "SRQL_RAW_TELEMETRY_RETENTION_HOURS must be a positive integer of hours; using fallback"
                );
                DEFAULT_RAW_TELEMETRY_RETENTION_HOURS
            }
        }
    })
}

pub(crate) fn supports_hourly_cagg(entity: &Entity) -> bool {
    matches!(
        entity,
        Entity::CpuMetrics
            | Entity::MemoryMetrics
            | Entity::DiskMetrics
            | Entity::ProcessMetrics
            | Entity::TimeseriesMetrics
            | Entity::TimeseriesMetricInterfaceHourly
            | Entity::TimeseriesMetricDiskHourly
            | Entity::SnmpMetrics
            | Entity::RperfMetrics
            | Entity::Flows
    )
}

pub(crate) fn cagg_table_for_entity(entity: &Entity) -> Option<&'static str> {
    match entity {
        Entity::CpuMetrics => Some("cpu_metrics_hourly"),
        Entity::MemoryMetrics => Some("memory_metrics_hourly"),
        Entity::DiskMetrics => Some("disk_metrics_hourly"),
        Entity::ProcessMetrics => Some("process_metrics_hourly"),
        Entity::TimeseriesMetrics | Entity::SnmpMetrics | Entity::RperfMetrics => {
            Some("timeseries_metrics_hourly")
        }
        Entity::TimeseriesMetricInterfaceHourly => Some("timeseries_metrics_interface_hourly"),
        Entity::TimeseriesMetricDiskHourly => Some("timeseries_metrics_disk_hourly"),
        Entity::Flows => Some("ocsf_network_activity_5m_traffic"),
        _ => None,
    }
}

pub(crate) fn cagg_column_for_entity(
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
        | Entity::TimeseriesMetricDiskHourly
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

pub(crate) fn max_time_range_days_for_ast(ast: &QueryAst) -> i64 {
    if matches!(
        ast.entity,
        Entity::TimeseriesMetricInterfaceHourly | Entity::TimeseriesMetricDiskHourly
    ) || is_hourly_cagg_eligible_query(
        &ast.entity,
        ast.stats.is_some(),
        ast.downsample.is_some(),
    ) {
        CAGG_MAX_TIME_RANGE_DAYS
    } else {
        90
    }
}

/// Whether a stats/downsample query over `entity` should read the hourly
/// CAGG instead of the raw hypertable.
///
/// Two arms, and they answer different questions:
///
/// - **Span** (`>= CAGG_ROUTING_THRESHOLD_HOURS`): the rollup is cheaper than
///   the raw scan for wide windows. This is the original heuristic.
/// - **Retention** (`raw_retention_hours`): a window that *starts* before the
///   raw tables' retention horizon must read the rollup regardless of span,
///   because the raw table has already dropped every row in that window — the
///   span arm alone answers a short old window from an empty source (#4514).
///   A sub-threshold span can never reach past the horizon into live raw
///   data, so this arm only fires for windows that are entirely beyond
///   retention.
pub(crate) fn should_route_to_hourly_cagg(
    entity: &Entity,
    time_range: Option<&TimeRange>,
    has_stats: bool,
    has_downsample: bool,
    raw_retention_hours: i64,
) -> bool {
    if !is_hourly_cagg_eligible_query(entity, has_stats, has_downsample) {
        return false;
    }

    let Some(time_range) = time_range else {
        return false;
    };

    let span = time_range.end.signed_duration_since(time_range.start);
    if span.ge(&ChronoDuration::hours(CAGG_ROUTING_THRESHOLD_HOURS)) {
        return true;
    }

    time_range
        .start
        .lt(&(Utc::now() - ChronoDuration::hours(raw_retention_hours.max(1))))
}

pub(crate) fn should_route_plan_to_hourly_cagg(plan: &QueryPlan) -> bool {
    should_route_to_hourly_cagg(
        &plan.entity,
        plan.time_range.as_ref(),
        plan.stats.is_some(),
        plan.downsample.is_some(),
        raw_telemetry_retention_hours(),
    )
}

pub(crate) fn hourly_cagg_lower_bound_clause(time_col: &str) -> String {
    format!("{time_col} >= time_bucket('1 hour', ?::timestamptz)")
}

pub(crate) fn hourly_cagg_upper_bound_clause(time_col: &str) -> String {
    format!("{time_col} < time_bucket('1 hour', ?::timestamptz) + INTERVAL '1 hour'")
}
