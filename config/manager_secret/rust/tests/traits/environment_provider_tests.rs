//! Which provider each environment selects.

use serviceradar_secret_manager::{EnvironmentProvider, SecretProvider};

/// Every deployed environment reads the environment, because that is what the platform does:
/// //helm/serviceradar supplies credentials with `valueFrom.secretKeyRef`, and a BuildBuddy
/// workflow secret has no other form.
#[test]
fn deployed_environments_read_the_environment() {
    for kind in ["ci", "saas", "demo", "onprem"] {
        let described = EnvironmentProvider::for_kind(kind).describe().to_string();
        assert!(described.starts_with("env("), "{kind} selected {described}");
    }
}

/// A developer machine has nothing injecting variables into a test action.
#[test]
fn localhost_reads_the_file_store() {
    let described = EnvironmentProvider::for_kind("localhost").describe().to_string();
    assert!(described.starts_with("file("), "localhost selected {described}");
}
