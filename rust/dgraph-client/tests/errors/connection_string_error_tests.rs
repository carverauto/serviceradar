/*
 * Copyright (c) "2026" . Marvin Hansen All Rights Reserved.
 */

use dgraph_client::{ConnectionStringError, ConnectionStringErrorEnum};

#[test]
fn constructors_produce_matching_classification() {
    assert!(matches!(
        ConnectionStringError::MissingPort().kind(),
        ConnectionStringErrorEnum::MissingPort
    ));
    assert!(matches!(
        ConnectionStringError::ConflictingAuth().kind(),
        ConnectionStringErrorEnum::ConflictingAuth
    ));
    assert!(matches!(
        ConnectionStringError::InvalidScheme("http".to_string()).kind(),
        ConnectionStringErrorEnum::InvalidScheme(s) if s == "http"
    ));
}

#[test]
fn display_names_the_accepted_ssl_modes() {
    let err = ConnectionStringError::UnknownSslMode("verify-full".to_string());

    let rendered = format!("{err}");
    assert!(rendered.contains("verify-full"));
    assert!(rendered.contains("disable"));
    assert!(rendered.contains("require"));
    assert!(rendered.contains("verify-ca"));
}

#[test]
fn equal_variants_compare_and_hash_equal() {
    use std::collections::HashSet;

    let a = ConnectionStringError::MissingPort();
    let b = ConnectionStringError::MissingPort();
    assert_eq!(a, b);

    let mut set = HashSet::new();
    set.insert(a);
    assert!(set.contains(&b));
}

#[test]
fn implements_std_error() {
    fn assert_error<E: std::error::Error>(_: &E) {}
    assert_error(&ConnectionStringError::MissingHost());
}
