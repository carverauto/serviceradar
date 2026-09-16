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

/// Device-page identity match as uncorrelated `IN` subqueries.
///
/// An earlier revision expressed this as correlated `EXISTS` subqueries
/// (including a `CROSS JOIN LATERAL unnest(...)` over the device's interface
/// addresses). Correlated means per-log-row: over a `last_24h` window the
/// database re-evaluated the inventory join for every candidate row, and when
/// the device's syslog rows were sparse or absent the scan ran to the end of
/// the window and died to `statement_timeout` (Postgrex `:query_canceled`).
///
/// The subqueries below reference no `logs` columns, so the planner evaluates
/// each once — a handful of indexed inventory lookups yielding a small set of
/// IPs/hostnames — and probes `logs` through its `source_ip`/`source` indexes
/// instead of scanning the window. `IS NOT NULL` guards on the inner selects
/// preserve the original `= NULL`-never-matches semantics exactly.
fn device_inventory_identity_clause(value: &str) -> String {
    let device_value = sql_string_literal(value);

    format!(
        "logs.source_ip IN (\
           SELECT d.ip \
           FROM platform.ocsf_devices AS d \
           WHERE (d.uid = {device_value} OR d.uid_alt = {device_value}) \
             AND d.ip IS NOT NULL \
         ) OR logs.source IN (\
           SELECT d.ip \
           FROM platform.ocsf_devices AS d \
           WHERE (d.uid = {device_value} OR d.uid_alt = {device_value}) \
             AND d.ip IS NOT NULL \
         ) OR logs.source IN (\
           SELECT d.hostname \
           FROM platform.ocsf_devices AS d \
           WHERE (d.uid = {device_value} OR d.uid_alt = {device_value}) \
             AND d.hostname IS NOT NULL \
         ) OR logs.source IN (\
           SELECT d.name \
           FROM platform.ocsf_devices AS d \
           WHERE (d.uid = {device_value} OR d.uid_alt = {device_value}) \
             AND d.name IS NOT NULL \
         ) OR logs.source_ip IN (\
           SELECT di.identifier_value \
           FROM platform.device_identifiers AS di \
           WHERE di.device_id = {device_value} \
             AND di.identifier_type IN ('ip', 'hostname') \
             AND di.identifier_value IS NOT NULL \
         ) OR logs.source IN (\
           SELECT di.identifier_value \
           FROM platform.device_identifiers AS di \
           WHERE di.device_id = {device_value} \
             AND di.identifier_type IN ('ip', 'hostname') \
             AND di.identifier_value IS NOT NULL \
         ) OR logs.source_ip IN (\
           SELECT unnest(di_if.ip_addresses) \
           FROM platform.discovered_interfaces AS di_if \
           WHERE di_if.device_id = {device_value} \
         ) OR logs.source_ip IN (\
           SELECT di_if.device_ip \
           FROM platform.discovered_interfaces AS di_if \
           WHERE di_if.device_id = {device_value} \
             AND di_if.device_ip IS NOT NULL \
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

#[cfg(test)]
mod tests {
    use super::super::test_support::{data_plan, scalar_filter};
    use super::super::to_sql_and_params;
    use crate::parser::FilterOp;

    #[test]
    fn device_id_eq_uses_uncorrelated_inventory_lookups() {
        let plan = data_plan(vec![scalar_filter(
            "device_id",
            FilterOp::Eq,
            "sr:test-uid",
        )]);

        let (sql, _params) = to_sql_and_params(&plan).expect("sql should generate");

        assert!(sql.contains("logs.source_ip IN ("), "{sql}");
        assert!(sql.contains("platform.ocsf_devices"), "{sql}");
        assert!(sql.contains("platform.device_identifiers"), "{sql}");
        assert!(sql.contains("platform.discovered_interfaces"), "{sql}");
        // Correlated EXISTS (and the per-row lateral unnest) scanned the whole
        // time window and timed out; the replacements must stay uncorrelated.
        assert!(!sql.contains("EXISTS ("), "{sql}");
        assert!(!sql.contains("CROSS JOIN LATERAL"), "{sql}");
    }

    #[test]
    fn uid_eq_routes_to_inventory_lookups() {
        let plan = data_plan(vec![scalar_filter("uid", FilterOp::Eq, "sr:test-uid")]);

        let (sql, _params) = to_sql_and_params(&plan).expect("sql should generate");

        assert!(sql.contains("logs.source_ip IN ("), "{sql}");
        assert!(!sql.contains("EXISTS ("), "{sql}");
    }

    #[test]
    fn source_device_uid_keeps_metadata_identity_path() {
        let plan = data_plan(vec![scalar_filter(
            "source_device_uid",
            FilterOp::Eq,
            "sr:test-uid",
        )]);

        let (sql, _params) = to_sql_and_params(&plan).expect("sql should generate");

        assert!(sql.contains("ILIKE"), "{sql}");
        assert!(!sql.contains("platform.ocsf_devices"), "{sql}");
    }
}
