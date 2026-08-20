use dgraph_test::utils_tests::endpoint;
use serviceradar_config_schema::DgraphTlsMode;

#[test]
fn plaintext_omits_sslmode() {
    let e = endpoint("localhost", 9080, DgraphTlsMode::Disable);
    // Plaintext is the client's default, so this is the string a caller would actually write.
    assert_eq!(e.connection_string_at(9080), "dgraph://localhost:9080");
    assert!(!e.is_tls());
}

#[test]
fn each_verified_posture_reaches_the_wire() {
    let require = endpoint("h", 9080, DgraphTlsMode::RequireNoVerify);
    assert_eq!(require.connection_string_at(9080), "dgraph://h:9080?sslmode=require");
    assert!(require.is_tls());

    let verify = endpoint("h", 9080, DgraphTlsMode::VerifyCa);
    assert_eq!(verify.connection_string_at(9080), "dgraph://h:9080?sslmode=verify-ca");
    assert!(verify.is_tls());
}

#[test]
fn unspecified_is_treated_as_plaintext_not_as_tls() {
    let e = endpoint("h", 9080, DgraphTlsMode::Unspecified);
    assert!(!e.is_tls());
    assert_eq!(e.connection_string_at(9080), "dgraph://h:9080");
}

/// The port is a parameter because docker_utils, not the configuration, is authoritative about
/// where a container actually landed.
#[test]
fn the_reported_port_wins_over_the_configured_one() {
    let e = endpoint("localhost", 9080, DgraphTlsMode::Disable);
    assert_eq!(e.connection_string_at(33333), "dgraph://localhost:33333");
}

/// Enabling TLS moves the WHOLE of Dgraph's HTTP port to HTTPS, not just gRPC. Getting this
/// wrong produces "client sent an HTTP request to an HTTPS server" and a fixture that never
/// reports ready.
#[test]
fn health_url_scheme_follows_the_tls_posture() {
    let plain = endpoint("h", 9080, DgraphTlsMode::Disable);
    assert_eq!(plain.health_url(), "http://h:8080/health");
    assert_eq!(plain.cluster_health_url(), "http://h:8080/health?all");

    let tls = endpoint("h", 9080, DgraphTlsMode::VerifyCa);
    assert_eq!(tls.health_url(), "https://h:8080/health");
    assert_eq!(tls.cluster_health_url(), "https://h:8080/health?all");
}

/// Regression: readiness MUST NOT use `?all`.
///
/// `?all` reports cluster membership, which goes green before the alpha will serve gRPC. Gating
/// readiness on it produced a fixture that reported ready followed immediately by
/// "Please retry again, server is not ready to accept requests" from connect().
#[test]
fn readiness_url_is_not_the_cluster_url() {
    let e = endpoint("h", 9080, DgraphTlsMode::Disable);
    assert!(!e.health_url().contains("?all"), "{}", e.health_url());
    assert_ne!(e.health_url(), e.cluster_health_url());
}

/// The admin port is fixed by Dgraph and is not the gRPC port the configuration names.
#[test]
fn health_url_uses_the_admin_port_not_the_grpc_port() {
    let e = endpoint("h", 19080, DgraphTlsMode::Disable);
    assert!(e.health_url().contains(":8080/"), "{}", e.health_url());
    assert!(!e.health_url().contains("19080"));
}
