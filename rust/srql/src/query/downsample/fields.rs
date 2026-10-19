use crate::{
    error::{Result, ServiceError},
    parser::{DownsampleAgg, Entity},
    query::{QueryPlan, filters_common::is_valid_jsonb_key},
};

pub(super) fn resolve_value_column(
    entity: Entity,
    value_field: Option<&str>,
    use_hourly_cagg: bool,
) -> Result<String> {
    let value_field = value_field.map(|value| value.trim().to_lowercase());
    let field = value_field.as_deref();

    if use_hourly_cagg {
        return match entity {
            Entity::TimeseriesMetrics | Entity::SnmpMetrics | Entity::RperfMetrics => match field {
                None | Some("value") => Ok("avg_value".to_string()),
                Some(other) => Err(ServiceError::InvalidRequest(format!(
                    "unsupported value_field '{other}' for timeseries_metrics_hourly"
                ))),
            },
            _ => Err(ServiceError::InvalidRequest(
                "hourly CAGG routing is only supported for metric entities".into(),
            )),
        };
    }

    match entity {
        Entity::TimeseriesMetrics | Entity::SnmpMetrics | Entity::RperfMetrics => match field {
            None | Some("value") => Ok("value".to_string()),
            Some(other) => Err(ServiceError::InvalidRequest(format!(
                "unsupported value_field '{other}' for timeseries metrics"
            ))),
        },
        _ => Err(ServiceError::InvalidRequest(
            "downsample is only supported for metric entities".into(),
        )),
    }
}

pub(super) fn series_expr(plan: &QueryPlan, table: &str) -> Result<String> {
    let downsample = plan.downsample.as_ref().ok_or_else(|| {
        ServiceError::InvalidRequest("downsample requires bucket:<duration>".into())
    })?;

    let Some(series) = downsample.series.as_deref() else {
        return Ok("NULL::text".to_string());
    };

    let series = series.trim().to_lowercase();

    let expr = match plan.entity {
        Entity::TimeseriesMetrics | Entity::SnmpMetrics | Entity::RperfMetrics => {
            match series.as_str() {
                "metric_name" => "metric_name".to_string(),
                "metric_type" => "metric_type".to_string(),
                "series_key" => "series_key".to_string(),
                "device_id" => "device_id".to_string(),
                "gateway_id" => "gateway_id".to_string(),
                "agent_id" => "agent_id".to_string(),
                // Pre-existing alias for `tags.core_id`, retained because
                // callers depend on the shorter spelling.
                "core_id" => "tags->>'core_id'".to_string(),
                "partition" => "partition".to_string(),
                "target_device_ip" => "target_device_ip".to_string(),
                "if_index" => "if_index::text".to_string(),
                // Split by an arbitrary tag. This expression is interpolated
                // into the SELECT and GROUP BY lists, so the key is validated
                // before it can reach the string — same rule as tag filtering
                // and tag grouping.
                candidate if candidate.starts_with("tags.") => {
                    let key = candidate.strip_prefix("tags.").unwrap_or_default();
                    if !is_valid_jsonb_key(key) {
                        return Err(ServiceError::InvalidRequest(format!(
                            "invalid tag key '{key}' in series field"
                        )));
                    }
                    format!("tags->>'{key}'")
                }
                other => {
                    return Err(ServiceError::InvalidRequest(format!(
                        "unsupported series field '{other}' for {table}"
                    )));
                }
            }
        }
        _ => {
            return Err(ServiceError::InvalidRequest(
                "downsample is only supported for metric entities".into(),
            ));
        }
    };

    Ok(format!("coalesce({expr}, '')"))
}

pub(super) fn agg_expr(agg: DownsampleAgg, value_col: &str, ts_col: &str) -> String {
    match agg {
        DownsampleAgg::Avg => format!("AVG({value_col})"),
        DownsampleAgg::Min => format!("MIN({value_col})"),
        DownsampleAgg::Max => format!("MAX({value_col})"),
        DownsampleAgg::Sum => format!("SUM({value_col})"),
        DownsampleAgg::Count => "COUNT(*)::double precision".to_string(),
        // Rate is handled specially in build_sql with a CTE, this is a fallback
        DownsampleAgg::Rate => format!("AVG({value_col})"),
        DownsampleAgg::RateSum => format!("SUM({value_col})"),
        // The newest sample in the bucket. Portable Postgres rather than
        // TimescaleDB's `last()`, so the raw tables need no extension function.
        DownsampleAgg::Last => format!("(array_agg({value_col} ORDER BY {ts_col} DESC))[1]"),
    }
}

/// How the per-series rates are combined inside one display bucket.
///
/// The LAG window always partitions by the full series identity, so the deltas
/// themselves are per underlying counter either way. This only decides what
/// happens when a display series collapses several of them together.
pub(super) fn rate_bucket_combine(agg: DownsampleAgg) -> &'static str {
    match agg {
        DownsampleAgg::RateSum => "SUM",
        _ => "AVG",
    }
}

/// Check if the aggregation type requires special rate-based query structure
pub(super) fn is_rate_agg(agg: DownsampleAgg) -> bool {
    matches!(agg, DownsampleAgg::Rate | DownsampleAgg::RateSum)
}
