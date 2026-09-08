use crate::{
    error::{Result, ServiceError},
    parser::{Filter, FilterOp, FilterValue},
    query::BindParam,
};

const MAX_IP_ADDRESS_FILTER_VALUES: usize = 64;

pub(super) fn extract_latest_filter(filters: &[Filter]) -> Result<(bool, Vec<Filter>)> {
    let mut latest_only = false;
    let mut remaining = Vec::new();

    for filter in filters {
        if filter.field == "latest" {
            if !matches!(filter.op, FilterOp::Eq) {
                return Err(ServiceError::InvalidRequest(
                    "latest filter only supports equality".into(),
                ));
            }
            let value = filter.value.as_scalar()?.trim().to_lowercase();
            latest_only = parse_bool(&value).ok_or_else(|| {
                ServiceError::InvalidRequest("latest filter expects boolean true/false".into())
            })?;
        } else {
            remaining.push(filter.clone());
        }
    }

    Ok((latest_only, remaining))
}

pub(super) fn filters_need_interface_settings(filters: &[Filter]) -> bool {
    filters
        .iter()
        .any(|filter| matches!(filter.field.as_str(), "favorited" | "metrics_enabled"))
}

pub(super) fn build_filter_clause(
    filter: &Filter,
    binds: &mut Vec<BindParam>,
    bind_idx: &mut usize,
) -> Result<Option<String>> {
    match filter.field.as_str() {
        "device_id" => build_text_clause("di.device_id", filter, binds, bind_idx),
        "device_ip" | "ip" => build_text_clause("di.device_ip", filter, binds, bind_idx),
        "gateway_id" => build_text_clause("di.gateway_id", filter, binds, bind_idx),
        "agent_id" => build_text_clause("di.agent_id", filter, binds, bind_idx),
        "interface_uid" => build_text_clause("di.interface_uid", filter, binds, bind_idx),
        "if_name" => build_text_clause("di.if_name", filter, binds, bind_idx),
        "if_descr" | "description" => build_text_clause("di.if_descr", filter, binds, bind_idx),
        "if_alias" => build_text_clause("di.if_alias", filter, binds, bind_idx),
        "if_type_name" => build_text_clause("di.if_type_name", filter, binds, bind_idx),
        "interface_kind" => build_text_clause("di.interface_kind", filter, binds, bind_idx),
        "duplex" => build_text_clause("di.duplex", filter, binds, bind_idx),
        "if_phys_address" | "mac" => build_mac_clause(filter, binds, bind_idx),
        "if_index" => build_int_clause("di.if_index", filter, binds, bind_idx),
        "if_type" => build_int_clause("di.if_type", filter, binds, bind_idx),
        "if_admin_status" | "admin_status" => {
            build_int_clause("di.if_admin_status", filter, binds, bind_idx)
        }
        "if_oper_status" | "oper_status" | "status" => {
            build_int_clause("di.if_oper_status", filter, binds, bind_idx)
        }
        "if_speed" | "speed" | "speed_bps" => build_int_clause(
            "COALESCE(di.speed_bps, di.if_speed)",
            filter,
            binds,
            bind_idx,
        ),
        "mtu" => build_int_clause("di.mtu", filter, binds, bind_idx),
        "ip_addresses" | "ip_address" => build_ip_addresses_clause(filter, binds, bind_idx),
        // Boolean filters from interface_settings (via LEFT JOIN)
        "favorited" => build_bool_clause("COALESCE(ifs.favorited, false)", filter, binds, bind_idx),
        "metrics_enabled" => build_bool_clause(
            "COALESCE(ifs.metrics_enabled, false)",
            filter,
            binds,
            bind_idx,
        ),
        other => Err(ServiceError::InvalidRequest(format!(
            "unsupported filter field '{other}'"
        ))),
    }
}

fn build_text_clause(
    column: &str,
    filter: &Filter,
    binds: &mut Vec<BindParam>,
    bind_idx: &mut usize,
) -> Result<Option<String>> {
    match filter.op {
        FilterOp::Eq => {
            let value = filter.value.as_scalar()?.to_string();
            let clause = format!("{column} = ${bind_idx}");
            binds.push(BindParam::Text(value));
            *bind_idx += 1;
            Ok(Some(clause))
        }
        FilterOp::NotEq => {
            let value = filter.value.as_scalar()?.to_string();
            let clause = format!("{column} != ${bind_idx}");
            binds.push(BindParam::Text(value));
            *bind_idx += 1;
            Ok(Some(clause))
        }
        FilterOp::Like => {
            let value = filter.value.as_scalar()?.to_string();
            let clause = format!("{column} ILIKE ${bind_idx}");
            binds.push(BindParam::Text(value));
            *bind_idx += 1;
            Ok(Some(clause))
        }
        FilterOp::NotLike => {
            let value = filter.value.as_scalar()?.to_string();
            let clause = format!("{column} NOT ILIKE ${bind_idx}");
            binds.push(BindParam::Text(value));
            *bind_idx += 1;
            Ok(Some(clause))
        }
        FilterOp::In => {
            let values = filter.value.as_list()?.to_vec();
            if values.is_empty() {
                return Ok(None);
            }
            let clause = format!("{column} = ANY(${bind_idx})");
            binds.push(BindParam::TextArray(values));
            *bind_idx += 1;
            Ok(Some(clause))
        }
        FilterOp::NotIn => {
            let values = filter.value.as_list()?.to_vec();
            if values.is_empty() {
                return Ok(None);
            }
            let clause = format!("NOT ({column} = ANY(${bind_idx}))");
            binds.push(BindParam::TextArray(values));
            *bind_idx += 1;
            Ok(Some(clause))
        }
        _ => Err(ServiceError::InvalidRequest(format!(
            "unsupported operator for text filter: {:?}",
            filter.op
        ))),
    }
}

fn build_mac_clause(
    filter: &Filter,
    binds: &mut Vec<BindParam>,
    bind_idx: &mut usize,
) -> Result<Option<String>> {
    let column = "lower(regexp_replace(di.if_phys_address, '[^0-9a-fA-F]', '', 'g'))";

    match filter.op {
        FilterOp::Eq | FilterOp::NotEq | FilterOp::Like | FilterOp::NotLike => {
            let raw = filter.value.as_scalar()?;
            let allow_wildcards = matches!(filter.op, FilterOp::Like | FilterOp::NotLike);
            let normalized = normalize_mac_value(raw, allow_wildcards)?;

            let clause = match filter.op {
                FilterOp::Eq => format!("{column} = ${bind_idx}"),
                FilterOp::NotEq => format!("{column} != ${bind_idx}"),
                FilterOp::Like => format!("{column} LIKE ${bind_idx}"),
                FilterOp::NotLike => format!("{column} NOT LIKE ${bind_idx}"),
                _ => unreachable!("filtered above"),
            };

            binds.push(BindParam::Text(normalized));
            *bind_idx += 1;
            Ok(Some(clause))
        }
        FilterOp::In | FilterOp::NotIn => {
            let values = filter
                .value
                .as_list()?
                .iter()
                .map(|value| normalize_mac_value(value, false))
                .collect::<Result<Vec<_>>>()?;

            if values.is_empty() {
                return Ok(None);
            }

            let clause = match filter.op {
                FilterOp::In => format!("{column} = ANY(${bind_idx})"),
                FilterOp::NotIn => format!("NOT ({column} = ANY(${bind_idx}))"),
                _ => unreachable!("filtered above"),
            };

            binds.push(BindParam::TextArray(values));
            *bind_idx += 1;
            Ok(Some(clause))
        }
        _ => Err(ServiceError::InvalidRequest(format!(
            "unsupported operator for mac filter: {:?}",
            filter.op
        ))),
    }
}

fn normalize_mac_value(raw: &str, allow_wildcards: bool) -> Result<String> {
    super::super::normalize_mac_value(raw, allow_wildcards)
}

fn build_int_clause(
    column: &str,
    filter: &Filter,
    binds: &mut Vec<BindParam>,
    bind_idx: &mut usize,
) -> Result<Option<String>> {
    let value = match filter.op {
        FilterOp::Eq | FilterOp::NotEq => parse_i64(filter.value.as_scalar()?)?,
        _ => {
            return Err(ServiceError::InvalidRequest(
                "numeric filters only support equality".into(),
            ));
        }
    };

    let clause = match filter.op {
        FilterOp::Eq => format!("{column} = ${bind_idx}"),
        FilterOp::NotEq => format!("{column} != ${bind_idx}"),
        _ => unreachable!("validated above"),
    };

    binds.push(BindParam::Int(value));
    *bind_idx += 1;
    Ok(Some(clause))
}

fn build_bool_clause(
    column: &str,
    filter: &Filter,
    binds: &mut Vec<BindParam>,
    bind_idx: &mut usize,
) -> Result<Option<String>> {
    let value = match filter.op {
        FilterOp::Eq | FilterOp::NotEq => {
            let raw = filter.value.as_scalar()?.trim().to_lowercase();
            parse_bool(&raw).ok_or_else(|| {
                ServiceError::InvalidRequest(format!(
                    "boolean filter expects true/false, got '{raw}'"
                ))
            })?
        }
        _ => {
            return Err(ServiceError::InvalidRequest(
                "boolean filters only support equality".into(),
            ));
        }
    };

    let clause = match filter.op {
        FilterOp::Eq => format!("{column} = ${bind_idx}"),
        FilterOp::NotEq => format!("{column} != ${bind_idx}"),
        _ => unreachable!("validated above"),
    };

    binds.push(BindParam::Bool(value));
    *bind_idx += 1;
    Ok(Some(clause))
}

fn build_ip_addresses_clause(
    filter: &Filter,
    binds: &mut Vec<BindParam>,
    bind_idx: &mut usize,
) -> Result<Option<String>> {
    let values: Vec<String> = match &filter.value {
        FilterValue::Scalar(value) => vec![value.to_string()],
        FilterValue::List(list) => list.clone(),
    };

    if values.is_empty() {
        return Ok(None);
    }
    if values.len() > MAX_IP_ADDRESS_FILTER_VALUES {
        return Err(ServiceError::InvalidRequest(format!(
            "ip_addresses filter supports at most {MAX_IP_ADDRESS_FILTER_VALUES} values"
        )));
    }

    match filter.op {
        FilterOp::Eq | FilterOp::In => {
            let clause = format!("coalesce(di.ip_addresses, ARRAY[]::text[]) && ${bind_idx}");
            binds.push(BindParam::TextArray(values));
            *bind_idx += 1;
            Ok(Some(clause))
        }
        FilterOp::NotEq | FilterOp::NotIn => {
            let clause = format!("NOT (coalesce(di.ip_addresses, ARRAY[]::text[]) && ${bind_idx})");
            binds.push(BindParam::TextArray(values));
            *bind_idx += 1;
            Ok(Some(clause))
        }
        FilterOp::Like | FilterOp::NotLike => Err(ServiceError::InvalidRequest(
            "ip_addresses filter does not support pattern matching".into(),
        )),
        _ => Err(ServiceError::InvalidRequest(format!(
            "ip_addresses filter does not support operator {:?}",
            filter.op
        ))),
    }
}

pub(super) fn parse_i64(raw: &str) -> Result<i64> {
    raw.parse::<i64>()
        .map_err(|_| ServiceError::InvalidRequest(format!("expected integer value for '{raw}'")))
}

pub(super) fn parse_bool(input: &str) -> Option<bool> {
    if input.is_empty() {
        return None;
    }
    input.parse::<bool>().ok()
}
