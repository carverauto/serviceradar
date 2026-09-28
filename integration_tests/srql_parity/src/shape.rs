//! The SHAPE of an SRQL query: what a product query and an inventory entry are compared by.
//!
//! Exact text cannot be compared, because a dashboard panel and an inventory entry differ in
//! filters and windows. A shape is the entity plus the clauses that select a SQL code path in either
//! dialect -- `bucket`, `agg`, `series`, `value_field`, `stats`, `rollup_stats`, `other` --
//! and the `sort`/`limit` modifiers. Filters are deliberately NOT part of a shape: a new
//! filter value does not pick a new aggregate translation, a new `agg:` does.
//!
//! This module is the definition of the normalization. It exists a second time, in Elixir, in
//! `elixir/web-ng/test/support/srql_parity_shape.ex`, because the builder-coverage test drives
//! the product's Elixir query builders and has to match what they produce. The two cannot drift
//! silently: `shape_examples.json` holds worked examples (text -> entity, chart?, clauses,
//! modifiers) and both test suites assert every one of them. Change the rules here, in the
//! Elixir port, and in the examples together.
//!
//! Two parameters are wildcarded because they never pick a translation on their own: the
//! `bucket:` width, and the prefix length of a `src_cidr:<n>` / `dst_cidr:<n>` group field.
//!
//! The three regressions that motivated the harness are each one clause value apart from a
//! query that worked (`agg:rate` vs `agg:avg`, `series:core_id` vs `series:metric_name`,
//! `sort:...:desc limit:N` vs no sort), which is why clause VALUES are kept and not just keys.

use std::collections::{BTreeMap, BTreeSet};

/// The `bucket` clause value: the width never selects a translation on its own.
pub const WILDCARD: &str = "*";

/// Worked normalization examples shared with the Elixir port (see the module docs).
pub const SHAPE_EXAMPLES_JSON: &str = include_str!("../shape_examples.json");

/// Clauses whose value picks a translation path. Order is irrelevant; membership is not.
pub const CLAUSE_KEYS: &[&str] = &[
    "bucket",
    "agg",
    "series",
    "value_field",
    "stats",
    "rollup_stats",
    "other",
];
/// Clauses that only reorder or truncate. A source query may carry fewer than its inventory
/// entry, never more.
pub const MODIFIER_KEYS: &[&str] = &["sort", "limit"];
/// Any of these marks a query as a chart/aggregate query rather than a row listing.
pub const CHART_KEYS: &[&str] = &["bucket", "agg", "series", "stats", "rollup_stats"];

#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord)]
pub struct Shape {
    /// `None` for a fragment such as `"#{base} bucket:5m agg:sum"` whose entity lives in
    /// another function.
    pub entity: Option<String>,
    pub clauses: BTreeMap<String, String>,
    pub modifiers: BTreeSet<String>,
}

impl Shape {
    pub fn is_chart(&self) -> bool {
        self.clauses
            .keys()
            .any(|key| CHART_KEYS.contains(&key.as_str()))
    }

    /// Whether `inventory` accounts for `self`: the same clauses with the same values, and no
    /// more modifiers.
    pub fn covered_by(&self, inventory: &Shape) -> bool {
        if let (Some(mine), Some(theirs)) = (&self.entity, &inventory.entity)
            && mine != theirs
        {
            return false;
        }
        self.clauses == inventory.clauses && self.modifiers.is_subset(&inventory.modifiers)
    }

    pub fn describe(&self) -> String {
        let mut parts = vec![format!(
            "in:{}",
            self.entity.as_deref().unwrap_or("<entity from caller>")
        )];
        parts.extend(self.clauses.iter().map(|(k, v)| format!("{k}={v}")));
        parts.extend(self.modifiers.iter().map(|m| format!("+{m}")));
        parts.join(" ")
    }
}

/// One `key:value` token of an SRQL text, with quoted values kept whole.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Token {
    pub key: String,
    pub value: String,
}

/// Splits SRQL text into `key:value` tokens.
///
/// Two forms of `stats:` exist in the product and both must survive: the quoted
/// `stats:"sum(x) as y by a, b"` and the bare `stats:sum(x) as y by a,b sort:y:desc`, where the
/// value runs on until the next known clause.
pub fn tokenize(text: &str) -> Vec<Token> {
    let mut tokens: Vec<Token> = Vec::new();
    // True only while the last token is a BARE `stats:` whose value may run on.
    let mut bare_stats_open = false;
    let mut previous = String::new();
    for word in split_words(text) {
        // Inside a bare `stats:` a `key:value` word ends the value -- unless it is a group
        // field, which follows `by` or a comma (`by addr,time:1h`, `by time:1h`).
        let continues_group =
            bare_stats_open && (previous.eq_ignore_ascii_case("by") || previous.ends_with(','));
        previous = word.clone();
        let keyed = split_key(&word).filter(|_| !continues_group);
        match keyed {
            Some((key, value)) => {
                bare_stats_open = key == "stats" && !value.starts_with('"');
                tokens.push(Token {
                    key: key.to_string(),
                    value: unquote(value),
                });
            }
            None if bare_stats_open => {
                if let Some(last) = tokens.last_mut() {
                    last.value.push(' ');
                    last.value.push_str(&word);
                }
            }
            None => {}
        }
    }
    tokens
}

fn split_key(word: &str) -> Option<(&str, &str)> {
    let (key, value) = word.split_once(':')?;
    let is_key = !key.is_empty()
        && key
            .chars()
            .all(|c| c.is_ascii_lowercase() || c == '_' || c == '.' || c.is_ascii_digit());
    // SRQL never has a bare `key:`.
    (is_key && !value.is_empty()).then_some((key, value))
}

fn split_words(text: &str) -> Vec<String> {
    let mut words = Vec::new();
    let mut current = String::new();
    let mut quoted = false;
    for ch in text.chars() {
        match ch {
            '"' => {
                quoted = !quoted;
                current.push(ch);
            }
            c if c.is_whitespace() && !quoted => {
                if !current.is_empty() {
                    words.push(std::mem::take(&mut current));
                }
            }
            c => current.push(c),
        }
    }
    if !current.is_empty() {
        words.push(current);
    }
    words
}

fn unquote(value: &str) -> String {
    value.trim_matches('"').to_string()
}

/// The shape of one SRQL text.
pub fn shape_of(text: &str) -> Shape {
    shape_of_tokens(&tokenize(text))
}

pub fn shape_of_tokens(tokens: &[Token]) -> Shape {
    let mut entity = None;
    let mut clauses: BTreeMap<String, String> = BTreeMap::new();
    let mut modifiers = BTreeSet::new();
    let mut stats_values: Vec<String> = Vec::new();

    for token in tokens {
        let key = token.key.as_str();
        if key == "in" {
            entity = Some(token.value.clone());
        } else if key == "stats" {
            stats_values.push(token.value.clone());
        } else if key == "bucket" {
            // The bucket width never selects a translation on its own; the rollup routing it
            // can trigger is covered by inventorying a coarse-bucket shape explicitly.
            clauses.insert("bucket".into(), WILDCARD.into());
        } else if CLAUSE_KEYS.contains(&key) {
            clauses.insert(key.into(), token.value.clone());
        } else if MODIFIER_KEYS.contains(&key) {
            modifiers.insert(key.to_string());
        }
    }
    if !stats_values.is_empty() {
        clauses.insert("stats".into(), stats_signature(&stats_values));
    }
    Shape {
        entity,
        clauses,
        modifiers,
    }
}

/// `sum(bytes_total) as b, count(*) as n by src_ip, dst_ip` -> `count(*),sum(bytes_total)|by:src_ip,dst_ip`.
///
/// Aliases are dropped (they rename a column, they do not change the SQL's meaning); the
/// aggregate functions and the group-by fields are kept, because computed group fields
/// (`tcp_flags_label`, `duration_bucket`, `src_cidr:<len>`) each have their own per-dialect SQL.
pub fn stats_signature(values: &[String]) -> String {
    let mut functions: BTreeSet<String> = BTreeSet::new();
    let mut group_by: Vec<String> = Vec::new();
    for value in values {
        let (aggregates, by) = match split_by(value) {
            Some((aggregates, by)) => (aggregates, Some(by)),
            None => (value.as_str(), None),
        };
        for item in split_top_level(aggregates) {
            let expr = item.trim();
            let expr = match expr.to_ascii_lowercase().find(" as ") {
                Some(at) => expr[..at].trim(),
                None => expr,
            };
            if expr.is_empty() {
                continue;
            }
            let expr = expr.replace(' ', "");
            functions.insert(if expr == "count()" {
                "count(*)".to_string()
            } else {
                expr
            });
        }
        if let Some(by) = by {
            group_by.extend(
                by.split(',')
                    .map(str::trim)
                    .filter(|field| !field.is_empty())
                    .map(group_field),
            );
        }
    }
    let functions: Vec<String> = functions.into_iter().collect();
    if group_by.is_empty() {
        functions.join(",")
    } else {
        format!("{}|by:{}", functions.join(","), group_by.join(","))
    }
}

/// Splits an aggregate list on the commas between aggregates, not the ones inside an
/// aggregate's argument list (`wavg(avg_us, received) as latency, count() as traces`).
fn split_top_level(list: &str) -> Vec<&str> {
    let mut items = Vec::new();
    let (mut depth, mut start) = (0usize, 0usize);
    for (at, ch) in list.char_indices() {
        match ch {
            '(' => depth += 1,
            ')' => depth = depth.saturating_sub(1),
            ',' if depth == 0 => {
                items.push(&list[start..at]);
                start = at + 1;
            }
            _ => {}
        }
    }
    items.push(&list[start..]);
    items
}

/// A group field, with the prefix length of a CIDR grouping wildcarded (`src_cidr:24` ->
/// `src_cidr:*`): the length is a parameter of one translation, like the bucket width.
fn group_field(field: &str) -> String {
    match field.split_once(':') {
        Some((name, length))
            if name.ends_with("_cidr")
                && !length.is_empty()
                && length.chars().all(|c| c.is_ascii_digit()) =>
        {
            format!("{name}:{WILDCARD}")
        }
        _ => field.to_string(),
    }
}

fn split_by(value: &str) -> Option<(&str, &str)> {
    let lower = value.to_ascii_lowercase();
    let at = lower.find(" by ")?;
    Some((&value[..at], &value[at + 4..]))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::coverage::warehouse_entity;
    use serde::Deserialize;

    /// `shape_examples.json`, the worked examples the Elixir port asserts too.
    #[derive(Deserialize)]
    #[serde(deny_unknown_fields)]
    struct Examples {
        #[serde(rename = "_doc")]
        _doc: String,
        entities: BTreeMap<String, Option<String>>,
        shapes: Vec<Example>,
    }

    #[derive(Deserialize)]
    #[serde(deny_unknown_fields)]
    struct Example {
        query: String,
        entity: Option<String>,
        chart: bool,
        clauses: BTreeMap<String, String>,
        modifiers: BTreeSet<String>,
    }

    #[test]
    fn the_shared_normalization_examples_hold() {
        let examples: Examples =
            serde_json::from_str(SHAPE_EXAMPLES_JSON).expect("shape_examples.json must parse");
        assert!(!examples.entities.is_empty() && !examples.shapes.is_empty());
        for (spelling, canonical) in &examples.entities {
            assert_eq!(
                warehouse_entity(spelling),
                canonical.as_deref(),
                "entity `{spelling}`"
            );
        }
        for example in &examples.shapes {
            let shape = shape_of(&example.query);
            let entity = shape.entity.as_deref().and_then(warehouse_entity);
            assert_eq!(
                entity,
                example.entity.as_deref(),
                "entity of {}",
                example.query
            );
            assert_eq!(
                shape.is_chart(),
                example.chart,
                "chart? of {}",
                example.query
            );
            assert_eq!(
                shape.clauses, example.clauses,
                "clauses of {}",
                example.query
            );
            assert_eq!(
                shape.modifiers, example.modifiers,
                "modifiers of {}",
                example.query
            );
        }
    }

    #[test]
    fn commas_inside_an_aggregate_do_not_split_it() {
        let shape = shape_of(
            "in:mtr_hops stats:\"wavg(avg_us, received) as latency, count() as traces by addr\"",
        );
        assert_eq!(
            shape.clauses["stats"],
            "count(*),wavg(avg_us,received)|by:addr"
        );
    }

    #[test]
    fn a_cidr_prefix_length_is_a_parameter_not_a_shape() {
        let sixteen = shape_of(
            r#"in:flows stats:"sum(bytes_total) as b by src_cidr:16, dst_endpoint_port, dst_cidr:16" limit:40"#,
        );
        let twenty_four = shape_of(
            r#"in:flows stats:"sum(bytes_total) as b by src_cidr:24, dst_endpoint_port, dst_cidr:24" limit:40"#,
        );
        assert_eq!(sixteen, twenty_four);
        assert_eq!(
            sixteen.clauses["stats"],
            "sum(bytes_total)|by:src_cidr:*,dst_endpoint_port,dst_cidr:*"
        );
        let by_ip = shape_of(
            r#"in:flows stats:"sum(bytes_total) as b by src_endpoint_ip, dst_endpoint_port, dst_cidr:24" limit:40"#,
        );
        assert_ne!(by_ip, sixteen);
    }

    #[test]
    fn quoted_and_bare_stats_produce_the_same_signature() {
        let quoted = shape_of(
            r#"in:flows time:last_1h stats:"sum(bytes_total) as b by src_endpoint_ip, dst_endpoint_ip" sort:b:desc limit:10"#,
        );
        let bare = shape_of(
            "in:flows time:last_1h stats:sum(bytes_total) as b by src_endpoint_ip,dst_endpoint_ip sort:b:desc limit:10",
        );
        assert_eq!(quoted, bare);
        assert_eq!(
            quoted.clauses["stats"],
            "sum(bytes_total)|by:src_endpoint_ip,dst_endpoint_ip"
        );
        assert!(quoted.modifiers.contains("sort") && quoted.modifiers.contains("limit"));
    }

    #[test]
    fn a_bare_stats_value_keeps_time_group_fields_and_stops_at_any_other_key() {
        let hourly = shape_of(
            "in:mtr_hops time:last_24h stats:loss_ratio(sent, received) as loss by time:1h limit:500",
        );
        assert_eq!(
            hourly.clauses["stats"],
            "loss_ratio(sent,received)|by:time:1h"
        );
        let mixed = shape_of(
            "in:mtr_hops stats:loss_ratio(sent, received) as loss by addr,time:1h sort:loss:asc",
        );
        assert_eq!(
            mixed.clauses["stats"],
            "loss_ratio(sent,received)|by:addr,time:1h"
        );
        let filtered = shape_of(
            r#"in:timeseries_metrics stats:profile_hour_of_week(value) timezone:"UTC" limit:5"#,
        );
        assert_eq!(filtered.clauses["stats"], "profile_hour_of_week(value)");
    }

    #[test]
    fn two_stats_clauses_merge() {
        let shape = shape_of(
            "in:flows stats:sum(bytes_total) as bytes_total stats:sum(packets_total) as packets_total by src_endpoint_ip sort:bytes_total:desc limit:5",
        );
        assert_eq!(
            shape.clauses["stats"],
            "sum(bytes_total),sum(packets_total)|by:src_endpoint_ip"
        );
    }

    #[test]
    fn agg_value_distinguishes_shapes() {
        let rate = shape_of("in:snmp_metrics bucket:5m agg:rate series:metric_name");
        let avg = shape_of("in:snmp_metrics bucket:5m agg:avg series:metric_name");
        assert!(!rate.covered_by(&avg));
        assert!(rate.covered_by(&rate));
    }

    #[test]
    fn modifiers_are_a_subset_and_other_clauses_are_exact() {
        let inventory = shape_of("in:timeseries_metrics bucket:5m agg:avg sort:timestamp:desc");
        assert!(shape_of("in:timeseries_metrics bucket:1h agg:avg").covered_by(&inventory));
        let with_series = shape_of("in:timeseries_metrics bucket:5m agg:avg series:core_id");
        assert!(!with_series.covered_by(&inventory));
        let sorted = shape_of("in:timeseries_metrics bucket:5m agg:avg sort:timestamp:desc");
        let unsorted = shape_of("in:timeseries_metrics bucket:5m agg:avg");
        assert!(!sorted.covered_by(&unsorted));
    }
}
