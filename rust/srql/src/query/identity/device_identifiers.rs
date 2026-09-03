//! `in:device_identifiers` -- identifier ownership joined to the owner's
//! current facts.
//!
//! The projection that matters is `matches_current_facts`: whether the
//! identifier still reflects what the owning device reports today, or is only
//! history. Without it, "this MAC edge merged two devices" cannot be told apart
//! from "this MAC used to be on that device three months ago", which is the
//! distinction an identity investigation turns on.

use super::{
    BuiltSql, IDENTIFIER_METADATA_KEYS, IDENTIFIER_TYPES, JsonPayload, bool_condition,
    jsonb_allowlist, order_by, reject_aggregations, rewrite_placeholders, scalar_bool, scalar_text,
    text_condition,
};
use crate::{
    error::{Result, ServiceError},
    parser::{Entity, Filter},
    query::{BindParam, QueryPlan, bind_sql_param},
    time::TimeRange,
};
use diesel::pg::Pg;
use diesel::sql_query;
use diesel_async::{AsyncPgConnection, RunQueryDsl};
use serde_json::Value;

const ORDERABLE: &[(&str, &str)] = &[
    ("last_seen", "last_seen"),
    ("time", "last_seen"),
    ("first_seen", "first_seen"),
    ("identifier_type", "identifier_type"),
    ("identifier_value", "identifier_value"),
    ("device_id", "device_id"),
    ("confidence", "confidence"),
];

/// Does this identifier still match what its owner reports?
///
/// Three-valued on purpose:
///
/// * `true`  -- the owner reports this value as a current fact
/// * `false` -- the owner exists and does NOT report it: a historical identifier
/// * NULL    -- the question does not apply, because this identifier type has no
///   corresponding current fact on the device at all
///
/// The NULL case is the one worth being careful about. An `armis_device_id` or a
/// `netbox_device_id` is an external system's key; there is no column on
/// `ocsf_devices` it could equal. Reporting `false` for those would read as
/// "this identifier is stale", which is a different and wrong claim, and it is
/// exactly the sort of confident-but-wrong signal an identity investigation
/// cannot afford. `hardware_serial` is NULL for the same reason: the serial
/// lives inside the `hw_info` JSON under no guaranteed key.
///
/// Deliberately computed rather than stored. The alternative -- a
/// `corroborated_at` column maintained by the registrar -- edits the write path
/// of the highest-volume table in the identity system to serve a diagnostic.
/// `LIMIT` is applied before this join, and both sides are keyed on indexed
/// columns, so the per-row cost is bounded.
const MATCHES_CURRENT_FACTS: &str = "\
CASE \
  WHEN d.uid IS NULL THEN false \
  WHEN di.identifier_type = 'mac' THEN ( \
    upper(replace(replace(COALESCE(d.mac, ''), ':', ''), '-', '')) \
      = upper(replace(replace(di.identifier_value, ':', ''), '-', '')) \
    OR EXISTS ( \
      SELECT 1 FROM platform.device_interface_macs ifm \
      WHERE ifm.device_id = di.device_id \
        AND upper(replace(replace(ifm.mac, ':', ''), '-', '')) \
            = upper(replace(replace(di.identifier_value, ':', ''), '-', '')) \
    ) \
  ) \
  WHEN di.identifier_type = 'agent_id' THEN COALESCE(d.agent_id, '') = di.identifier_value \
  WHEN di.identifier_type = 'ip' THEN COALESCE(d.ip, '') = di.identifier_value \
  WHEN di.identifier_type = 'hostname' THEN COALESCE(d.hostname, '') = di.identifier_value \
  ELSE NULL::boolean \
END";

pub(in crate::query) async fn execute(
    conn: &mut AsyncPgConnection,
    plan: &QueryPlan,
) -> Result<Vec<Value>> {
    // Execution goes through `to_sql_and_params`, not around it, so the SQL that
    // runs is by construction the SQL that translate returns. They used to be
    // built separately, and the execute side passed `?` straight to Diesel --
    // which does not translate it for Postgres, where `?` is a valid operator
    // character. `col = ? OR ...` then parsed as a prefix operator and failed as
    // "syntax error at or near OR", naming neither the placeholder nor the
    // column. A test comparing the two paths could not have caught it; removing
    // the second path does.
    let (sql, binds) = to_sql_and_params(plan)?;
    let mut query = sql_query(&sql).into_boxed::<Pg>();
    for bind in binds {
        query = bind_sql_param(query, bind)?;
    }

    let rows: Vec<JsonPayload> = query
        .load::<JsonPayload>(conn)
        .await
        .map_err(|err| ServiceError::Internal(err.into()))?;

    Ok(rows
        .into_iter()
        .map(|row| Value::from(row.payload))
        .collect())
}

pub(in crate::query) fn to_sql_and_params(plan: &QueryPlan) -> Result<(String, Vec<BindParam>)> {
    ensure_entity(plan)?;
    let built = build_sql(plan)?;
    Ok((rewrite_placeholders(&built.sql), built.binds))
}

fn ensure_entity(plan: &QueryPlan) -> Result<()> {
    if !matches!(plan.entity, Entity::DeviceIdentifiers) {
        return Err(ServiceError::InvalidRequest(
            "entity not supported by device_identifiers query".into(),
        ));
    }
    reject_aggregations(plan, "device_identifiers")
}

fn has_type_filter(filters: &[Filter]) -> bool {
    filters.iter().any(|f| {
        matches!(
            f.field.to_ascii_lowercase().as_str(),
            "identifier_type" | "type"
        )
    })
}

fn build_sql(plan: &QueryPlan) -> Result<BuiltSql> {
    let mut binds = Vec::new();
    let mut where_parts: Vec<String> = Vec::new();

    if let Some(TimeRange { start, end }) = &plan.time_range {
        where_parts.push("di.last_seen >= ? AND di.last_seen <= ?".to_string());
        binds.push(BindParam::timestamptz(*start));
        binds.push(BindParam::timestamptz(*end));
    }

    let mut value_without_type = false;

    for filter in &plan.filters {
        let field = filter.field.to_ascii_lowercase();
        if matches!(field.as_str(), "value" | "identifier_value") && !has_type_filter(&plan.filters)
        {
            value_without_type = true;
        }
        where_parts.push(filter_condition(filter, &mut binds)?);
    }

    // A bare value lookup cannot use `(identifier_type, identifier_value,
    // partition)` without a predicate on the leading column, and this table
    // carries millions of rows. Constrain the type to its closed set so the
    // plan still reaches the index instead of seq-scanning.
    if value_without_type {
        let owned: Vec<String> = IDENTIFIER_TYPES.iter().map(|t| (*t).to_string()).collect();
        binds.push(BindParam::TextArray(owned));
        where_parts.push("di.identifier_type = ANY(?)".to_string());
    }

    let where_sql = if where_parts.is_empty() {
        String::new()
    } else {
        format!(" WHERE {}", where_parts.join(" AND "))
    };

    let order_sql = order_by(&plan.order, ORDERABLE, "last_seen DESC NULLS LAST, id DESC")?;
    let metadata = jsonb_allowlist("di.metadata", IDENTIFIER_METADATA_KEYS);

    binds.push(BindParam::Int(plan.limit));
    binds.push(BindParam::Int(plan.offset));

    let sql = format!(
        "SELECT to_jsonb(sub) AS payload FROM (\
           SELECT di.id, di.device_id, di.identifier_type, di.identifier_value, di.partition, \
                  di.confidence, di.source, di.first_seen, di.last_seen, di.verified, \
                  {metadata} AS metadata, \
                  {MATCHES_CURRENT_FACTS} AS matches_current_facts, \
                  (d.deleted_at IS NOT NULL) AS owner_deleted, \
                  d.deleted_at AS owner_deleted_at, \
                  d.deleted_by AS owner_deleted_by, \
                  d.deleted_reason AS owner_deleted_reason, \
                  d.hostname AS owner_hostname, \
                  d.ip AS owner_ip, \
                  d.partition AS owner_partition \
           FROM platform.device_identifiers di \
           LEFT JOIN platform.ocsf_devices d ON d.uid = di.device_id\
           {where_sql} \
           ORDER BY {order_sql} \
           LIMIT ? OFFSET ?\
         ) sub"
    );

    Ok(BuiltSql { sql, binds })
}

fn filter_condition(filter: &Filter, binds: &mut Vec<BindParam>) -> Result<String> {
    let field = filter.field.to_ascii_lowercase();
    match field.as_str() {
        "device_id" | "device" | "device_uid" | "uid" => {
            text_condition("di.device_id", filter, binds)
        }
        "identifier_type" | "type" => text_condition("di.identifier_type", filter, binds),
        "value" | "identifier_value" => text_condition("di.identifier_value", filter, binds),
        "partition" => text_condition("di.partition", filter, binds),
        "confidence" => text_condition("di.confidence", filter, binds),
        "source" => text_condition("di.source", filter, binds),
        "verified" => bool_condition("di.verified", filter, binds),
        "owner_deleted" | "deleted" => {
            let want = scalar_bool(filter)?;
            Ok(if want {
                "d.deleted_at IS NOT NULL".to_string()
            } else {
                "d.deleted_at IS NULL".to_string()
            })
        }
        "matches_current_facts" | "corroborated" => {
            let raw = scalar_text(filter)?;
            let want = matches!(raw.to_ascii_lowercase().as_str(), "true" | "1" | "yes");
            Ok(if want {
                format!("({MATCHES_CURRENT_FACTS})")
            } else {
                format!("NOT ({MATCHES_CURRENT_FACTS})")
            })
        }
        other => Err(ServiceError::InvalidRequest(format!(
            "unsupported device_identifiers filter '{other}'"
        ))),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::query::identity::tests_support::plan_for;

    #[test]
    fn projects_currency_and_owner_tombstone() {
        let (sql, _) =
            to_sql_and_params(&plan_for("in:device_identifiers device_id:sr:aaa limit:10"))
                .unwrap();
        assert!(sql.contains("matches_current_facts"), "{sql}");
        assert!(sql.contains("owner_deleted"), "{sql}");
        assert!(sql.contains("owner_deleted_reason"), "{sql}");
        assert!(sql.contains("LEFT JOIN platform.ocsf_devices"), "{sql}");
    }

    #[test]
    fn mac_currency_checks_interfaces_as_well_as_the_column() {
        let (sql, _) = to_sql_and_params(&plan_for("in:identifiers limit:10")).unwrap();
        assert!(sql.contains("platform.device_interface_macs"), "{sql}");
        // Normalised on both sides: stored MACs are not consistently delimited.
        assert!(sql.contains("replace(replace("), "{sql}");
    }

    #[test]
    fn value_without_type_constrains_the_leading_index_column() {
        // A bare value lookup on a 12M-row table must not seq-scan.
        let (sql, binds) =
            to_sql_and_params(&plan_for("in:identifiers value:001122334455 limit:10")).unwrap();
        assert!(sql.contains("di.identifier_type = ANY($"), "{sql}");
        let types = binds.iter().find_map(|b| match b {
            BindParam::TextArray(values) => Some(values.clone()),
            _ => None,
        });
        assert_eq!(types.map(|t| t.len()), Some(8));
    }

    #[test]
    fn value_with_explicit_type_does_not_add_the_expansion() {
        let (sql, _) = to_sql_and_params(&plan_for(
            "in:identifiers identifier_type:mac value:001122334455 limit:10",
        ))
        .unwrap();
        assert!(!sql.contains("= ANY($"), "{sql}");
    }

    #[test]
    fn metadata_is_allowlisted() {
        let (sql, _) = to_sql_and_params(&plan_for("in:identifiers limit:10")).unwrap();
        assert!(sql.contains("jsonb_each"), "{sql}");
        assert!(!sql.contains("di.metadata AS metadata"), "{sql}");
    }

    #[test]
    fn types_without_a_comparable_current_fact_are_null_not_false() {
        // An armis/netbox/integration id has no column on ocsf_devices it could
        // equal. Reporting false would read as "stale", which is a different
        // and wrong claim.
        let (sql, _) = to_sql_and_params(&plan_for("in:identifiers limit:10")).unwrap();
        assert!(sql.contains("ELSE NULL::boolean"), "{sql}");
        // The types that DO have a comparable fact are still compared.
        assert!(sql.contains("di.identifier_type = 'agent_id'"), "{sql}");
        assert!(sql.contains("di.identifier_type = 'ip'"), "{sql}");
        assert!(sql.contains("di.identifier_type = 'mac'"), "{sql}");
        // hostname must not be the catch-all for every remaining type.
        assert!(
            !sql.contains("ELSE COALESCE(d.hostname"),
            "hostname must not be the ELSE branch: {sql}"
        );
    }

    #[test]
    fn injection_in_a_value_is_bound() {
        let injection = "aaa' OR '1'='1";
        let query = format!("in:identifiers value:\"{injection}\" limit:10");
        let (sql, binds) = to_sql_and_params(&plan_for(&query)).unwrap();
        assert!(!sql.contains("1'='1"), "{sql}");
        assert!(
            binds
                .iter()
                .any(|b| matches!(b, BindParam::Text(v) if v == injection))
        );
    }

    #[test]
    fn unknown_filter_is_rejected() {
        let err = to_sql_and_params(&plan_for("in:identifiers nonsense:1")).unwrap_err();
        assert!(matches!(err, ServiceError::InvalidRequest(_)));
    }
}
