use dgraph_migrate::{EXIT_CURRENT, EXIT_DEPROVISIONED, EXIT_MIGRATED, Outcome, SchemaReport};

#[test]
fn already_current_is_unchanged_success() {
    let outcome = Outcome::AlreadyCurrent;
    assert!(!outcome.changed_the_cluster());
    assert_eq!(outcome.exit_code(), EXIT_CURRENT);
}

#[test]
fn migrated_is_changed_and_not_shell_success() {
    let outcome = Outcome::Migrated(SchemaReport::new(vec!["device.id".to_string()], Vec::new()));
    assert!(outcome.changed_the_cluster());
    assert_eq!(outcome.exit_code(), EXIT_MIGRATED);
}

#[test]
fn deprovisioned_is_changed() {
    let outcome = Outcome::Deprovisioned;
    assert!(outcome.changed_the_cluster());
    assert_eq!(outcome.exit_code(), EXIT_DEPROVISIONED);
}

#[test]
fn status_is_unchanged_success_even_when_incomplete() {
    let outcome = Outcome::Status(SchemaReport::new(vec!["device.id".to_string()], Vec::new()));
    assert!(!outcome.changed_the_cluster());
    assert_eq!(outcome.exit_code(), EXIT_CURRENT);
}
