//! No committed environment instance contains a credential.
//!
//! Input is the canonical text of the compiled binary, so every field that is PRESENT is
//! scanned and no comment is. See serviceradar_config_validator::credentials.

use serviceradar_config_validator::credentials::scan;
use serviceradar_config_validator::text::{flatten, Pair};
use serviceradar_config_validator::utils_tests::{read, INSTANCES};

fn instance(name: &str) -> Vec<Pair> {
    let src = read(&format!("config/environments/{name}.canonical.textproto"));
    flatten(&src).unwrap_or_else(|e| panic!("{name}.canonical.textproto: {e}"))
}

fn pairs(items: &[(&str, &str)]) -> Vec<Pair> {
    items
        .iter()
        .map(|(path, value)| Pair { path: (*path).into(), value: (*value).into() })
        .collect()
}

#[test]
#[ignore = "needs artifacts built by Bazel (protoc-compiled .binpb); run //config/manager_validator/rust/tests, which passes --include-ignored"]
fn no_committed_instance_contains_a_credential() {
    let mut failed = false;
    for name in INSTANCES {
        let fields = instance(name);
        assert!(!fields.is_empty(), "{name} flattened to nothing");

        for finding in scan(&fields) {
            failed = true;
            eprintln!("{name}: {} -- {}", finding.path, finding.reason);
        }
    }
    assert!(!failed, "committed instances contain credential-shaped values (see above)");
}

/// The negative control, one case per shape. A scanner that finds nothing in four clean files
/// is indistinguishable from one that never ran.
#[test]
#[ignore = "needs artifacts built by Bazel (protoc-compiled .binpb); run //config/manager_validator/rust/tests, which passes --include-ignored"]
fn every_credential_shape_is_detected() {
    let cases: &[(&str, &str, &str)] = &[
        (
            "database.host",
            "\"postgres://serviceradar:hunter2@cnpg-rw.serviceradar.svc.cluster.local:5432/db\"",
            "URL with embedded credentials",
        ),
        (
            "database.search_path",
            "\"host=cnpg-rw port=5432 password=hunter2\"",
            "connection string with an embedded credential parameter",
        ),
        (
            "core.workload_socket",
            "\"-----BEGIN PRIVATE KEY-----\\nMIIE\\n-----END PRIVATE KEY-----\"",
            "PEM-encoded key or certificate material",
        ),
        (
            "nats.server_name",
            "\"aGVsbG90aGVyZWZyaWVuZHRoaXNpc2Fsb25ndG9rZW52YWx1ZQ==\"",
            "high-entropy token",
        ),
    ];

    for (path, value, reason) in cases {
        let findings = scan(&pairs(&[(path, value)]));
        assert!(
            findings.iter().any(|f| f.reason == *reason),
            "{path} = {value} should be flagged as {reason:?}, got {findings:?}"
        );
    }
}

/// A field whose NAME denotes a credential is rejected even if its value looks harmless,
/// because the schema is not supposed to have such a field at all.
#[test]
#[ignore = "needs artifacts built by Bazel (protoc-compiled .binpb); run //config/manager_validator/rust/tests, which passes --include-ignored"]
fn a_credential_named_field_is_rejected_regardless_of_value() {
    let findings = scan(&pairs(&[("database.password", "\"x\"")]));
    assert_eq!(
        findings.iter().map(|f| f.reason).collect::<Vec<_>>(),
        vec!["field name denotes a credential"]
    );
}

/// The false-positive control. A shape check that rejects legitimate values gets disabled by
/// whoever it blocks, so the values this schema actually holds must survive it.
#[test]
#[ignore = "needs artifacts built by Bazel (protoc-compiled .binpb); run //config/manager_validator/rust/tests, which passes --include-ignored"]
fn legitimate_configuration_values_are_not_flagged() {
    let clean = pairs(&[
        ("database.host", "\"cnpg-rw.serviceradar.svc.cluster.local\""),
        ("database.connecting_role", "\"serviceradar\""),
        ("database.search_path", "\"platform, ag_catalog\""),
        ("database.port", "5432"),
        ("nats.url", "\"tls://serviceradar-nats.demo.svc.cluster.local:4222\""),
        ("core.api_url", "\"http://serviceradar-core:8090\""),
        ("core.address", "\"serviceradar-core:50052\""),
        ("core.server_spiffe_id", "\"spiffe://serviceradar.cloud/ns/demo/sa/core\""),
        ("core.trust_domain", "\"serviceradar.cloud\""),
        ("dgraph.host", "\"dgraph.serviceradar.svc.cluster.local\""),
        ("kind", "ENVIRONMENT_KIND_DEMO"),
        ("database.tls_mode", "TLS_MODE_VERIFY_FULL"),
    ]);
    assert_eq!(scan(&clean), vec![], "clean values must not be flagged");
}
