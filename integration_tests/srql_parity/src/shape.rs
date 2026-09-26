//! The SHAPE of an SRQL query: what the inventory and the source scan are compared by.
//!
//! Exact text cannot be compared, because the product builds queries from interpolated
//! fragments. A shape is the entity plus the clauses that select a SQL code path in either
//! dialect -- `bucket`, `agg`, `series`, `value_field`, `stats`, `rollup_stats`, `other` --
//! and the `sort`/`limit` modifiers. Filters are deliberately NOT part of a shape: a new
//! filter value does not pick a new aggregate translation, a new `agg:` does.
//!
//! The three regressions that motivated the harness are each one clause value apart from a
//! query that worked (`agg:rate` vs `agg:avg`, `series:core_id` vs `series:metric_name`,
//! `sort:...:desc limit:N` vs no sort), which is why clause VALUES are kept and not just keys.

use std::collections::{BTreeMap, BTreeSet};

/// What an interpolation (`#{...}`) is replaced with before a template is tokenised.
pub const PLACEHOLDER: &str = "{}";
/// A clause value that was interpolated, so the scan cannot know it.
pub const WILDCARD: &str = "*";

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

    /// Whether `inventory` (a fully literal shape) accounts for `self` (a scanned shape that
    /// may carry wildcards).
    pub fn covered_by(&self, inventory: &Shape) -> bool {
        if let (Some(mine), Some(theirs)) = (&self.entity, &inventory.entity)
            && mine != theirs
        {
            return false;
        }
        if self.clauses.keys().ne(inventory.clauses.keys()) {
            return false;
        }
        let values_agree = self.clauses.iter().all(|(key, value)| {
            let theirs = &inventory.clauses[key];
            wildcard_match(value, theirs)
        });
        values_agree && self.modifiers.is_subset(&inventory.modifiers)
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

/// `*` in a scanned value stands for one interpolation. `a,*` matches `a,b`; `*` matches
/// anything. Only the scanned side may carry wildcards.
fn wildcard_match(scanned: &str, literal: &str) -> bool {
    if !scanned.contains(WILDCARD) {
        return scanned == literal;
    }
    let pieces: Vec<&str> = scanned.split(WILDCARD).collect();
    let mut rest = literal;
    for (index, piece) in pieces.iter().enumerate() {
        if index == 0 {
            let Some(after) = rest.strip_prefix(piece) else {
                return false;
            };
            rest = after;
        } else if index == pieces.len() - 1 {
            return rest.ends_with(piece);
        } else {
            let Some(at) = rest.find(piece) else {
                return false;
            };
            rest = &rest[at + piece.len()..];
        }
    }
    true
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
    // `bucket: bucket` is an Elixir keyword pair, not SRQL: SRQL never has a bare `key:`.
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

/// The shape of one SRQL text. Interpolation placeholders become wildcards.
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
            if !token.value.contains(PLACEHOLDER) {
                entity = Some(token.value.clone());
            }
        } else if key == "stats" {
            stats_values.push(token.value.clone());
        } else if key == "bucket" {
            // The bucket width never selects a translation on its own; the rollup routing it
            // can trigger is covered by inventorying a coarse-bucket shape explicitly.
            clauses.insert("bucket".into(), WILDCARD.into());
        } else if CLAUSE_KEYS.contains(&key) {
            clauses.insert(key.into(), wildcarded(&token.value));
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

fn wildcarded(value: &str) -> String {
    if value.contains(PLACEHOLDER) {
        value.replace(PLACEHOLDER, WILDCARD)
    } else {
        value.to_string()
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
        let value = wildcarded(value);
        let (aggregates, by) = match split_by(&value) {
            Some((aggregates, by)) => (aggregates, Some(by)),
            None => (value.as_str(), None),
        };
        for item in aggregates.split(',') {
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
                    .map(|field| field.trim().to_string())
                    .filter(|field| !field.is_empty()),
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

fn split_by(value: &str) -> Option<(&str, &str)> {
    let lower = value.to_ascii_lowercase();
    let at = lower.find(" by ")?;
    Some((&value[..at], &value[at + 4..]))
}

#[cfg(test)]
mod tests {
    use super::*;

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
            "{} stats:sum(bytes_total) as bytes_total stats:sum(packets_total) as packets_total by {} sort:{}:desc limit:{}",
        );
        assert_eq!(shape.entity, None);
        assert_eq!(
            shape.clauses["stats"],
            "sum(bytes_total),sum(packets_total)|by:*"
        );
    }

    #[test]
    fn elixir_keyword_pairs_are_not_clauses() {
        assert!(!shape_of("bucket: bucket, agg: agg").is_chart());
    }

    #[test]
    fn agg_value_distinguishes_shapes() {
        let rate = shape_of("in:snmp_metrics bucket:5m agg:rate series:metric_name");
        let avg = shape_of("in:snmp_metrics bucket:5m agg:avg series:metric_name");
        assert!(!rate.covered_by(&avg));
        assert!(rate.covered_by(&rate));
    }

    #[test]
    fn interpolated_value_is_a_wildcard_and_modifiers_are_a_subset() {
        let scanned = shape_of("in:timeseries_metrics bucket:{} agg:{}");
        let inventory = shape_of("in:timeseries_metrics bucket:5m agg:avg sort:timestamp:desc");
        assert!(scanned.covered_by(&inventory));
        // The inventory entry has no `series`, so a scanned query with one is a new shape.
        let with_series = shape_of("in:timeseries_metrics bucket:{} agg:{} series:core_id");
        assert!(!with_series.covered_by(&inventory));
        // A source query that sorts is not covered by an entry that does not.
        let sorted = shape_of("in:timeseries_metrics bucket:5m agg:avg sort:timestamp:desc");
        let unsorted = shape_of("in:timeseries_metrics bucket:5m agg:avg");
        assert!(!sorted.covered_by(&unsorted));
    }

    #[test]
    fn partial_wildcards_match_by_position() {
        assert!(wildcard_match(
            "sum(bytes_total)|by:*,b",
            "sum(bytes_total)|by:a,b"
        ));
        assert!(!wildcard_match(
            "sum(bytes_total)|by:*,b",
            "sum(bytes_total)|by:a,c"
        ));
    }
}
