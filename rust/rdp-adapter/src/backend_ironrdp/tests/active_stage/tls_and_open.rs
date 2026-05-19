#[cfg(serviceradar_rdp_connector_link_probe)]
#[test]
fn connector_probe_blocking_connect_finalize_writes_credssp_without_password() {
    let payload = parse_open_payload(valid_open_payload().as_bytes()).expect("valid payload");
    let plan = build_nonsecret_connection_plan(&payload).expect("plan");
    let credential = build_memory_user_credential(
        payload
            .credential_grant
            .as_ref()
            .expect("memory user credential grant"),
        &payload.actor_id,
    )
    .expect("credential");

    let server_public_key = derive_credssp_server_public_key_from_verified_tls_peer_for_probe(
        &fixture_server_cert_der(),
    )
    .expect("server public key");
    let probe = drive_blocking_connect_finalize_for_probe(&plan, &credential, server_public_key)
        .expect("blocking connect finalize");

    assert!(probe.wrote_credssp_bytes);
    assert!(!probe.contains_cleartext_password);
    assert!(!probe.written_bytes.is_empty());
}

#[cfg(serviceradar_rdp_connector_link_probe)]
#[test]
fn connector_probe_blocking_connect_finalize_rejects_empty_public_key() {
    let payload = parse_open_payload(valid_open_payload().as_bytes()).expect("valid payload");
    let plan = build_nonsecret_connection_plan(&payload).expect("plan");
    let credential = build_memory_user_credential(
        payload
            .credential_grant
            .as_ref()
            .expect("memory user credential grant"),
        &payload.actor_id,
    )
    .expect("credential");

    let err = drive_blocking_connect_finalize_for_probe(
        &plan,
        &credential,
        VerifiedTlsPeerPublicKeyForProbe { bytes: Vec::new() },
    )
    .expect_err("empty public key rejected");

    assert_eq!(err, BackendError::Unsupported(CONNECTOR_NOT_IMPLEMENTED));
}

#[cfg(serviceradar_rdp_connector_link_probe)]
#[test]
fn connector_probe_extracts_tls_public_key_for_credssp_binding() {
    let public_key = derive_credssp_server_public_key_from_verified_tls_peer_for_probe(
        &fixture_server_cert_der(),
    )
    .expect("server public key")
    .into_bytes();

    assert_eq!(public_key.len(), 270);
    assert_eq!(&public_key[..2], &[0x30, 0x82]);
}

#[cfg(serviceradar_rdp_connector_link_probe)]
#[test]
fn connector_probe_rejects_invalid_tls_certificate_for_public_key_binding() {
    let err =
        derive_credssp_server_public_key_from_verified_tls_peer_for_probe(b"not a certificate")
            .expect_err("invalid cert rejected");

    assert_eq!(err, BackendError::Unsupported(CONNECTOR_NOT_IMPLEMENTED));
}

#[cfg(serviceradar_rdp_connector_link_probe)]
#[test]
fn connector_probe_registered_ca_bundle_rejects_der_material() {
    let err = build_verified_tls_client_config_for_registered_ca_bundle(&fixture_server_cert_der())
        .err()
        .expect("der material rejected");

    assert_eq!(err, BackendError::Unsupported(INVALID_TLS_CA_BUNDLE));
}

#[cfg(serviceradar_rdp_connector_link_probe)]
#[test]
fn connector_probe_registered_ca_bundle_builds_verified_tls_client_config_from_pem_chain() {
    let cert_pem = fixture_server_cert_pem();
    let ca_bundle = format!("{cert_pem}\n{cert_pem}");
    let probe = build_verified_tls_client_config_for_registered_ca_bundle(ca_bundle.as_bytes())
        .expect("verified TLS config")
        .probe();

    assert_eq!(
        probe,
        VerifiedTlsClientConfigProbe {
            trusted_root_count: 2,
            resumption_disabled_for_credssp: true,
        }
    );
}

#[cfg(serviceradar_rdp_connector_link_probe)]
#[test]
fn connector_probe_registered_ca_bundle_rejects_empty_or_invalid_material() {
    let empty = build_verified_tls_client_config_for_registered_ca_bundle(b" \n\t")
        .err()
        .expect("empty rejected");
    let invalid = build_verified_tls_client_config_for_registered_ca_bundle(b"not a certificate")
        .err()
        .expect("invalid rejected");

    assert_eq!(empty, BackendError::Unsupported(INVALID_TLS_CA_BUNDLE));
    assert_eq!(invalid, BackendError::Unsupported(INVALID_TLS_CA_BUNDLE));
}

#[cfg(serviceradar_rdp_connector_link_probe)]
#[test]
fn connector_probe_builds_verified_tls_client_config_from_plan_bundle_material() {
    let mut payload = parse_open_payload(valid_open_payload().as_bytes()).expect("payload");
    payload.target.tls.ca_bundle_id = "ca-rdp-prod".to_owned();
    payload.target.tls.ca_bundle_pem = fixture_server_cert_pem();
    let plan = build_nonsecret_connection_plan(&payload).expect("plan");

    let probe = build_verified_tls_client_config_for_plan(&plan)
        .expect("verified config")
        .probe();

    assert_eq!(
        probe,
        VerifiedTlsClientConfigProbe {
            trusted_root_count: 1,
            resumption_disabled_for_credssp: true,
        }
    );
}

#[cfg(serviceradar_rdp_connector_link_probe)]
#[test]
fn connector_probe_rejects_invalid_plan_bundle_material() {
    let mut payload = parse_open_payload(valid_open_payload().as_bytes()).expect("payload");
    payload.target.tls.ca_bundle_id = "ca-rdp-prod".to_owned();
    payload.target.tls.ca_bundle_pem = "not a certificate".to_owned();
    let plan = build_nonsecret_connection_plan(&payload).expect("plan");

    let err = build_verified_tls_client_config_for_plan(&plan)
        .err()
        .expect("invalid plan bundle rejected");

    assert_eq!(err, BackendError::Unsupported(INVALID_TLS_CA_BUNDLE));
}

#[cfg(serviceradar_rdp_connector_link_probe)]
#[test]
fn connector_probe_backend_open_runs_verified_tls_preflight_before_fail_closed() {
    let mut payload = parse_open_payload(valid_open_payload().as_bytes()).expect("payload");
    payload.target.tls.ca_bundle_id = "ca-rdp-prod".to_owned();
    payload.target.tls.ca_bundle_pem = fixture_server_cert_pem();
    let mut backend = IronRdpBackend;

    let result = backend.open(payload);

    assert!(matches!(
        result,
        Err(BackendError::Unsupported(CONNECTOR_NOT_IMPLEMENTED))
    ));
}

#[cfg(serviceradar_rdp_connector_link_probe)]
#[test]
fn connector_probe_backend_open_rejects_invalid_ca_bundle_before_connector_loop() {
    let mut payload = parse_open_payload(valid_open_payload().as_bytes()).expect("payload");
    payload.target.tls.ca_bundle_id = "ca-rdp-prod".to_owned();
    payload.target.tls.ca_bundle_pem = "not a certificate".to_owned();
    let mut backend = IronRdpBackend;

    let result = backend.open(payload);

    assert!(matches!(
        result,
        Err(BackendError::Unsupported(INVALID_TLS_CA_BUNDLE))
    ));
}

#[cfg(serviceradar_rdp_connector_link_probe)]
#[test]
fn connector_probe_system_roots_build_verified_tls_client_config() {
    let probe =
        build_verified_tls_client_config_for_system_roots().expect("system roots TLS config");
    let probe = probe.probe();

    assert!(probe.trusted_root_count > 0);
    assert!(probe.resumption_disabled_for_credssp);
}
