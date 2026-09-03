//! SRQL entities for device identity reconciliation diagnostics.
//!
//! Five read-only entities that together let an operator explain an inventory
//! change without database credentials (GitHub #4229):
//!
//! * [`merge_audit`] -- merge records, plus `chain:` recursive resolution of the
//!   canonical merge chain in both directions.
//! * [`device_revival_audit`] -- every time a tombstoned device came back.
//! * [`device_identifiers`] -- identifier ownership, joined to the owner's
//!   current facts so a historical identifier is distinguishable from a
//!   corroborated one.
//! * [`reconciliation_runs`] -- one row per scheduled sweep, including whether
//!   it stopped at its work cap.
//! * [`evidence_edges`] -- the connected component of devices joined by shared
//!   identifiers, separating direct evidence from transitive connectivity.
//!
//! These build SQL text with `?` placeholders rather than the Diesel DSL. Two
//! of them are recursive CTEs and two project computed columns that are not on
//! any table, neither of which the typed DSL expresses well. `public_endpoints`
//! sets the same precedent. Every value is bound; nothing is interpolated.

pub(super) mod device_identifiers;
pub(super) mod device_revival_audit;
pub(super) mod evidence_edges;
pub(super) mod merge_audit;
pub(super) mod reconciliation_runs;

use super::BindParam;
use crate::{
    error::{Result, ServiceError},
    jsonb::DbJson,
    parser::{Filter, FilterOp, OrderDirection},
};
use diesel::deserialize::QueryableByName;
use diesel::sql_types::Jsonb;

/// Row shape for every identity entity: one jsonb payload per row.
#[derive(Debug, QueryableByName)]
#[diesel(check_for_backend(diesel::pg::Pg))]
pub(super) struct JsonPayload {
    #[diesel(sql_type = Jsonb)]
    pub payload: DbJson,
}

/// Hard ceiling on how far the two recursive walks may travel.
///
/// The merge graph is known to contain cycles -- oscillating pairs re-merged
/// 18-22 times are a documented live condition -- so termination cannot rely on
/// the data being acyclic. `UNION` on visited device ids handles the cycle; this
/// cap handles a legitimately deep chain, and the caller is told when it bites
/// rather than being handed a partial chain that looks complete.
pub(super) const DEFAULT_DEPTH_CAP: i64 = 32;
pub(super) const MAX_DEPTH_CAP: i64 = 256;

/// Keys projected from `merge_audit.details`.
///
/// The column is free-form jsonb written by several callers. Projecting it
/// whole would hand every SRQL and MCP caller whatever any writer happened to
/// put there, so unknown keys are dropped rather than passed through.
pub(super) const MERGE_DETAILS_KEYS: &[&str] = &[
    "source",
    "component_size",
    "evidence",
    "reason",
    "identifier_type",
    "identifier_value",
    "partition",
    "confidence",
    "merge_kind",
    "canonical_device_id",
];

/// Keys projected from `device_identifiers.metadata`.
pub(super) const IDENTIFIER_METADATA_KEYS: &[&str] = &[
    "source",
    "observed_by",
    "interface_name",
    "if_index",
    "sighting_count",
    "promoted_at",
    "origin",
];

/// The closed set of identifier types.
///
/// A bare `value:` filter with no `type:` expands to `= ANY(<this>)` so the plan
/// still uses the leading column of `device_identifiers_unique_identifier_index`
/// instead of scanning a table that carries millions of rows.
pub(super) const IDENTIFIER_TYPES: &[&str] = &[
    "agent_id",
    "armis_device_id",
    "integration_id",
    "netbox_device_id",
    "hardware_serial",
    "mac",
    "ip",
    "passive_fingerprint",
];

/// Build the SQL fragment that filters a jsonb column down to an allowlist.
///
/// Emits a literal `array[...]` of key names rather than a bind, because the
/// allowlist is a compile-time constant in this file and never caller input.
pub(super) fn jsonb_allowlist(column: &str, keys: &[&str]) -> String {
    let quoted = keys
        .iter()
        .map(|key| format!("'{key}'"))
        .collect::<Vec<_>>()
        .join(", ");
    format!(
        "COALESCE(jsonb_strip_nulls((SELECT jsonb_object_agg(k, v) FROM jsonb_each(COALESCE({column}, '{{}}'::jsonb)) AS e(k, v) WHERE k IN ({quoted}))), '{{}}'::jsonb)"
    )
}

pub(super) struct BuiltSql {
    pub sql: String,
    pub binds: Vec<BindParam>,
}

/// Diesel's `sql_query` takes `?`; `to_sql_and_params` must hand callers real
/// `$n` placeholders.
pub(super) fn rewrite_placeholders(sql: &str) -> String {
    let mut out = String::with_capacity(sql.len() + 8);
    let mut idx = 1u32;
    for ch in sql.chars() {
        if ch == '?' {
            out.push('$');
            out.push_str(&idx.to_string());
            idx += 1;
        } else {
            out.push(ch);
        }
    }
    out
}

pub(super) fn scalar_text(filter: &Filter) -> Result<String> {
    Ok(filter.value.as_scalar()?.to_string())
}

pub(super) fn scalar_bool(filter: &Filter) -> Result<bool> {
    match filter
        .value
        .as_scalar()?
        .to_string()
        .to_ascii_lowercase()
        .as_str()
    {
        "true" | "1" | "yes" => Ok(true),
        "false" | "0" | "no" => Ok(false),
        other => Err(ServiceError::InvalidRequest(format!(
            "expected a boolean for {}, got '{other}'",
            filter.field
        ))),
    }
}

/// Equality, negation, membership, and `%` wildcards for a text column.
///
/// `ILIKE` is used only when the caller actually wrote a `%`; a plain value
/// stays an equality so it can use an index.
pub(super) fn text_condition(
    column: &str,
    filter: &Filter,
    binds: &mut Vec<BindParam>,
) -> Result<String> {
    if let Ok(values) = filter.value.as_list() {
        let owned: Vec<String> = values.iter().map(ToString::to_string).collect();
        binds.push(BindParam::TextArray(owned));
        return Ok(match filter.op {
            FilterOp::NotEq => format!("NOT ({column} = ANY(?))"),
            _ => format!("{column} = ANY(?)"),
        });
    }

    let value = scalar_text(filter)?;

    if value.contains('%') {
        binds.push(BindParam::Text(value));
        return Ok(match filter.op {
            FilterOp::NotEq => format!("({column} IS NULL OR {column} NOT ILIKE ?)"),
            _ => format!("{column} ILIKE ?"),
        });
    }

    binds.push(BindParam::Text(value));
    Ok(match filter.op {
        FilterOp::NotEq => format!("({column} IS NULL OR {column} <> ?)"),
        _ => format!("{column} = ?"),
    })
}

pub(super) fn bool_condition(
    column: &str,
    filter: &Filter,
    binds: &mut Vec<BindParam>,
) -> Result<String> {
    let value = scalar_bool(filter)?;
    let value = match filter.op {
        FilterOp::NotEq => !value,
        FilterOp::Eq => value,
        _ => {
            return Err(ServiceError::InvalidRequest(format!(
                "{} filter only supports equality",
                filter.field
            )));
        }
    };
    binds.push(BindParam::Bool(value));
    Ok(format!("COALESCE({column}, false) = ?"))
}

pub(super) fn numeric_condition(
    column: &str,
    filter: &Filter,
    binds: &mut Vec<BindParam>,
) -> Result<String> {
    let raw = scalar_text(filter)?;
    let value: f64 = raw.parse().map_err(|_| {
        ServiceError::InvalidRequest(format!("{} expects a number, got '{raw}'", filter.field))
    })?;
    let op = match filter.op {
        FilterOp::Eq => "=",
        FilterOp::NotEq => "<>",
        FilterOp::Gt => ">",
        FilterOp::Gte => ">=",
        FilterOp::Lt => "<",
        FilterOp::Lte => "<=",
        _ => {
            return Err(ServiceError::InvalidRequest(format!(
                "unsupported comparison for {}",
                filter.field
            )));
        }
    };
    binds.push(BindParam::Float(value));
    Ok(format!("{column} {op} ?"))
}

/// Render an ORDER BY from the plan, restricted to a per-entity allowlist so a
/// caller cannot order by an arbitrary expression.
pub(super) fn order_by(
    order: &[crate::parser::OrderClause],
    allowed: &[(&str, &str)],
    default: &str,
) -> Result<String> {
    if order.is_empty() {
        return Ok(default.to_string());
    }

    let mut parts = Vec::with_capacity(order.len());
    for clause in order {
        let column = allowed
            .iter()
            .find(|(field, _)| field.eq_ignore_ascii_case(&clause.field))
            .map(|(_, column)| *column)
            .ok_or_else(|| {
                ServiceError::InvalidRequest(format!("cannot sort by '{}'", clause.field))
            })?;
        let direction = match clause.direction {
            OrderDirection::Asc => "ASC",
            OrderDirection::Desc => "DESC",
        };
        parts.push(format!("{column} {direction}"));
    }
    Ok(parts.join(", "))
}

/// Reject stats/downsample uniformly: none of these entities is a hypertable
/// and none has a group-by caller yet.
pub(super) fn reject_aggregations(plan: &super::QueryPlan, entity: &str) -> Result<()> {
    if plan.stats.is_some() {
        return Err(ServiceError::InvalidRequest(format!(
            "{entity} does not support stats queries"
        )));
    }
    if plan.downsample.is_some() {
        return Err(ServiceError::InvalidRequest(format!(
            "{entity} does not support downsample"
        )));
    }
    Ok(())
}

/// Read a depth cap from a `depth:` filter, clamped.
pub(super) fn depth_cap(filters: &[Filter]) -> Result<i64> {
    let Some(filter) = filters
        .iter()
        .find(|f| f.field.eq_ignore_ascii_case("depth"))
    else {
        return Ok(DEFAULT_DEPTH_CAP);
    };
    let raw = scalar_text(filter)?;
    let parsed: i64 = raw.parse().map_err(|_| {
        ServiceError::InvalidRequest(format!("depth expects a number, got '{raw}'"))
    })?;
    if parsed < 1 {
        return Err(ServiceError::InvalidRequest(
            "depth must be at least 1".into(),
        ));
    }
    Ok(parsed.min(MAX_DEPTH_CAP))
}

#[cfg(test)]
pub(super) mod tests_support {
    use crate::{
        config::AppConfig,
        parser,
        query::{QueryPlan, QueryRequest, build_query_plan},
    };

    /// Build a `QueryPlan` from SRQL text, the same way the HTTP path does.
    pub(crate) fn plan_for(query: &str) -> QueryPlan {
        let request = QueryRequest {
            query: query.to_string(),
            limit: Some(25),
            cursor: None,
            direction: Default::default(),
            mode: None,
        };
        let ast = parser::parse(query).expect("parse identity query");
        build_query_plan(
            &AppConfig::embedded("postgres://srql-test".to_string()),
            &request,
            ast,
        )
        .expect("build identity plan")
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn allowlist_names_only_the_permitted_keys() {
        let sql = jsonb_allowlist("ma.details", MERGE_DETAILS_KEYS);
        assert!(sql.contains("'source'"));
        assert!(sql.contains("'component_size'"));
        // A key nothing allowlists must not appear.
        assert!(!sql.contains("'password'"));
        assert!(sql.contains("jsonb_each"));
    }

    #[test]
    fn every_entity_emits_positional_placeholders_for_execution() {
        // The SQL handed to `sql_query` must carry `$n`, never `?`. Postgres
        // treats `?` as an operator character, so a stray one does not fail as
        // "unknown placeholder" -- it fails as a syntax error at the NEXT token,
        // which is how this reached CI reading as a broken OR clause.
        for query in [
            "in:merge_audit device_id:sr:aaa limit:10",
            "in:merge_audit chain:sr:aaa limit:10",
            "in:device_revival_audit device_uid:sr:aaa limit:10",
            "in:device_identifiers device_id:sr:aaa limit:10",
            "in:identity_reconciliation_runs status:failed limit:10",
            "in:identity_evidence_edges device:sr:aaa limit:10",
        ] {
            let plan = tests_support::plan_for(query);
            let (sql, binds) = match plan.entity {
                crate::parser::Entity::MergeAudit => merge_audit::to_sql_and_params(&plan),
                crate::parser::Entity::DeviceRevivalAudit => {
                    device_revival_audit::to_sql_and_params(&plan)
                }
                crate::parser::Entity::DeviceIdentifiers => {
                    device_identifiers::to_sql_and_params(&plan)
                }
                crate::parser::Entity::IdentityReconciliationRuns => {
                    reconciliation_runs::to_sql_and_params(&plan)
                }
                crate::parser::Entity::IdentityEvidenceEdges => {
                    evidence_edges::to_sql_and_params(&plan)
                }
                other => panic!("unexpected entity {other:?} for {query}"),
            }
            .unwrap_or_else(|err| panic!("{query} failed to build: {err:?}"));

            assert!(!sql.contains('?'), "{query} left a bare `?` in: {sql}");
            for n in 1..=binds.len() {
                assert!(
                    sql.contains(&format!("${n}")),
                    "{query} binds {} values but has no ${n}: {sql}",
                    binds.len()
                );
            }
        }
    }

    #[test]
    fn placeholders_become_positional() {
        assert_eq!(
            rewrite_placeholders("SELECT ? WHERE a = ? AND b = ?"),
            "SELECT $1 WHERE a = $2 AND b = $3"
        );
    }

    #[test]
    fn depth_cap_is_clamped_and_defaulted() {
        assert_eq!(depth_cap(&[]).unwrap(), DEFAULT_DEPTH_CAP);
    }

    #[test]
    fn identifier_types_match_device_identifier_exactly() {
        // The ANY() expansion is only index-safe while this list stays closed,
        // and it is only CORRECT while it matches DeviceIdentifier's declared
        // types. A type missing here makes a bare `value:` lookup for that type
        // silently return nothing -- the query succeeds and finds no rows, which
        // is indistinguishable from the identifier not existing.
        //
        // Source of truth: @identifier_types in
        // elixir/serviceradar_core/lib/serviceradar/inventory/device_identifier.ex
        let expected = [
            "agent_id",
            "armis_device_id",
            "integration_id",
            "netbox_device_id",
            "hardware_serial",
            "mac",
            "ip",
            "passive_fingerprint",
        ];
        assert_eq!(IDENTIFIER_TYPES, &expected);
    }
}
