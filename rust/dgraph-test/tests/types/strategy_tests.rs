use dgraph_test::{Exclusivity, Strategy};
use serviceradar_config_manager::Identity;

fn identity(value: &str) -> Identity {
    Identity::parse(Some(value)).expect("a valid identity")
}

#[test]
fn localhost_provisions_and_owns() {
    let strategy = Strategy::for_identity(&identity("localhost")).expect("localhost is supported");
    assert_eq!(strategy, Strategy::Container);
    assert_eq!(strategy.exclusivity(), Exclusivity::Exclusive);
}

#[test]
fn ci_verifies_and_does_not_own() {
    let strategy = Strategy::for_identity(&identity("ci")).expect("ci is supported");
    assert_eq!(strategy, Strategy::Existing);
    // Concurrent pull requests share the CI fixture, so it is never ours to wipe.
    assert_eq!(strategy.exclusivity(), Exclusivity::Shared);
}

/// The guard that keeps a test fixture away from production Dgraph.
#[test]
fn production_kinds_are_refused() {
    for kind in ["saas", "demo"] {
        let err = Strategy::for_identity(&identity(kind))
            .expect_err("production must not be reachable from a fixture");
        assert!(err.is_unsupported_environment(), "{kind}: {err}");
        assert!(err.to_string().contains(kind));
    }
}

#[test]
fn onprem_is_refused_too() {
    let err = Strategy::for_identity(&identity("onprem:untd"))
        .expect_err("onprem is not a fixture environment");
    assert!(err.is_unsupported_environment(), "{err}");
}
