#[cfg(serviceradar_rdp_connector_link_probe)]
#[test]
fn connector_probe_initial_pdu_advertises_nla_without_tls_fallback() {
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

    let pdu = build_initial_connector_pdu_for_probe(&plan, &credential).expect("initial pdu");
    let request = decode_initial_connection_request_for_probe(&pdu).expect("decoded pdu");

    assert!(request.protocol.intersects(
        ironrdp_pdu::nego::SecurityProtocol::HYBRID
            | ironrdp_pdu::nego::SecurityProtocol::HYBRID_EX
    ));
    assert!(!request
        .protocol
        .intersects(ironrdp_pdu::nego::SecurityProtocol::SSL));
}

#[cfg(serviceradar_rdp_connector_link_probe)]
#[test]
fn connector_probe_hybrid_confirm_reaches_tls_then_credssp_boundary() {
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

    for protocol in [
        ironrdp_pdu::nego::SecurityProtocol::HYBRID,
        ironrdp_pdu::nego::SecurityProtocol::HYBRID_EX,
    ] {
        let boundary = drive_connector_to_upgrade_boundary_for_probe(&plan, &credential, protocol)
            .expect("upgrade boundary");

        assert!(boundary.requires_security_upgrade);
        assert!(boundary.requires_credssp_after_upgrade);
    }
}

#[cfg(serviceradar_rdp_connector_link_probe)]
#[test]
fn connector_probe_rejects_tls_only_server_confirm() {
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

    let err = drive_connector_to_upgrade_boundary_for_probe(
        &plan,
        &credential,
        ironrdp_pdu::nego::SecurityProtocol::SSL,
    )
    .expect_err("tls-only confirm rejected");

    assert_eq!(err, BackendError::Unsupported(CONNECTOR_NOT_IMPLEMENTED));
}

#[cfg(serviceradar_rdp_connector_link_probe)]
#[test]
fn connector_probe_blocking_connect_begin_reuses_upstream_loop_without_password() {
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

    let probe =
        drive_blocking_connect_begin_for_probe(&plan, &credential).expect("blocking connect begin");

    assert!(probe.requires_security_upgrade);
    assert!(!probe.contains_cleartext_password);
    assert!(!probe.written_bytes.is_empty());
}

#[cfg(serviceradar_rdp_connector_link_probe)]
#[test]
fn connector_probe_begin_handoff_carries_upgrade_state_and_verified_tls_config() {
    let mut payload = parse_open_payload(valid_open_payload().as_bytes()).expect("payload");
    payload.target.tls.ca_bundle_id = "ca-rdp-prod".to_owned();
    payload.target.tls.ca_bundle_pem = fixture_server_cert_pem();
    let plan = build_nonsecret_connection_plan(&payload).expect("plan");
    let credential = build_memory_user_credential(
        payload
            .credential_grant
            .as_ref()
            .expect("memory user credential grant"),
        &payload.actor_id,
    )
    .expect("credential");
    let server_confirm =
        encode_server_confirm_for_probe(ironrdp_pdu::nego::SecurityProtocol::HYBRID_EX)
            .expect("server confirm");

    let handoff = begin_connector_handoff_for_probe(
        &plan,
        &credential,
        ScriptedStream::new(vec![server_confirm]),
    )
    .expect("connector begin handoff");
    let (stream, leftover) = handoff.framed.get_inner();

    assert!(handoff.requires_security_upgrade());
    assert_eq!(handoff.server_name(), "win.example");
    assert_eq!(handoff.remote_endpoint(), "win.example:3389");
    assert_eq!(
        handoff.tls_probe(),
        VerifiedTlsClientConfigProbe {
            trusted_root_count: 1,
            resumption_disabled_for_credssp: true,
        }
    );
    assert!(leftover.is_empty());
    assert!(!stream.writes.is_empty());
    assert!(!bytes_contain_secret(
        &stream.writes,
        credential.password.value.as_str().as_bytes(),
    ));
}

#[cfg(serviceradar_rdp_connector_link_probe)]
#[test]
fn connector_probe_begin_handoff_uses_supplied_client_socket_addr() {
    let mut payload = parse_open_payload(valid_open_payload().as_bytes()).expect("payload");
    payload.target.tls.ca_bundle_id = "ca-rdp-prod".to_owned();
    payload.target.tls.ca_bundle_pem = fixture_server_cert_pem();
    let plan = build_nonsecret_connection_plan(&payload).expect("plan");
    let credential = build_memory_user_credential(
        payload
            .credential_grant
            .as_ref()
            .expect("memory user credential grant"),
        &payload.actor_id,
    )
    .expect("credential");
    let server_confirm =
        encode_server_confirm_for_probe(ironrdp_pdu::nego::SecurityProtocol::HYBRID_EX)
            .expect("server confirm");
    let client_addr: SocketAddr = "10.7.8.9:49152".parse().expect("client addr");

    let handoff = begin_connector_handoff_with_client_addr_for_probe(
        &plan,
        &credential,
        ScriptedStream::new(vec![server_confirm]),
        client_addr,
    )
    .expect("connector begin handoff");

    assert_eq!(handoff.client_addr(), client_addr);
    assert!(handoff.requires_security_upgrade());
}

#[cfg(serviceradar_rdp_connector_link_probe)]
#[test]
fn connector_probe_begin_handoff_accepts_prepared_dialed_stream() {
    let mut payload = parse_open_payload(valid_open_payload().as_bytes()).expect("payload");
    payload.target.tls.ca_bundle_id = "ca-rdp-prod".to_owned();
    payload.target.tls.ca_bundle_pem = fixture_server_cert_pem();
    let plan = build_nonsecret_connection_plan(&payload).expect("plan");
    let credential = build_memory_user_credential(
        payload
            .credential_grant
            .as_ref()
            .expect("memory user credential grant"),
        &payload.actor_id,
    )
    .expect("credential");
    let server_confirm =
        encode_server_confirm_for_probe(ironrdp_pdu::nego::SecurityProtocol::HYBRID_EX)
            .expect("server confirm");
    let client_addr: SocketAddr = "10.7.8.9:49152".parse().expect("client addr");
    let dialed = prepare_dialed_connector_stream_for_probe(
        &plan,
        ScriptedStream::new(vec![server_confirm]),
        client_addr,
    )
    .expect("dialed stream");

    assert_eq!(dialed.endpoint(), "win.example:3389");
    assert_eq!(dialed.client_addr(), client_addr);

    let handoff = begin_connector_handoff_with_dialed_stream_for_probe(&plan, &credential, dialed)
        .expect("connector begin handoff");
    let (stream, leftover) = handoff.framed.get_inner();

    assert!(handoff.requires_security_upgrade());
    assert_eq!(handoff.client_addr(), client_addr);
    assert_eq!(handoff.remote_endpoint(), "win.example:3389");
    assert!(leftover.is_empty());
    assert!(!stream.writes.is_empty());
    assert!(!bytes_contain_secret(
        &stream.writes,
        credential.password.value.as_str().as_bytes(),
    ));
}

#[cfg(serviceradar_rdp_connector_link_probe)]
#[test]
fn connector_probe_begin_handoff_rejects_tls_only_server_confirm() {
    let mut payload = parse_open_payload(valid_open_payload().as_bytes()).expect("payload");
    payload.target.tls.ca_bundle_id = "ca-rdp-prod".to_owned();
    payload.target.tls.ca_bundle_pem = fixture_server_cert_pem();
    let plan = build_nonsecret_connection_plan(&payload).expect("plan");
    let credential = build_memory_user_credential(
        payload
            .credential_grant
            .as_ref()
            .expect("memory user credential grant"),
        &payload.actor_id,
    )
    .expect("credential");
    let server_confirm = encode_server_confirm_for_probe(ironrdp_pdu::nego::SecurityProtocol::SSL)
        .expect("server confirm");

    let result = begin_connector_handoff_for_probe(
        &plan,
        &credential,
        ScriptedStream::new(vec![server_confirm]),
    );

    assert!(matches!(
        result,
        Err(BackendError::Unsupported(CONNECTOR_NOT_IMPLEMENTED))
    ));
}
