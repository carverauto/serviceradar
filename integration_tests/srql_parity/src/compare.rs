//! Result normalisation and the diff.
//!
//! Both backends' rows arrive as JSON objects keyed by column name (CNPG through
//! `row_to_json`, StarRocks by decoding the text protocol by column type). Normalisation only
//! removes REPRESENTATION differences that the product's own decoders also remove:
//!
//! * a boolean is `1`/`0` (StarRocks has no boolean on the wire, it sends TINYINT);
//! * a timestamp string, with or without offset, `T` or space, is canonical UTC with
//!   microseconds (a StarRocks DATETIME carries no zone; the stored values are UTC);
//! * a string holding a JSON object or array is that JSON (StarRocks returns JSON and ARRAY
//!   columns as text, CNPG `row_to_json` embeds them);
//! * a row whose only column is a JSON object is that object's fields (the CNPG rollup
//!   builders return one `payload` jsonb; the StarRocks dialect returns the fields as columns).
//!
//! Values are otherwise compared exactly, numbers within `Tolerance`.

use serde_json::{Map, Value};

pub type Row = Map<String, Value>;

#[derive(Debug, Clone)]
pub struct Tolerance {
    pub relative: f64,
    pub absolute: f64,
    /// Columns compared with `wide` instead.
    pub wide_columns: Vec<String>,
    pub wide: f64,
}

impl Tolerance {
    fn for_column(&self, column: &str) -> f64 {
        if self.wide_columns.iter().any(|c| c == column) {
            self.wide
        } else {
            self.relative
        }
    }
}

pub fn normalize_rows(rows: Vec<Row>, ignore: &[String]) -> Vec<Row> {
    rows.into_iter()
        .map(|row| {
            let row = flatten_payload(row);
            row.into_iter()
                .filter(|(column, _)| !ignore.contains(column))
                .map(|(column, value)| (column, normalize_value(value)))
                .collect()
        })
        .collect()
}

pub fn flatten_payload(row: Row) -> Row {
    if row.len() == 1 {
        let (column, value) = row.iter().next().expect("one column");
        let parsed = match value {
            Value::Object(map) => Some(map.clone()),
            Value::String(text) => match serde_json::from_str::<Value>(text) {
                Ok(Value::Object(map)) => Some(map),
                _ => None,
            },
            _ => None,
        };
        if let Some(map) = parsed {
            let _ = column;
            return map;
        }
    }
    row
}

pub fn normalize_value(value: Value) -> Value {
    match value {
        Value::Bool(b) => Value::from(if b { 1.0 } else { 0.0 }),
        Value::Number(n) => Value::from(n.as_f64().unwrap_or(f64::NAN)),
        Value::String(text) => {
            if let Some(ts) = canonical_timestamp(&text) {
                return Value::String(ts);
            }
            let trimmed = text.trim_start();
            if (trimmed.starts_with('{') || trimmed.starts_with('['))
                && let Ok(parsed) = serde_json::from_str::<Value>(&text)
            {
                return normalize_value(parsed);
            }
            Value::String(text)
        }
        Value::Array(items) => Value::Array(items.into_iter().map(normalize_value).collect()),
        Value::Object(map) => Value::Object(
            map.into_iter()
                .map(|(k, v)| (k, normalize_value(v)))
                .collect(),
        ),
        Value::Null => Value::Null,
    }
}

/// `2030-01-02 03:04:05`, `2030-01-02T03:04:05.25`, `2030-01-02T03:04:05+00:00`, `...Z`.
pub fn canonical_timestamp(text: &str) -> Option<String> {
    use chrono::{DateTime, NaiveDateTime, Utc};
    if text.len() < 19 || !text.as_bytes()[4].eq(&b'-') {
        return None;
    }
    if let Ok(dt) = DateTime::parse_from_rfc3339(text) {
        return Some(format(dt.with_timezone(&Utc).naive_utc()));
    }
    for pattern in ["%Y-%m-%d %H:%M:%S%.f%#z", "%Y-%m-%dT%H:%M:%S%.f%#z"] {
        if let Ok(dt) = DateTime::parse_from_str(text, pattern) {
            return Some(format(dt.with_timezone(&Utc).naive_utc()));
        }
    }
    for pattern in ["%Y-%m-%d %H:%M:%S%.f", "%Y-%m-%dT%H:%M:%S%.f"] {
        if let Ok(naive) = NaiveDateTime::parse_from_str(text, pattern) {
            return Some(format(naive));
        }
    }
    fn format(naive: NaiveDateTime) -> String {
        naive.format("%Y-%m-%dT%H:%M:%S%.6fZ").to_string()
    }
    None
}

/// Rewrites every canonical timestamp in `rows` as its offset from `anchor` (`@+300000ms`), so
/// rows recorded in `inventory.json` do not depend on the day a run was made. Call after
/// `normalize_rows`.
pub fn relative_to(rows: Vec<Row>, anchor: chrono::DateTime<chrono::Utc>) -> Vec<Row> {
    fn relative(value: Value, anchor: chrono::DateTime<chrono::Utc>) -> Value {
        match value {
            Value::String(text) => match chrono::DateTime::parse_from_rfc3339(&text) {
                Ok(at) => Value::String(format!(
                    "@{:+}ms",
                    (at.with_timezone(&chrono::Utc) - anchor).num_milliseconds()
                )),
                Err(_) => Value::String(text),
            },
            Value::Array(items) => {
                Value::Array(items.into_iter().map(|v| relative(v, anchor)).collect())
            }
            Value::Object(map) => Value::Object(
                map.into_iter()
                    .map(|(k, v)| (k, relative(v, anchor)))
                    .collect(),
            ),
            other => other,
        }
    }
    rows.into_iter()
        .map(|row| {
            row.into_iter()
                .map(|(k, v)| (k, relative(v, anchor)))
                .collect()
        })
        .collect()
}

fn numbers_equal(a: f64, b: f64, relative: f64, absolute: f64) -> bool {
    if a == b {
        return true;
    }
    if a.is_nan() || b.is_nan() {
        return false;
    }
    (a - b).abs() <= absolute.max(relative * a.abs().max(b.abs()))
}

pub fn values_equal(a: &Value, b: &Value, relative: f64, absolute: f64) -> bool {
    match (a, b) {
        (Value::Number(x), Value::Number(y)) => numbers_equal(
            x.as_f64().unwrap_or(f64::NAN),
            y.as_f64().unwrap_or(f64::NAN),
            relative,
            absolute,
        ),
        (Value::Array(x), Value::Array(y)) => {
            x.len() == y.len()
                && x.iter()
                    .zip(y)
                    .all(|(p, q)| values_equal(p, q, relative, absolute))
        }
        (Value::Object(x), Value::Object(y)) => {
            x.len() == y.len()
                && x.iter().all(|(k, v)| {
                    y.get(k)
                        .is_some_and(|w| values_equal(v, w, relative, absolute))
                })
        }
        _ => a == b,
    }
}

fn rows_equal(a: &Row, b: &Row, tolerance: &Tolerance) -> bool {
    a.len() == b.len()
        && a.iter().all(|(column, value)| {
            b.get(column).is_some_and(|other| {
                values_equal(
                    value,
                    other,
                    tolerance.for_column(column),
                    tolerance.absolute,
                )
            })
        })
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Verdict {
    Equal,
    Different(String),
}

/// Compares two normalised result sets. `order_keys` are the columns the query orders by; when
/// given, their sequence must agree position by position (so a wrong sort direction, a missing
/// `NULLS FIRST` or the wrong newest-N cut fails) while rows that tie on them may come in any
/// order. The rows themselves are then compared as multisets.
pub fn compare(
    cnpg: &[Row],
    starrocks: &[Row],
    order_keys: &[String],
    tolerance: &Tolerance,
) -> Verdict {
    let mut problems = Vec::new();
    if cnpg.len() != starrocks.len() {
        problems.push(format!(
            "row count: cnpg={} starrocks={}",
            cnpg.len(),
            starrocks.len()
        ));
    }
    let columns = |rows: &[Row]| -> Vec<String> {
        rows.first()
            .map(|row| row.keys().cloned().collect())
            .unwrap_or_default()
    };
    let (cc, sc) = (columns(cnpg), columns(starrocks));
    if !cnpg.is_empty() && !starrocks.is_empty() && cc != sc {
        problems.push(format!("columns: cnpg={cc:?} starrocks={sc:?}"));
        return Verdict::Different(problems.join("; "));
    }

    let keys: Vec<&String> = order_keys.iter().filter(|k| cc.contains(k)).collect();
    if !keys.is_empty() {
        for (index, (c, s)) in cnpg.iter().zip(starrocks).enumerate() {
            let agrees = keys.iter().all(|key| match (c.get(*key), s.get(*key)) {
                (Some(x), Some(y)) => {
                    values_equal(x, y, tolerance.for_column(key), tolerance.absolute)
                }
                (None, None) => true,
                _ => false,
            });
            if !agrees {
                problems.push(format!(
                    "order differs at row {index} on {keys:?}: cnpg={} starrocks={}",
                    project(c, &keys),
                    project(s, &keys)
                ));
                break;
            }
        }
    }

    let mut unmatched: Vec<Option<&Row>> = starrocks.iter().map(Some).collect();
    let mut only_cnpg = Vec::new();
    for row in cnpg {
        match unmatched
            .iter()
            .position(|candidate| candidate.is_some_and(|c| rows_equal(row, c, tolerance)))
        {
            Some(at) => unmatched[at] = None,
            None => only_cnpg.push(row),
        }
    }
    let only_starrocks: Vec<&Row> = unmatched.into_iter().flatten().collect();
    if !only_cnpg.is_empty() || !only_starrocks.is_empty() {
        let sample = |rows: &[&Row]| -> String {
            rows.iter()
                .take(4)
                .map(|r| Value::Object((*r).clone()).to_string())
                .collect::<Vec<_>>()
                .join("\n        ")
        };
        problems.push(format!(
            "{} row(s) only in cnpg, {} only in starrocks\n      cnpg only:\n        {}\n      starrocks only:\n        {}",
            only_cnpg.len(),
            only_starrocks.len(),
            sample(&only_cnpg),
            sample(&only_starrocks)
        ));
    }
    if problems.is_empty() {
        Verdict::Equal
    } else {
        Verdict::Different(problems.join("\n    "))
    }
}

fn project(row: &Row, keys: &[&String]) -> String {
    let map: Map<String, Value> = keys
        .iter()
        .map(|k| ((*k).clone(), row.get(*k).cloned().unwrap_or(Value::Null)))
        .collect();
    Value::Object(map).to_string()
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn rows(value: Value) -> Vec<Row> {
        value
            .as_array()
            .unwrap()
            .iter()
            .map(|r| r.as_object().unwrap().clone())
            .collect()
    }

    fn exact() -> Tolerance {
        Tolerance {
            relative: 1e-9,
            absolute: 1e-9,
            wide_columns: vec![],
            wide: 0.0,
        }
    }

    #[test]
    fn recorded_timestamps_are_offsets_from_the_anchor() {
        let anchor = chrono::DateTime::parse_from_rfc3339("2030-01-02T00:00:00Z")
            .unwrap()
            .with_timezone(&chrono::Utc);
        let observed = normalize_rows(
            rows(json!([{"timestamp": "2030-01-02 00:05:00", "value": 3, "series": "a"}])),
            &[],
        );
        let recorded = rows(json!([{"timestamp": "@+300000ms", "value": 3.0, "series": "a"}]));
        assert_eq!(
            compare(&relative_to(observed, anchor), &recorded, &[], &exact()),
            Verdict::Equal
        );
        let drifted = rows(json!([{"timestamp": "@+300000ms", "value": 4.0, "series": "a"}]));
        assert!(matches!(
            compare(&recorded, &drifted, &[], &exact()),
            Verdict::Different(_)
        ));
    }

    #[test]
    fn representation_differences_normalise_away() {
        let cnpg = normalize_rows(
            rows(
                json!([{"payload": {"total": 3, "ok": true, "t": "2030-01-02T03:04:05.25+00:00"}}]),
            ),
            &[],
        );
        let starrocks = normalize_rows(
            rows(json!([{"ok": 1, "t": "2030-01-02 03:04:05.250000", "total": 3.0}])),
            &[],
        );
        assert_eq!(compare(&cnpg, &starrocks, &[], &exact()), Verdict::Equal);
        let json_text = normalize_rows(rows(json!([{"a": "[1, 2]"}])), &[]);
        let json_array = normalize_rows(rows(json!([{"a": [1, 2]}])), &[]);
        assert_eq!(
            compare(&json_text, &json_array, &[], &exact()),
            Verdict::Equal
        );
    }

    #[test]
    fn a_sum_where_a_rate_belongs_is_a_difference() {
        let rate = rows(json!([{"timestamp": "2030-01-01 00:00:00", "value": 125000000.0}]));
        let sum = rows(json!([{"timestamp": "2030-01-01 00:00:00", "value": 3.0e11}]));
        assert!(matches!(
            compare(&rate, &sum, &["timestamp".into()], &exact()),
            Verdict::Different(_)
        ));
    }

    #[test]
    fn ties_may_permute_but_the_order_key_sequence_may_not() {
        let a = rows(json!([{"k": 2, "v": "x"}, {"k": 2, "v": "y"}, {"k": 1, "v": "z"}]));
        let tie_swapped = rows(json!([{"k": 2, "v": "y"}, {"k": 2, "v": "x"}, {"k": 1, "v": "z"}]));
        let reversed = rows(json!([{"k": 1, "v": "z"}, {"k": 2, "v": "x"}, {"k": 2, "v": "y"}]));
        let keys = vec!["k".to_string()];
        assert_eq!(compare(&a, &tie_swapped, &keys, &exact()), Verdict::Equal);
        assert!(matches!(
            compare(&a, &reversed, &keys, &exact()),
            Verdict::Different(_)
        ));
    }

    #[test]
    fn floating_point_noise_is_not_a_difference_but_a_real_gap_is() {
        let a = rows(json!([{"v": 0.1 + 0.2}]));
        let b = rows(json!([{"v": 0.3}]));
        let c = rows(json!([{"v": 0.3000001}]));
        assert_eq!(compare(&a, &b, &[], &exact()), Verdict::Equal);
        assert!(matches!(
            compare(&b, &c, &[], &exact()),
            Verdict::Different(_)
        ));
    }
}
