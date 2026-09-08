//! Every committed environment instance satisfies every file-phase rule.
//!
//! This is the gate that makes the rule set real. Without it the rules in
//! //config/rules:ruleset.textproto are a document, and an instance that violates one is
//! discovered by a service failing to start.
//!
//! Inputs are the COMPILED binaries, not the .textproto sources: that is what the runtime
//! loads, so validating anything else would be checking a different artifact.

use serviceradar_config_schema::{EnvironmentConfig, RuleSet};
use serviceradar_config_validator::validate;
use serviceradar_config_validator::utils_tests::{data_path, INSTANCES};

use prost::Message;

fn load_rules() -> RuleSet {
    let path = data_path("config/rules/ruleset.binpb");
    let bytes = std::fs::read(&path).unwrap_or_else(|e| panic!("read {path:?}: {e}"));
    RuleSet::decode(&*bytes).unwrap_or_else(|e| panic!("decode {path:?}: {e}"))
}

fn load_instance(name: &str) -> EnvironmentConfig {
    let path = data_path(&format!("config/environments/{name}.binpb"));
    let bytes = std::fs::read(&path).unwrap_or_else(|e| panic!("read {path:?}: {e}"));
    EnvironmentConfig::decode(&*bytes).unwrap_or_else(|e| panic!("decode {path:?}: {e}"))
}

#[test]
#[ignore = "needs artifacts built by Bazel (protoc-compiled .binpb); run //config/manager_validator/rust/tests, which passes --include-ignored"]
fn every_committed_instance_satisfies_the_file_phase_rules() {
    let rules = load_rules();
    assert!(!rules.rules.is_empty(), "rule set decoded empty");

    let mut failed = false;
    for name in INSTANCES {
        let cfg = load_instance(name);
        let violations = validate(&rules, &cfg)
            .unwrap_or_else(|e| panic!("{name}: rule names a field the schema lacks: {}", e.0));
        if !violations.is_empty() {
            failed = true;
            eprintln!("\n{name}.textproto has {} violation(s):", violations.len());
            for v in &violations {
                eprintln!("  {:<34} {}", v.field_path, v.code);
                if !v.description.is_empty() {
                    eprintln!("  {:<34}   {}", "", v.description);
                }
            }
        }
    }
    assert!(!failed, "committed instances violate the rule set (see above)");
}

/// The negative control. A rule set that never fires is indistinguishable from one that is
/// never evaluated, so prove the engine rejects something before trusting that it accepts.
#[test]
#[ignore = "needs artifacts built by Bazel (protoc-compiled .binpb); run //config/manager_validator/rust/tests, which passes --include-ignored"]
fn a_deliberately_broken_instance_is_rejected() {
    let rules = load_rules();
    let mut cfg = load_instance("saas");

    // Plaintext outside localhost: DATABASE_TLS_MODE_VERIFIED_OUTSIDE_LOCALHOST.
    if let Some(db) = cfg.database.as_mut() {
        db.tls_mode = Some(serviceradar_config_schema::TlsMode::Disable as i32);
        db.host = Some(String::new()); // DATABASE_HOST_NON_EMPTY
        db.port = Some(99_999); // DATABASE_PORT_RANGE
    }

    let violations = validate(&rules, &cfg).expect("schema covers every rule's field");
    let codes: Vec<&str> = violations.iter().map(|v| v.code.as_str()).collect();

    for expected in [
        "DATABASE_HOST_NON_EMPTY",
        "DATABASE_PORT_RANGE",
        "DATABASE_TLS_MODE_VERIFIED_OUTSIDE_LOCALHOST",
    ] {
        assert!(codes.contains(&expected), "missing {expected}, got {codes:?}");
    }

    // Ordering is part of the contract: cross-language vectors compare sequences.
    let mut sorted = violations.clone();
    sorted.sort();
    assert_eq!(violations, sorted, "violations must be ordered by (field_path, code)");
}

/// Absence reports once, not once per predicate on the same field. database.port carries both
/// Required and IntRange; dropping it must yield DATABASE_PORT_REQUIRED alone.
#[test]
#[ignore = "needs artifacts built by Bazel (protoc-compiled .binpb); run //config/manager_validator/rust/tests, which passes --include-ignored"]
fn an_absent_required_field_cascades_to_one_violation() {
    let rules = load_rules();
    let mut cfg = load_instance("saas");
    if let Some(db) = cfg.database.as_mut() {
        db.port = None;
    }

    let violations = validate(&rules, &cfg).expect("schema covers every rule's field");
    let port: Vec<&str> = violations
        .iter()
        .filter(|v| v.field_path == "database.port")
        .map(|v| v.code.as_str())
        .collect();

    assert_eq!(port, vec!["DATABASE_PORT_REQUIRED"], "expected exactly one");
}
