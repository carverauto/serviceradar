use super::{
    availability::freshness_threshold,
    composite::{filter_values as composite_filter_values, parse_composite_field},
    identity::collect_mac_params,
    ip::collect_ip_params,
    jsonb::{is_valid_jsonb_key, parse_bool},
    text::collect_text_params,
};
use crate::{
    error::{Result, ServiceError},
    parser::{Filter, FilterOp, FilterValue},
    query::BindParam,
};

pub(in crate::query::devices) fn collect_filter_params(
    params: &mut Vec<BindParam>,
    filter: &Filter,
) -> Result<()> {
    match filter.field.as_str() {
        "uid" => collect_text_params(params, filter, true),
        "hostname" => collect_text_params(params, filter, false),
        "vlan_uid" => collect_text_params(params, filter, true),
        "partition" => collect_text_params(params, filter, true),
        "mac" => collect_mac_params(params, filter),
        "ip" => collect_ip_params(params, filter),
        "gateway_id"
        | "agent_id"
        | "availability_source_agent_id"
        | "availability_source_agent"
        | "primary_availability_source"
        | "primary_availability_source_agent_id"
        | "available_from_agent"
        | "unavailable_from_agent"
        | "vendor_name"
        | "model"
        | "risk_level" => {
            params.push(BindParam::Text(filter.value.as_scalar()?.to_string()));
            Ok(())
        }
        "cve" | "cve_id" => collect_match_cve_params(params, filter),
        "kev" => {
            let _ = parse_bool(filter.value.as_scalar()?)?;
            params.push(BindParam::Bool(true));
            Ok(())
        }
        "type" | "device_type" => collect_device_type_params(params, filter),
        "availability_source_fresh_within" | "availability_source_stale_after" => {
            params.push(BindParam::timestamptz(freshness_threshold(filter)?));
            Ok(())
        }
        "first_seen" | "first_seen_time" => {
            if !matches!(filter.op, FilterOp::Eq | FilterOp::NotEq) {
                return Err(ServiceError::InvalidRequest(
                    "first_seen filter only supports equality (for example first_seen:last_7d)"
                        .into(),
                ));
            }
            let range = super::seen::first_seen_range(filter)?;
            params.push(BindParam::timestamptz(range.start));
            params.push(BindParam::timestamptz(range.end));
            Ok(())
        }
        "tags" => match filter.op {
            FilterOp::Eq | FilterOp::NotEq => {
                params.push(BindParam::Text(filter.value.as_scalar()?.to_string()));
                Ok(())
            }
            FilterOp::In | FilterOp::NotIn => {
                let values = filter.value.as_list()?.to_vec();
                if values.is_empty() {
                    return Ok(());
                }
                params.push(BindParam::TextArray(values));
                Ok(())
            }
            _ => Err(ServiceError::InvalidRequest(
                "tags filter only supports equality and list filters".into(),
            )),
        },
        "type_id" => {
            let type_id: i64 =
                filter.value.as_scalar()?.parse().map_err(|_| {
                    ServiceError::InvalidRequest("type_id must be an integer".into())
                })?;
            params.push(BindParam::Int(type_id));
            Ok(())
        }
        "is_available" => {
            params.push(BindParam::Bool(parse_bool(filter.value.as_scalar()?)?));
            Ok(())
        }
        "is_active" => {
            params.push(BindParam::Bool(parse_bool(filter.value.as_scalar()?)?));
            Ok(())
        }
        "include_inactive" => {
            let _ = parse_bool(filter.value.as_scalar()?)?;
            Ok(())
        }
        "deleted" => {
            let _ = parse_bool(filter.value.as_scalar()?)?;
            Ok(())
        }
        // Derived predicate over metadata/discovery_sources literals: binds nothing.
        "awx_managed" => {
            let _ = parse_bool(filter.value.as_scalar()?)?;
            Ok(())
        }
        "discovery_sources" => {
            let values = match &filter.value {
                FilterValue::Scalar(v) => vec![v.to_string()],
                FilterValue::List(list) => list.clone(),
            };
            if values.is_empty() {
                return Ok(());
            }
            params.push(BindParam::TextArray(values));
            Ok(())
        }
        // Fixed JSONB path fields. These share apply_jsonb_text_filter with the
        // dynamic tags.*/metadata.* fields, so they must accept the same
        // operators -- otherwise `os.name:(Linux,Windows)` executes but fails
        // to translate.
        "os.name"
        | "os.version"
        | "os.type"
        | "hw_info.serial_number"
        | "hw_info.cpu_type"
        | "hw_info.cpu_architecture"
        | "switch_port_attachment.switch_hostname"
        | "switch_port_attachment.port"
        | "switch_port_attachment.source" => {
            let (column, key) = filter
                .field
                .split_once('.')
                .expect("fixed JSONB field always contains a dot");
            collect_jsonb_subkey_params(params, filter, column, key)
        }
        // Dynamic composite.* fields.
        //
        // Mirrors the composite arm in `apply_filter`: one Text bind for the
        // slug, then one Array<Text> bind for the values, in that order. These
        // are parallel matches in two files, and a drift between them does not
        // fail to compile -- it produces a placeholder/parameter mismatch when
        // the query runs. The empty-values early return must mirror it too.
        field if field.starts_with("composite.") => {
            let (slug, _column) = parse_composite_field(field).ok_or_else(|| {
                ServiceError::InvalidRequest(format!("invalid composite check field '{field}'"))
            })?;

            let values = composite_filter_values(filter);
            if values.is_empty() {
                return Ok(());
            }

            params.push(BindParam::Text(slug));
            params.push(BindParam::TextArray(values));
            Ok(())
        }
        // Dynamic metadata.* fields
        field if field.starts_with("metadata.") => {
            let key = field.strip_prefix("metadata.").unwrap();
            collect_jsonb_subkey_params(params, filter, "metadata", key)
        }
        // Dynamic tags.* fields
        field if field.starts_with("tags.") => {
            let key = field.strip_prefix("tags.").unwrap();
            collect_jsonb_subkey_params(params, filter, "tags", key)
        }
        other => Err(ServiceError::InvalidRequest(format!(
            "unsupported filter field '{other}'"
        ))),
    }
}

fn collect_match_cve_params(params: &mut Vec<BindParam>, filter: &Filter) -> Result<()> {
    match filter.op {
        FilterOp::Eq | FilterOp::NotEq | FilterOp::In | FilterOp::NotIn => {
            let values = crate::query::advisory::cve_eq_values(filter)?;
            if values.is_empty() {
                return Ok(());
            }
            params.push(BindParam::TextArray(values));
            Ok(())
        }
        FilterOp::Like | FilterOp::NotLike => {
            params.push(BindParam::Text(filter.value.as_scalar()?.to_string()));
            Ok(())
        }
        _ => Err(ServiceError::InvalidRequest(
            "cve filter only supports equality, membership, and % wildcards".into(),
        )),
    }
}

fn collect_device_type_params(params: &mut Vec<BindParam>, filter: &Filter) -> Result<()> {
    match filter.op {
        FilterOp::Eq | FilterOp::NotEq | FilterOp::Like | FilterOp::NotLike => {
            params.push(BindParam::Text(filter.value.as_scalar()?.to_string()));
            Ok(())
        }
        FilterOp::In | FilterOp::NotIn => {
            let values = filter.value.as_list()?.to_vec();
            if values.is_empty() {
                return Ok(());
            }
            params.push(BindParam::TextArray(values));
            Ok(())
        }
        _ => Err(ServiceError::InvalidRequest(
            "device_type filter only supports equality, LIKE, and list filters".into(),
        )),
    }
}

/// Bind params for a `tags.<key>` / `metadata.<key>` filter.
///
/// This must accept exactly the operators `jsonb::apply_jsonb_text_filter`
/// builds SQL for -- the two run over the same filter and a mismatch shows up
/// as a placeholder/parameter arity error at execution time, not here.
fn collect_jsonb_subkey_params(
    params: &mut Vec<BindParam>,
    filter: &Filter,
    column: &str,
    key: &str,
) -> Result<()> {
    if !is_valid_jsonb_key(key) {
        return Err(ServiceError::InvalidRequest(format!(
            "invalid {column} key '{key}'"
        )));
    }

    match filter.op {
        FilterOp::Eq | FilterOp::NotEq | FilterOp::Like | FilterOp::NotLike => {
            params.push(BindParam::Text(filter.value.as_scalar()?.to_string()));
            Ok(())
        }
        FilterOp::In | FilterOp::NotIn => {
            let values = filter.value.as_list()?.to_vec();
            if values.is_empty() {
                return Ok(());
            }
            params.push(BindParam::TextArray(values));
            Ok(())
        }
        _ => Err(ServiceError::InvalidRequest(format!(
            "JSONB field '{column}.{key}' only supports equality, LIKE, and list filters"
        ))),
    }
}
