//! Task 1.5: every chart query the product sends to a warehouse-served entity has an inventory
//! entry.
//!
//! The scan walks the source trees the product builds SRQL in -- the Phoenix app, core, the
//! checked-in dashboards and dashboard packages, and the browser bundle -- extracts every chart
//! template (`scan`), keeps those whose entity SRQL can serve from StarRocks, and asks the
//! inventory to account for each one. A template the inventory does not cover fails the unit
//! test with the file, line and shape, so a new `in:<entity>` chart query cannot ship without a
//! parity entry, and a parity entry cannot be forgotten when a shape changes.

use crate::scan::{
    Literal, Template, entities_named_in, templates_from_literal_windows, templates_in,
};
use crate::shape::{PLACEHOLDER, shape_of};
use std::path::{Path, PathBuf};

/// The source trees scanned, relative to the repository root. Each is a named filegroup
/// (`srql_chart_query_sources`) so the Bazel test declares exactly these as inputs.
pub const SOURCE_ROOTS: &[&str] = &[
    "elixir/web-ng/lib",
    "elixir/web-ng/priv/dashboards",
    "elixir/web-ng/priv/dashboard-packages",
    "elixir/web-ng/assets/js",
    "elixir/serviceradar_core/lib",
];

/// Canonical SRQL entity for every spelling `ServiceRadar.Analytics.StarRocks.Readers.
/// dataset_for_entity/1` routes to the warehouse, restricted to the entities the StarRocks
/// dialect (`rust/srql/src/query/starrocks.rs` `dataset_for`, `starrocks/mtr.rs`) compiles.
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
        _ => return None,
    })
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Language {
    Elixir,
    Json,
    JavaScript,
}

fn language(path: &Path) -> Option<Language> {
    let name = path.file_name()?.to_str()?;
    if name.ends_with(".test.js") || name.ends_with(".spec.js") {
        return None;
    }
    match path.extension()?.to_str()? {
        "ex" => Some(Language::Elixir),
        "json" => Some(Language::Json),
        "js" | "mjs" | "ts" => Some(Language::JavaScript),
        _ => None,
    }
}

/// One scanned chart template, attributed to the warehouse entities it can run against.
#[derive(Debug, Clone)]
pub struct Finding {
    pub template: Template,
    /// The canonical entity of a rooted template, or every warehouse entity its file names
    /// for a fragment.
    pub entities: Vec<&'static str>,
}

/// Every warehouse chart template in one file.
pub fn findings_in(file: &str, source: &str) -> Vec<Finding> {
    let Some(language) = language(Path::new(file)) else {
        return Vec::new();
    };
    let (templates, named) = match language {
        Language::Elixir => (templates_in(file, source), entities_named_in(source)),
        Language::Json => {
            let windows = json_windows(source);
            let named = named_in_windows(&windows);
            (templates_from_literal_windows(file, windows), named)
        }
        Language::JavaScript => {
            let windows = js_windows(source);
            let named = named_in_windows(&windows);
            (templates_from_literal_windows(file, windows), named)
        }
    };
    let named: Vec<&'static str> = named.iter().filter_map(|e| warehouse_entity(e)).collect();
    templates
        .into_iter()
        .filter_map(|template| {
            let entities = match &template.shape.entity {
                Some(entity) => vec![warehouse_entity(entity)?],
                // A fragment belongs to the entities its file queries; a file that names
                // none of the warehouse entities builds some other entity's chart.
                None if named.is_empty() => return None,
                None => {
                    let mut named = named.clone();
                    named.sort();
                    named.dedup();
                    named
                }
            };
            Some(Finding { template, entities })
        })
        .collect()
}

fn named_in_windows(windows: &[Vec<Literal>]) -> Vec<String> {
    windows
        .iter()
        .flatten()
        .filter_map(|literal| shape_of(&literal.text).entity)
        .collect()
}

/// A JSON document's string values, one window each: a dashboard panel's query is one string.
fn json_windows(source: &str) -> Vec<Vec<Literal>> {
    let Ok(value) = serde_json::from_str::<serde_json::Value>(source) else {
        return Vec::new();
    };
    let mut windows = Vec::new();
    collect_json_strings(&value, &mut windows);
    windows
}

fn collect_json_strings(value: &serde_json::Value, out: &mut Vec<Vec<Literal>>) {
    match value {
        serde_json::Value::String(text) => out.push(vec![Literal {
            line: 0,
            text: text.clone(),
        }]),
        serde_json::Value::Array(items) => items.iter().for_each(|v| collect_json_strings(v, out)),
        serde_json::Value::Object(map) => map.values().for_each(|v| collect_json_strings(v, out)),
        _ => {}
    }
}

/// JavaScript string literals grouped by function. `${...}` interpolations become the
/// placeholder and `//` / `/* */` comments are skipped. A window starts at every line that
/// opens a `function` (declared, async, or exported). A regex literal is not recognised; one
/// containing a quote can shift the lexer until the end of that line, which a single-line
/// string literal cannot outlive.
fn js_windows(source: &str) -> Vec<Vec<Literal>> {
    let chars: Vec<char> = source.chars().collect();
    let mut windows: Vec<Vec<Literal>> = vec![Vec::new()];
    let mut index = 0;
    let mut line = 1;
    let mut line_start = true;
    while index < chars.len() {
        let ch = chars[index];
        if line_start {
            let rest: String = chars[index..].iter().take_while(|c| **c != '\n').collect();
            let trimmed = rest.trim_start();
            if [
                "function ",
                "async function ",
                "export function ",
                "export async function ",
            ]
            .iter()
            .any(|prefix| trimmed.starts_with(prefix))
            {
                windows.push(Vec::new());
            }
            line_start = false;
        }
        match ch {
            '\n' => {
                line += 1;
                line_start = true;
                index += 1;
            }
            '/' if chars.get(index + 1) == Some(&'/') => {
                while index < chars.len() && chars[index] != '\n' {
                    index += 1;
                }
            }
            '/' if chars.get(index + 1) == Some(&'*') => {
                index += 2;
                while index + 1 < chars.len() && !(chars[index] == '*' && chars[index + 1] == '/') {
                    if chars[index] == '\n' {
                        line += 1;
                    }
                    index += 1;
                }
                index += 2;
            }
            '"' | '\'' | '`' => {
                let quote = ch;
                let start_line = line;
                let mut text = String::new();
                index += 1;
                while index < chars.len() && chars[index] != quote {
                    let c = chars[index];
                    if c == '\\' && index + 1 < chars.len() {
                        if chars[index + 1] == '"' {
                            text.push('"');
                        }
                        index += 2;
                        continue;
                    }
                    if quote == '`' && c == '$' && chars.get(index + 1) == Some(&'{') {
                        let mut depth = 0usize;
                        while index < chars.len() {
                            match chars[index] {
                                '{' => depth += 1,
                                '}' => {
                                    depth -= 1;
                                    if depth == 0 {
                                        break;
                                    }
                                }
                                '\n' => line += 1,
                                _ => {}
                            }
                            index += 1;
                        }
                        text.push_str(PLACEHOLDER);
                        index += 1;
                        continue;
                    }
                    if c == '\n' {
                        if quote != '`' {
                            break;
                        }
                        line += 1;
                    }
                    text.push(c);
                    index += 1;
                }
                index += 1;
                if let Some(window) = windows.last_mut() {
                    window.push(Literal {
                        line: start_line,
                        text,
                    });
                }
            }
            _ => index += 1,
        }
    }
    windows.retain(|window| !window.is_empty());
    windows
}

/// Every source file under the scanned roots, sorted for a stable report.
pub fn source_files(repo_root: &Path) -> Vec<(String, PathBuf)> {
    let mut files = Vec::new();
    for root in SOURCE_ROOTS {
        walk(repo_root, &repo_root.join(root), &mut files);
    }
    files.sort();
    files
}

fn walk(repo_root: &Path, dir: &Path, out: &mut Vec<(String, PathBuf)>) {
    let Ok(entries) = std::fs::read_dir(dir) else {
        return;
    };
    for entry in entries.flatten() {
        let path = entry.path();
        // Runfiles trees are symlinks; `metadata` follows them.
        let Ok(metadata) = std::fs::metadata(&path) else {
            continue;
        };
        if metadata.is_dir() {
            if path
                .file_name()
                .is_some_and(|n| n == "node_modules" || n == "vendor")
            {
                continue;
            }
            walk(repo_root, &path, out);
        } else if language(&path).is_some() {
            let relative = path
                .strip_prefix(repo_root)
                .unwrap_or(&path)
                .to_string_lossy()
                .replace('\\', "/");
            out.push((relative, path));
        }
    }
}

/// Every warehouse chart template under the scanned roots.
pub fn all_findings(repo_root: &Path) -> Vec<Finding> {
    let mut findings = Vec::new();
    for (relative, path) in source_files(repo_root) {
        let Ok(source) = std::fs::read_to_string(&path) else {
            continue;
        };
        findings.extend(findings_in(&relative, &source));
    }
    findings
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
        assert_eq!(warehouse_entity("cpu_metrics"), None);
    }

    #[test]
    fn json_dashboard_queries_are_templates() {
        let source = r#"{"panels":[{"srql_query":"in:mtr_hops time:last_24h stats:\"loss_ratio(sent, received) as loss by addr\" sort:loss:desc limit:20"},{"srql_query":"in:devices sort:first_seen:desc limit:5"}]}"#;
        let findings = findings_in("x/dash.json", source);
        assert_eq!(findings.len(), 1);
        assert_eq!(findings[0].entities, vec!["mtr_hops"]);
        assert_eq!(
            findings[0].template.shape.clauses["stats"],
            "loss_ratio(sent,received)|by:addr"
        );
    }

    #[test]
    fn javascript_token_lists_and_template_literals_are_read() {
        let source = r#"
// in:flows bucket:5m agg:sum is a comment
function chart(ip) {
  const q = ["in:flows", `src_endpoint_ip:${quote(ip)}`, "bucket:5m", "agg:sum"].join(" ")
  return q
}
function rows() {
  return "in:flows sort:time:desc limit:10"
}
"#;
        let findings = findings_in("x/a.js", source);
        assert_eq!(findings.len(), 1, "{findings:?}");
        assert_eq!(
            findings[0].template.shape.describe(),
            "in:flows agg=sum bucket=*"
        );
        assert!(findings_in("x/a.test.js", source).is_empty());
    }

    #[test]
    fn a_fragment_in_a_file_with_no_warehouse_entity_is_not_ours() {
        let source = r##"
  def chart(base), do: "#{base} bucket:5m agg:avg"
  def list, do: "in:cpu_metrics sort:timestamp:desc"
"##;
        assert!(findings_in("x.ex", source).is_empty());
    }
}

#[cfg(test)]
mod inventory_coverage {
    use super::*;
    use crate::inventory::Inventory;

    /// Task 1.5. When this fails, add an `inventory.json` entry whose query has the reported
    /// shape (and run the parity target to see whether the backends agree on it).
    #[test]
    fn every_warehouse_chart_query_in_the_product_has_an_inventory_entry() {
        let root = crate::repo_root();
        let inventory = Inventory::load();
        let findings = all_findings(&root);
        let total = findings.len();
        let missing: Vec<&Finding> = findings.iter().filter(|f| !inventory.covers(f)).collect();
        for exclusion in &inventory.scan_exclusions {
            assert!(
                findings.iter().any(|f| exclusion.matches(f)),
                "scan exclusion {} / {:?} matches no scanned template any more: remove it",
                exclusion.file,
                exclusion.text
            );
        }
        assert!(
            total > 20,
            "the scan found only {total} chart templates under {}: the source roots are \
             probably not in the runfiles",
            root.display()
        );
        let report: Vec<String> = missing
            .iter()
            .map(|f| {
                format!(
                    "  {}:{}  [{}]  {}\n      {}",
                    f.template.file,
                    f.template.line,
                    f.entities.join(","),
                    f.template.shape.describe(),
                    f.template.text.chars().take(200).collect::<String>()
                )
            })
            .collect();
        assert!(
            missing.is_empty(),
            "{} of {total} warehouse chart templates have no inventory entry:\n{}",
            missing.len(),
            report.join("\n")
        );
    }
}
