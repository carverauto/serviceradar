mod availability;
mod composite;
mod defaults;
mod identity;
mod ip;
mod jsonb;
mod params;
mod seen;
mod text;

pub(super) use self::{
    defaults::{
        apply_default_active_filter, has_deleted_filter, should_apply_default_active_filter,
    },
    ip::safe_device_ip_inet_sql,
    jsonb::{is_valid_jsonb_key, parse_bool},
    params::collect_filter_params,
    seen::first_seen_range,
};

use self::{
    availability::{apply_agent_availability_filter, apply_availability_source_freshness_filter},
    composite::{apply_composite_verdict_filter, parse_composite_field},
    defaults::apply_active_filter,
    identity::{apply_device_type_filter, apply_mac_filter},
    ip::apply_ip_filter,
    jsonb::{apply_jsonb_text_filter, apply_tags_filter},
    seen::apply_first_seen_filter,
};
use super::DeviceQuery;
use crate::{
    error::{Result, ServiceError},
    parser::{Filter, FilterOp, FilterValue},
    query::is_negated_membership_op,
    schema::ocsf_devices::dsl::{
        agent_id as col_agent_id, availability_source_agent_id as col_availability_source_agent_id,
        deleted_at as col_deleted_at, gateway_id as col_gateway_id, hostname as col_hostname,
        is_available as col_is_available, model as col_model, partition as col_partition,
        risk_level as col_risk_level, type_id as col_type_id, uid as col_uid,
        vendor_name as col_vendor_name, vlan_uid as col_vlan_uid,
    },
};
use diesel::dsl::{not, sql};
use diesel::prelude::*;
use diesel::sql_types::{Array, Bool, Text};

/// SQL predicate that identifies AWX / ansible-capable devices.
///
/// Mirrors `ServiceRadarWebNGWeb`'s `AnsiblePanelRuntime.awx_managed?/1`: the
/// authoritative signal is the AWX inventory reference the backend materializes
/// onto `metadata.awx` (`host_id` / `controller_id`), with a fallback to the
/// `awx` / `ansible` discovery source so older rows still surface. The
/// expression is fully parenthesized and NULL-safe (each branch yields a plain
/// boolean, never NULL), so wrapping it in `NOT (...)` produces the exact
/// complement. It binds no user input — every literal is hard-coded — so it
/// contributes zero placeholders to the query.
pub(in crate::query::devices) const AWX_MANAGED_PREDICATE: &str =
    "(metadata -> 'awx' ->> 'host_id' IS NOT NULL \
     OR metadata -> 'awx' ->> 'controller_id' IS NOT NULL \
     OR COALESCE(discovery_sources, ARRAY[]::text[]) && ARRAY['awx', 'ansible']::text[])";

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
        "partition" => {
            query = apply_text_filter!(query, filter, col_partition)?;
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
        "availability_source_agent_id"
        | "availability_source_agent"
        | "primary_availability_source"
        | "primary_availability_source_agent_id" => {
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
        "availability_source_fresh_within" => {
            query = apply_availability_source_freshness_filter(query, filter, true)?;
        }
        "availability_source_stale_after" => {
            query = apply_availability_source_freshness_filter(query, filter, false)?;
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
        // Added-at window. `time:` still filters last_seen_time; this is the
        // first-seen equivalent (`first_seen:last_7d`).
        "first_seen" | "first_seen_time" => {
            query = apply_first_seen_filter(query, filter)?;
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
        "vlan_uid" => {
            query = apply_text_filter!(query, filter, col_vlan_uid)?;
        }
        "switch_port_attachment.switch_hostname" => {
            query = apply_jsonb_text_filter(
                query,
                filter,
                "switch_port_attachment",
                "switch_hostname",
            )?;
        }
        "switch_port_attachment.port" => {
            query = apply_jsonb_text_filter(query, filter, "switch_port_attachment", "port")?;
        }
        "switch_port_attachment.source" => {
            query = apply_jsonb_text_filter(query, filter, "switch_port_attachment", "source")?;
        }
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
        "cve" | "cve_id" => {
            query = apply_device_match_cve_filter(query, filter)?;
        }
        "kev" => {
            query = apply_device_match_kev_filter(query, filter)?;
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
            let expr = sql::<Bool>("coalesce(discovery_sources, ARRAY[]::text[]) && ")
                .bind::<Array<Text>, _>(values);
            query = if is_negated_membership_op(&filter.op) {
                query.filter(not(expr))
            } else {
                query.filter(expr)
            };
        }
        // Derived boolean: is this device part of an AWX inventory / ansible-capable?
        // Not backed by a single column; translated to the AWX_MANAGED_PREDICATE.
        "awx_managed" => {
            let managed = parse_bool(filter.value.as_scalar()?)?;
            let want_managed = match filter.op {
                FilterOp::Eq => managed,
                FilterOp::NotEq => !managed,
                _ => {
                    return Err(ServiceError::InvalidRequest(
                        "awx_managed only supports equality".into(),
                    ));
                }
            };
            let expr = sql::<Bool>(AWX_MANAGED_PREDICATE);
            query = if want_managed {
                query.filter(expr)
            } else {
                query.filter(not(expr))
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
        // Derived from composite check results; not backed by a device column.
        // Compiled to a correlated EXISTS in filters/composite.rs. Must stay in
        // lockstep with the matching arm in filters/params.rs.
        field if field.starts_with("composite.") => {
            let (slug, column) = parse_composite_field(field).ok_or_else(|| {
                ServiceError::InvalidRequest(format!("invalid composite check field '{field}'"))
            })?;
            query = apply_composite_verdict_filter(query, filter, &slug, column)?;
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

fn apply_device_match_cve_filter<'a>(
    query: DeviceQuery<'a>,
    filter: &Filter,
) -> Result<DeviceQuery<'a>> {
    let prefix = "EXISTS (SELECT 1 FROM endpoint_vulnerability_assessments a \
         WHERE a.device_uid = ocsf_devices.uid AND a.status = 'active' \
         AND a.assessment = 'confirmed' AND a.disposition = 'affected' AND ";
    match filter.op {
        FilterOp::Eq | FilterOp::NotEq | FilterOp::In | FilterOp::NotIn => {
            let values = crate::query::advisory::cve_eq_values(filter)?;
            if values.is_empty() {
                return Ok(query);
            }
            let expr = sql::<Bool>(prefix)
                .sql("a.cve_id = ANY(")
                .bind::<Array<Text>, _>(values)
                .sql("))");
            Ok(if matches!(filter.op, FilterOp::NotEq | FilterOp::NotIn) {
                query.filter(not(expr))
            } else {
                query.filter(expr)
            })
        }
        FilterOp::Like | FilterOp::NotLike => {
            let value = filter.value.as_scalar()?.to_string();
            let expr = sql::<Bool>(prefix)
                .sql("a.cve_id ILIKE ")
                .bind::<Text, _>(value)
                .sql(")");
            Ok(if matches!(filter.op, FilterOp::NotLike) {
                query.filter(not(expr))
            } else {
                query.filter(expr)
            })
        }
        _ => Err(ServiceError::InvalidRequest(
            "cve filter only supports equality, membership, and % wildcards".into(),
        )),
    }
}

fn apply_device_match_kev_filter<'a>(
    query: DeviceQuery<'a>,
    filter: &Filter,
) -> Result<DeviceQuery<'a>> {
    if !matches!(filter.op, FilterOp::Eq | FilterOp::NotEq) {
        return Err(ServiceError::InvalidRequest(
            "kev filter only supports equality".into(),
        ));
    }
    let want = parse_bool(filter.value.as_scalar()?)?;
    let want = if matches!(filter.op, FilterOp::NotEq) {
        !want
    } else {
        want
    };
    let expr = sql::<Bool>(
        "EXISTS (SELECT 1 FROM endpoint_vulnerability_assessments a \
         WHERE a.device_uid = ocsf_devices.uid AND a.status = 'active' \
         AND a.assessment = 'confirmed' AND a.disposition = 'affected' AND a.kev = ",
    )
    .bind::<Bool, _>(true)
    .sql(")");
    Ok(if want {
        query.filter(expr)
    } else {
        query.filter(not(expr))
    })
}
