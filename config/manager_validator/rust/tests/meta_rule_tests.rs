//! Every schema field carries at least one rule, and every rule names a real field.
//!
//! Without this the rule set is complete only by memory. A field added to the schema and not to
//! the rule set is not reported by anything: `validate` evaluates the rules it has, so an
//! unconstrained field passes silently -- which reads exactly like being valid.
//!
//! The field list comes from the schema's own descriptor rather than from a list in this file,
//! because a hand-kept list is one more thing to forget to update, and forgetting is the failure
//! being caught.

use prost::Message;
use prost_types::FileDescriptorSet;
use serviceradar_config_schema::RuleSet;
use serviceradar_config_validator::coverage::leaf_field_paths;
use std::collections::BTreeSet;
use serviceradar_config_validator::utils_tests::data_path;

fn load<T: Message + Default>(relative: &str) -> T {
    let path = data_path(relative);
    let bytes = std::fs::read(&path).unwrap_or_else(|e| panic!("read {path:?}: {e}"));
    T::decode(&*bytes).unwrap_or_else(|e| panic!("decode {path:?}: {e}"))
}

fn schema_fields() -> Vec<String> {
    let descriptor: FileDescriptorSet = load("config/proto/config.descriptor_set");
    leaf_field_paths(&descriptor).unwrap_or_else(|e| panic!("{}", e.0))
}

fn ruled_fields() -> BTreeSet<String> {
    let rules: RuleSet = load("config/rules/ruleset.binpb");
    rules.rules.iter().filter_map(|r| r.field_path.clone()).collect()
}

#[test]
#[ignore = "needs artifacts built by Bazel (protoc-compiled .binpb); run //config/manager_validator/rust/tests, which passes --include-ignored"]
fn every_schema_field_carries_at_least_one_rule() {
    let fields = schema_fields();
    assert!(!fields.is_empty(), "the descriptor yielded no fields");

    let ruled = ruled_fields();
    let unconstrained: Vec<&String> = fields.iter().filter(|f| !ruled.contains(*f)).collect();

    assert!(
        unconstrained.is_empty(),
        "schema fields with no rule -- they are unvalidated, which reads exactly like valid: {unconstrained:#?}"
    );
}

/// The other direction. A rule naming a field the schema lacks is dead: it can never fire, so
/// the constraint it was written to express is simply absent.
#[test]
#[ignore = "needs artifacts built by Bazel (protoc-compiled .binpb); run //config/manager_validator/rust/tests, which passes --include-ignored"]
fn every_rule_names_a_field_the_schema_has() {
    let fields: BTreeSet<String> = schema_fields().into_iter().collect();
    let ruled = ruled_fields();
    let dangling: Vec<&String> = ruled.iter().filter(|f| !fields.contains(*f)).collect();

    assert!(dangling.is_empty(), "rules naming fields the schema lacks: {dangling:#?}");
}

/// The descriptor walk is the part that could silently under-report: a bug that returns only
/// top-level fields would make the coverage check pass while constraining nothing nested.
#[test]
#[ignore = "needs artifacts built by Bazel (protoc-compiled .binpb); run //config/manager_validator/rust/tests, which passes --include-ignored"]
fn the_descriptor_walk_reaches_nested_sections() {
    let fields = schema_fields();
    for expected in [
        "kind",
        "instance",
        "database.host",
        "database.tls_mode",
        "nats.url",
        "core.security_mode",
        "dgraph.tls_mode",
    ] {
        assert!(fields.iter().any(|f| f == expected), "{expected} missing from {fields:#?}");
    }

    // A section is not a value, so no rule can constrain it and it must not be demanded.
    for section in ["database", "nats", "core", "dgraph"] {
        assert!(!fields.iter().any(|f| f == section), "{section} is a message, not a leaf");
    }
}

/// A conditional pair keyed on an enum must cover every value of that enum.
///
/// This is what stops the `instance` invariant decaying. `RequiredIf` names the one kind that
/// permits an instance and `ForbiddenIf` names the rest; adding a sixth kind without extending
/// the forbidding set would silently re-permit an instance identifier there, and the field would
/// still have rules, so the coverage check above would not notice.
#[test]
#[ignore = "needs artifacts built by Bazel (protoc-compiled .binpb); run //config/manager_validator/rust/tests, which passes --include-ignored"]
fn a_conditional_pair_keyed_on_an_enum_is_exhaustive() {
    use serviceradar_config_schema::rule::Predicate;
    use serviceradar_config_validator::coverage::enum_values_at;

    let descriptor: FileDescriptorSet = load("config/proto/config.descriptor_set");
    let rules: RuleSet = load("config/rules/ruleset.binpb");

    let mut checked = 0;
    for field_path in rules.rules.iter().filter_map(|r| r.field_path.clone()) {
        let on_field = || rules.rules.iter().filter(|r| r.field_path.as_deref() == Some(&field_path));

        let mut keyed_on: Option<String> = None;
        let mut covered: BTreeSet<String> = BTreeSet::new();
        let mut has_required_if = false;
        let mut has_forbidden_if = false;

        for rule in on_field() {
            match rule.predicate.as_ref() {
                Some(Predicate::RequiredIf(c)) => {
                    has_required_if = true;
                    keyed_on = c.other_field_path.clone();
                    covered.extend(c.other_enum_value.clone());
                }
                Some(Predicate::ForbiddenIf(c)) => {
                    has_forbidden_if = true;
                    keyed_on = c.other_field_path.clone();
                    covered.extend(c.other_enum_values.iter().cloned());
                }
                _ => {}
            }
        }

        if !(has_required_if && has_forbidden_if) {
            continue;
        }
        let Some(key) = keyed_on else { continue };
        let Some(values) = enum_values_at(&descriptor, &key) else { continue };

        checked += 1;
        let missing: Vec<&String> = values.iter().filter(|v| !covered.contains(*v)).collect();
        assert!(
            missing.is_empty(),
            "{field_path} is conditional on {key}, but these {key} values appear in neither the \
             required-if nor the forbidden-if trigger, so {field_path} is unconstrained for them: \
             {missing:#?}"
        );
    }

    // A check that examines nothing passes for the wrong reason.
    assert!(checked > 0, "no conditional pair was examined");
}
