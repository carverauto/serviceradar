//! The DSN is assembled from typed fields, and is as secret as the password inside it.

use serviceradar_config_manager::utils_tests::{encode, rules, valid_ci};
use serviceradar_config_manager::{ConfigManager, Identity, ReadSource};
use serviceradar_config_schema::TlsMode;

const PASSWORD: &str = "hunter2-correct-horse";

struct NoMount;
impl ReadSource for NoMount {
    fn read(&self, _: &str) -> Result<Vec<u8>, String> {
        Err("not used".into())
    }
}

fn manager_with(tls: TlsMode) -> ConfigManager {
    let mut cfg = valid_ci();
    cfg.database.as_mut().unwrap().tls_mode = Some(tls as i32);
    let bytes = encode(&cfg);
    let built_ins: &[(&str, &[u8])] = &[("ci", &bytes)];
    let identity = Identity::parse(Some("ci")).unwrap();
    ConfigManager::load(&identity, built_ins, &rules(), &NoMount).expect("valid")
}

/// The typed TLS mode becomes `sslmode`. A DSN built by concatenation is how `sslmode` went
/// missing and tokio-postgres fell back to Prefer, permitting a plaintext connection while every
/// test still passed.
#[test]
fn the_typed_tls_mode_becomes_sslmode() {
    for (mode, expected) in [
        (TlsMode::VerifyFull, "sslmode=verify-full"),
        (TlsMode::VerifyCa, "sslmode=verify-ca"),
    ] {
        let dsn = manager_with(mode).database_url(PASSWORD).unwrap();
        assert!(dsn.expose().contains(expected), "{}", dsn.expose());
    }
}

/// A DSN without `sslmode` is unreachable, and not because `database_url` guards against it: an
/// unspecified TLS mode never survives loading, so no ConfigManager can hold one. The guard in
/// `database_url` is defence in depth behind that, which is why this asserts the LOAD fails
/// rather than asserting the guard fires.
#[test]
fn an_unspecified_tls_mode_never_reaches_a_loaded_manager() {
    let mut cfg = valid_ci();
    cfg.database.as_mut().unwrap().tls_mode = Some(TlsMode::Unspecified as i32);
    let bytes = encode(&cfg);
    let built_ins: &[(&str, &[u8])] = &[("ci", &bytes)];
    let identity = Identity::parse(Some("ci")).unwrap();

    assert!(
        ConfigManager::load(&identity, built_ins, &rules(), &NoMount).is_err(),
        "validation must reject an unspecified TLS mode before a DSN can be built"
    );
}

#[test]
fn the_dsn_carries_the_typed_coordinates() {
    let dsn = manager_with(TlsMode::VerifyFull).database_url(PASSWORD).unwrap();
    let text = dsn.expose();
    assert!(text.starts_with("postgres://srql_test:"), "{text}");
    assert!(text.contains("@db:5432/srql_fixture"), "{text}");
}

/// The reason the DSN is not a schema field is that it embeds a password. That reasoning does not
/// stop at the schema: an assembled DSN is as sensitive as the secret inside it.
#[test]
fn the_dsn_never_prints_its_password() {
    let dsn = manager_with(TlsMode::VerifyFull).database_url(PASSWORD).unwrap();

    let rendered = format!("{dsn} {dsn:?} {:?} {:?}", Some(&dsn), vec![&dsn]);
    assert!(!rendered.contains(PASSWORD), "the DSN leaked its password: {rendered}");
    assert!(!rendered.contains("srql_fixture"), "and it should not print at all: {rendered}");
}

/// A password containing `@` or `:` would otherwise truncate the host or the role, producing a
/// DSN that parses into something else entirely rather than failing.
#[test]
fn a_password_with_delimiters_is_encoded_not_truncated() {
    let dsn = manager_with(TlsMode::VerifyFull)
        .database_url("p@ss:word/with?odd#chars")
        .unwrap();
    let text = dsn.expose();

    assert!(text.contains("p%40ss%3Aword%2Fwith%3Fodd%23chars"), "{text}");
    assert!(text.contains("@db:5432/"), "the host must still parse: {text}");
}

/// Required under verify-full because the certificate may carry DNS SANs and no IP SANs, so an
/// address-based caller must state the name verification is performed against.
#[test]
fn the_tls_server_name_reaches_the_dsn() {
    let dsn = manager_with(TlsMode::VerifyFull).database_url(PASSWORD).unwrap();
    assert!(dsn.expose().contains("host=db"), "{}", dsn.expose());
}
