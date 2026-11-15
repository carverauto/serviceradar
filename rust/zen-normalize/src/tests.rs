use super::*;
use serde_json::{Value, json};

fn graph(node: Value) -> String {
    json!({
        "nodes": [
            {"id": "in", "type": "inputNode", "name": "Request"},
            node,
            {"id": "out", "type": "outputNode", "name": "Response"}
        ],
        "edges": [
            {"id": "a", "sourceId": "in", "targetId": "step", "type": "edge"},
            {"id": "b", "sourceId": "step", "targetId": "out", "type": "edge"}
        ]
    })
    .to_string()
}

/// A rule that returns only the listed fields.
fn sets(fields: &[(&str, &str)]) -> String {
    let expressions: Vec<Value> = fields
        .iter()
        .enumerate()
        .map(|(index, (key, value))| json!({"id": format!("e{index}"), "key": key, "value": value}))
        .collect();
    graph(json!({
        "id": "step", "type": "expressionNode", "name": "Set",
        "content": {"expressions": expressions}
    }))
}

fn javascript(source: &str) -> String {
    graph(json!({
        "id": "step", "type": "functionNode", "name": "Script",
        "content": {"source": source}
    }))
}

/// A rule that returns its whole input.
fn passthrough() -> String {
    json!({
        "nodes": [
            {"id": "in", "type": "inputNode", "name": "Request"},
            {"id": "out", "type": "outputNode", "name": "Response"}
        ],
        "edges": [{"id": "a", "sourceId": "in", "targetId": "out", "type": "edge"}]
    })
    .to_string()
}

fn normalize(rules: &[(&str, String)], record: &str) -> Result<String, String> {
    RuleSet::compile(rules)
        .and_then(|rules| rules.normalize_json(record))
        .map_err(|error| error.to_string())
}

// Every expected record below was produced by the JSON-text implementation
// this crate replaced, so these cases hold the two to the same results.

#[test]
fn each_rule_sees_the_record_the_previous_rules_left() {
    assert_eq!(
        normalize(
            &[
                ("first", sets(&[("a", "1")])),
                ("second", sets(&[("b", "a + 1")]))
            ],
            r#"{"keep":"yes"}"#,
        )
        .unwrap(),
        r#"{"a":1,"b":2,"keep":"yes"}"#
    );
}

#[test]
fn results_merge_objects_and_replace_everything_else() {
    assert_eq!(
        normalize(
            &[(
                "shape",
                sets(&[
                    ("attrs.level", "'warn'"),
                    ("attrs.gone", "null"),
                    ("list", "[3]"),
                    ("scalar", "{'k': 1}"),
                    ("object", "7"),
                ]),
            )],
            r#"{"attrs":{"level":"info","host":"host01.example.com","gone":1},"list":[1,2],"scalar":5,"object":{"x":1}}"#,
        )
        .unwrap(),
        r#"{"attrs":{"gone":null,"host":"host01.example.com","level":"warn"},"list":[3],"object":7,"scalar":{"k":1}}"#
    );
}

#[test]
fn numbers_keep_their_text_until_a_rule_returns_them() {
    let record =
        r#"{"float":1.0,"exp":1e2,"big":18446744073709551615,"huge":1e300,"nested":{"float":2.5}}"#;
    for (rules, expected) in [
        (
            vec![],
            r#"{"big":18446744073709551615,"exp":100.0,"float":1.0,"huge":1e+300,"nested":{"float":2.5}}"#,
        ),
        (
            vec![("other", sets(&[("a", "1")]))],
            r#"{"a":1,"big":18446744073709551615,"exp":100.0,"float":1.0,"huge":1e+300,"nested":{"float":2.5}}"#,
        ),
        // Returned numbers take Zen's decimal form. Zen cannot hold `huge`: the
        // rule reads it as null, and the record keeps the original.
        (
            vec![
                ("all", passthrough()),
                ("probe", sets(&[("unreadable", "huge == null")])),
            ],
            r#"{"big":18446744073709551615,"exp":100,"float":1,"huge":1e+300,"nested":{"float":2.5},"unreadable":true}"#,
        ),
    ] {
        assert_eq!(normalize(&rules, record).unwrap(), expected);
    }
}

#[test]
fn a_later_rule_changes_only_the_field_it_returns() {
    // The first rule returns one object under two fields. The script's write
    // to its own input reaches its result but not the record.
    assert_eq!(
        normalize(
            &[
                ("copy", sets(&[("a", "source"), ("b", "source")])),
                ("change", sets(&[("a.x", "2")])),
                (
                    "script",
                    javascript(
                        "export const handler = async (input) => { input.b.x = 9; return { seen: input.b.x }; };"
                    ),
                ),
            ],
            r#"{"source":{"x":1}}"#,
        )
        .unwrap(),
        r#"{"a":{"x":2},"b":{"x":1},"seen":9,"source":{"x":1}}"#
    );
}

#[test]
fn failures_name_the_rule_and_return_no_record() {
    for (rules, record, expected) in [
        (
            vec![("broken", r#"{"nodes":[]}"#.to_owned())],
            "{}",
            "invalid Zen rule broken: missing field `edges`",
        ),
        (
            vec![
                ("first", sets(&[("a", "1")])),
                ("second", sets(&[("b", "1 +")])),
            ],
            "{}",
            r#"failed to evaluate Zen rule second: Failed to evaluate expression: "1 +""#,
        ),
    ] {
        assert_eq!(normalize(&rules, record).unwrap_err(), expected);
    }
    assert!(
        normalize(&[("first", sets(&[("a", "1")]))], "{")
            .unwrap_err()
            .starts_with("invalid context JSON: ")
    );
}
