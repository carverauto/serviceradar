use super::{bind::DeviceSqlBindValue, clauses};
use crate::{
    error::{Result, ServiceError},
    parser::{Filter, FilterOp, FilterValue},
    query::is_negated_membership_op,
};

pub(super) fn build_grouped_stats_filter_clause(
    filter: &Filter,
) -> Result<Option<(String, Vec<DeviceSqlBindValue>)>> {
    let mut binds = Vec::new();
    let clause = match filter.field.as_str() {
        "uid" => clauses::build_grouped_text_clause("uid", filter, &mut binds)?,
        "hostname" => clauses::build_grouped_text_clause("hostname", filter, &mut binds)?,
        "ip" => clauses::build_grouped_text_clause("ip", filter, &mut binds)?,
        "mac" => clauses::build_grouped_mac_clause(filter, &mut binds)?,
        "gateway_id" => clauses::build_grouped_text_clause("gateway_id", filter, &mut binds)?,
        "agent_id" => clauses::build_grouped_text_clause("agent_id", filter, &mut binds)?,
        "availability_source_agent_id"
        | "availability_source_agent"
        | "primary_availability_source"
        | "primary_availability_source_agent_id" => {
            clauses::build_grouped_text_clause("availability_source_agent_id", filter, &mut binds)?
        }
        "available_from_agent" => {
            clauses::build_grouped_agent_availability_clause(filter, true, &mut binds)?
        }
        "unavailable_from_agent" => {
            clauses::build_grouped_agent_availability_clause(filter, false, &mut binds)?
        }
        "availability_source_fresh_within" => {
            clauses::build_grouped_availability_source_freshness_clause(filter, true, &mut binds)?
        }
        "availability_source_stale_after" => {
            clauses::build_grouped_availability_source_freshness_clause(filter, false, &mut binds)?
        }
        "type" | "device_type" => clauses::build_grouped_device_type_clause(filter, &mut binds)?,
        "type_id" => build_type_id_clause(filter, &mut binds)?,
        "vendor_name" => clauses::build_grouped_text_clause("vendor_name", filter, &mut binds)?,
        "model" => clauses::build_grouped_text_clause("model", filter, &mut binds)?,
        "risk_level" => clauses::build_grouped_text_clause("risk_level", filter, &mut binds)?,
        "is_available" => build_bool_clause("is_available", filter, &mut binds)?,
        "is_active" => build_active_clause(filter, &mut binds)?,
        "include_inactive" => {
            let _ = super::super::filters::parse_bool(filter.value.as_scalar()?)?;
            return Ok(None);
        }
        "deleted" => build_deleted_clause(filter)?,
        "awx_managed" => build_awx_managed_clause(filter)?,
        "discovery_sources" => build_discovery_sources_clause(filter, &mut binds)?,
        "tags" => clauses::build_grouped_tags_clause(filter, &mut binds)?,
        field if field.starts_with("metadata.") => {
            let key = field.strip_prefix("metadata.").unwrap();
            if !super::super::filters::is_valid_jsonb_key(key) {
                return Err(ServiceError::InvalidRequest(format!(
                    "invalid metadata key '{key}'"
                )));
            }
            clauses::build_grouped_jsonb_text_clause("metadata", key, filter, &mut binds)?
        }
        field if field.starts_with("tags.") => {
            let key = field.strip_prefix("tags.").unwrap();
            if !super::super::filters::is_valid_jsonb_key(key) {
                return Err(ServiceError::InvalidRequest(format!(
                    "invalid tags key '{key}'"
                )));
            }
            clauses::build_grouped_jsonb_text_clause("tags", key, filter, &mut binds)?
        }
        other => {
            return Err(ServiceError::InvalidRequest(format!(
                "unsupported filter field for device stats: '{other}'"
            )));
        }
    };

    Ok(Some((clause, binds)))
}

fn build_type_id_clause(filter: &Filter, binds: &mut Vec<DeviceSqlBindValue>) -> Result<String> {
    let type_id: i64 = filter
        .value
        .as_scalar()?
        .parse()
        .map_err(|_| ServiceError::InvalidRequest("type_id must be an integer".into()))?;
    binds.push(DeviceSqlBindValue::Int(type_id));

    match filter.op {
        FilterOp::Eq => Ok("type_id = ?".to_string()),
        FilterOp::NotEq => Ok("(type_id IS NULL OR type_id <> ?)".to_string()),
        _ => Err(ServiceError::InvalidRequest(
            "type_id filter only supports equality".into(),
        )),
    }
}

fn build_bool_clause(
    column: &str,
    filter: &Filter,
    binds: &mut Vec<DeviceSqlBindValue>,
) -> Result<String> {
    let value = super::super::filters::parse_bool(filter.value.as_scalar()?)?;
    binds.push(DeviceSqlBindValue::Bool(value));

    match filter.op {
        FilterOp::Eq => Ok(format!("{column} = ?")),
        FilterOp::NotEq => Ok(format!("({column} IS NULL OR {column} <> ?)")),
        _ => Err(ServiceError::InvalidRequest(format!(
            "{column} filter only supports equality"
        ))),
    }
}

fn build_active_clause(filter: &Filter, binds: &mut Vec<DeviceSqlBindValue>) -> Result<String> {
    let value = super::super::filters::parse_bool(filter.value.as_scalar()?)?;
    binds.push(DeviceSqlBindValue::Bool(value));

    match filter.op {
        FilterOp::Eq => Ok("COALESCE(is_active, true) = ?".to_string()),
        FilterOp::NotEq => Ok("COALESCE(is_active, true) <> ?".to_string()),
        _ => Err(ServiceError::InvalidRequest(
            "is_active filter only supports equality".into(),
        )),
    }
}

fn build_deleted_clause(filter: &Filter) -> Result<String> {
    let value = super::super::filters::parse_bool(filter.value.as_scalar()?)?;
    match filter.op {
        FilterOp::Eq => Ok(if value {
            "deleted_at IS NOT NULL".to_string()
        } else {
            "deleted_at IS NULL".to_string()
        }),
        FilterOp::NotEq => Ok(if value {
            "deleted_at IS NULL".to_string()
        } else {
            "deleted_at IS NOT NULL".to_string()
        }),
        _ => Err(ServiceError::InvalidRequest(
            "deleted filter only supports equality".into(),
        )),
    }
}

fn build_awx_managed_clause(filter: &Filter) -> Result<String> {
    let managed = super::super::filters::parse_bool(filter.value.as_scalar()?)?;
    let want_managed = match filter.op {
        FilterOp::Eq => managed,
        FilterOp::NotEq => !managed,
        _ => {
            return Err(ServiceError::InvalidRequest(
                "awx_managed filter only supports equality".into(),
            ));
        }
    };
    let predicate = super::super::filters::AWX_MANAGED_PREDICATE;
    Ok(if want_managed {
        predicate.to_string()
    } else {
        format!("NOT {predicate}")
    })
}

fn build_discovery_sources_clause(
    filter: &Filter,
    binds: &mut Vec<DeviceSqlBindValue>,
) -> Result<String> {
    let values = match &filter.value {
        FilterValue::Scalar(v) => vec![v.to_string()],
        FilterValue::List(list) => list.clone(),
    };
    if values.is_empty() {
        return Ok("1=1".to_string());
    }

    binds.push(DeviceSqlBindValue::TextArray(values));
    match &filter.op {
        FilterOp::In | FilterOp::Eq => {
            Ok("coalesce(discovery_sources, ARRAY[]::text[]) && ?".to_string())
        }
        op if is_negated_membership_op(op) => {
            Ok("NOT (coalesce(discovery_sources, ARRAY[]::text[]) && ?)".to_string())
        }
        _ => Err(ServiceError::InvalidRequest(
            "discovery_sources filter only supports equality and list filters".into(),
        )),
    }
}
