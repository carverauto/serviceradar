use super::bind::DeviceSqlBindValue;
use crate::{
    error::{Result, ServiceError},
    parser::{Filter, FilterOp},
    query::normalize_mac_value,
    time::parse_time_value,
};
use chrono::Utc;

pub(super) fn build_grouped_text_clause(
    column: &str,
    filter: &Filter,
    binds: &mut Vec<DeviceSqlBindValue>,
) -> Result<String> {
    match filter.op {
        FilterOp::Eq => {
            binds.push(DeviceSqlBindValue::Text(
                filter.value.as_scalar()?.to_string(),
            ));
            Ok(format!("{column} = ?"))
        }
        FilterOp::NotEq => {
            binds.push(DeviceSqlBindValue::Text(
                filter.value.as_scalar()?.to_string(),
            ));
            Ok(format!("({column} IS NULL OR {column} <> ?)"))
        }
        FilterOp::Like => {
            binds.push(DeviceSqlBindValue::Text(
                filter.value.as_scalar()?.to_string(),
            ));
            Ok(format!("{column} ILIKE ?"))
        }
        FilterOp::NotLike => {
            binds.push(DeviceSqlBindValue::Text(
                filter.value.as_scalar()?.to_string(),
            ));
            Ok(format!("({column} IS NULL OR {column} NOT ILIKE ?)"))
        }
        FilterOp::In => {
            let values = filter.value.as_list()?.to_vec();
            if values.is_empty() {
                return Ok("1=1".to_string());
            }
            binds.push(DeviceSqlBindValue::TextArray(values));
            Ok(format!("{column} = ANY(?)"))
        }
        FilterOp::NotIn => {
            let values = filter.value.as_list()?.to_vec();
            if values.is_empty() {
                return Ok("1=1".to_string());
            }
            binds.push(DeviceSqlBindValue::TextArray(values));
            Ok(format!("({column} IS NULL OR NOT ({column} = ANY(?)))"))
        }
        _ => Err(ServiceError::InvalidRequest(format!(
            "unsupported operator for text filter: {:?}",
            filter.op
        ))),
    }
}

pub(super) fn build_grouped_device_type_clause(
    filter: &Filter,
    binds: &mut Vec<DeviceSqlBindValue>,
) -> Result<String> {
    let column = "COALESCE(NULLIF(trim(type), ''), 'Unknown')";

    match filter.op {
        FilterOp::Eq => {
            binds.push(DeviceSqlBindValue::Text(
                filter.value.as_scalar()?.to_string(),
            ));
            Ok(format!("{column} = ?"))
        }
        FilterOp::NotEq => {
            binds.push(DeviceSqlBindValue::Text(
                filter.value.as_scalar()?.to_string(),
            ));
            Ok(format!("{column} <> ?"))
        }
        FilterOp::In => {
            let values = filter.value.as_list()?.to_vec();
            if values.is_empty() {
                return Ok("1=1".to_string());
            }
            binds.push(DeviceSqlBindValue::TextArray(values));
            Ok(format!("{column} = ANY(?)"))
        }
        FilterOp::NotIn => {
            let values = filter.value.as_list()?.to_vec();
            if values.is_empty() {
                return Ok("1=1".to_string());
            }
            binds.push(DeviceSqlBindValue::TextArray(values));
            Ok(format!("NOT ({column} = ANY(?))"))
        }
        FilterOp::Like => {
            binds.push(DeviceSqlBindValue::Text(
                filter.value.as_scalar()?.to_string(),
            ));
            Ok(format!("{column} ILIKE ?"))
        }
        FilterOp::NotLike => {
            binds.push(DeviceSqlBindValue::Text(
                filter.value.as_scalar()?.to_string(),
            ));
            Ok(format!("NOT ({column} ILIKE ?)"))
        }
        _ => Err(ServiceError::InvalidRequest(
            "device_type filter only supports equality, LIKE, and list filters".into(),
        )),
    }
}

pub(super) fn build_grouped_jsonb_text_clause(
    column: &str,
    key: &str,
    filter: &Filter,
    binds: &mut Vec<DeviceSqlBindValue>,
) -> Result<String> {
    let jsonb_expr = format!("{column}->>'{key}'");

    match filter.op {
        FilterOp::Eq => {
            binds.push(DeviceSqlBindValue::Text(
                filter.value.as_scalar()?.to_string(),
            ));
            Ok(format!("{jsonb_expr} = ?"))
        }
        FilterOp::NotEq => {
            binds.push(DeviceSqlBindValue::Text(
                filter.value.as_scalar()?.to_string(),
            ));
            Ok(format!("({jsonb_expr} IS NULL OR {jsonb_expr} <> ?)"))
        }
        FilterOp::Like => {
            binds.push(DeviceSqlBindValue::Text(
                filter.value.as_scalar()?.to_string(),
            ));
            Ok(format!("{jsonb_expr} ILIKE ?"))
        }
        FilterOp::NotLike => {
            binds.push(DeviceSqlBindValue::Text(
                filter.value.as_scalar()?.to_string(),
            ));
            Ok(format!(
                "({jsonb_expr} IS NULL OR {jsonb_expr} NOT ILIKE ?)"
            ))
        }
        // List form, e.g. tags.gate:(B40,B41). Mirrors
        // `filters::jsonb::apply_jsonb_text_filter` so a filter behaves the
        // same whether or not the query also carries a `stats:` clause.
        FilterOp::In | FilterOp::NotIn => {
            let values = filter.value.as_list()?.to_vec();
            if values.is_empty() {
                return Ok("1=1".to_string());
            }

            binds.push(DeviceSqlBindValue::TextArray(values));
            if matches!(filter.op, FilterOp::NotIn) {
                Ok(format!(
                    "({jsonb_expr} IS NULL OR NOT ({jsonb_expr} = ANY(?)))"
                ))
            } else {
                Ok(format!("{jsonb_expr} = ANY(?)"))
            }
        }
        _ => Err(ServiceError::InvalidRequest(format!(
            "JSONB field '{column}.{key}' only supports equality, LIKE, and list filters"
        ))),
    }
}

/// Bare `tags:<key>` is a JSONB key-existence check, matching
/// `filters::jsonb::apply_tags_filter`.
///
/// This path spells the check as `jsonb_exists` / `jsonb_exists_any` rather
/// than the `?` and `?|` operators the Diesel path uses. Grouped stats build
/// raw SQL that `rewrite_placeholders` post-processes, and that pass turns
/// *every* `?` into `$n` -- a literal `?` operator here would be rewritten into
/// a bind placeholder and the query would fail to parse.
pub(super) fn build_grouped_tags_clause(
    filter: &Filter,
    binds: &mut Vec<DeviceSqlBindValue>,
) -> Result<String> {
    match filter.op {
        FilterOp::Eq | FilterOp::NotEq => {
            binds.push(DeviceSqlBindValue::Text(
                filter.value.as_scalar()?.to_string(),
            ));
            if matches!(filter.op, FilterOp::NotEq) {
                Ok("NOT jsonb_exists(coalesce(tags, '{}'::jsonb), ?)".to_string())
            } else {
                Ok("jsonb_exists(coalesce(tags, '{}'::jsonb), ?)".to_string())
            }
        }
        FilterOp::In | FilterOp::NotIn => {
            let values = filter.value.as_list()?.to_vec();
            if values.is_empty() {
                return Ok("1=1".to_string());
            }

            binds.push(DeviceSqlBindValue::TextArray(values));
            if matches!(filter.op, FilterOp::NotIn) {
                Ok("NOT jsonb_exists_any(coalesce(tags, '{}'::jsonb), ?)".to_string())
            } else {
                Ok("jsonb_exists_any(coalesce(tags, '{}'::jsonb), ?)".to_string())
            }
        }
        _ => Err(ServiceError::InvalidRequest(
            "tags filter only supports equality and list filters".into(),
        )),
    }
}

pub(super) fn build_grouped_agent_availability_clause(
    filter: &Filter,
    available: bool,
    binds: &mut Vec<DeviceSqlBindValue>,
) -> Result<String> {
    if !matches!(filter.op, FilterOp::Eq) {
        return Err(ServiceError::InvalidRequest(
            "per-agent availability filters only support equality".into(),
        ));
    }

    binds.push(DeviceSqlBindValue::Text(
        filter.value.as_scalar()?.to_string(),
    ));

    Ok(format!(
        "EXISTS (SELECT 1 FROM device_agent_availability daa WHERE daa.device_uid = ocsf_devices.uid AND daa.agent_id = ? AND daa.is_available = {available})"
    ))
}

pub(super) fn build_grouped_availability_source_freshness_clause(
    filter: &Filter,
    fresh: bool,
    binds: &mut Vec<DeviceSqlBindValue>,
) -> Result<String> {
    if !matches!(filter.op, FilterOp::Eq) {
        return Err(ServiceError::InvalidRequest(
            "availability source freshness filters only support equality".into(),
        ));
    }

    let threshold = filter
        .value
        .as_scalar()
        .and_then(parse_time_value)?
        .resolve(Utc::now())?
        .start;

    binds.push(DeviceSqlBindValue::Timestamp(threshold));

    let exists_op = if fresh { "EXISTS" } else { "NOT EXISTS" };

    Ok(format!(
        "NULLIF(BTRIM(ocsf_devices.availability_source_agent_id), '') IS NOT NULL \
         AND {exists_op} (SELECT 1 FROM device_agent_availability daa \
         WHERE daa.device_uid = ocsf_devices.uid \
         AND daa.agent_id = ocsf_devices.availability_source_agent_id \
         AND daa.checked_at >= ?)"
    ))
}

pub(super) fn build_grouped_mac_clause(
    filter: &Filter,
    binds: &mut Vec<DeviceSqlBindValue>,
) -> Result<String> {
    let norm_col = "lower(regexp_replace(mac, '[^0-9a-fA-F]', '', 'g'))";

    match filter.op {
        FilterOp::Eq => {
            let normalized = normalize_mac_value(filter.value.as_scalar()?, false)?;
            binds.push(DeviceSqlBindValue::Text(normalized));
            Ok(format!("{norm_col} = ?"))
        }
        FilterOp::NotEq => {
            let normalized = normalize_mac_value(filter.value.as_scalar()?, false)?;
            binds.push(DeviceSqlBindValue::Text(normalized));
            Ok(format!("(mac IS NULL OR {norm_col} <> ?)"))
        }
        FilterOp::Like => {
            let normalized = normalize_mac_value(filter.value.as_scalar()?, true)?;
            binds.push(DeviceSqlBindValue::Text(normalized));
            Ok(format!("{norm_col} LIKE ?"))
        }
        FilterOp::NotLike => {
            let normalized = normalize_mac_value(filter.value.as_scalar()?, true)?;
            binds.push(DeviceSqlBindValue::Text(normalized));
            Ok(format!("(mac IS NULL OR {norm_col} NOT LIKE ?)"))
        }
        _ => Err(ServiceError::InvalidRequest(
            "mac filter only supports equality and LIKE operators".into(),
        )),
    }
}
