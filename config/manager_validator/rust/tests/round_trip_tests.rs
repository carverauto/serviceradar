//! Each generated binary corresponds to its committed .textproto source.
//!
//! What makes this more than a tautology is that the two sides are read from different places:
//! the committed file comes from the source tree, the canonical text comes from decoding the
//! artifact a runtime actually loads. They agree only if the artifact was in fact built from
//! that source -- which is the property that starts carrying weight the moment the binary is
//! copied into a release artifact's priv/ rather than read out of bazel-bin.

use serviceradar_config_validator::text::{flatten, Pair};
use serviceradar_config_validator::utils_tests::{read, INSTANCES};

fn committed(name: &str) -> Vec<Pair> {
    let src = read(&format!("config/environments/{name}.textproto"));
    flatten(&src).unwrap_or_else(|e| panic!("{name}.textproto: {e}"))
}

fn canonical(name: &str) -> Vec<Pair> {
    let src = read(&format!("config/environments/{name}.canonical.textproto"));
    flatten(&src).unwrap_or_else(|e| panic!("{name}.canonical.textproto: {e}"))
}

#[test]
#[ignore = "needs artifacts built by Bazel (protoc-compiled .binpb); run //config/manager_validator/rust/tests, which passes --include-ignored"]
fn every_generated_binary_round_trips_to_its_committed_source() {
    for name in INSTANCES {
        let mut source = committed(name);
        let mut artifact = canonical(name);

        // A flattener returning nothing for both sides would make every comparison below
        // trivially true, so prove there is something to compare before comparing it.
        assert!(!source.is_empty(), "{name}.textproto flattened to nothing");

        source.sort();
        artifact.sort();

        if source != artifact {
            let only_source: Vec<_> = source.iter().filter(|p| !artifact.contains(p)).collect();
            let only_artifact: Vec<_> = artifact.iter().filter(|p| !source.contains(p)).collect();
            panic!(
                "{name}: the compiled binary does not match {name}.textproto\n  \
                 in the source but not the binary: {only_source:#?}\n  \
                 in the binary but not the source: {only_artifact:#?}"
            );
        }
    }
}

/// The negative control. An equality check that cannot fail proves nothing about the pair it
/// compares, so corrupt one side and confirm the comparison notices.
#[test]
#[ignore = "needs artifacts built by Bazel (protoc-compiled .binpb); run //config/manager_validator/rust/tests, which passes --include-ignored"]
fn a_binary_built_from_a_different_source_is_rejected() {
    let source = committed("saas");
    let mut artifact = canonical("saas");

    let target = artifact
        .iter_mut()
        .find(|p| p.path == "database.host")
        .expect("saas sets database.host");
    target.value = "\"cnpg-rw.elsewhere.svc.cluster.local\"".to_string();

    let mut source = source;
    source.sort();
    artifact.sort();
    assert_ne!(source, artifact, "a changed host must not compare equal");
}

/// Comments and blank lines are the whole reason the comparison is structural rather than
/// byte-for-byte, so confirm they are what the flattener drops -- and only that.
#[test]
#[ignore = "needs artifacts built by Bazel (protoc-compiled .binpb); run //config/manager_validator/rust/tests, which passes --include-ignored"]
fn comments_and_blank_lines_do_not_affect_the_comparison() {
    let plain = flatten("a: 1\nb { c: \"x\" }\n");
    assert!(plain.is_err(), "inline braces are not emitted by protoc and are not accepted");

    let with_noise = flatten("# lead\n\na: 1\n\nb {\n  c: \"x\"  # trailing\n}\n").unwrap();
    let without = flatten("a: 1\nb {\n  c: \"x\"\n}\n").unwrap();
    assert_eq!(with_noise, without);

    // A '#' inside a value is data, not a comment.
    let quoted = flatten("a: \"x#y\"\n").unwrap();
    assert_eq!(quoted[0].value, "\"x#y\"");
}
