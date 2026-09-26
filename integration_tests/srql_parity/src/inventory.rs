//! The checked-in query-shape inventory (`inventory.json`), task 1.5.
//!
//! Every entry is a concrete SRQL query the parity runner executes against both backends. Its
//! SHAPE (`shape::shape_of`) is what the source scan compares against, so one entry accounts
//! for every product query with the same entity and translation-selecting clauses.
//!
//! An entry that is not expected to match names a deviation, and every deviation carries its
//! reason (task 1.6). Nothing is loosened implicitly: the default comparison is exact up to
//! floating-point rounding (`DEFAULT_RELATIVE_TOLERANCE`), and a wider tolerance, an ignored
//! column or an expected mismatch exists only as a named, reasoned deviation.

use crate::coverage::{Finding, warehouse_entity};
use crate::shape::{Shape, shape_of};
use serde::Deserialize;
use std::collections::BTreeMap;

/// Relative tolerance for comparing two floats computed by different engines. Summation order
/// and DOUBLE vs NUMERIC intermediate precision differ in the last few bits; anything larger
/// is a real difference.
pub const DEFAULT_RELATIVE_TOLERANCE: f64 = 1e-9;
/// Absolute floor for values that should be zero.
pub const DEFAULT_ABSOLUTE_TOLERANCE: f64 = 1e-9;

pub const INVENTORY_JSON: &str = include_str!("../inventory.json");

#[derive(Debug, Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Inventory {
    pub deviations: BTreeMap<String, Deviation>,
    pub entries: Vec<Entry>,
    /// Scanned templates that are not warehouse queries although the scan attributes them to
    /// one: a fragment whose base query, built in another function, names an entity SRQL does
    /// not serve from StarRocks. Each must still match a scanned template (a stale exclusion
    /// fails the coverage test) and say why.
    #[serde(default)]
    pub scan_exclusions: Vec<ScanExclusion>,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ScanExclusion {
    pub file: String,
    /// A substring of the scanned template text.
    pub text: String,
    pub reason: String,
}

impl ScanExclusion {
    pub fn matches(&self, finding: &Finding) -> bool {
        finding.template.file == self.file && finding.template.text.contains(&self.text)
    }
}

#[derive(Debug, Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Deviation {
    /// Why the two backends are allowed to differ here. Required and non-empty.
    pub reason: String,
    /// `accepted`: a documented semantic difference kept on purpose (task 1.6).
    /// `defect`: a StarRocks dialect bug found by this harness and not fixed yet.
    /// `unsupported`: the warehouse dialect refuses the shape (fail-closed, task 1.3).
    /// `reference_gap`: the CNPG dialect cannot answer the shape, so there is no reference
    /// result to compare with (a warehouse-only dataset such as flows can outgrow it).
    pub kind: DeviationKind,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum DeviationKind {
    Accepted,
    Defect,
    Unsupported,
    ReferenceGap,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize, Default)]
#[serde(rename_all = "snake_case")]
pub enum Expect {
    /// Both backends return the same rows.
    #[default]
    Match,
    /// The rows differ, for the reason the entry's deviation gives. The runner still executes
    /// both sides and FAILS if they start to agree, so a fixed defect cannot keep its xfail.
    Mismatch,
    /// The StarRocks dialect refuses to compile the query. The runner fails if it compiles.
    StarrocksRefuses,
    /// The CNPG dialect refuses the query; StarRocks must still compile and run it. The runner
    /// fails if CNPG starts to accept it, so the entry becomes a real comparison.
    CnpgRefuses,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Entry {
    pub id: String,
    /// The SRQL text, with `{window_*}` placeholders the fixture anchor fills in.
    pub query: String,
    #[serde(default)]
    pub expect: Expect,
    /// Required for anything but a plain match, and for `tolerance`/`ignore_columns`.
    #[serde(default)]
    pub deviation: Option<String>,
    /// Wider relative tolerance for the named columns (e.g. approximate percentiles).
    #[serde(default)]
    pub tolerance: Option<Tolerance>,
    /// Columns left out of the comparison.
    #[serde(default)]
    pub ignore_columns: Vec<String>,
    /// CNPG result columns renamed before the comparison, `{cnpg_name: starrocks_name}`, for a
    /// builder that names a column differently from the query's alias. The values are still
    /// compared.
    #[serde(default)]
    pub cnpg_rename: BTreeMap<String, String>,
    /// Compare rows in order. Defaults to true when the query sorts or buckets.
    #[serde(default)]
    pub ordered: Option<bool>,
    /// The product call sites this entry stands for. Informational.
    #[serde(default)]
    pub sources: Vec<String>,
    /// An empty result proves nothing, so a matching entry must return rows unless this is
    /// set (for a shape whose correct answer on the fixture is genuinely empty).
    #[serde(default)]
    pub allow_empty: bool,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Tolerance {
    pub relative: f64,
    pub columns: Vec<String>,
}

impl Entry {
    pub fn shape(&self) -> Shape {
        shape_of(&self.query)
    }

    pub fn entity(&self) -> Option<&'static str> {
        self.shape().entity.as_deref().and_then(warehouse_entity)
    }

    pub fn is_ordered(&self) -> bool {
        self.ordered.unwrap_or_else(|| {
            let shape = self.shape();
            shape.modifiers.contains("sort") || shape.clauses.contains_key("bucket")
        })
    }

    pub fn deviation<'a>(&self, inventory: &'a Inventory) -> Option<&'a Deviation> {
        self.deviation
            .as_ref()
            .and_then(|id| inventory.deviations.get(id))
    }
}

impl Inventory {
    pub fn load() -> Self {
        let inventory: Inventory =
            serde_json::from_str(INVENTORY_JSON).expect("inventory.json must parse");
        inventory.validate().expect("inventory.json must be valid");
        inventory
    }

    pub fn validate(&self) -> Result<(), String> {
        let mut problems = Vec::new();
        for (id, deviation) in &self.deviations {
            if deviation.reason.trim().len() < 20 {
                problems.push(format!("deviation {id}: the reason must say why"));
            }
            if !self
                .entries
                .iter()
                .any(|e| e.deviation.as_deref() == Some(id))
            {
                problems.push(format!("deviation {id}: no entry uses it"));
            }
        }
        for exclusion in &self.scan_exclusions {
            if exclusion.reason.trim().len() < 20 {
                problems.push(format!(
                    "scan exclusion {}: the reason must say why",
                    exclusion.file
                ));
            }
        }
        let mut ids = std::collections::BTreeSet::new();
        for entry in &self.entries {
            if !ids.insert(entry.id.as_str()) {
                problems.push(format!("{}: duplicate id", entry.id));
            }
            if entry.entity().is_none() {
                problems.push(format!(
                    "{}: `{}` is not a warehouse-served entity",
                    entry.id, entry.query
                ));
            }
            if !entry.query.contains("{window_") {
                problems.push(format!(
                    "{}: use a fixture window, never a relative time",
                    entry.id
                ));
            }
            let needs_deviation = entry.expect != Expect::Match
                || entry.tolerance.is_some()
                || !entry.ignore_columns.is_empty()
                || !entry.cnpg_rename.is_empty();
            match (&entry.deviation, needs_deviation) {
                (None, true) => problems.push(format!("{}: needs a deviation", entry.id)),
                (Some(id), _) if !self.deviations.contains_key(id) => {
                    problems.push(format!("{}: unknown deviation {id}", entry.id))
                }
                (Some(id), false) => problems.push(format!(
                    "{}: deviation {id} given but nothing deviates",
                    entry.id
                )),
                _ => {}
            }
            if let Some(deviation) = entry.deviation(self) {
                let consistent = match entry.expect {
                    Expect::StarrocksRefuses => deviation.kind == DeviationKind::Unsupported,
                    Expect::CnpgRefuses => deviation.kind == DeviationKind::ReferenceGap,
                    Expect::Mismatch => matches!(
                        deviation.kind,
                        DeviationKind::Accepted | DeviationKind::Defect
                    ),
                    Expect::Match => deviation.kind == DeviationKind::Accepted,
                };
                if !consistent {
                    problems.push(format!(
                        "{}: expect {:?} does not fit a {:?} deviation",
                        entry.id, entry.expect, deviation.kind
                    ));
                }
            }
        }
        if problems.is_empty() {
            Ok(())
        } else {
            Err(problems.join("\n"))
        }
    }

    /// Whether some entry accounts for a scanned template.
    pub fn covers(&self, finding: &Finding) -> bool {
        if self.scan_exclusions.iter().any(|e| e.matches(finding)) {
            return true;
        }
        self.entries.iter().any(|entry| {
            let Some(entity) = entry.entity() else {
                return false;
            };
            if !finding.entities.contains(&entity) {
                return false;
            }
            let mut scanned = finding.template.shape.clone();
            // A fragment's entity comes from its caller; compare the clauses only.
            scanned.entity = None;
            let mut literal = entry.shape();
            literal.entity = None;
            scanned.covered_by(&literal)
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_checked_in_inventory_is_valid() {
        let inventory = Inventory::load();
        assert!(!inventory.entries.is_empty());
    }

    #[test]
    fn every_dataset_the_warehouse_serves_has_entries() {
        let inventory = Inventory::load();
        for entity in [
            "flows",
            "timeseries_metrics",
            "snmp_metrics",
            "rperf_metrics",
            "logs",
            "events",
            "security_findings",
            "mtr_hops",
            "mtr_traces",
        ] {
            assert!(
                inventory.entries.iter().any(|e| e.entity() == Some(entity)),
                "no inventory entry for in:{entity}"
            );
        }
    }
}
