//! Which source an identity reads from.

use serviceradar_config_manager::{Identity, Source, MOUNTED_INSTANCE_PATH};

fn identity(value: &str) -> Identity {
    Identity::parse(Some(value)).unwrap()
}

/// localhost and ci carry their instance because neither has a platform to mount anything: a
/// developer running a binary directly and a Bazel test action both have a filesystem nobody
/// provisioned.
#[test]
fn kinds_without_a_platform_carry_their_instance() {
    for value in ["localhost", "ci"] {
        assert_eq!(
            Source::for_identity(&identity(value)),
            Source::BuiltIn { name: value.to_string() }
        );
    }
}

#[test]
fn deployed_kinds_read_the_mount() {
    for value in ["saas", "demo", "onprem:untd"] {
        assert_eq!(
            Source::for_identity(&identity(value)),
            Source::Mounted { path: MOUNTED_INSTANCE_PATH.to_string() },
            "{value}"
        );
    }
}

#[test]
fn display_names_a_built_in_by_identity_and_a_mount_by_path() {
    assert_eq!(Source::for_identity(&identity("ci")).to_string(), "built-in:ci");
    assert_eq!(
        Source::for_identity(&identity("saas")).to_string(),
        MOUNTED_INSTANCE_PATH
    );
}
