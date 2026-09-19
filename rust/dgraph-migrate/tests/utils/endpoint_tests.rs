use dgraph_migrate::{Environment, HOST_ENV, resolve_from};

#[test]
fn local_defaults_to_loopback() {
    let url = resolve_from(Environment::Local, None, None, None).expect("local");
    assert_eq!(url, "dgraph://127.0.0.1:9080");
}

#[test]
fn url_wins_over_host_port() {
    let url = resolve_from(
        Environment::Cluster,
        Some("dgraph://groot:secret@alpha:9080?sslmode=disable".to_string()),
        Some("ignored.example.com".to_string()),
        Some("1".to_string()),
    )
    .expect("url");
    assert_eq!(url, "dgraph://groot:secret@alpha:9080?sslmode=disable");
}

#[test]
fn ci_requires_host() {
    let err = resolve_from(Environment::Ci, None, None, None).expect_err("ci");
    assert!(err.to_string().contains(HOST_ENV));
}

#[test]
fn cluster_requires_host() {
    let err = resolve_from(Environment::Cluster, None, None, None).expect_err("cluster");
    assert!(err.to_string().contains(HOST_ENV));
}

#[test]
fn assembled_url_uses_configured_host_and_port() {
    let url = resolve_from(
        Environment::Ci,
        None,
        Some("dgraph-ci.example.com".to_string()),
        Some("19080".to_string()),
    )
    .expect("ci");
    assert_eq!(url, "dgraph://dgraph-ci.example.com:19080");
}

#[test]
fn invalid_port_is_an_error() {
    let err = resolve_from(
        Environment::Local,
        None,
        None,
        Some("not-a-port".to_string()),
    )
    .expect_err("port");
    assert!(err.to_string().contains("invalid"));
}
