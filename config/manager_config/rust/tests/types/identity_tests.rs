//! Parsing the one variable that decides the environment.

use serviceradar_config_manager::{Identity, SelectorError};

#[test]
fn an_unset_variable_is_an_error_with_no_default() {
    assert_eq!(Identity::parse(None).unwrap_err(), SelectorError::Absent);
}

/// A shell exporting `SERVICERADAR_ENV=` has selected nothing, and this repository's build
/// tooling pins several variables to "" deliberately. Empty must not become a kind.
#[test]
fn an_empty_value_is_unset_not_a_choice() {
    assert_eq!(Identity::parse(Some("")).unwrap_err(), SelectorError::Absent);
    assert_eq!(Identity::parse(Some("   ")).unwrap_err(), SelectorError::Absent);
}

#[test]
fn single_instance_kinds_accept_no_instance() {
    for kind in ["localhost", "ci", "saas", "demo"] {
        let parsed = Identity::parse(Some(kind)).unwrap();
        assert_eq!(parsed.kind(), kind);
        assert_eq!(parsed.instance(), None);

        assert_eq!(
            Identity::parse(Some(&format!("{kind}:x"))).unwrap_err(),
            SelectorError::InstanceNotAccepted(kind.to_string())
        );
    }
}

#[test]
fn onprem_requires_an_instance() {
    assert_eq!(
        Identity::parse(Some("onprem")).unwrap_err(),
        SelectorError::InstanceRequired("onprem".into())
    );
    assert_eq!(
        Identity::parse(Some("onprem:")).unwrap_err(),
        SelectorError::InstanceRequired("onprem".into())
    );

    let parsed = Identity::parse(Some("onprem:untd")).unwrap();
    assert_eq!(parsed.kind(), "onprem");
    assert_eq!(parsed.instance(), Some("untd"));
}

#[test]
fn an_unrecognised_kind_is_rejected() {
    assert_eq!(
        Identity::parse(Some("CI-staging")).unwrap_err(),
        SelectorError::UnknownKind("CI-staging".into())
    );
}

#[test]
fn surrounding_whitespace_is_tolerated() {
    assert_eq!(Identity::parse(Some("  saas  ")).unwrap().kind(), "saas");
}

/// Display is the spelling `SERVICERADAR_ENV` accepts, so an error can quote back something a
/// reader can paste into a manifest.
#[test]
fn display_round_trips_through_parse() {
    for value in ["localhost", "ci", "saas", "demo", "onprem:untd"] {
        let parsed = Identity::parse(Some(value)).unwrap();
        assert_eq!(parsed.to_string(), value);
        assert_eq!(Identity::parse(Some(&parsed.to_string())).unwrap(), parsed);
    }
}
