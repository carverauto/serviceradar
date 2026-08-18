//! Loading validates, and a source that fails validation yields no configuration at all.

mod utils_load;

use serviceradar_config_manager::{load, ConfigError, Identity, ReadSource, Source};
use serviceradar_config_schema::{EnvironmentKind, TlsMode};
use utils_load::{encode, rules, valid_ci};

const NO_BUILT_INS: &[(&str, &[u8])] = &[];

fn id(kind: &str, instance: Option<&str>) -> Identity {
    Identity { kind: kind.into(), instance: instance.map(str::to_string) }
}

/// A mount that is not there, and one that is.
struct Missing;
impl ReadSource for Missing {
    fn read(&self, path: &str) -> Result<Vec<u8>, String> {
        Err(format!("no such file: {path}"))
    }
}

struct Mounted(Vec<u8>);
impl ReadSource for Mounted {
    fn read(&self, _path: &str) -> Result<Vec<u8>, String> {
        Ok(self.0.clone())
    }
}

#[test]
fn a_built_in_loads_and_reports_its_source() {
    let bytes = encode(&valid_ci());
    let built_ins: &[(&str, &[u8])] = &[("ci", &bytes)];

    let loaded = load(&id("ci", None), built_ins, &rules(), &Missing)
        .expect("the fixture instance is valid");

    assert_eq!(loaded.source, Source::BuiltIn { name: "ci".into() });
    assert_eq!(loaded.identity, id("ci", None));
    assert_eq!(loaded.config.database.unwrap().port, Some(5432));
}

/// localhost and ci carry their instance; every deployed kind reads the mount. A developer
/// running `cargo run` and a Bazel test action both have a filesystem nobody provisioned.
#[test]
fn the_kind_decides_where_the_instance_comes_from() {
    assert_eq!(
        Source::for_identity(&id("localhost", None)),
        Source::BuiltIn { name: "localhost".into() }
    );
    assert_eq!(Source::for_identity(&id("ci", None)), Source::BuiltIn { name: "ci".into() });

    for deployed in [id("saas", None), id("demo", None), id("onprem", Some("untd"))] {
        assert!(
            matches!(Source::for_identity(&deployed), Source::Mounted { .. }),
            "{deployed} must read the mount"
        );
    }
}

/// The check that catches a wrong ConfigMap. It is otherwise completely silent, and its blast
/// radius is the database a component connects to.
#[test]
fn an_artifact_describing_another_environment_is_rejected() {
    // saas configuration mounted into a component told it is demo.
    let mut saas = valid_ci();
    saas.kind = Some(EnvironmentKind::Saas as i32);
    let mounted = Mounted(encode(&saas));

    let err = load(&id("demo", None), NO_BUILT_INS, &rules(), &mounted)
        .expect_err("the artifact says saas; the selector says demo");

    match err {
        ConfigError::IdentityMismatch { selected, found, .. } => {
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
    let mounted = Mounted(encode(&other));

    let err = load(&id("onprem", Some("untd")), NO_BUILT_INS, &rules(), &mounted).unwrap_err();
    let text = err.to_string();
    assert!(text.contains("onprem:untd"), "{text}");
    assert!(text.contains("onprem:someone-else"), "{text}");
}

/// The load-time check, which is the reason loading and validation are one operation. A
/// committed instance is validated at build; a mounted one has never been seen by this build.
#[test]
fn an_invalid_instance_is_rejected_at_load_and_yields_nothing() {
    let mut cfg = valid_ci();
    cfg.database.as_mut().unwrap().tls_mode = Some(TlsMode::Disable as i32);
    let bytes = encode(&cfg);
    let built_ins: &[(&str, &[u8])] = &[("ci", &bytes)];

    let err = load(&id("ci", None), built_ins, &rules(), &Missing)
        .expect_err("plaintext TLS outside localhost must not load");

    match err {
        ConfigError::Invalid { violations, .. } => assert!(
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

    let err = load(&id("localhost", None), built_ins, &rules(), &Missing).unwrap_err();
    let text = err.to_string();
    assert!(text.contains("localhost"), "{text}");
    assert!(text.contains("ci"), "{text}");
}

/// A missing mount is fatal. There is no cached fallback to fall back TO, by construction:
/// nothing in the module retains bytes across a call.
#[test]
fn a_missing_mount_is_fatal_and_names_the_path() {
    let err = load(&id("saas", None), NO_BUILT_INS, &rules(), &Missing).unwrap_err();
    match err {
        ConfigError::Read { source, .. } => {
            assert!(matches!(source, Source::Mounted { .. }), "{source}")
        }
        other => panic!("expected Read, got {other:?}"),
    }
}

#[test]
fn bytes_that_are_not_an_environment_config_are_rejected() {
    // A well-formed message of a DIFFERENT type, because a wrong-but-valid artifact is the
    // realistic mistake rather than random bytes.
    let mut buf = Vec::new();
    prost::Message::encode(&rules(), &mut buf).unwrap();

    let err = load(&id("saas", None), NO_BUILT_INS, &rules(), &Mounted(buf)).unwrap_err();
    assert!(
        matches!(err, ConfigError::Decode { .. } | ConfigError::IdentityMismatch { .. }),
        "{err:?}"
    );
}
