//! Resolution is least privilege first, then fail-closed.

use serviceradar_secret_manager::utils_tests::MapProvider;
use serviceradar_secret_manager::{Manifest, SecretError, SecretManager};

fn manager(declared: &[&str], stored: &[(&str, &str)]) -> SecretManager<MapProvider> {
    SecretManager::new(
        MapProvider::new(stored.iter().copied()),
        Manifest::new(declared.iter().copied()),
    )
}

#[test]
fn a_declared_and_stored_secret_resolves() {
    let m = manager(&["database.password"], &[("database.password", "hunter2")]);
    assert_eq!(m.resolve("database.password").unwrap().expose(), "hunter2");
}

/// Configuration gets least privilege from the build graph; a secret cannot be a build target, so
/// the symmetric mechanism is the declaration, enforced here.
#[test]
fn an_undeclared_name_is_refused_even_when_the_store_has_it() {
    let m = manager(
        &["database.password"],
        &[("database.password", "hunter2"), ("nats.creds", "secret-creds")],
    );

    match m.resolve("nats.creds").unwrap_err() {
        SecretError::Undeclared { name, declared } => {
            assert_eq!(name, "nats.creds");
            assert_eq!(declared, vec!["database.password"]);
        }
        other => panic!("expected Undeclared, got {other:?}"),
    }
}

/// Refusal precedes resolution. Answering an undeclared name -- even to say "not found" -- tells
/// a component whether a secret it may not have exists.
#[test]
fn an_undeclared_name_is_refused_identically_whether_or_not_it_exists() {
    let m = manager(&["database.password"], &[("database.password", "hunter2")]);

    let present = manager(
        &["database.password"],
        &[("database.password", "hunter2"), ("nats.creds", "x")],
    );

    let absent_err = m.resolve("nats.creds").unwrap_err();
    let present_err = present.resolve("nats.creds").unwrap_err();
    assert_eq!(absent_err, present_err, "the refusal must not reveal existence");
}

/// There is no default and no empty fallback: a component that continued here would authenticate
/// with a blank credential.
#[test]
fn a_declared_but_missing_secret_names_the_key_and_the_provider() {
    let m = manager(&["database.password"], &[]);

    match m.resolve("database.password").unwrap_err() {
        SecretError::Unresolvable { name, provider } => {
            assert_eq!(name, "database.password");
            assert_eq!(provider, "test-map");
        }
        other => panic!("expected Unresolvable, got {other:?}"),
    }
}

/// An empty stored value is a failure to resolve, not a resolved empty secret.
#[test]
fn an_empty_stored_value_does_not_resolve() {
    let m = manager(&["database.password"], &[("database.password", "")]);
    assert!(matches!(
        m.resolve("database.password").unwrap_err(),
        SecretError::Unresolvable { .. }
    ));
}

/// Startup resolves everything declared. A component that resolves lazily discovers a missing
/// secret when it first needs it -- under load, and far from the deploy that caused it.
#[test]
fn resolve_all_returns_every_declared_secret() {
    let m = manager(
        &["database.password", "nats.creds"],
        &[("database.password", "hunter2"), ("nats.creds", "creds")],
    );

    let resolved = m.resolve_all().unwrap();
    let names: Vec<&str> = resolved.iter().map(|(n, _)| n.as_str()).collect();
    assert_eq!(names, vec!["database.password", "nats.creds"]);
}

#[test]
fn resolve_all_fails_when_any_declared_secret_is_missing() {
    let m = manager(
        &["database.password", "nats.creds"],
        &[("database.password", "hunter2")],
    );

    match m.resolve_all().unwrap_err() {
        SecretError::Unresolvable { name, .. } => assert_eq!(name, "nats.creds"),
        other => panic!("expected Unresolvable, got {other:?}"),
    }
}

/// `explain` has to report which store was consulted, or a reader cannot tell where to put a
/// missing value.
#[test]
fn the_provider_is_reportable() {
    assert_eq!(manager(&[], &[]).provider(), "test-map");
}
