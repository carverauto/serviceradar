use crate::query::flows::{
    FLOW_APP_EXPR, FLOW_EXPORTER_NAME_EXPR, FLOW_IN_IF_NAME_EXPR, FLOW_IN_IF_SPEED_BPS_EXPR,
    FLOW_OUT_IF_NAME_EXPR, FLOW_OUT_IF_SPEED_BPS_EXPR, FLOW_PROTOCOL_GROUP_EXPR,
};
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
            Entity::CpuMetrics => match field {
                None | Some("usage_percent") => Ok("avg_usage_percent".to_string()),
                Some(other) => Err(ServiceError::InvalidRequest(format!(
                    "unsupported value_field '{other}' for cpu_metrics_hourly"
                ))),
            },
            Entity::MemoryMetrics => match field {
                None | Some("usage_percent") => Ok("avg_usage_percent".to_string()),
                Some("used_bytes") => Ok("avg_used_bytes".to_string()),
                Some("available_bytes") => Ok("avg_available_bytes".to_string()),
                Some(other) => Err(ServiceError::InvalidRequest(format!(
                    "unsupported value_field '{other}' for memory_metrics_hourly"
                ))),
            },
            Entity::DiskMetrics => match field {
                None | Some("usage_percent") => Ok("avg_usage_percent".to_string()),
                Some("used_bytes") => Ok("avg_used_bytes".to_string()),
                Some("available_bytes") => Ok("avg_available_bytes".to_string()),
                Some(other) => Err(ServiceError::InvalidRequest(format!(
                    "unsupported value_field '{other}' for disk_metrics_hourly"
                ))),
            },
            Entity::ProcessMetrics => match field {
                None | Some("cpu_usage") => Ok("avg_cpu_usage".to_string()),
                Some("memory_usage") => Ok("avg_memory_usage".to_string()),
                Some(other) => Err(ServiceError::InvalidRequest(format!(
                    "unsupported value_field '{other}' for process_metrics_hourly"
                ))),
            },
            Entity::Flows => match field {
                None | Some("bytes_total") => Ok("bytes_total".to_string()),
                Some("packets_total") => Ok("packets_total".to_string()),
                Some(other) => Err(ServiceError::InvalidRequest(format!(
                    "unsupported value_field '{other}' for flow CAGG (supported: bytes_total|packets_total)"
                ))),
            },
            _ => Err(ServiceError::InvalidRequest(
                "hourly CAGG routing is only supported for metric entities and flows".into(),
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
        Entity::CpuMetrics => match field {
            None | Some("usage_percent") => Ok("usage_percent".to_string()),
            Some("frequency_hz") => Ok("frequency_hz".to_string()),
            Some(other) => Err(ServiceError::InvalidRequest(format!(
                "unsupported value_field '{other}' for cpu_metrics"
            ))),
        },
        Entity::MemoryMetrics => match field {
            None | Some("usage_percent") => Ok("usage_percent".to_string()),
            Some("used_bytes") => Ok("used_bytes".to_string()),
            Some("available_bytes") => Ok("available_bytes".to_string()),
            Some("total_bytes") => Ok("total_bytes".to_string()),
            Some(other) => Err(ServiceError::InvalidRequest(format!(
                "unsupported value_field '{other}' for memory_metrics"
            ))),
        },
        Entity::DiskMetrics => match field {
            None | Some("usage_percent") => Ok("usage_percent".to_string()),
            Some("used_bytes") => Ok("used_bytes".to_string()),
            Some("available_bytes") => Ok("available_bytes".to_string()),
            Some("total_bytes") => Ok("total_bytes".to_string()),
            Some(other) => Err(ServiceError::InvalidRequest(format!(
                "unsupported value_field '{other}' for disk_metrics"
            ))),
        },
        Entity::ProcessMetrics => match field {
            None | Some("cpu_usage") => Ok("cpu_usage".to_string()),
            Some("memory_usage") => Ok("memory_usage".to_string()),
            Some(other) => Err(ServiceError::InvalidRequest(format!(
                "unsupported value_field '{other}' for process_metrics"
            ))),
        },
        Entity::Flows => match field {
            None | Some("bytes_total") => Ok(flow_value_column("bytes_total", false)),
            Some("packets_total") => Ok(flow_value_column("packets_total", false)),
            Some("bytes_in") => Ok(flow_value_column("bytes_in", true)),
            Some("bytes_out") => Ok(flow_value_column("bytes_out", true)),
            Some("packets_in") => Ok(flow_value_column("packets_in", true)),
            Some("packets_out") => Ok(flow_value_column("packets_out", true)),
            Some(other) => Err(ServiceError::InvalidRequest(format!(
                "unsupported value_field '{other}' for flows (supported: bytes_total|packets_total|bytes_in|bytes_out|packets_in|packets_out)"
            ))),
        },
        _ => Err(ServiceError::InvalidRequest(
            "downsample is only supported for metric entities and flows".into(),
        )),
    }
}

fn flow_value_column(column: &str, nullable: bool) -> String {
    let value = if nullable {
        format!("COALESCE({column}, 0)")
    } else {
        column.to_string()
    };

    format!(
        "({value}::double precision * GREATEST(COALESCE(sampling_rate, 1), 1)::double precision)"
    )
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
        Entity::CpuMetrics => match series.as_str() {
            "device_id" => "device_id".to_string(),
            "host_id" => "host_id".to_string(),
            "gateway_id" => "gateway_id".to_string(),
            "agent_id" => "agent_id".to_string(),
            "core_id" => "core_id::text".to_string(),
            "label" => "label".to_string(),
            "cluster" => "cluster".to_string(),
            "partition" => "partition".to_string(),
            other => {
                return Err(ServiceError::InvalidRequest(format!(
                    "unsupported series field '{other}' for {table}"
                )));
            }
        },
        Entity::MemoryMetrics => match series.as_str() {
            "device_id" => "device_id".to_string(),
            "host_id" => "host_id".to_string(),
            "gateway_id" => "gateway_id".to_string(),
            "agent_id" => "agent_id".to_string(),
            "partition" => "partition".to_string(),
            other => {
                return Err(ServiceError::InvalidRequest(format!(
                    "unsupported series field '{other}' for {table}"
                )));
            }
        },
        Entity::DiskMetrics => match series.as_str() {
            "device_id" => "device_id".to_string(),
            "host_id" => "host_id".to_string(),
            "gateway_id" => "gateway_id".to_string(),
            "agent_id" => "agent_id".to_string(),
            "partition" => "partition".to_string(),
            "mount_point" => "mount_point".to_string(),
            "device_name" => "device_name".to_string(),
            other => {
                return Err(ServiceError::InvalidRequest(format!(
                    "unsupported series field '{other}' for {table}"
                )));
            }
        },
        Entity::ProcessMetrics => match series.as_str() {
            "device_id" => "device_id".to_string(),
            "host_id" => "host_id".to_string(),
            "gateway_id" => "gateway_id".to_string(),
            "agent_id" => "agent_id".to_string(),
            "partition" => "partition".to_string(),
            "name" => "name".to_string(),
            "pid" => "pid::text".to_string(),
            "status" => "status".to_string(),
            other => {
                return Err(ServiceError::InvalidRequest(format!(
                    "unsupported series field '{other}' for {table}"
                )));
            }
        },
        Entity::Flows => match series.as_str() {
            "src_endpoint_ip" | "src_ip" => "src_endpoint_ip".to_string(),
            "dst_endpoint_ip" | "dst_ip" => "dst_endpoint_ip".to_string(),
            "protocol_name" => "protocol_name".to_string(),
            "protocol_num" | "proto" => "protocol_num::text".to_string(),
            "protocol_group" | "proto_group" => format!("({})", FLOW_PROTOCOL_GROUP_EXPR),
            "app" => format!("({})", FLOW_APP_EXPR),
            "dst_endpoint_port" | "dst_port" => "dst_endpoint_port::text".to_string(),
            "src_endpoint_port" | "src_port" => "src_endpoint_port::text".to_string(),
            "sampler_address" => "sampler_address".to_string(),
            "exporter_name" => format!("({})", FLOW_EXPORTER_NAME_EXPR),
            "in_if_name" => format!("({})", FLOW_IN_IF_NAME_EXPR),
            "out_if_name" => format!("({})", FLOW_OUT_IF_NAME_EXPR),
            "in_if_speed_bps" => format!("({})::text", FLOW_IN_IF_SPEED_BPS_EXPR),
            "out_if_speed_bps" => format!("({})::text", FLOW_OUT_IF_SPEED_BPS_EXPR),
            other => {
                return Err(ServiceError::InvalidRequest(format!(
                    "unsupported series field '{other}' for {table}"
                )));
            }
        },
        _ => {
            return Err(ServiceError::InvalidRequest(
                "downsample is only supported for metric entities and flows".into(),
            ));
        }
    };

    Ok(format!("coalesce({expr}, '')"))
}

pub(super) fn agg_expr(agg: DownsampleAgg, value_col: &str) -> String {
    match agg {
        DownsampleAgg::Avg => format!("AVG({value_col})"),
        DownsampleAgg::Min => format!("MIN({value_col})"),
        DownsampleAgg::Max => format!("MAX({value_col})"),
        DownsampleAgg::Sum => format!("SUM({value_col})"),
        DownsampleAgg::Count => "COUNT(*)::double precision".to_string(),
        // Rate is handled specially in build_sql with a CTE, this is a fallback
        DownsampleAgg::Rate => format!("AVG({value_col})"),
        DownsampleAgg::RateSum => format!("SUM({value_col})"),
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

pub(super) fn flow_cagg_for_bucket(bucket_seconds: i64) -> &'static str {
    const ONE_HOUR: i64 = 3600;
    const ONE_DAY: i64 = 86400;

    if bucket_seconds >= ONE_DAY {
        "flow_traffic_1d"
    } else if bucket_seconds >= ONE_HOUR {
        "flow_traffic_1h"
    } else {
        "ocsf_network_activity_5m_traffic"
    }
}
