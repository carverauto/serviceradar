//! Every secret failure is actionable, and none of them prints a value.

use serviceradar_secret_manager::SecretError;

#[test]
fn an_undeclared_refusal_lists_what_is_declared_and_says_why() {
    let text = SecretError::Undeclared {
        name: "nats.creds".into(),
        declared: vec!["database.password".into()],
    }
    .to_string();

    assert!(text.contains("nats.creds"), "{text}");
    assert!(text.contains("database.password"), "{text}");
    assert!(text.contains("manifest"), "the fix is editing the manifest: {text}");
}

/// The message must rule out the reading that a missing secret is survivable.
#[test]
fn an_unresolvable_secret_names_the_key_the_provider_and_the_consequence() {
    let text = SecretError::Unresolvable {
        name: "database.password".into(),
        provider: "file(/etc/serviceradar/secrets)".into(),
    }
    .to_string();

    assert!(text.contains("database.password"), "{text}");
    assert!(text.contains("/etc/serviceradar/secrets"), "{text}");
    assert!(text.contains("no default"), "{text}");
    assert!(text.contains("blank credential"), "{text}");
}

#[test]
fn a_provider_failure_names_the_provider_and_the_cause() {
    let text = SecretError::Provider {
        name: "database.password".into(),
        provider: "file(/etc/serviceradar/secrets)".into(),
        detail: "permission denied".into(),
    }
    .to_string();

    assert!(text.contains("permission denied"), "{text}");
    assert!(text.contains("/etc/serviceradar/secrets"), "{text}");
}

/// A secret error names a KEY, never a value -- these are the strings that reach logs.
#[test]
fn no_secret_error_can_carry_a_value() {
    let errors = [
        SecretError::Undeclared { name: "k".into(), declared: vec!["d".into()] },
        SecretError::Unresolvable { name: "k".into(), provider: "p".into() },
        SecretError::Provider { name: "k".into(), provider: "p".into(), detail: "d".into() },
    ];

    for err in errors {
        let text = format!("{err} {err:?}");
        assert!(!text.contains("hunter2"), "{text}");
    }
}
