use super::bind::SqlBindValue;
use crate::query::flows::{
    FLOW_APP_EXPR, FLOW_DIRECTION_EXPR, FLOW_EXPORTER_NAME_EXPR, FLOW_IN_IF_NAME_EXPR,
    FLOW_IN_IF_SPEED_BPS_EXPR, FLOW_INPUT_SNMP_EXPR, FLOW_OUT_IF_NAME_EXPR,
    FLOW_OUT_IF_SPEED_BPS_EXPR, FLOW_OUTPUT_SNMP_EXPR, FLOW_PROTOCOL_GROUP_EXPR,
};
use crate::{
    error::{Result, ServiceError},
    parser::{Entity, Filter, FilterOp},
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
