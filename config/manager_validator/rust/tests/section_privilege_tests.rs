//! A target that declares one section cannot see the others.
//!
//! Decision 6 is a claim about RUNFILES, so it is only true if something checks the runfiles.
//! This target declares `//config/environments:ci_database` and nothing else; the assertions
//! below are the difference between least privilege and a comment saying least privilege.
//!
//! Under remote execution the property is absolute -- only declared inputs are uploaded to the
//! executor -- so this is strongest exactly where it matters.

use prost::Message;
use serviceradar_config_schema::{DatabaseConfig, TlsMode};
use serviceradar_config_validator::utils_tests::runfile;

#[test]
#[ignore = "needs artifacts built by Bazel (protoc-compiled .binpb); run //config/manager_validator/rust/tests, which passes --include-ignored"]
fn the_declared_section_is_present_and_decodes() {
    let path = runfile("config/environments/ci.database.binpb")
        .expect("ci_database is declared as data on this target");
    let bytes = std::fs::read(&path).unwrap_or_else(|e| panic!("read {path:?}: {e}"));

    let db = DatabaseConfig::decode(&*bytes).expect("the section decodes as DatabaseConfig");
    assert_eq!(db.database.as_deref(), Some("srql_fixture"));
    assert_eq!(db.port, Some(5432));
    assert_eq!(db.tls_mode, Some(TlsMode::VerifyFull as i32));
}

/// The actual privilege assertion. A component that needs the database has no business holding
/// the NATS coordinates, and the mechanism that stops it is the absence of the file.
#[test]
#[ignore = "needs artifacts built by Bazel (protoc-compiled .binpb); run //config/manager_validator/rust/tests, which passes --include-ignored"]
fn the_undeclared_sections_are_absent() {
    for undeclared in ["nats", "core", "dgraph"] {
        let path = format!("config/environments/ci.{undeclared}.binpb");
        assert!(
            runfile(&path).is_none(),
            "{path} is reachable from a target that declared only ci_database"
        );
    }
}

/// The whole instance is absent too. Declaring one section must not be a back door to every
/// other one via the composite artifact it was cut from.
#[test]
#[ignore = "needs artifacts built by Bazel (protoc-compiled .binpb); run //config/manager_validator/rust/tests, which passes --include-ignored"]
fn the_full_instance_is_absent() {
    assert!(
        runfile("config/environments/ci.binpb").is_none(),
        "the full ci instance is reachable from a target that declared only ci_database"
    );
}
