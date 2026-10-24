//! Filters over the canonical merged availability on `ocsf_devices`
//! (`add-merged-device-availability`): the state, its provenance, and the
//! per-agent summary the resolver keeps in `availability_agents`.
//!
//! The row query, the bind collector and the grouped-stats builder all build
//! from these functions, so the three paths cannot drift on a predicate or on
//! its one bind. `availability_agents` is NULL until the resolver owns the
//! device row, and a missing counter reads as zero.

use crate::{
    error::{Result, ServiceError},
    parser::{Filter, FilterOp},
};

const STATES: [&str; 3] = ["available", "unavailable", "unknown"];

const CLASSES: [&str; 6] = [
    "operator_policy",
    "self_report",
    "managing_controller",
    "active_probe",
    "passive_observation",
    "inventory_declared",
];

/// Availability rank for ordering: available, then unavailable, then unknown.
pub(in crate::query::devices) const AVAILABILITY_RANK_SQL: &str =
    "CASE availability_state WHEN 'available' THEN 0 WHEN 'unavailable' THEN 1 ELSE 2 END";

/// A filter that binds one text array: `<column> = ANY(?)`, negated for `!=` and `not in`.
pub(in crate::query::devices) struct BoundFilter {
    pub column: &'static str,
    pub values: Vec<String>,
    pub negated: bool,
}

impl BoundFilter {
    /// The predicate with one `?` placeholder for the values.
    pub fn placeholder_sql(&self) -> String {
        if self.negated {
            format!("NOT ({} = ANY(?))", self.column)
        } else {
            format!("{} = ANY(?)", self.column)
        }
    }
}

/// `availability:`, `availability_source:` and `availability_class:`. `None` for any
/// other field, and for an empty list, which filters nothing and binds nothing.
pub(in crate::query::devices) fn bound_filter(filter: &Filter) -> Result<Option<BoundFilter>> {
    let (column, allowed): (&'static str, Option<&[&str]>) = match filter.field.as_str() {
        "availability" => ("availability_state", Some(&STATES)),
        "availability_source" => (
            "COALESCE(availability_decided_by ->> 'source_kind', '')",
            None,
        ),
        "availability_class" => (
            "COALESCE(availability_decided_by ->> 'authority_class', '')",
            Some(&CLASSES),
        ),
        _ => return Ok(None),
    };

    let (values, negated) = values_and_negation(filter)?;
    if values.is_empty() {
        return Ok(None);
    }

    let values = match allowed {
        Some(allowed) => values
            .into_iter()
            .map(|value| {
                let value = value.trim().to_ascii_lowercase();
                if allowed.contains(&value.as_str()) {
                    Ok(value)
                } else {
                    Err(ServiceError::InvalidRequest(format!(
                        "{} must be one of: {}",
                        filter.field,
                        allowed.join(", ")
                    )))
                }
            })
            .collect::<Result<Vec<_>>>()?,
        None => values,
    };

    Ok(Some(BoundFilter {
        column,
        values,
        negated,
    }))
}

/// `agent_reachability:` and `availability_policy:` as a complete predicate that binds
/// nothing (every literal comes from a validated keyword). `None` for any other field,
/// and for an empty list.
pub(in crate::query::devices) fn summary_predicate(filter: &Filter) -> Result<Option<String>> {
    let keyword: fn(&str) -> Option<String> = match filter.field.as_str() {
        "agent_reachability" => reachability_sql,
        "availability_policy" => policy_sql,
        _ => return Ok(None),
    };

    let (values, negated) = values_and_negation(filter)?;
    if values.is_empty() {
        return Ok(None);
    }

    let predicates = values
        .iter()
        .map(|value| {
            keyword(&value.trim().to_ascii_lowercase()).ok_or_else(|| {
                ServiceError::InvalidRequest(format!(
                    "{} must be one of: {}",
                    filter.field,
                    match filter.field.as_str() {
                        "agent_reachability" => "all, partial, none",
                        _ => "violation, verified, inconclusive",
                    }
                ))
            })
        })
        .collect::<Result<Vec<_>>>()?;

    let any = format!("({})", predicates.join(" OR "));
    Ok(Some(if negated { format!("NOT {any}") } else { any }))
}

fn agent_counter(key: &str) -> String {
    format!("COALESCE((availability_agents ->> '{key}')::bigint, 0)")
}

/// Reachability over fresh non-control agents: `all` reach it, `partial` some do and
/// some do not, `none` probe it and none reach it. A device no fresh agent probes
/// matches none of the three.
fn reachability_sql(value: &str) -> Option<String> {
    let up = agent_counter("up");
    let down = agent_counter("down");

    match value {
        "all" => Some(format!("({up} > 0 AND {down} = 0)")),
        "partial" => Some(format!("({up} > 0 AND {down} > 0)")),
        "none" => Some(format!("({up} = 0 AND {down} > 0)")),
        _ => None,
    }
}

fn policy_sql(value: &str) -> Option<String> {
    let key = match value {
        "violation" => "policy_violation",
        "verified" => "blocked_verified",
        "inconclusive" => "inconclusive_control",
        _ => return None,
    };

    Some(format!("{} > 0", agent_counter(key)))
}

fn values_and_negation(filter: &Filter) -> Result<(Vec<String>, bool)> {
    match filter.op {
        FilterOp::Eq => Ok((vec![filter.value.as_scalar()?.to_string()], false)),
        FilterOp::NotEq => Ok((vec![filter.value.as_scalar()?.to_string()], true)),
        FilterOp::In => Ok((filter.value.as_list()?.to_vec(), false)),
        FilterOp::NotIn => Ok((filter.value.as_list()?.to_vec(), true)),
        _ => Err(ServiceError::InvalidRequest(format!(
            "{} only supports equality and list filters",
            filter.field
        ))),
    }
}
