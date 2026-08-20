/*
 * Copyright (c) "2026" . Marvin Hansen All Rights Reserved.
 */

use dgraph_client::{CaCertificate, ClientConfig, TlsMode};

const PEM: &[u8] = b"-----BEGIN CERTIFICATE-----\nnot-a-real-certificate\n-----END CERTIFICATE-----\n";

#[test]
fn pem_variant_returns_its_bytes_without_touching_the_filesystem() {
    let ca = CaCertificate::Pem(PEM.to_vec());
    assert_eq!(ca.pem().expect("in-memory PEM never fails"), PEM);
}

#[test]
fn file_variant_reads_the_file() {
    let dir = std::env::temp_dir().join(format!("dgraph-ca-{}", std::process::id()));
    std::fs::create_dir_all(&dir).expect("temp dir");
    let path = dir.join("ca.crt");
    std::fs::write(&path, PEM).expect("write");

    let ca = CaCertificate::File(path.clone());
    assert_eq!(ca.pem().expect("readable file"), PEM);

    std::fs::remove_dir_all(&dir).ok();
}

#[test]
fn missing_file_is_an_error_rather_than_a_silent_empty_certificate() {
    // The failure that matters: an unreadable CA must not degrade into "no CA", which would
    // silently fall back to whatever the system trust store allows.
    let ca = CaCertificate::File("/nonexistent/dgraph/ca.crt".into());
    assert!(ca.pem().is_err());
}

#[test]
fn sslrootcert_populates_the_config_from_a_connection_string() {
    let config =
        ClientConfig::from_connection_string("dgraph://host:9080?sslmode=verify-ca&sslrootcert=/etc/ssl/ca.crt")
            .expect("parses");

    assert_eq!(config.tls_mode(), TlsMode::VerifyCa);
    match config.ca_certificate() {
        Some(CaCertificate::File(path)) => assert_eq!(path.to_str(), Some("/etc/ssl/ca.crt")),
        other => panic!("expected a file CA, got {other:?}"),
    }
}

#[test]
fn absent_sslrootcert_leaves_the_system_trust_store_in_play() {
    let config =
        ClientConfig::from_connection_string("dgraph://host:9080?sslmode=verify-ca").expect("parses");
    assert!(config.ca_certificate().is_none());
}

#[test]
fn builder_takes_pem_content_for_callers_that_resolve_it_as_a_secret() {
    let config = ClientConfig::builder()
        .endpoint("host:9080")
        .tls_mode(TlsMode::VerifyCa)
        .ca_certificate(CaCertificate::Pem(PEM.to_vec()))
        .build()
        .expect("builds");

    assert!(matches!(config.ca_certificate(), Some(CaCertificate::Pem(_))));
}
