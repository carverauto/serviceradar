use super::DeviceQuery;
use crate::{
    error::{Result, ServiceError},
    parser::{Filter, FilterOp, FilterValue},
    query::{is_negated_membership_op, normalize_mac_value, BindParam},
    schema::ocsf_devices::dsl::{
        agent_id as col_agent_id, availability_source_agent_id as col_availability_source_agent_id,
        deleted_at as col_deleted_at, gateway_id as col_gateway_id, hostname as col_hostname,
        ip as col_ip, is_available as col_is_available, model as col_model,
        risk_level as col_risk_level, type_id as col_type_id, uid as col_uid,
        vendor_name as col_vendor_name,
    },
};
use diesel::dsl::{not, sql};
use diesel::prelude::*;
use diesel::sql_types::{Array, Bool, Text};
use diesel::PgTextExpressionMethods;
use std::net::IpAddr;

pub(super) fn apply_filter<'a>(
    mut query: DeviceQuery<'a>,
    filter: &Filter,
) -> Result<DeviceQuery<'a>> {
    match filter.field.as_str() {
        "uid" => {
            query = apply_text_filter!(query, filter, col_uid)?;
        }
        "hostname" => {
            query = apply_text_filter_no_lists!(
                query,
                filter,
                col_hostname,
                "hostname filter does not support lists"
            )?;
        }
        "ip" => {
            query = apply_ip_filter(query, filter)?;
        }
        "mac" => {
            query = apply_mac_filter(query, filter)?;
        }
        "gateway_id" => {
            query = apply_eq_filter!(
                query,
                filter,
                col_gateway_id,
                filter.value.as_scalar()?.to_string(),
                "gateway filter only supports equality"
            )?;
        }
        "agent_id" => {
            query = apply_eq_filter!(
                query,
                filter,
                col_agent_id,
                filter.value.as_scalar()?.to_string(),
                "agent filter only supports equality"
            )?;
        }
        "availability_source_agent_id" | "availability_source_agent" => {
            query = apply_eq_filter!(
                query,
                filter,
                col_availability_source_agent_id,
                filter.value.as_scalar()?.to_string(),
                "availability source agent filter only supports equality"
            )?;
        }
        "available_from_agent" => {
            query = apply_agent_availability_filter(query, filter, true)?;
        }
        "unavailable_from_agent" => {
            query = apply_agent_availability_filter(query, filter, false)?;
        }
        "is_available" => {
            query = apply_eq_filter!(
                query,
                filter,
                col_is_available,
                parse_bool(filter.value.as_scalar()?)?,
                "is_available only supports equality"
            )?;
        }
        "is_active" => {
            query = apply_active_filter(query, filter)?;
        }
        "include_inactive" => {
            let _ = parse_bool(filter.value.as_scalar()?)?;
        }
        // OCSF device type (string name like "Server", "Router", etc.)
        "type" | "device_type" => {
            query = apply_device_type_filter(query, filter)?;
        }
        // OCSF device type_id (numeric enum)
        "type_id" => {
            let type_id: i32 =
                filter.value.as_scalar()?.parse().map_err(|_| {
                    ServiceError::InvalidRequest("type_id must be an integer".into())
                })?;
            query = apply_eq_filter!(
                query,
                filter,
                col_type_id,
                type_id,
                "type_id filter only supports equality"
            )?;
        }
        // OCSF vendor_name
        "vendor_name" => {
            query = apply_eq_filter!(
                query,
                filter,
                col_vendor_name,
                filter.value.as_scalar()?.to_string(),
                "vendor_name filter only supports equality"
            )?;
        }
        // OCSF model
        "model" => {
            query = apply_eq_filter!(
                query,
                filter,
                col_model,
                filter.value.as_scalar()?.to_string(),
                "model filter only supports equality"
            )?;
        }
        // OCSF risk_level
        "risk_level" => {
            query = apply_eq_filter!(
                query,
                filter,
                col_risk_level,
                filter.value.as_scalar()?.to_string(),
                "risk_level filter only supports equality"
            )?;
        }
        "deleted" => {
            let value = parse_bool(filter.value.as_scalar()?)?;
            let matches_deleted = col_deleted_at.is_not_null();
            let matches_active = col_deleted_at.is_null();
            query = match filter.op {
                FilterOp::Eq => {
                    if value {
                        query.filter(matches_deleted)
                    } else {
                        query.filter(matches_active)
                    }
                }
                FilterOp::NotEq => {
                    if value {
                        query.filter(matches_active)
                    } else {
                        query.filter(matches_deleted)
                    }
                }
                _ => {
                    return Err(ServiceError::InvalidRequest(
                        "deleted filter only supports equality".into(),
                    ));
                }
            };
        }
        "tags" => {
            query = apply_tags_filter(query, filter)?;
        }
        "discovery_sources" => {
            let values = match &filter.value {
                FilterValue::Scalar(v) => vec![v.to_string()],
                FilterValue::List(list) => list.clone(),
            };
            if values.is_empty() {
                return Ok(query);
            }
            let expr = sql::<Bool>("coalesce(discovery_sources, ARRAY[]::text[]) @> ")
                .bind::<Array<Text>, _>(values);
            query = if is_negated_membership_op(&filter.op) {
                query.filter(not(expr))
            } else {
                query.filter(expr)
            };
        }
        // JSONB path queries for os object
        "os.name" => {
            query = apply_jsonb_text_filter(query, filter, "os", "name")?;
        }
        "os.version" => {
            query = apply_jsonb_text_filter(query, filter, "os", "version")?;
        }
        "os.type" => {
            query = apply_jsonb_text_filter(query, filter, "os", "type")?;
        }
        // JSONB path queries for hw_info object
        "hw_info.serial_number" => {
            query = apply_jsonb_text_filter(query, filter, "hw_info", "serial_number")?;
        }
        "hw_info.cpu_type" => {
            query = apply_jsonb_text_filter(query, filter, "hw_info", "cpu_type")?;
        }
        "hw_info.cpu_architecture" => {
            query = apply_jsonb_text_filter(query, filter, "hw_info", "cpu_architecture")?;
        }
        // JSONB path queries for metadata (arbitrary keys)
        field if field.starts_with("metadata.") => {
            let key = field.strip_prefix("metadata.").unwrap();
            if !is_valid_jsonb_key(key) {
                return Err(ServiceError::InvalidRequest(format!(
                    "invalid metadata key '{key}'"
                )));
            }
            query = apply_jsonb_text_filter(query, filter, "metadata", key)?;
        }
        // JSONB path queries for tags (arbitrary keys)
        field if field.starts_with("tags.") => {
            let key = field.strip_prefix("tags.").unwrap();
            if !is_valid_jsonb_key(key) {
                return Err(ServiceError::InvalidRequest(format!(
                    "invalid tags key '{key}'"
                )));
            }
            query = apply_jsonb_text_filter(query, filter, "tags", key)?;
        }
        other => {
            return Err(ServiceError::InvalidRequest(format!(
                "unsupported filter field '{other}'"
            )));
        }
    }

    Ok(query)
}

pub(super) fn has_deleted_filter(filters: &[Filter]) -> bool {
    filters
        .iter()
        .any(|filter| filter.field.eq_ignore_ascii_case("deleted"))
}

fn has_active_filter(filters: &[Filter]) -> bool {
    filters
        .iter()
        .any(|filter| filter.field.eq_ignore_ascii_case("is_active"))
}

pub(super) fn should_apply_default_active_filter(filters: &[Filter]) -> Result<bool> {
    if has_active_filter(filters) {
        return Ok(false);
    }

    for filter in filters {
        if filter.field.eq_ignore_ascii_case("include_inactive") {
            return Ok(!parse_bool(filter.value.as_scalar()?)?);
        }
    }

    Ok(true)
}

pub(super) fn apply_default_active_filter<'a>(query: DeviceQuery<'a>) -> DeviceQuery<'a> {
    query.filter(sql::<Bool>(
        "COALESCE(\"ocsf_devices\".\"is_active\", true) = true",
    ))
}

fn apply_active_filter<'a>(query: DeviceQuery<'a>, filter: &Filter) -> Result<DeviceQuery<'a>> {
    let value = parse_bool(filter.value.as_scalar()?)?;

    match filter.op {
        FilterOp::Eq => Ok(query.filter(
            sql::<Bool>("COALESCE(\"ocsf_devices\".\"is_active\", true) = ").bind::<Bool, _>(value),
        )),
        FilterOp::NotEq => Ok(query.filter(
            sql::<Bool>("COALESCE(\"ocsf_devices\".\"is_active\", true) <> ")
                .bind::<Bool, _>(value),
        )),
        _ => Err(ServiceError::InvalidRequest(
            "is_active only supports equality".into(),
        )),
    }
}

fn apply_device_type_filter<'a>(
    query: DeviceQuery<'a>,
    filter: &Filter,
) -> Result<DeviceQuery<'a>> {
    let value = filter.value.as_scalar()?.to_string();
    let expr = "COALESCE(NULLIF(trim(\"ocsf_devices\".\"type\"), ''), 'Unknown')";

    match filter.op {
        FilterOp::Eq => Ok(query.filter(sql::<Bool>(&format!("{expr} = ")).bind::<Text, _>(value))),
        FilterOp::NotEq => {
            Ok(query.filter(sql::<Bool>(&format!("{expr} <> ")).bind::<Text, _>(value)))
        }
        _ => Err(ServiceError::InvalidRequest(
            "device_type filter only supports equality".into(),
        )),
    }
}

fn apply_ip_filter<'a>(query: DeviceQuery<'a>, filter: &Filter) -> Result<DeviceQuery<'a>> {
    match filter.op {
        FilterOp::Eq | FilterOp::NotEq => {
            let value = filter.value.as_scalar()?.to_string();
            if let Some(cidr) = parse_cidr(&value)? {
                let ip_expr = safe_device_ip_inet_sql();
                let expr = if matches!(filter.op, FilterOp::NotEq) {
                    sql::<Bool>(&format!("({ip_expr} IS NOT NULL AND NOT ({ip_expr} <<= "))
                        .bind::<Text, _>(cidr)
                        .sql("::cidr))")
                } else {
                    sql::<Bool>(&format!("({ip_expr} IS NOT NULL AND {ip_expr} <<= "))
                        .bind::<Text, _>(cidr)
                        .sql("::cidr)")
                };
                return Ok(query.filter(expr));
            }

            if let Some((start, end)) = parse_ip_range(&value)? {
                let ip_expr = safe_device_ip_inet_sql();
                let expr = if matches!(filter.op, FilterOp::NotEq) {
                    sql::<Bool>(&format!("({ip_expr} IS NOT NULL AND NOT ({ip_expr} >= "))
                        .bind::<Text, _>(start)
                        .sql(&format!("::inet AND {ip_expr} <= "))
                        .bind::<Text, _>(end)
                        .sql("::inet))")
                } else {
                    sql::<Bool>(&format!("({ip_expr} IS NOT NULL AND {ip_expr} >= "))
                        .bind::<Text, _>(start)
                        .sql(&format!("::inet AND {ip_expr} <= "))
                        .bind::<Text, _>(end)
                        .sql("::inet)")
                };
                return Ok(query.filter(expr));
            }
        }
        _ => {}
    }

    apply_text_filter_no_lists!(query, filter, col_ip, "ip filter does not support lists")
}

fn apply_agent_availability_filter<'a>(
    query: DeviceQuery<'a>,
    filter: &Filter,
    available: bool,
) -> Result<DeviceQuery<'a>> {
    if !matches!(filter.op, FilterOp::Eq) {
        return Err(ServiceError::InvalidRequest(
            "per-agent availability filters only support equality".into(),
        ));
    }

    let agent_id = filter.value.as_scalar()?.to_string();
    let expr = sql::<Bool>(
        "EXISTS (SELECT 1 FROM device_agent_availability daa WHERE daa.device_uid = ocsf_devices.uid AND daa.agent_id = ",
    )
    .bind::<Text, _>(agent_id)
    .sql(" AND daa.is_available = ")
    .sql(if available { "true" } else { "false" })
    .sql(")");

    Ok(query.filter(expr))
}

/// Normalized MAC filter for the Diesel typed query path.
/// Strips separators from both column and value so any format matches.
fn apply_mac_filter<'a>(query: DeviceQuery<'a>, filter: &Filter) -> Result<DeviceQuery<'a>> {
    let norm_col = "lower(regexp_replace(mac, '[^0-9a-fA-F]', '', 'g'))";

    match filter.op {
        FilterOp::Eq => {
            let normalized = normalize_mac_value(filter.value.as_scalar()?, false)?;
            Ok(query.filter(sql::<Bool>(&format!("{norm_col} = ")).bind::<Text, _>(normalized)))
        }
        FilterOp::NotEq => {
            let normalized = normalize_mac_value(filter.value.as_scalar()?, false)?;
            Ok(query.filter(
                sql::<Bool>(&format!("(mac IS NULL OR {norm_col} <> "))
                    .bind::<Text, _>(normalized)
                    .sql(")"),
            ))
        }
        FilterOp::Like => {
            let normalized = normalize_mac_value(filter.value.as_scalar()?, true)?;
            Ok(query.filter(sql::<Bool>(&format!("{norm_col} LIKE ")).bind::<Text, _>(normalized)))
        }
        FilterOp::NotLike => {
            let normalized = normalize_mac_value(filter.value.as_scalar()?, true)?;
            Ok(query.filter(
                sql::<Bool>(&format!("(mac IS NULL OR {norm_col} NOT LIKE "))
                    .bind::<Text, _>(normalized)
                    .sql(")"),
            ))
        }
        _ => Err(ServiceError::InvalidRequest(
            "mac filter only supports equality and LIKE operators".into(),
        )),
    }
}

/// Collects normalized MAC bind params for the count/non-grouped stats path.
fn collect_mac_params(params: &mut Vec<BindParam>, filter: &Filter) -> Result<()> {
    match filter.op {
        FilterOp::Eq | FilterOp::NotEq => {
            let normalized = normalize_mac_value(filter.value.as_scalar()?, false)?;
            params.push(BindParam::Text(normalized));
            Ok(())
        }
        FilterOp::Like | FilterOp::NotLike => {
            let normalized = normalize_mac_value(filter.value.as_scalar()?, true)?;
            params.push(BindParam::Text(normalized));
            Ok(())
        }
        _ => Err(ServiceError::InvalidRequest(
            "mac filter only supports equality and LIKE operators".into(),
        )),
    }
}

fn collect_text_params(
    params: &mut Vec<BindParam>,
    filter: &Filter,
    allow_lists: bool,
) -> Result<()> {
    match filter.op {
        FilterOp::Eq | FilterOp::NotEq | FilterOp::Like | FilterOp::NotLike => {
            params.push(BindParam::Text(filter.value.as_scalar()?.to_string()));
            Ok(())
        }
        FilterOp::In | FilterOp::NotIn if allow_lists => {
            let values = filter.value.as_list()?.to_vec();
            if values.is_empty() {
                return Ok(());
            }
            params.push(BindParam::TextArray(values));
            Ok(())
        }
        FilterOp::In | FilterOp::NotIn => Err(ServiceError::InvalidRequest(
            "list filters are not supported for this field".into(),
        )),
        _ => Err(ServiceError::InvalidRequest(format!(
            "unsupported operator for text filter: {:?}",
            filter.op
        ))),
    }
}

pub(super) fn collect_filter_params(params: &mut Vec<BindParam>, filter: &Filter) -> Result<()> {
    match filter.field.as_str() {
        "uid" => collect_text_params(params, filter, true),
        "hostname" => collect_text_params(params, filter, false),
        "mac" => collect_mac_params(params, filter),
        "ip" => collect_ip_params(params, filter),
        "gateway_id"
        | "agent_id"
        | "availability_source_agent_id"
        | "availability_source_agent"
        | "available_from_agent"
        | "unavailable_from_agent"
        | "type"
        | "device_type"
        | "vendor_name"
        | "model"
        | "risk_level" => {
            params.push(BindParam::Text(filter.value.as_scalar()?.to_string()));
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
        // JSONB path fields - all use text bind params
        "os.name"
        | "os.version"
        | "os.type"
        | "hw_info.serial_number"
        | "hw_info.cpu_type"
        | "hw_info.cpu_architecture" => {
            params.push(BindParam::Text(filter.value.as_scalar()?.to_string()));
            Ok(())
        }
        // Dynamic metadata.* fields
        field if field.starts_with("metadata.") => {
            let key = field.strip_prefix("metadata.").unwrap();
            if !is_valid_jsonb_key(key) {
                return Err(ServiceError::InvalidRequest(format!(
                    "invalid metadata key '{key}'"
                )));
            }
            params.push(BindParam::Text(filter.value.as_scalar()?.to_string()));
            Ok(())
        }
        // Dynamic tags.* fields
        field if field.starts_with("tags.") => {
            let key = field.strip_prefix("tags.").unwrap();
            if !is_valid_jsonb_key(key) {
                return Err(ServiceError::InvalidRequest(format!(
                    "invalid tags key '{key}'"
                )));
            }
            params.push(BindParam::Text(filter.value.as_scalar()?.to_string()));
            Ok(())
        }
        other => Err(ServiceError::InvalidRequest(format!(
            "unsupported filter field '{other}'"
        ))),
    }
}

fn collect_ip_params(params: &mut Vec<BindParam>, filter: &Filter) -> Result<()> {
    match filter.op {
        FilterOp::Eq | FilterOp::NotEq => {
            let value = filter.value.as_scalar()?.to_string();

            if let Some(cidr) = parse_cidr(&value)? {
                params.push(BindParam::Text(cidr));
                return Ok(());
            }

            if let Some((start, end)) = parse_ip_range(&value)? {
                params.push(BindParam::Text(start));
                params.push(BindParam::Text(end));
                return Ok(());
            }

            params.push(BindParam::Text(value));
            Ok(())
        }
        _ => collect_text_params(params, filter, false),
    }
}

fn parse_cidr(value: &str) -> Result<Option<String>> {
    if !value.contains('/') {
        return Ok(None);
    }

    let (ip_part, prefix_part) = value
        .split_once('/')
        .ok_or_else(|| ServiceError::InvalidRequest("invalid CIDR for ip filter".into()))?;
    let ip_part = ip_part.trim();
    let prefix_part = prefix_part.trim();

    if ip_part.is_empty() || prefix_part.is_empty() {
        return Err(ServiceError::InvalidRequest(
            "invalid CIDR for ip filter".into(),
        ));
    }

    let ip: IpAddr = ip_part
        .parse()
        .map_err(|_| ServiceError::InvalidRequest("invalid CIDR for ip filter".into()))?;
    let prefix: u8 = prefix_part
        .parse()
        .map_err(|_| ServiceError::InvalidRequest("invalid CIDR for ip filter".into()))?;

    let max_prefix = match ip {
        IpAddr::V4(_) => 32,
        IpAddr::V6(_) => 128,
    };

    if prefix > max_prefix {
        return Err(ServiceError::InvalidRequest(
            "invalid CIDR for ip filter".into(),
        ));
    }

    Ok(Some(format!("{}/{}", ip, prefix)))
}

fn parse_ip_range(value: &str) -> Result<Option<(String, String)>> {
    if !value.contains('-') {
        return Ok(None);
    }

    let (start_part, end_part) = value
        .split_once('-')
        .ok_or_else(|| ServiceError::InvalidRequest("invalid ip range for ip filter".into()))?;

    let start_part = start_part.trim();
    let end_part = end_part.trim();

    if start_part.is_empty() || end_part.is_empty() {
        return Err(ServiceError::InvalidRequest(
            "invalid ip range for ip filter".into(),
        ));
    }

    let start_ip: IpAddr = start_part
        .parse()
        .map_err(|_| ServiceError::InvalidRequest("invalid ip range for ip filter".into()))?;
    let end_ip: IpAddr = end_part
        .parse()
        .map_err(|_| ServiceError::InvalidRequest("invalid ip range for ip filter".into()))?;

    if std::mem::discriminant(&start_ip) != std::mem::discriminant(&end_ip) {
        return Err(ServiceError::InvalidRequest(
            "invalid ip range for ip filter".into(),
        ));
    }

    Ok(Some((start_ip.to_string(), end_ip.to_string())))
}

pub(super) fn safe_device_ip_inet_sql() -> &'static str {
    "(CASE WHEN pg_input_is_valid(NULLIF(btrim(split_part(ip, ',', 1)), ''), 'inet') THEN NULLIF(btrim(split_part(ip, ',', 1)), '')::inet ELSE NULL END)"
}

pub(super) fn parse_bool(raw: &str) -> Result<bool> {
    match raw.to_lowercase().as_str() {
        "true" | "1" | "yes" => Ok(true),
        "false" | "0" | "no" => Ok(false),
        _ => Err(ServiceError::InvalidRequest(format!(
            "invalid boolean value '{raw}'"
        ))),
    }
}

/// Validates that a JSONB key is safe to use in a query.
/// Only allows alphanumeric characters, underscores, and hyphens.
pub(super) fn is_valid_jsonb_key(key: &str) -> bool {
    !key.is_empty()
        && key.len() <= 64
        && key
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || c == '_' || c == '-')
}

/// Applies a text filter to a JSONB field path using the ->> operator.
/// Supports equality, inequality, and LIKE operations.
fn apply_jsonb_text_filter<'a>(
    query: DeviceQuery<'a>,
    filter: &Filter,
    column: &str,
    key: &str,
) -> Result<DeviceQuery<'a>> {
    // Construct the JSONB text extraction expression: column->>'key'
    let jsonb_expr = format!("{column}->>'{key}'");
    let value = filter.value.as_scalar()?.to_string();

    match filter.op {
        FilterOp::Eq => {
            let expr = sql::<Bool>(&format!("{jsonb_expr} = ")).bind::<Text, _>(value);
            Ok(query.filter(expr))
        }
        FilterOp::NotEq => {
            let expr = sql::<Bool>(&format!("({jsonb_expr} IS NULL OR {jsonb_expr} != "))
                .bind::<Text, _>(value)
                .sql(")");
            Ok(query.filter(expr))
        }
        FilterOp::Like => {
            let expr = sql::<Bool>(&format!("{jsonb_expr} ILIKE ")).bind::<Text, _>(value);
            Ok(query.filter(expr))
        }
        FilterOp::NotLike => {
            let expr = sql::<Bool>(&format!("({jsonb_expr} IS NULL OR {jsonb_expr} NOT ILIKE "))
                .bind::<Text, _>(value)
                .sql(")");
            Ok(query.filter(expr))
        }
        _ => Err(ServiceError::InvalidRequest(format!(
            "JSONB field '{column}.{key}' only supports equality and LIKE filters"
        ))),
    }
}

fn apply_tags_filter<'a>(query: DeviceQuery<'a>, filter: &Filter) -> Result<DeviceQuery<'a>> {
    match filter.op {
        FilterOp::Eq | FilterOp::NotEq => {
            let tag = filter.value.as_scalar()?.to_string();
            let expr = sql::<Bool>("coalesce(tags, '{}'::jsonb) ? ").bind::<Text, _>(tag);
            if matches!(filter.op, FilterOp::NotEq) {
                Ok(query.filter(not(expr)))
            } else {
                Ok(query.filter(expr))
            }
        }
        FilterOp::In | FilterOp::NotIn => {
            let tags = filter.value.as_list()?.to_vec();
            if tags.is_empty() {
                return Ok(query);
            }
            let expr = sql::<Bool>("coalesce(tags, '{}'::jsonb) ?| ").bind::<Array<Text>, _>(tags);
            if matches!(filter.op, FilterOp::NotIn) {
                Ok(query.filter(not(expr)))
            } else {
                Ok(query.filter(expr))
            }
        }
        _ => Err(ServiceError::InvalidRequest(
            "tags filter only supports equality and list filters".into(),
        )),
    }
}
