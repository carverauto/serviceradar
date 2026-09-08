//! What a component declared, and nothing else.

use serviceradar_secret_manager::Manifest;

#[test]
fn a_manifest_reports_what_it_declares() {
    let manifest = Manifest::new(["database.password", "nats.creds"]);
    assert!(manifest.declares("database.password"));
    assert!(manifest.declares("nats.creds"));
    assert!(!manifest.declares("database.admin_password"));
}

/// Sorted, so a refusal message is stable and diffable rather than ordered by hash.
#[test]
fn declared_names_are_sorted() {
    let manifest = Manifest::new(["nats.creds", "database.password", "core.key"]);
    assert_eq!(manifest.declared(), vec!["core.key", "database.password", "nats.creds"]);
}

/// A component that declares nothing can request nothing -- the default is no access, not all.
#[test]
fn an_empty_manifest_declares_nothing() {
    let manifest = Manifest::new(Vec::<String>::new());
    assert!(manifest.is_empty());
    assert!(!manifest.declares("database.password"));
}
