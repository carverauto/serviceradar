use super::bind::SqlBindValue;
use crate::query::flows::{
    FLOW_APP_EXPR, FLOW_DIRECTION_EXPR, FLOW_EXPORTER_NAME_EXPR, FLOW_IN_IF_NAME_EXPR,
    FLOW_IN_IF_SPEED_BPS_EXPR, FLOW_INPUT_SNMP_EXPR, FLOW_OUT_IF_NAME_EXPR,
    FLOW_OUT_IF_SPEED_BPS_EXPR, FLOW_OUTPUT_SNMP_EXPR, FLOW_PROTOCOL_GROUP_EXPR,
    normalize_cidr_literal,
};
use crate::{
    error::{Result, ServiceError},
    parser::{Entity, Filter, FilterOp},
    query::filters_common::is_valid_jsonb_key,
};

pub(super) fn filter_clause(
    entity: &Entity,
    _table: &str,
    filter: &Filter,
) -> Result<(String, Vec<SqlBindValue>)> {
    match entity {
        Entity::TimeseriesMetrics | Entity::SnmpMetrics | Entity::RperfMetrics => {
            timeseries_filter_clause(filter)
        }
        Entity::CpuMetrics => cpu_filter_clause(filter),
        Entity::MemoryMetrics => memory_filter_clause(filter),
        Entity::DiskMetrics => disk_filter_clause(filter),
        Entity::ProcessMetrics => process_filter_clause(filter),
        Entity::Flows => flows_filter_clause(filter),
        _ => Err(ServiceError::InvalidRequest(
            "downsample is only supported for metric entities and flows".into(),
        )),
    }
}

fn flows_filter_clause(filter: &Filter) -> Result<(String, Vec<SqlBindValue>)> {
    match filter.field.as_str() {
        "src_endpoint_ip" | "src_ip" => text_clause("src_endpoint_ip", filter),
        "dst_endpoint_ip" | "dst_ip" => text_clause("dst_endpoint_ip", filter),
        "ip" | "endpoint_ip" => bidirectional_ip_clause(filter),
        // Same device address set as the row/stats paths. Without this the
        // timeseries query for a device rejected `device_id:` outright, so the
        // Traffic Profile chart and the sparkline had no data at all.
        "device_addr" | "device_address" => device_addr_clause(filter),
        "src_cidr" => cidr_clause("src_endpoint_ip", filter),
        "dst_cidr" => cidr_clause("dst_endpoint_ip", filter),
        // Bare `cidr:` matches either endpoint (same shape as row/stats paths).
        "cidr" => bidirectional_cidr_clause(filter),
        "protocol_name" => text_clause("protocol_name", filter),
        "sampler_address" => text_clause("sampler_address", filter),
        "exporter_name" => expr_text_clause(FLOW_EXPORTER_NAME_EXPR, filter),
        "input_snmp" | "in_if_index" => int_clause(FLOW_INPUT_SNMP_EXPR, filter, false),
        "output_snmp" | "out_if_index" => int_clause(FLOW_OUTPUT_SNMP_EXPR, filter, false),
        "in_if_name" => expr_text_clause(FLOW_IN_IF_NAME_EXPR, filter),
        "out_if_name" => expr_text_clause(FLOW_OUT_IF_NAME_EXPR, filter),
        "in_if_speed_bps" => expr_text_clause(FLOW_IN_IF_SPEED_BPS_EXPR, filter),
        "out_if_speed_bps" => expr_text_clause(FLOW_OUT_IF_SPEED_BPS_EXPR, filter),
        "protocol_group" | "proto_group" => expr_text_clause(FLOW_PROTOCOL_GROUP_EXPR, filter),
        "app" => expr_text_clause(FLOW_APP_EXPR, filter),
        "direction" => expr_text_clause(FLOW_DIRECTION_EXPR, filter),
        "protocol_num" | "proto" => int_clause("protocol_num", filter, false),
        "src_endpoint_port" | "src_port" => int_clause("src_endpoint_port", filter, false),
        "dst_endpoint_port" | "dst_port" => int_clause("dst_endpoint_port", filter, false),
        other => Err(ServiceError::InvalidRequest(format!(
            "unsupported filter field for downsample flows: '{other}'"
        ))),
    }
}

fn expr_text_clause(expr: &str, filter: &Filter) -> Result<(String, Vec<SqlBindValue>)> {
    text_clause(&format!("({expr})"), filter)
}

/// `ip:` across both flow endpoints for the chart (`bucket:`) path.
///
/// A positive match is "either endpoint matches"; a negative match is "neither
/// endpoint matches" -- the AND of the two per-side negatives, not their OR.
/// Binds are concatenated in src-then-dst order to match the emitted clause.
fn bidirectional_ip_clause(filter: &Filter) -> Result<(String, Vec<SqlBindValue>)> {
    let joiner = match filter.op {
        FilterOp::NotEq | FilterOp::NotLike | FilterOp::NotIn => " AND ",
        _ => " OR ",
    };

    let (src_clause, mut binds) = text_clause("src_endpoint_ip", filter)?;
    let (dst_clause, dst_binds) = text_clause("dst_endpoint_ip", filter)?;
    binds.extend(dst_binds);

    Ok((format!("({src_clause}{joiner}{dst_clause})"), binds))
}

/// Any of a device's addresses against either endpoint or the sampler.
///
/// An empty list is rejected rather than delegated. `text_clause` would render
/// it as `1=0` here, which is harmless, but the stats path's equivalent renders
/// `1=1` and the row path cannot express it at all -- so rejecting in all three
/// is the only behaviour a caller can reason about.
fn device_addr_clause(filter: &Filter) -> Result<(String, Vec<SqlBindValue>)> {
    if !matches!(filter.op, FilterOp::Eq | FilterOp::In) {
        return Err(ServiceError::InvalidRequest(
            "device_addr filter supports equality and list matching".into(),
        ));
    }

    if matches!(filter.op, FilterOp::In) && filter.value.as_list()?.is_empty() {
        return Err(ServiceError::InvalidRequest(
            "device_addr filter requires at least one address".into(),
        ));
    }

    let (src_clause, mut binds) = text_clause("src_endpoint_ip", filter)?;
    let (dst_clause, dst_binds) = text_clause("dst_endpoint_ip", filter)?;
    let (sampler_clause, sampler_binds) = text_clause("sampler_address", filter)?;
    binds.extend(dst_binds);
    binds.extend(sampler_binds);

    Ok((
        format!("({src_clause} OR {dst_clause} OR {sampler_clause})"),
        binds,
    ))
}

/// Single-side CIDR containment against a flow endpoint IP column.
fn cidr_clause(ip_col: &str, filter: &Filter) -> Result<(String, Vec<SqlBindValue>)> {
    match filter.op {
        FilterOp::Eq | FilterOp::NotEq => {
            let cidr = normalize_cidr_literal(filter.value.as_scalar()?)?;
            let binds = vec![SqlBindValue::Text(cidr)];
            let clause = match filter.op {
                FilterOp::Eq => {
                    format!("(try_inet(NULLIF({ip_col}, '')) <<= ?::cidr)")
                }
                FilterOp::NotEq => format!(
                    "(try_inet(NULLIF({ip_col}, '')) IS NULL OR NOT (try_inet(NULLIF({ip_col}, '')) <<= ?::cidr))"
                ),
                _ => unreachable!(),
            };
            Ok((clause, binds))
        }
        FilterOp::In | FilterOp::NotIn => {
            let values = filter.value.as_list()?;
            if values.is_empty() {
                return Ok((
                    if matches!(filter.op, FilterOp::In) {
                        "1=0".to_string()
                    } else {
                        "1=1".to_string()
                    },
                    Vec::new(),
                ));
            }
            let mut out = Vec::with_capacity(values.len());
            for value in values {
                out.push(normalize_cidr_literal(value)?);
            }
            let binds = vec![SqlBindValue::TextArray(out)];
            let clause = match filter.op {
                FilterOp::In => {
                    format!("(try_inet(NULLIF({ip_col}, '')) <<= ANY(?::cidr[]))")
                }
                FilterOp::NotIn => format!(
                    "(try_inet(NULLIF({ip_col}, '')) IS NULL OR NOT (try_inet(NULLIF({ip_col}, '')) <<= ANY(?::cidr[])))"
                ),
                _ => unreachable!(),
            };
            Ok((clause, binds))
        }
        _ => Err(ServiceError::InvalidRequest(format!(
            "{ip_col} CIDR filter only supports equality or list matching"
        ))),
    }
}

/// Bare `cidr:` — either endpoint is inside the block (chart / `bucket:` path).
///
/// Positive match is OR of the two sides; negative match is AND of the two
/// NULL-safe per-side negatives. Binds are duplicated in src-then-dst order.
fn bidirectional_cidr_clause(filter: &Filter) -> Result<(String, Vec<SqlBindValue>)> {
    match filter.op {
        FilterOp::Eq | FilterOp::NotEq => {
            let cidr = normalize_cidr_literal(filter.value.as_scalar()?)?;
            let binds = vec![SqlBindValue::Text(cidr.clone()), SqlBindValue::Text(cidr)];
            let clause = match filter.op {
                FilterOp::Eq => "(try_inet(NULLIF(src_endpoint_ip, '')) <<= ?::cidr \
                     OR try_inet(NULLIF(dst_endpoint_ip, '')) <<= ?::cidr)"
                    .to_string(),
                FilterOp::NotEq => "((try_inet(NULLIF(src_endpoint_ip, '')) IS NULL OR NOT (try_inet(NULLIF(src_endpoint_ip, '')) <<= ?::cidr)) \
                     AND (try_inet(NULLIF(dst_endpoint_ip, '')) IS NULL OR NOT (try_inet(NULLIF(dst_endpoint_ip, '')) <<= ?::cidr)))"
                    .to_string(),
                _ => unreachable!(),
            };
            Ok((clause, binds))
        }
        _ => Err(ServiceError::InvalidRequest(
            "cidr filter only supports equality".into(),
        )),
    }
}

fn text_clause(column: &str, filter: &Filter) -> Result<(String, Vec<SqlBindValue>)> {
    let mut binds = Vec::new();
    let clause = match filter.op {
        FilterOp::Eq => {
            binds.push(SqlBindValue::Text(filter.value.as_scalar()?.to_string()));
            format!("{column} = ?")
        }
        FilterOp::NotEq => {
            binds.push(SqlBindValue::Text(filter.value.as_scalar()?.to_string()));
            format!("{column} <> ?")
        }
        FilterOp::Like => {
            binds.push(SqlBindValue::Text(filter.value.as_scalar()?.to_string()));
            format!("{column} ILIKE ?")
        }
        FilterOp::NotLike => {
            binds.push(SqlBindValue::Text(filter.value.as_scalar()?.to_string()));
            format!("NOT ({column} ILIKE ?)")
        }
        FilterOp::In => {
            let values = filter.value.as_list()?.to_vec();
            if values.is_empty() {
                return Ok(("1=0".to_string(), Vec::new()));
            }
            binds.push(SqlBindValue::TextArray(values));
            format!("{column} = ANY(?)")
        }
        FilterOp::NotIn => {
            let values = filter.value.as_list()?.to_vec();
            if values.is_empty() {
                return Ok(("1=1".to_string(), Vec::new()));
            }
            binds.push(SqlBindValue::TextArray(values));
            format!("{column} <> ALL(?)")
        }
        _ => {
            return Err(ServiceError::InvalidRequest(format!(
                "unsupported operator for {column}: {:?}",
                filter.op
            )));
        }
    };
    Ok((clause, binds))
}

fn float_clause(
    column: &str,
    filter: &Filter,
    allow_ranges: bool,
) -> Result<(String, Vec<SqlBindValue>)> {
    let mut binds = Vec::new();
    let value = filter
        .value
        .as_scalar()?
        .parse::<f64>()
        .map_err(|_| ServiceError::InvalidRequest("invalid numeric value".into()))?;
    let clause = match filter.op {
        FilterOp::Eq => {
            binds.push(SqlBindValue::Float(value));
            format!("{column} = ?")
        }
        FilterOp::NotEq => {
            binds.push(SqlBindValue::Float(value));
            format!("{column} <> ?")
        }
        FilterOp::Gt if allow_ranges => {
            binds.push(SqlBindValue::Float(value));
            format!("{column} > ?")
        }
        FilterOp::Gte if allow_ranges => {
            binds.push(SqlBindValue::Float(value));
            format!("{column} >= ?")
        }
        FilterOp::Lt if allow_ranges => {
            binds.push(SqlBindValue::Float(value));
            format!("{column} < ?")
        }
        FilterOp::Lte if allow_ranges => {
            binds.push(SqlBindValue::Float(value));
            format!("{column} <= ?")
        }
        _ => {
            return Err(ServiceError::InvalidRequest(format!(
                "{column} filter does not support operator {:?}",
                filter.op
            )));
        }
    };
    Ok((clause, binds))
}

fn int_clause(
    column: &str,
    filter: &Filter,
    allow_ranges: bool,
) -> Result<(String, Vec<SqlBindValue>)> {
    let mut binds = Vec::new();
    let value = filter
        .value
        .as_scalar()?
        .parse::<i64>()
        .map_err(|_| ServiceError::InvalidRequest("invalid integer value".into()))?;

    let clause = match filter.op {
        FilterOp::Eq => {
            binds.push(SqlBindValue::BigInt(value));
            format!("{column} = ?")
        }
        FilterOp::NotEq => {
            binds.push(SqlBindValue::BigInt(value));
            format!("{column} <> ?")
        }
        FilterOp::Gt if allow_ranges => {
            binds.push(SqlBindValue::BigInt(value));
            format!("{column} > ?")
        }
        FilterOp::Gte if allow_ranges => {
            binds.push(SqlBindValue::BigInt(value));
            format!("{column} >= ?")
        }
        FilterOp::Lt if allow_ranges => {
            binds.push(SqlBindValue::BigInt(value));
            format!("{column} < ?")
        }
        FilterOp::Lte if allow_ranges => {
            binds.push(SqlBindValue::BigInt(value));
            format!("{column} <= ?")
        }
        _ => {
            return Err(ServiceError::InvalidRequest(format!(
                "{column} filter does not support operator {:?}",
                filter.op
            )));
        }
    };

    Ok((clause, binds))
}

fn timeseries_filter_clause(filter: &Filter) -> Result<(String, Vec<SqlBindValue>)> {
    match filter.field.as_str() {
        "gateway_id" | "agent_id" | "metric_name" | "metric_type" | "device_id"
        | "target_device_ip" | "partition" => text_clause(filter.field.as_str(), filter),
        "if_index" => int_clause("if_index", filter, false),
        "value" => float_clause("value", filter, true),
        // Completes the tag story. Filters already accept `tags.<key>` on the raw
        // and stats paths, and `series:tags.<key>` splits a bucketed aggregate by
        // one — but a bucketed query could not be SCOPED to a tag, so "clients at
        // ORD over time" was inexpressible while "clients per site over time" was
        // fine. The key is validated before interpolation, as everywhere else.
        field if field.starts_with("tags.") => {
            let key = field.strip_prefix("tags.").unwrap_or_default();
            if !is_valid_jsonb_key(key) {
                return Err(ServiceError::InvalidRequest(format!(
                    "invalid tag key '{key}' in downsample filter"
                )));
            }

            text_clause(&format!("tags->>'{key}'"), filter)
        }
        other => Err(ServiceError::InvalidRequest(format!(
            "unsupported filter field for downsample timeseries_metrics: '{other}'"
        ))),
    }
}

fn cpu_filter_clause(filter: &Filter) -> Result<(String, Vec<SqlBindValue>)> {
    match filter.field.as_str() {
        "gateway_id" | "agent_id" | "host_id" | "device_id" | "partition" | "cluster" | "label" => {
            text_clause(filter.field.as_str(), filter)
        }
        "core_id" => int_clause("core_id", filter, false),
        "usage_percent" => float_clause("usage_percent", filter, true),
        "frequency_hz" => float_clause("frequency_hz", filter, true),
        other => Err(ServiceError::InvalidRequest(format!(
            "unsupported filter field for downsample cpu_metrics: '{other}'"
        ))),
    }
}

fn memory_filter_clause(filter: &Filter) -> Result<(String, Vec<SqlBindValue>)> {
    match filter.field.as_str() {
        "gateway_id" | "agent_id" | "host_id" | "device_id" | "partition" => {
            text_clause(filter.field.as_str(), filter)
        }
        "usage_percent" => float_clause("usage_percent", filter, false),
        "total_bytes" => int_clause("total_bytes", filter, false),
        "used_bytes" => int_clause("used_bytes", filter, false),
        "available_bytes" => int_clause("available_bytes", filter, false),
        other => Err(ServiceError::InvalidRequest(format!(
            "unsupported filter field for downsample memory_metrics: '{other}'"
        ))),
    }
}

fn disk_filter_clause(filter: &Filter) -> Result<(String, Vec<SqlBindValue>)> {
    match filter.field.as_str() {
        "gateway_id" | "agent_id" | "host_id" | "device_id" | "partition" | "mount_point"
        | "device_name" => text_clause(filter.field.as_str(), filter),
        "usage_percent" => float_clause("usage_percent", filter, false),
        "total_bytes" => int_clause("total_bytes", filter, false),
        "used_bytes" => int_clause("used_bytes", filter, false),
        "available_bytes" => int_clause("available_bytes", filter, false),
        other => Err(ServiceError::InvalidRequest(format!(
            "unsupported filter field for downsample disk_metrics: '{other}'"
        ))),
    }
}

fn process_filter_clause(filter: &Filter) -> Result<(String, Vec<SqlBindValue>)> {
    match filter.field.as_str() {
        "gateway_id" | "agent_id" | "host_id" | "device_id" | "partition" | "name" | "status"
        | "start_time" => text_clause(filter.field.as_str(), filter),
        "pid" => int_clause("pid", filter, false),
        "cpu_usage" => float_clause("cpu_usage", filter, true),
        "memory_usage" => int_clause("memory_usage", filter, true),
        other => Err(ServiceError::InvalidRequest(format!(
            "unsupported filter field for downsample process_metrics: '{other}'"
        ))),
    }
}

#[cfg(test)]
mod device_addr_tests {
    use super::*;
    use crate::parser::FilterValue;

    fn device_addr(op: FilterOp, value: FilterValue) -> Filter {
        Filter {
            field: "device_addr".into(),
            op,
            value,
        }
    }

    /// The downsample path is what feeds the Traffic Profile chart and the
    /// sparkline. It rejects `device_id:` outright, so before `device_addr`
    /// existed a device scope produced no timeseries at all.
    #[test]
    fn device_addr_matches_either_endpoint_or_the_sampler() {
        let filter = device_addr(
            FilterOp::In,
            FilterValue::List(vec!["192.168.6.1".into(), "192.168.7.1".into()]),
        );

        let (clause, binds) =
            flows_filter_clause(&filter).expect("device_addr must translate for downsample");

        assert!(clause.contains("src_endpoint_ip"), "missing src: {clause}");
        assert!(clause.contains("dst_endpoint_ip"), "missing dst: {clause}");
        assert!(
            clause.contains("sampler_address"),
            "missing sampler: {clause}"
        );
        // One array bind per arm; a mismatch here shifts every later placeholder.
        assert_eq!(binds.len(), 3, "expected one bind per arm, got {binds:?}");
    }

    #[test]
    fn device_addr_rejects_an_empty_address_list() {
        let filter = device_addr(FilterOp::In, FilterValue::List(Vec::new()));

        let err = flows_filter_clause(&filter).expect_err("empty device_addr must be rejected");
        assert!(
            err.to_string().contains("at least one address"),
            "expected an explicit empty-scope error, got: {err}"
        );
    }

    #[test]
    fn device_addr_rejects_operators_it_cannot_express() {
        let filter = device_addr(FilterOp::Like, FilterValue::Scalar("192.168.%".into()));

        let err = flows_filter_clause(&filter).expect_err("device_addr must reject LIKE");
        assert!(
            err.to_string().contains("equality and list matching"),
            "expected an operator error, got: {err}"
        );
    }
}
