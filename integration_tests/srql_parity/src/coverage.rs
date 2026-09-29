//! Task 1.5: every chart query a checked-in dashboard sends to a warehouse-served entity has an
//! inventory entry.
//!
//! The dashboard definitions (`priv/dashboards`, `priv/dashboard-packages`) are declarative JSON.
//! They are loaded as data and each panel's SRQL query is read from its `srql_query` / `query`
//! field, so prose that happens to mention a query is not one. A panel that charts a
//! warehouse-served entity must be covered by an inventory entry of the same shape.
//!
//! Queries the product assembles in Elixir are checked on the Elixir side, by
//! `elixir/web-ng/test/phoenix/srql/warehouse_query_inventory_test.exs`: it calls the product's
//! query builders through their public functions and matches every warehouse query they produce
//! against this inventory, with the normalization `shape_examples.json` pins for both languages.

use crate::shape::{Shape, shape_of};
use serde_json::Value;
use std::path::{Path, PathBuf};

/// The dashboard definition trees, relative to the repository root. Each must yield at least one
/// warehouse query, so a root that drops out of the runfiles fails loudly.
pub const DASHBOARD_ROOTS: &[&str] = &[
    "elixir/web-ng/priv/dashboards",
    "elixir/web-ng/priv/dashboard-packages",
];

/// The fields of a dashboard or package definition that hold an SRQL query.
const QUERY_FIELDS: &[&str] = &["srql_query", "query"];

/// Canonical SRQL entity for every spelling `ServiceRadar.Analytics.StarRocks.Readers.
/// dataset_for_entity/1` routes to the warehouse, restricted to the entities the StarRocks
/// dialect (`rust/srql/src/query/starrocks.rs` `dataset_for`, `starrocks/mtr.rs`,
/// `starrocks/otel_metrics.rs`) compiles.
/// `None` for anything else: a query SRQL never sends to StarRocks has no parity question.
pub fn warehouse_entity(entity: &str) -> Option<&'static str> {
    let entity = entity
        .trim_matches(|c| c == '"' || c == '\'')
        .to_ascii_lowercase();
    Some(match entity.as_str() {
        "flows" | "flow" | "network_activity" => "flows",
        "attributed_flows" | "attributed_flow" | "flow_attributions" | "flow_attribution" => {
            "attributed_flows"
        }
        "timeseries_metrics" | "timeseries" => "timeseries_metrics",
        "cpu_metrics" | "cpu" => "cpu_metrics",
        "memory_metrics" | "memory" => "memory_metrics",
        "disk_metrics" | "disk" => "disk_metrics",
        "process_metrics" | "processes" => "process_metrics",
        "snmp_metrics" | "snmp" => "snmp_metrics",
        "rperf_metrics" | "rperf" => "rperf_metrics",
        "logs" => "logs",
        "events" | "activity" => "events",
        "security_findings" | "security_finding" | "findings" | "finding" => "security_findings",
        "scan_activity" | "scan_activities" | "security_scans" | "scanner_activity" => {
            "scan_activity"
        }
        "dns_activity" | "dns_activities" | "dns_security_activity" | "powerdns" | "pdns" => {
            "dns_activity"
        }
        "mtr_traces" => "mtr_traces",
        "mtr_hops" | "mtr_hop_stats" => "mtr_hops",
        "otel_metrics" | "metrics" => "otel_metrics",
        "otel_metric_points" | "metric_points" => "otel_metric_points",
        "otel_traces" | "traces" | "trace_spans" => "traces",
        "otel_trace_summaries" | "trace_summaries" | "traces_summaries" => "otel_trace_summaries",
        _ => return None,
    })
}

/// One panel query on a warehouse-served entity.
#[derive(Debug, Clone)]
pub struct PanelQuery {
    pub file: String,
    pub query: String,
    pub entity: &'static str,
    pub shape: Shape,
}

/// Every SRQL query held in a query field of a parsed definition, at any depth.
pub fn definition_queries(value: &Value) -> Vec<String> {
    let mut queries = Vec::new();
    collect_queries(value, &mut queries);
    queries
}

fn collect_queries(value: &Value, out: &mut Vec<String>) {
    match value {
        Value::Object(map) => {
            for (key, value) in map {
                match value {
                    Value::String(text) if QUERY_FIELDS.contains(&key.as_str()) => {
                        out.push(text.clone());
                    }
                    _ => collect_queries(value, out),
                }
            }
        }
        Value::Array(items) => items.iter().for_each(|item| collect_queries(item, out)),
        _ => {}
    }
}

/// The warehouse-entity queries of one definition.
pub fn panel_queries_in(file: &str, definition: &Value) -> Vec<PanelQuery> {
    definition_queries(definition)
        .into_iter()
        .filter_map(|query| {
            let shape = shape_of(&query);
            let entity = warehouse_entity(shape.entity.as_deref()?)?;
            Some(PanelQuery {
                file: file.to_string(),
                query,
                entity,
                shape,
            })
        })
        .collect()
}

/// The warehouse-entity queries of every `*.json` definition under one root. An unreadable
/// directory or a file that is not JSON is an error, never an empty result.
pub fn panel_queries(repo_root: &Path, root: &str) -> Result<Vec<PanelQuery>, String> {
    let mut files = Vec::new();
    json_files(&repo_root.join(root), &mut files)?;
    files.sort();
    let mut queries = Vec::new();
    for path in files {
        let relative = path
            .strip_prefix(repo_root)
            .unwrap_or(&path)
            .to_string_lossy()
            .replace('\\', "/");
        let text = std::fs::read_to_string(&path).map_err(|e| format!("{relative}: {e}"))?;
        let definition: Value =
            serde_json::from_str(&text).map_err(|e| format!("{relative}: not JSON: {e}"))?;
        queries.extend(panel_queries_in(&relative, &definition));
    }
    Ok(queries)
}

fn json_files(dir: &Path, out: &mut Vec<PathBuf>) -> Result<(), String> {
    let entries = std::fs::read_dir(dir).map_err(|e| format!("{}: {e}", dir.display()))?;
    for entry in entries {
        let path = entry.map_err(|e| format!("{}: {e}", dir.display()))?.path();
        // Runfiles trees are symlinks; `metadata` follows them.
        let metadata = std::fs::metadata(&path).map_err(|e| format!("{}: {e}", path.display()))?;
        if metadata.is_dir() {
            json_files(&path, out)?;
        } else if path.extension().is_some_and(|ext| ext == "json") {
            out.push(path);
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn aliases_resolve_to_the_canonical_warehouse_entity() {
        assert_eq!(warehouse_entity("snmp"), Some("snmp_metrics"));
        assert_eq!(warehouse_entity("mtr_hop_stats"), Some("mtr_hops"));
        assert_eq!(warehouse_entity("pdns"), Some("dns_activity"));
        assert_eq!(warehouse_entity("\"Flows\""), Some("flows"));
        assert_eq!(warehouse_entity("devices"), None);
        assert_eq!(warehouse_entity("cpu_metrics"), Some("cpu_metrics"));
    }

    #[test]
    fn only_query_fields_of_warehouse_entities_are_panel_queries() {
        let definition: Value = serde_json::from_str(
            r#"{
              "description": "in:flows bucket:5m agg:sum is only prose here",
              "panels": [
                {"srql_query": "in:mtr_hops time:last_24h stats:\"loss_ratio(sent, received) as loss by addr\" sort:loss:desc limit:20"},
                {"srql_query": "in:devices sort:first_seen:desc limit:5"},
                {"nested": [{"query": "in:flows time:last_1h bucket:5m agg:sum value_field:bytes_total"}]},
                {"title": "in:logs stats:\"count() as total\""}
              ]
            }"#,
        )
        .unwrap();
        let queries = panel_queries_in("x/dash.json", &definition);
        let found: Vec<(&str, bool)> = queries
            .iter()
            .map(|q| (q.entity, q.shape.is_chart()))
            .collect();
        assert_eq!(found, vec![("mtr_hops", true), ("flows", true)]);
        assert_eq!(
            queries[0].shape.clauses["stats"],
            "loss_ratio(sent,received)|by:addr"
        );
    }

    #[test]
    fn a_missing_root_or_a_file_that_is_not_json_is_an_error() {
        let root = std::env::temp_dir().join(format!("srql_parity_cov_{}", std::process::id()));
        std::fs::create_dir_all(root.join("dash")).unwrap();
        std::fs::write(root.join("dash/broken.json"), "{not json").unwrap();
        let broken = panel_queries(&root, "dash");
        std::fs::remove_dir_all(&root).unwrap();
        assert!(broken.unwrap_err().contains("not JSON"));
        assert!(panel_queries(Path::new("/nonexistent-srql-parity"), "dash").is_err());
    }
}

#[cfg(test)]
mod inventory_coverage {
    use super::*;
    use crate::inventory::Inventory;

    /// Task 1.5. When this fails, add an `inventory.json` entry whose query has the reported
    /// shape (and run the parity target to see whether the backends agree on it).
    #[test]
    fn every_warehouse_chart_panel_in_a_dashboard_definition_has_an_inventory_entry() {
        let root = crate::repo_root();
        let inventory = Inventory::load();
        let mut missing = Vec::new();
        for dashboards in DASHBOARD_ROOTS {
            let queries = panel_queries(&root, dashboards)
                .unwrap_or_else(|e| panic!("reading {dashboards}: {e}"));
            assert!(
                !queries.is_empty(),
                "{dashboards} yielded no warehouse query: the definitions are probably not in \
                 the runfiles"
            );
            missing.extend(
                queries
                    .into_iter()
                    .filter(|q| q.shape.is_chart() && !inventory.covers(q.entity, &q.shape)),
            );
        }
        let report: Vec<String> = missing
            .iter()
            .map(|q| format!("  {}  {}\n      {}", q.file, q.shape.describe(), q.query))
            .collect();
        assert!(
            missing.is_empty(),
            "{} dashboard chart queries have no inventory entry:\n{}",
            missing.len(),
            report.join("\n")
        );
    }
}
