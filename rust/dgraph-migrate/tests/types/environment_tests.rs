use dgraph_migrate::Environment;

#[test]
fn empty_is_local() {
    assert_eq!(Environment::parse(None), Some(Environment::Local));
    assert_eq!(Environment::parse(Some("")), Some(Environment::Local));
}

#[test]
fn known_values_parse() {
    assert_eq!(Environment::parse(Some("local")), Some(Environment::Local));
    assert_eq!(Environment::parse(Some("CI")), Some(Environment::Ci));
    assert_eq!(
        Environment::parse(Some("CLUSTER")),
        Some(Environment::Cluster)
    );
}

#[test]
fn unknown_is_none() {
    assert_eq!(Environment::parse(Some("staging")), None);
}

#[test]
fn only_local_defaults_host() {
    assert!(Environment::Local.allows_localhost_default());
    assert!(!Environment::Ci.allows_localhost_default());
    assert!(!Environment::Cluster.allows_localhost_default());
}

#[test]
fn only_cluster_requires_confirm() {
    assert!(!Environment::Local.deprovision_requires_confirm());
    assert!(!Environment::Ci.deprovision_requires_confirm());
    assert!(Environment::Cluster.deprovision_requires_confirm());
}
