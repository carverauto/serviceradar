//! Every schema field carries at least one rule, and every rule names a real field.
//!
//! Without this the rule set is complete only by memory. A field added to the schema and not to
//! the rule set is not reported by anything: `validate` evaluates the rules it has, so an
//! unconstrained field passes silently -- which reads exactly like being valid.
//!
//! The field list comes from the schema's own descriptor rather than from a list in this file,
//! because a hand-kept list is one more thing to forget to update, and forgetting is the failure
//! being caught.

mod utils_tests;

use prost::Message;
use prost_types::FileDescriptorSet;
use serviceradar_config_schema::RuleSet;
use serviceradar_config_validator::coverage::leaf_field_paths;
use std::collections::BTreeSet;
use utils_tests::data_path;

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
fn every_rule_names_a_field_the_schema_has() {
    let fields: BTreeSet<String> = schema_fields().into_iter().collect();
    let ruled = ruled_fields();
    let dangling: Vec<&String> = ruled.iter().filter(|f| !fields.contains(*f)).collect();

    assert!(dangling.is_empty(), "rules naming fields the schema lacks: {dangling:#?}");
}

/// The descriptor walk is the part that could silently under-report: a bug that returns only
/// top-level fields would make the coverage check pass while constraining nothing nested.
#[test]
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
