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

// Except for field removal, every expected record below was produced by the
// JSON-text implementation this crate replaced, which could not remove a field.

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
fn a_rule_removes_only_the_top_level_fields_it_names() {
    let record = r#"{"full_message":"<13>raw text","short_message":"text","attrs":{"full_message":"nested"}}"#;
    assert_eq!(
        normalize(
            &[(
                "strip",
                sets(&[(REMOVE_FIELDS, "['full_message', 'absent']")])
            )],
            record
        )
        .unwrap(),
        r#"{"attrs":{"full_message":"nested"},"short_message":"text"}"#
    );
    // Nulling a field does not remove it: Zen drops the null from the result.
    assert_eq!(
        normalize(&[("null", sets(&[("full_message", "null")]))], record).unwrap(),
        r#"{"attrs":{"full_message":"nested"},"full_message":"<13>raw text","short_message":"text"}"#
    );
    assert_eq!(
        normalize(
            &[("bad", sets(&[(REMOVE_FIELDS, "'full_message'")]))],
            record
        )
        .unwrap_err(),
        "failed to evaluate Zen rule bad: serviceradar_remove_fields must be an array of field names"
    );
}

#[test]
fn a_record_cannot_remove_its_own_fields() {
    // A sender controls the record; a rule that returns its input must not
    // hand the sender's instruction back as its own.
    let record = r#"{"serviceradar_remove_fields":["severity"],"severity":"high"}"#;
    assert_eq!(
        normalize(&[("all", passthrough())], record).unwrap(),
        r#"{"serviceradar_remove_fields":["severity"],"severity":"high"}"#
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

fn bundle(schema: &str, rules: &[(&str, &str)], digest: &str) -> Vec<u8> {
    let rules: Vec<Value> = rules
        .iter()
        .map(|(key, jdm)| json!({"key": key, "jdm": jdm}))
        .collect();
    json!({
        "schema": schema,
        "stream_name": "events",
        "subject": "logs.syslog",
        "rules": rules,
        "digest": digest,
    })
    .to_string()
    .into_bytes()
}

// Core's publisher asserts the same digests for the same content in
// elixir/serviceradar_core/test/serviceradar/observability/zen/rule_bundle_test.exs.
const FIRST: (&str, &str) = ("first", r#"{"nodes":[],"edges":[]}"#);
const SECOND: (&str, &str) = ("second", r#"{"edges":[],"nodes":[]}"#);
const TWO_RULE_DIGEST: &str =
    "sha256:578cb4621ff7758cbcec93bfcb0208ddce0a52cb01011eb5b28f15332d4d70b4";
const EMPTY_DIGEST: &str =
    "sha256:11f468c88fd9041ba1b94ae65bbb4b04cf2d8f690b8d1d62f99f4689ccfc961b";

#[test]
fn a_bundle_is_accepted_only_with_the_digest_of_its_ordered_content() {
    let accepted =
        RuleBundle::parse(&bundle(BUNDLE_SCHEMA, &[FIRST, SECOND], TWO_RULE_DIGEST)).unwrap();
    assert_eq!(accepted.digest, TWO_RULE_DIGEST);
    assert_eq!(
        (accepted.stream_name.as_str(), accepted.subject.as_str()),
        ("events", "logs.syslog")
    );

    let empty = RuleBundle::parse(&bundle(BUNDLE_SCHEMA, &[], EMPTY_DIGEST)).unwrap();
    assert!(empty.rules.is_empty());

    for (name, document) in [
        (
            "reordered rules",
            bundle(BUNDLE_SCHEMA, &[SECOND, FIRST], TWO_RULE_DIGEST),
        ),
        (
            "a dropped rule",
            bundle(BUNDLE_SCHEMA, &[FIRST], TWO_RULE_DIGEST),
        ),
        (
            "changed rule text",
            bundle(
                BUNDLE_SCHEMA,
                &[FIRST, ("second", r#"{"edges":[], "nodes":[]}"#)],
                TWO_RULE_DIGEST,
            ),
        ),
    ] {
        assert!(
            matches!(
                RuleBundle::parse(&document),
                Err(BundleError::Digest { .. })
            ),
            "accepted a bundle with {name}"
        );
    }
}

#[test]
fn a_bundle_with_an_unknown_schema_or_a_bad_rule_is_rejected_whole() {
    assert!(matches!(
        RuleBundle::parse(&bundle(
            "serviceradar.zen.ruleset.v2",
            &[FIRST, SECOND],
            TWO_RULE_DIGEST
        )),
        Err(BundleError::Schema(_))
    ));

    // The digest is correct for this content; the second rule is not JDM.
    let rules = [FIRST, ("second", r#"{"nodes":[]}"#)];
    let digest = "sha256:5f4c2b3c1b6c3b1a8e3a2f3f3b0b6f6d1d5d0c7b3b1f3c0a9d5a4e6f7a8b9c0d";
    let document = bundle(BUNDLE_SCHEMA, &rules, digest);
    let Err(BundleError::Digest { computed, .. }) = RuleBundle::parse(&document) else {
        panic!("placeholder digest was accepted");
    };
    assert!(matches!(
        RuleBundle::parse(&bundle(BUNDLE_SCHEMA, &rules, &computed)),
        Err(BundleError::Rules(Error::InvalidRule { key, .. })) if key == "second"
    ));
}
