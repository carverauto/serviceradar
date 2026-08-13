use super::{enforce_list_limit, LogsQuery};
use crate::{
    error::{Result, ServiceError},
    parser::{Filter, FilterOp},
};
use diesel::dsl::sql;
use diesel::prelude::*;
use diesel::sql_types::Bool;

pub(super) const LOG_DEVICE_IDENTITY_KEYS: &[&str] = &[
    "service_radar.device_uid",
    "service_radar.device.uid",
    "service_radar.device_id",
    "serviceradar.device_id",
    "serviceradar.device.uid",
    "device_id",
    "device_uid",
    "source_device_uid",
    "target_device_uid",
    "uid",
    "id",
];

pub(super) fn apply_metadata_identity_filter<'a>(
    query: LogsQuery<'a>,
    filter: &Filter,
    keys: &[&str],
) -> Result<LogsQuery<'a>> {
    let negate = matches!(filter.op, FilterOp::NotEq | FilterOp::NotIn);
    let values = match filter.op {
        FilterOp::Eq | FilterOp::NotEq => vec![filter.value.as_scalar()?.to_string()],
        FilterOp::In | FilterOp::NotIn => {
            let values = filter.value.as_list()?.to_vec();
            if values.is_empty() {
                return Ok(query);
            }
            enforce_list_limit(&filter.field, values.len())?;
            values
        }
        _ => {
            return Err(ServiceError::InvalidRequest(format!(
                "{} filter only supports equality and IN/NOT IN comparisons",
                filter.field
            )));
        }
    };

    let mut clauses = Vec::new();

    for value in values {
        if keys == LOG_DEVICE_IDENTITY_KEYS && device_id_field(&filter.field) {
            // Device pages query device_id:<uid>. Attribute ILIKE over last_24h
            // logs times out; match syslog source columns and inventory IPs only.
            clauses.push(device_inventory_identity_clause(&value));
        } else {
            clauses.push(metadata_identity_clause(&value, keys));
        }
    }

    if clauses.is_empty() {
        return Ok(query);
    }

    let clause = clauses.join(" OR ");
    let sql_clause = if negate {
        format!("NOT ({clause})")
    } else {
        format!("({clause})")
    };

    Ok(query.filter(sql::<Bool>(&sql_clause)))
}

fn metadata_identity_clause(value: &str, keys: &[&str]) -> String {
    let mut clauses = Vec::new();

    for key in keys {
        let key_pattern = escape_like_fragment(key);
        let value_pattern = escape_like_fragment(value);
        let json_pattern = sql_string_literal(&format!("%\"{key_pattern}\"%\"{value_pattern}\"%"));
        let kv_pattern = sql_string_literal(&format!("%{key_pattern}={value_pattern}%"));

        clauses.push(format!(
            "(COALESCE(resource_attributes, '') ILIKE {json_pattern} ESCAPE '\\' OR \
              COALESCE(attributes, '') ILIKE {json_pattern} ESCAPE '\\' OR \
              COALESCE(resource_attributes, '') ILIKE {kv_pattern} ESCAPE '\\' OR \
              COALESCE(attributes, '') ILIKE {kv_pattern} ESCAPE '\\')"
        ));
    }

    format!("({})", clauses.join(" OR "))
}

fn device_id_field(field: &str) -> bool {
    matches!(field, "device_id" | "uid")
}

fn device_inventory_identity_clause(value: &str) -> String {
    let device_value = sql_string_literal(value);

    format!(
        "EXISTS (\
           SELECT 1 \
           FROM platform.ocsf_devices AS d \
           WHERE (d.uid = {device_value} OR d.uid_alt = {device_value}) \
             AND ( \
               (logs.source_ip IS NOT NULL AND logs.source_ip = d.ip) \
               OR (logs.source IS NOT NULL AND logs.source = d.ip) \
               OR (logs.source IS NOT NULL AND logs.source = d.hostname) \
               OR (logs.source IS NOT NULL AND logs.source = d.name) \
             ) \
         ) OR EXISTS (\
           SELECT 1 \
           FROM platform.device_identifiers AS di \
           WHERE (di.device_id = {device_value}) \
             AND di.identifier_type IN ('ip', 'hostname') \
             AND ( \
               (logs.source_ip IS NOT NULL AND logs.source_ip = di.identifier_value) \
               OR (logs.source IS NOT NULL AND logs.source = di.identifier_value) \
             ) \
         ) OR EXISTS (\
           SELECT 1 \
           FROM platform.discovered_interfaces AS di_if \
           CROSS JOIN LATERAL unnest(COALESCE(di_if.ip_addresses, ARRAY[]::text[])) AS if_ip \
           WHERE di_if.device_id = {device_value} \
             AND ( \
               (logs.source_ip IS NOT NULL AND logs.source_ip = if_ip) \
               OR (logs.source_ip IS NOT NULL AND logs.source_ip = di_if.device_ip) \
             ) \
         )"
    )
}

fn escape_like_fragment(value: &str) -> String {
    value
        .replace('\\', r"\\")
        .replace('%', r"\%")
        .replace('_', r"\_")
}

fn sql_string_literal(value: &str) -> String {
    format!("'{}'", value.replace('\'', "''"))
}
