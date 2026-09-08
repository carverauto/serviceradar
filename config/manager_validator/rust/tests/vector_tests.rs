//! The committed fixtures are what the rule set claims they are.
//!
//! Each case serves two roles at once (SEMANTICS.md sections 8 and 10): a NEGATIVE FIXTURE,
//! whose case starts passing if the rule it targets is deleted or weakened, and a CONFORMANCE
//! VECTOR that all three implementations must reproduce. Until something ran them they were
//! neither -- a fixture file nothing evaluates is a document.
//!
//! Comparison is by the ORDERED SEQUENCE of (code, field_path), not by accept/reject and not as
//! a set. Three implementations can reject the same input for three different reasons and a
//! bare rejection assertion stays green; ordering is part of the contract precisely so the
//! sequences can be compared across languages (SEMANTICS.md section 5).

use prost::Message;
use serviceradar_config_schema::{FixtureSet, RuleSet};
use serviceradar_config_validator::validate;
use serviceradar_config_validator::utils_tests::data_path;

fn load<T: Message + Default>(relative: &str) -> T {
    let path = data_path(relative);
    let bytes = std::fs::read(&path).unwrap_or_else(|e| panic!("read {path:?}: {e}"));
    T::decode(&*bytes).unwrap_or_else(|e| panic!("decode {path:?}: {e}"))
}

fn rules() -> RuleSet {
    load("config/rules/ruleset.binpb")
}

fn fixtures() -> FixtureSet {
    load("config/rules/fixtures/fixtures.binpb")
}

#[test]
#[ignore = "needs artifacts built by Bazel (protoc-compiled .binpb); run //config/manager_validator/rust/tests, which passes --include-ignored"]
fn every_fixture_produces_exactly_its_expected_violations() {
    let rules = rules();
    let fixtures = fixtures();
    assert!(!fixtures.fixtures.is_empty(), "the fixture set decoded empty");

    let mut failures = Vec::new();
    for fixture in &fixtures.fixtures {
        let name = fixture.name().to_string();
        let Some(instance) = fixture.instance.as_ref() else {
            failures.push(format!("{name}: fixture sets no instance"));
            continue;
        };

        let actual: Vec<(String, String)> = match validate(&rules, instance) {
            Ok(v) => v.into_iter().map(|v| (v.code, v.field_path)).collect(),
            Err(e) => {
                failures.push(format!("{name}: rule names a field the schema lacks: {}", e.0));
                continue;
            }
        };
        let expected: Vec<(String, String)> = fixture
            .expected_violations
            .iter()
            .map(|v| (v.code().to_string(), v.field_path().to_string()))
            .collect();

        if actual != expected {
            failures.push(format!("{name}:\n    expected {expected:?}\n    actual   {actual:?}"));
        }
    }

    assert!(failures.is_empty(), "fixture mismatches:\n  {}", failures.join("\n  "));
}

/// The invariant the rule set file states in its own header and that nothing enforced: every
/// rule must have a fixture that violates it.
///
/// Without this a rule can be added, be wrong, and never fire -- and the file-phase test would
/// stay green, because the committed instances are all valid. A rule no case exercises is
/// indistinguishable from a rule that does nothing.
#[test]
#[ignore = "needs artifacts built by Bazel (protoc-compiled .binpb); run //config/manager_validator/rust/tests, which passes --include-ignored"]
fn every_rule_is_violated_by_at_least_one_fixture() {
    let rules = rules();
    let fixtures = fixtures();

    let exercised: std::collections::BTreeSet<String> = fixtures
        .fixtures
        .iter()
        .flat_map(|f| f.expected_violations.iter())
        .map(|v| v.code().to_string())
        .collect();

    let unexercised: Vec<&str> = rules
        .rules
        .iter()
        .filter_map(|r| r.code.as_deref())
        // Ranges over instances rather than within one, so no single-instance fixture can
        // exercise it; SEMANTICS.md section 6 covers it separately.
        .filter(|c| !c.is_empty())
        .filter(|c| !exercised.contains(*c))
        .collect();

    assert!(
        unexercised.is_empty(),
        "{} of {} rules have no fixture that violates them, so nothing would notice if they \
         stopped firing:\n{unexercised:#?}",
        unexercised.len(),
        rules.rules.len()
    );
}

/// A fixture naming a code no rule defines is dead weight that reads like coverage.
#[test]
#[ignore = "needs artifacts built by Bazel (protoc-compiled .binpb); run //config/manager_validator/rust/tests, which passes --include-ignored"]
fn every_expected_violation_names_a_rule_that_exists() {
    let codes: std::collections::BTreeSet<String> =
        rules().rules.iter().filter_map(|r| r.code.clone()).collect();

    let dangling: Vec<String> = fixtures()
        .fixtures
        .iter()
        .flat_map(|f| {
            let name = f.name().to_string();
            f.expected_violations
                .iter()
                .map(move |v| (name.clone(), v.code().to_string()))
        })
        .filter(|(_, code)| !codes.contains(code))
        .map(|(fixture, code)| format!("{fixture} expects {code}"))
        .collect();

    assert!(dangling.is_empty(), "fixtures expecting undefined codes: {dangling:#?}");
}
