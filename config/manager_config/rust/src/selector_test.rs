//! Selection is fail-closed, and the failure is legible.
//!
//! One variable, required, no default. Every case here is a way a deployment could start on an
//! environment nobody chose; none of them may resolve to one.

use serviceradar_config_manager::selector::{resolve, Identity, SelectorError};

fn id(kind: &str, instance: Option<&str>) -> Identity {
    Identity { kind: kind.into(), instance: instance.map(str::to_string) }
}

#[test]
fn an_unset_variable_is_an_error_with_no_default() {
    assert_eq!(resolve(None).unwrap_err(), SelectorError::Absent);
}

/// A shell exporting `SERVICERADAR_ENV=` has selected nothing, and this repository's build
/// tooling pins several variables to "" deliberately. Empty must not become a kind.
#[test]
fn an_empty_value_is_unset_not_a_choice() {
    assert_eq!(resolve(Some("")).unwrap_err(), SelectorError::Absent);
    assert_eq!(resolve(Some("   ")).unwrap_err(), SelectorError::Absent);
}

/// The message a reader meets in a crash loop with no other output. It is asserted rather than
/// merely written, because the one thing worse than this failure is this failure explained
/// badly -- and a docstring cannot be checked.
#[test]
fn the_unset_message_says_what_to_set_and_how() {
    let text = resolve(None).unwrap_err().to_string();

    assert!(text.contains("SERVICERADAR_ENV"), "must name the variable:\n{text}");
    assert!(text.contains("CANNOT START"), "must say nothing will happen:\n{text}");
    assert!(text.contains("NO DEFAULT"), "must say there is no fallback:\n{text}");

    for kind in ["localhost", "ci", "saas", "demo", "onprem"] {
        assert!(text.contains(kind), "must list {kind}:\n{text}");
    }
    for platform in ["Kubernetes", "Docker", "Compose", "CI", "Local dev"] {
        assert!(text.contains(platform), "must show how to set it on {platform}:\n{text}");
    }
}

#[test]
fn single_instance_kinds_accept_no_instance() {
    for kind in ["localhost", "ci", "saas", "demo"] {
        assert_eq!(resolve(Some(kind)).unwrap(), id(kind, None));
        assert_eq!(
            resolve(Some(&format!("{kind}:x"))).unwrap_err(),
            SelectorError::InstanceNotAccepted(kind.to_string())
        );
    }
}

#[test]
fn onprem_requires_an_instance() {
    assert_eq!(
        resolve(Some("onprem")).unwrap_err(),
        SelectorError::InstanceRequired("onprem".into())
    );
    assert_eq!(
        resolve(Some("onprem:")).unwrap_err(),
        SelectorError::InstanceRequired("onprem".into())
    );
    assert_eq!(resolve(Some("onprem:untd")).unwrap(), id("onprem", Some("untd")));
}

#[test]
fn an_unrecognised_kind_names_the_value_and_the_valid_set() {
    let err = resolve(Some("CI-staging")).unwrap_err();
    assert_eq!(err, SelectorError::UnknownKind("CI-staging".into()));
    let text = err.to_string();
    assert!(text.contains("CI-staging"), "{text}");
    assert!(text.contains("saas"), "{text}");
}

#[test]
fn surrounding_whitespace_is_tolerated() {
    assert_eq!(resolve(Some("  saas  ")).unwrap(), id("saas", None));
}
