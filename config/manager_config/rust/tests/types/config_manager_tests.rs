//! Loading validates, and a source that fails any check yields no configuration at all.

use serviceradar_config_manager::utils_tests::{encode, valid_ci};
use serviceradar_config_manager::{ConfigManager, Identity, LoadError, ReadSource, Source};
use serviceradar_config_schema::{EnvironmentKind, TlsMode};

const NO_BUILT_INS: &[(&str, &[u8])] = &[];

fn identity(value: &str) -> Identity {
    Identity::parse(Some(value)).unwrap()
}

/// A mount that is not there.
struct Missing;
impl ReadSource for Missing {
    fn read(&self, path: &str) -> Result<Vec<u8>, String> {
        Err(format!("no such file: {path}"))
    }
}

/// A mount carrying exactly these bytes.
struct Mounted(Vec<u8>);
impl ReadSource for Mounted {
    fn read(&self, _path: &str) -> Result<Vec<u8>, String> {
        Ok(self.0.clone())
    }
}

#[test]
fn a_built_in_loads_and_exposes_its_sections() {
    let bytes = encode(&valid_ci());
    let built_ins: &[(&str, &[u8])] = &[("ci", &bytes)];

    let manager = ConfigManager::load(&identity("ci"), built_ins, &Missing)
        .expect("the fixture instance is valid");

    assert_eq!(manager.source(), &Source::BuiltIn { name: "ci".into() });
    assert_eq!(manager.identity(), &identity("ci"));
    assert_eq!(manager.database().and_then(|d| d.port), Some(5432));
    assert!(manager.nats().is_some());
    assert!(manager.core().is_some());
    assert!(manager.dgraph().is_some());
}

/// The check that catches a wrong ConfigMap. It is otherwise completely silent, and its blast
/// radius is the database a component connects to.
#[test]
fn an_artifact_describing_another_environment_is_rejected() {
    let mut saas = valid_ci();
    saas.kind = Some(EnvironmentKind::Saas as i32);

    let err = ConfigManager::load(&identity("demo"), NO_BUILT_INS, &Mounted(encode(&saas)),
    )
    .expect_err("the artifact says saas; the selector says demo");

    match err {
        LoadError::IdentityMismatch { selected, found, .. } => {
            assert_eq!(selected, "demo");
            assert_eq!(found, "saas");
        }
        other => panic!("expected IdentityMismatch, got {other:?}"),
    }
}

/// The same check, one on-prem customer's artifact in another's deployment.
#[test]
fn a_different_onprem_instance_is_rejected() {
    let mut other = valid_ci();
    other.kind = Some(EnvironmentKind::Onprem as i32);
    other.instance = Some("someone-else".into());

    let err = ConfigManager::load(&identity("onprem:untd"), NO_BUILT_INS, &Mounted(encode(&other)),
    )
    .unwrap_err();

    let text = err.to_string();
    assert!(text.contains("onprem:untd"), "{text}");
    assert!(text.contains("onprem:someone-else"), "{text}");
}

/// Loading and validating are one operation. A committed instance is validated at build; a
/// mounted one has never been seen by this repository's build at all.
#[test]
fn an_invalid_instance_is_rejected_at_load_and_yields_nothing() {
    let mut cfg = valid_ci();
    cfg.database.as_mut().unwrap().tls_mode = Some(TlsMode::Disable as i32);
    let bytes = encode(&cfg);
    let built_ins: &[(&str, &[u8])] = &[("ci", &bytes)];

    let err = ConfigManager::load(&identity("ci"), built_ins, &Missing)
        .expect_err("plaintext TLS outside localhost must not load");

    match err {
        LoadError::Invalid { violations, .. } => assert!(
            violations.iter().any(|v| v.code == "DATABASE_TLS_MODE_VERIFIED_OUTSIDE_LOCALHOST"),
            "{violations:?}"
        ),
        other => panic!("expected Invalid, got {other:?}"),
    }
}

#[test]
fn an_unknown_built_in_lists_what_the_release_carries() {
    let bytes = encode(&valid_ci());
    let built_ins: &[(&str, &[u8])] = &[("ci", &bytes)];

    let err = ConfigManager::load(&identity("localhost"), built_ins, &Missing)
        .unwrap_err();

    let text = err.to_string();
    assert!(text.contains("localhost"), "{text}");
    assert!(text.contains("ci"), "{text}");
}

/// A missing mount is fatal. There is no cached fallback to fall back TO, by construction:
/// nothing retains bytes across a call.
#[test]
fn a_missing_mount_is_fatal_and_names_the_source() {
    let err =
        ConfigManager::load(&identity("saas"), NO_BUILT_INS, &Missing).unwrap_err();

    match err {
        LoadError::Read { source, .. } => {
            assert!(matches!(source, Source::Mounted { .. }), "{source}")
        }
        other => panic!("expected Read, got {other:?}"),
    }
}

/// A well-formed message of the WRONG type, because a wrong-but-valid artifact is the realistic
/// mistake rather than random bytes.
#[test]
fn a_well_formed_message_of_another_type_is_rejected() {
    let mut buf = Vec::new();
    // The embedded rule set: a real artifact of the wrong type, which is the realistic
    // mistake -- a ConfigMap holding the rules rather than an instance.
    prost::Message::encode(serviceradar_config_manager::rules::embedded(), &mut buf).unwrap();

    let err =
        ConfigManager::load(&identity("saas"), NO_BUILT_INS, &Mounted(buf)).unwrap_err();

    assert!(
        matches!(err, LoadError::Decode { .. } | LoadError::IdentityMismatch { .. }),
        "{err:?}"
    );
}
