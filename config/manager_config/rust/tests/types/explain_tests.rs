//! `explain` reports where every value came from, and cannot report a secret.

use serviceradar_config_manager::utils_tests::{encode, valid_ci};
use serviceradar_config_manager::{ConfigManager, Explanation, Identity, ReadSource};

struct NoMount;
impl ReadSource for NoMount {
    fn read(&self, _: &str) -> Result<Vec<u8>, String> {
        Err("not used".into())
    }
}

fn manager() -> ConfigManager {
    let bytes = encode(&valid_ci());
    let built_ins: &[(&str, &[u8])] = &[("ci", &bytes)];
    let identity = Identity::parse(Some("ci")).unwrap();
    ConfigManager::load(&identity, built_ins, &NoMount).expect("valid")
}

/// The failure this whole system replaces was SILENT: a value came from somewhere nobody could
/// name. Every reported value therefore carries an origin, including one that was compiled in --
/// "it was built into the release" is an answer, and omitting it leaves the question open.
#[test]
fn every_reported_value_carries_an_origin() {
    let explanation = Explanation::new(&manager(), &[]);
    assert!(!explanation.entries.is_empty());

    for entry in &explanation.entries {
        assert!(!entry.origin.is_empty(), "{} has no origin", entry.field);
        assert_eq!(entry.origin, "built-in:ci", "{}", entry.field);
    }
}

#[test]
fn the_report_names_the_environment_and_the_source() {
    let rendered = Explanation::new(&manager(), &[]).render();
    assert!(rendered.contains("SERVICERADAR_ENV=ci"), "{rendered}");
    assert!(rendered.contains("source: built-in:ci"), "{rendered}");
}

#[test]
fn typed_enums_are_reported_by_name_not_by_number() {
    let explanation = Explanation::new(&manager(), &[]);
    let tls = explanation
        .entries
        .iter()
        .find(|e| e.field == "database.tls_mode")
        .expect("tls_mode is reported");
    assert_eq!(tls.value, "TLS_MODE_VERIFY_FULL");
}

/// Secret NAMES are useful in a report; secret VALUES are not, and a masked value beside a name
/// is one formatting change away from an unmasked one. `Explanation` has no way to reach a
/// secret at all, which is stronger than remembering to redact.
#[test]
fn declared_secrets_are_listed_by_name_only() {
    let rendered = Explanation::new(&manager(), &["database.password", "nats.creds"]).render();

    assert!(rendered.contains("database.password"), "{rendered}");
    assert!(rendered.contains("nats.creds"), "{rendered}");
    assert!(rendered.contains("value not shown"), "{rendered}");
}

/// The report is assembled from the loaded configuration, which by construction contains no
/// credential: the schema has no password field and the DSN is not a field either.
#[test]
fn no_credential_can_appear_in_the_report() {
    let rendered = Explanation::new(&manager(), &["database.password"]).render();

    for forbidden in ["hunter2", "postgres://", "password="] {
        assert!(!rendered.contains(forbidden), "report contained {forbidden}: {rendered}");
    }
}

#[test]
fn a_component_declaring_no_secrets_says_so() {
    assert!(Explanation::new(&manager(), &[]).render().contains("(none)"));
}
