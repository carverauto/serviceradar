//! A secret cannot be printed.
//!
//! This is the single most important property in the crate. Every other check here guards a
//! mistake; this one guards the mistake that ends up in a log aggregator, a crash report, or a
//! support ticket, where it outlives the process that leaked it.

use serviceradar_secret_manager::{Secret, REDACTED};

const VALUE: &str = "hunter2-correct-horse-battery-staple";

#[test]
fn debug_never_contains_the_value() {
    let secret = Secret::new(VALUE).unwrap();
    let rendered = format!("{secret:?}");
    assert!(!rendered.contains(VALUE), "Debug leaked the value: {rendered}");
    assert!(rendered.contains(REDACTED), "{rendered}");
}

#[test]
fn display_never_contains_the_value() {
    let secret = Secret::new(VALUE).unwrap();
    let rendered = format!("{secret}");
    assert!(!rendered.contains(VALUE), "Display leaked the value: {rendered}");
    assert_eq!(rendered, REDACTED);
}

/// `{:?}` reaches secrets through paths that do not look like printing one: a tracing span, an
/// `unwrap` panic, an error chain. Nesting is where a derived Debug on a CONTAINER would defeat a
/// redacted Debug on the value.
#[test]
fn a_secret_nested_in_a_container_is_still_redacted() {
    let secret = Secret::new(VALUE).unwrap();

    let in_option = format!("{:?}", Some(&secret));
    let in_vec = format!("{:?}", vec![&secret]);
    let in_tuple = format!("{:?}", ("database.password", &secret));
    let in_result: Result<&Secret, ()> = Ok(&secret);
    let in_result = format!("{in_result:?}");

    for rendered in [in_option, in_vec, in_tuple, in_result] {
        assert!(!rendered.contains(VALUE), "leaked through a container: {rendered}");
    }
}

/// The value is reachable only through a method whose name says so, which makes every read
/// visible in review and greppable in audit.
#[test]
fn the_value_is_reachable_only_by_exposing_it() {
    assert_eq!(Secret::new(VALUE).unwrap().expose(), VALUE);
}

/// Empty is not a secret. A provider returning an empty string has failed to resolve one, and
/// treating it as a value is how a component connects with a blank password.
#[test]
fn an_empty_value_is_not_a_secret() {
    assert!(Secret::new("").is_none());
}

/// Whitespace is not empty: a secret may legitimately be or contain spaces, and trimming here
/// would silently change a credential.
#[test]
fn whitespace_is_a_value_not_an_absence() {
    let secret = Secret::new(" ").unwrap();
    assert_eq!(secret.expose(), " ");
    assert_eq!(secret.len(), 1);
}
