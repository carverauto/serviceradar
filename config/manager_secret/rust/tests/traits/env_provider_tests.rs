//! `EnvProvider` reads secrets from the process environment.

use serviceradar_secret_manager::{EnvProvider, SecretProvider, SECRET_ENV_PREFIX};

/// The whole point of the transform: a caller that knows the logical name can compute the
/// variable, so no mapping table exists to disagree with the manifest.
#[test]
fn the_variable_is_derived_from_the_logical_name() {
    assert_eq!(
        EnvProvider::variable_for("database.password"),
        "SERVICERADAR_SECRET_DATABASE_PASSWORD"
    );
    assert_eq!(
        EnvProvider::variable_for("database.admin_password"),
        "SERVICERADAR_SECRET_DATABASE_ADMIN_PASSWORD"
    );
}

#[test]
fn every_separator_becomes_an_underscore() {
    assert_eq!(EnvProvider::variable_for("a.b-c/d"), format!("{SECRET_ENV_PREFIX}A_B_C_D"));
}

#[test]
fn an_unset_variable_is_unresolvable_and_names_the_provider() {
    let provider = EnvProvider::new();
    let error = provider.resolve("database.password").expect_err("nothing set it");
    let rendered = error.to_string();
    assert!(rendered.contains("database.password"), "{rendered}");
    assert!(rendered.contains("env("), "the error must name the store consulted: {rendered}");
}

/// A set-but-blank secret is the failure this guards: it authenticates as nobody and the
/// server reports something unrelated. Absent and empty must be the same answer here.
#[test]
fn an_empty_variable_is_absent_not_an_empty_credential() {
    let name = "database.password";
    let variable = EnvProvider::variable_for(name);
    // SAFETY: single-threaded test process; no other thread reads the environment.
    unsafe { std::env::set_var(&variable, "") };
    let outcome = EnvProvider::new().resolve(name);
    unsafe { std::env::remove_var(&variable) };
    assert!(outcome.is_err(), "an empty variable must not resolve to an empty secret");
}

#[test]
fn a_set_variable_resolves_without_its_trailing_newline() {
    let name = "database.ca_cert";
    let variable = EnvProvider::variable_for(name);
    unsafe { std::env::set_var(&variable, "value\n") };
    let secret = EnvProvider::new().resolve(name).expect("set");
    unsafe { std::env::remove_var(&variable) };
    assert_eq!(secret.expose(), "value");
}
