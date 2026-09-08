use super::*;

#[test]
fn tls_upgrade_plan_uses_system_roots_by_default() {
    let request = open_request("EXAMPLE\\alice", "required");
    let plan = crate::build_tls_upgrade_plan(&request).expect("tls plan");

    assert_eq!(
        plan,
        TlsUpgradePlan {
            server_name: "win.example".to_owned(),
            trust_source: TlsTrustSource::SystemRoots,
        }
    );
}

#[test]
fn tls_upgrade_plan_uses_registered_ca_bundle_for_verify_mode() {
    let mut request = open_request("EXAMPLE\\alice", "required");
    request.target.tls.ca_bundle_id = "ca-bundle-1".to_owned();
    let plan = crate::build_tls_upgrade_plan(&request).expect("tls plan");

    assert_eq!(
        plan,
        TlsUpgradePlan {
            server_name: "win.example".to_owned(),
            trust_source: TlsTrustSource::RegisteredCaBundle("ca-bundle-1".to_owned()),
        }
    );
}

#[test]
fn tls_upgrade_plan_requires_registered_ca_for_pinned_ca_mode() {
    let mut request = open_request("EXAMPLE\\alice", "required");
    request.target.tls.mode = "pinned_ca".to_owned();

    let err = crate::build_tls_upgrade_plan(&request).unwrap_err();

    assert_eq!(err, "tls ca bundle is required");
}

#[test]
fn tls_upgrade_plan_rejects_insecure_modes() {
    let mut request = open_request("EXAMPLE\\alice", "required");
    request.target.tls.mode = "insecure".to_owned();

    let err = crate::build_tls_upgrade_plan(&request).unwrap_err();

    assert_eq!(err, "tls verification mode is unsupported");
}

#[test]
fn registered_ca_bundle_refuses_raw_der_bytes() {
    // Audit finding 1.A2.1: raw DER (or any non-PEM body) must be refused
    // with a structured ca_bundle_invalid reason. Previously the parser
    // wrapped the bytes as a CertificateDer and handed them to rustls,
    // which then failed opaquely at handshake time.
    let err = crate::build_verified_tls_client_config_for_registered_ca_bundle(
        &fixture_server_cert_der(),
    )
    .expect_err("raw DER must be refused");

    assert!(
        err.starts_with("ca_bundle_invalid"),
        "unexpected error: {err}"
    );
    assert!(
        err.contains("not PEM-encoded"),
        "error must explain the cause: {err}"
    );
}

#[test]
fn registered_ca_bundle_builds_verified_tls_client_config_from_pem_chain() {
    let cert_pem = fixture_server_cert_pem();
    let ca_bundle = format!("{cert_pem}\n{cert_pem}");
    let probe =
        crate::build_verified_tls_client_config_for_registered_ca_bundle(ca_bundle.as_bytes())
            .expect("verified TLS config");

    assert_eq!(
        probe,
        VerifiedTlsClientConfigProbe {
            trusted_root_count: 2,
            resumption_disabled_for_credssp: true,
        }
    );
}

#[test]
fn registered_ca_bundle_rejects_empty_or_invalid_material() {
    let empty = crate::build_verified_tls_client_config_for_registered_ca_bundle(b" \n\t")
        .expect_err("empty rejected");
    let invalid =
        crate::build_verified_tls_client_config_for_registered_ca_bundle(b"not a certificate")
            .expect_err("invalid rejected");

    // Every rejection from the CA-bundle parser carries the
    // ca_bundle_invalid prefix (audit finding 1.A2.1) so callers can
    // map it to a structured operator-facing reason.
    assert!(
        empty.starts_with("ca_bundle_invalid"),
        "unexpected empty-case error: {empty}"
    );
    assert!(
        invalid.starts_with("ca_bundle_invalid"),
        "unexpected invalid-case error: {invalid}"
    );
    assert!(
        invalid.contains("not PEM-encoded"),
        "non-PEM input must be rejected at the marker check: {invalid}"
    );
}

#[test]
fn system_roots_build_verified_tls_client_config() {
    let probe = crate::build_verified_tls_client_config_for_system_roots()
        .expect("system roots TLS config");

    assert!(probe.trusted_root_count > 0);
    assert!(probe.resumption_disabled_for_credssp);
}

#[test]
fn extracts_tls_server_public_key_for_credssp_binding() {
    let public_key = crate::extract_credssp_server_public_key(&fixture_server_cert_der())
        .expect("server public key");

    assert_eq!(public_key.len(), 270);
    assert_eq!(&public_key[..2], &[0x30, 0x82]);
}

#[test]
fn rejects_invalid_tls_server_certificate_for_credssp_binding() {
    let err = crate::extract_credssp_server_public_key(b"not a certificate").unwrap_err();

    assert_eq!(err, "tls peer certificate decode failed");
}

#[test]
fn blocking_connect_finalize_writes_credssp_without_cleartext_password() {
    let server_public_key = crate::extract_credssp_server_public_key(&fixture_server_cert_der())
        .expect("server public key");
    let finalize = crate::drive_blocking_connect_finalize_until_server_input(
        open_request("EXAMPLE\\alice", "required"),
        server_public_key,
    )
    .expect("finalize probe");

    assert_eq!(finalize.after_upgrade_state, "Credssp");
    assert!(finalize.wrote_credssp_bytes);
    assert!(!finalize.contains_cleartext_password);
    assert!(!finalize
        .written_bytes
        .windows(b"secret".len())
        .any(|window| window == b"secret"));
}

#[test]
fn parse_registered_ca_bundle_rejects_empty_input() {
    let err = super::parse_registered_ca_bundle(b"").expect_err("empty CA bundle must be refused");
    assert!(
        err.starts_with("ca_bundle_invalid"),
        "unexpected error: {err}"
    );
}

#[test]
fn parse_registered_ca_bundle_rejects_raw_der_bytes() {
    // Audit finding 1.A2.1: a CA bundle whose body lacks a PEM marker
    // (raw DER, binary corruption, junk) MUST be refused with a structured
    // ca_bundle_invalid reason instead of being wrapped as a CertificateDer
    // and forwarded to rustls, which would later reject it opaquely.
    let der = fixture_server_cert_der();
    let err = super::parse_registered_ca_bundle(&der)
        .expect_err("raw DER bytes must be refused, no fallback path");
    assert!(
        err.starts_with("ca_bundle_invalid"),
        "unexpected error: {err}"
    );
    assert!(
        err.contains("not PEM-encoded"),
        "error must explain the cause: {err}"
    );
}

#[test]
fn parse_registered_ca_bundle_rejects_garbage_bytes() {
    let err = super::parse_registered_ca_bundle(b"\x00\x01\x02not a certificate\xff\xfe")
        .expect_err("non-PEM garbage must be refused");
    assert!(
        err.starts_with("ca_bundle_invalid"),
        "unexpected error: {err}"
    );
}

#[test]
fn parse_registered_ca_bundle_accepts_valid_pem() {
    let pem = fixture_server_cert_pem();
    let certs =
        super::parse_registered_ca_bundle(pem.as_bytes()).expect("valid PEM bundle must parse");
    assert_eq!(certs.len(), 1, "fixture is a single certificate");
}
