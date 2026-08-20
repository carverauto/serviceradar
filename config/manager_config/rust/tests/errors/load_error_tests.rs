//! Every load failure names its source, so a reader knows which artifact to look at.

use serviceradar_config_manager::{LoadError, Source};

fn mounted() -> Source {
    Source::Mounted { path: "/etc/serviceradar/environment.binpb".into() }
}

#[test]
fn a_read_failure_names_the_path_and_the_cause() {
    let text = LoadError::Read { source: mounted(), detail: "permission denied".into() }.to_string();
    assert!(text.contains("/etc/serviceradar/environment.binpb"), "{text}");
    assert!(text.contains("permission denied"), "{text}");
}

#[test]
fn a_decode_failure_says_what_the_bytes_were_expected_to_be() {
    let text = LoadError::Decode { source: mounted(), detail: "bad wire type".into() }.to_string();
    assert!(text.contains("EnvironmentConfig"), "{text}");
}

#[test]
fn an_unknown_built_in_lists_the_alternatives() {
    let text = LoadError::UnknownBuiltIn {
        name: "staging".into(),
        available: vec!["localhost".into(), "ci".into()],
    }
    .to_string();
    assert!(text.contains("staging"), "{text}");
    assert!(text.contains("localhost") && text.contains("ci"), "{text}");
}

/// The mismatch message has to make the consequence obvious, not merely report two strings: the
/// component would connect to the wrong database while believing it was right.
#[test]
fn a_mismatch_states_the_consequence_not_just_the_difference() {
    let text = LoadError::IdentityMismatch {
        selected: "demo".into(),
        found: "saas".into(),
        source: mounted(),
    }
    .to_string();
    assert!(text.contains("demo") && text.contains("saas"), "{text}");
    assert!(text.contains("wrong artifact is mounted"), "{text}");
    assert!(text.contains("database"), "{text}");
}
