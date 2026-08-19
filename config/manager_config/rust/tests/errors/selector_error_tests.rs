//! The message a reader meets in a crash loop with no other output.
//!
//! Asserted rather than merely written: the one thing worse than this failure is this failure
//! explained badly, and a docstring cannot be checked.

use serviceradar_config_manager::{Identity, SelectorError};

fn unset_message() -> String {
    Identity::parse(None).unwrap_err().to_string()
}

#[test]
fn the_unset_message_names_the_variable_and_says_nothing_can_start() {
    let text = unset_message();
    assert!(text.contains("SERVICERADAR_ENV"), "{text}");
    assert!(text.contains("CANNOT START"), "{text}");
}

#[test]
fn the_unset_message_says_there_is_no_default() {
    assert!(unset_message().contains("NO DEFAULT"), "{}", unset_message());
}

#[test]
fn the_unset_message_lists_every_accepted_value() {
    let text = unset_message();
    for kind in ["localhost", "ci", "saas", "demo", "onprem"] {
        assert!(text.contains(kind), "missing {kind}:\n{text}");
    }
}

/// The reader's next action is editing a manifest, not reading source.
#[test]
fn the_unset_message_shows_how_to_set_it_on_every_platform() {
    let text = unset_message();
    for platform in ["Kubernetes", "Docker", "Compose", "CI", "Local dev"] {
        assert!(text.contains(platform), "missing {platform}:\n{text}");
    }
}

#[test]
fn every_other_selector_error_quotes_the_offending_value() {
    assert!(SelectorError::UnknownKind("CI-staging".into()).to_string().contains("CI-staging"));
    assert!(SelectorError::InstanceRequired("onprem".into()).to_string().contains("onprem"));
    assert!(SelectorError::InstanceNotAccepted("saas".into()).to_string().contains("saas"));
}
