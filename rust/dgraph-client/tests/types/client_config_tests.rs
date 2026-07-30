/*
 * Copyright (c) "2026" . Marvin Hansen All Rights Reserved.
 */

use dgraph_client::{ClientConfig, ConnectErrorEnum, Secret, TlsMode};

// The Go client accepts an empty client list and then panics in rand.Intn(0) on first use.
#[test]
fn rejects_an_empty_endpoint_list() {
    let err = ClientConfig::builder().build().expect_err("should reject");

    assert!(matches!(err.kind(), ConnectErrorEnum::NoEndpoints));
}

#[test]
fn builds_from_endpoints() {
    let config = ClientConfig::builder()
        .endpoint("localhost:9080")
        .endpoint("localhost:9081")
        .build()
        .expect("should build");

    assert_eq!(config.endpoints().len(), 2);
    assert_eq!(config.tls_mode(), TlsMode::Disable);
    assert!(!config.has_acl_credentials());
}

#[test]
fn records_acl_credentials() {
    let config = ClientConfig::builder()
        .endpoint("localhost:9080")
        .acl_credentials("groot", Secret::new("password"))
        .build()
        .expect("should build");

    assert!(config.has_acl_credentials());
    assert_eq!(config.username(), Some("groot"));
}

#[test]
fn builds_from_connection_string() {
    let config = ClientConfig::from_connection_string(
        "dgraph://groot:pw@[::1]:9080?sslmode=verify-ca&namespace=7",
    )
    .expect("should parse");

    assert_eq!(config.endpoints(), ["[::1]:9080"]);
    assert_eq!(config.tls_mode(), TlsMode::VerifyCa);
    assert_eq!(config.namespace(), Some(7));
    assert!(config.has_acl_credentials());
}

#[test]
fn debug_redacts_credentials() {
    let config = ClientConfig::from_connection_string("dgraph://groot:sup3rs3cret@h:1")
        .expect("should parse");

    let rendered = format!("{config:?}");
    assert!(!rendered.contains("sup3rs3cret"), "leaked: {rendered}");
}
