use super::bind::SqlBindValue;
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
        _ => Err(ServiceError::InvalidRequest(
            "downsample is only supported for metric entities".into(),
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
