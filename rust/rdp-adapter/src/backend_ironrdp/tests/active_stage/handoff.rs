#[cfg(serviceradar_rdp_connector_link_probe)]
#[test]
fn connector_probe_marked_tls_handoff_enters_credssp_state_without_password() {
    let mut payload = parse_open_payload(valid_open_payload().as_bytes()).expect("payload");
    payload.target.tls.ca_bundle_id = "ca-rdp-prod".to_owned();
    payload.target.tls.ca_bundle_pem = fixture_server_cert_pem();
    payload.target.metadata.insert(
        METADATA_KDC_PROXY_URL.to_owned(),
        "tcp://kdc.example:88".to_owned(),
    );
    payload.target.metadata.insert(
        METADATA_KERBEROS_HOSTNAME.to_owned(),
        "win.example".to_owned(),
    );
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
    let begin_handoff = begin_connector_handoff_for_probe(
        &plan,
        &credential,
        ScriptedStream::new(vec![server_confirm]),
    )
    .expect("connector begin handoff");
    assert!(begin_handoff.kerberos_config.is_some());
    let server_public_key = derive_credssp_server_public_key_from_verified_tls_peer_for_probe(
        &fixture_server_cert_der(),
    )
    .expect("server public key");

    let credssp_handoff =
        mark_connector_handoff_tls_upgraded_for_probe(begin_handoff, server_public_key)
            .expect("credssp handoff");
    let (stream, leftover) = credssp_handoff.framed.get_inner();

    assert!(credssp_handoff.requires_credssp());
    assert_eq!(credssp_handoff.server_name(), "win.example");
    assert!(credssp_handoff.kerberos_config.is_some());
    assert!(leftover.is_empty());
    assert!(!stream.writes.is_empty());
    assert!(!bytes_contain_secret(
        &stream.writes,
        credential.password.value.as_str().as_bytes(),
    ));
}

#[cfg(serviceradar_rdp_connector_link_probe)]
#[test]
fn connector_probe_finalize_failure_preserves_framed_stream_without_password() {
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
    let begin_handoff = begin_connector_handoff_for_probe(
        &plan,
        &credential,
        ScriptedStream::new(vec![server_confirm]),
    )
    .expect("connector begin handoff");
    let server_public_key = derive_credssp_server_public_key_from_verified_tls_peer_for_probe(
        &fixture_server_cert_der(),
    )
    .expect("server public key");
    let credssp_handoff =
        mark_connector_handoff_tls_upgraded_for_probe(begin_handoff, server_public_key)
            .expect("credssp handoff");
    let mut network_client = RejectingNetworkClient;

    let failure = match finalize_connector_handoff_for_probe(credssp_handoff, &mut network_client) {
        Ok(_) => panic!("rejecting network client should not finalize"),
        Err(failure) => failure,
    };
    let (stream, leftover) = failure.framed.get_inner();

    assert_eq!(
        failure.error,
        BackendError::Unsupported(CONNECTOR_NOT_IMPLEMENTED)
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
fn connector_probe_finalized_handoff_builds_network_pump_session() {
    let mut payload = parse_open_payload(valid_open_payload().as_bytes()).expect("valid payload");
    payload
        .target
        .metadata
        .insert(METADATA_MEDIA_SESSION_ID.to_owned(), "media-1".to_owned());
    let plan = build_nonsecret_connection_plan(&payload).expect("plan");
    let credential = build_memory_user_credential(
        payload
            .credential_grant
            .as_ref()
            .expect("memory user credential grant"),
        &payload.actor_id,
    )
    .expect("credential");
    let (connection_result, desktop_size) = build_connection_result_for_probe(&plan, &credential);
    let handoff = ConnectorFinalizedHandoff {
        framed: ironrdp_blocking::Framed::new(ScriptedStream::new(Vec::new())),
        connection_result,
        desktop_size,
    };
    let mut session = finalized_connector_handoff_into_network_pump_session_for_probe(
        handoff,
        Vec::<u8>::new(),
        &payload,
    )
    .expect("finalized connector handoff session");

    {
        let session_trait: &mut dyn RdpBackendSession = &mut session;
        session_trait
            .input(&desktop_key_frame("Enter", true))
            .expect("input routed after finalized connector handoff");
    }

    assert!(session.upstream_ref().is_empty());
    assert!(session.network_writes_len() > 0);
    assert!(session.drain_media_frames().is_empty());
}

#[cfg(serviceradar_rdp_connector_link_probe)]
#[test]
fn connector_probe_finalized_handoff_requires_media_binding() {
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
    let (connection_result, desktop_size) = build_connection_result_for_probe(&plan, &credential);
    let handoff = ConnectorFinalizedHandoff {
        framed: ironrdp_blocking::Framed::new(ScriptedStream::new(Vec::new())),
        connection_result,
        desktop_size,
    };

    let err = match finalized_connector_handoff_into_network_pump_session_for_probe(
        handoff,
        Vec::<u8>::new(),
        &payload,
    ) {
        Ok(_) => panic!("missing media binding should be rejected"),
        Err(err) => err,
    };

    assert_eq!(err, BackendError::Unsupported(INVALID_CONNECTION_PLAN));
}

#[cfg(serviceradar_rdp_connector_link_probe)]
#[test]
fn connector_probe_finalized_handoff_opens_network_pump_session() {
    let mut payload = parse_open_payload(valid_open_payload().as_bytes()).expect("valid payload");
    let plan = build_nonsecret_connection_plan(&payload).expect("plan");
    let credential = build_memory_user_credential(
        payload
            .credential_grant
            .as_ref()
            .expect("memory user credential grant"),
        &payload.actor_id,
    )
    .expect("credential");
    let (connection_result, desktop_size) = build_connection_result_for_probe(&plan, &credential);

    let missing_binding_err = finalized_connector_handoff_into_network_pump_session_for_probe(
        ConnectorFinalizedHandoff {
            framed: ironrdp_blocking::Framed::new(ScriptedStream::new(Vec::new())),
            connection_result,
            desktop_size,
        },
        io::sink(),
        &payload,
    )
    .err()
    .expect("missing media binding rejected");

    assert_eq!(
        missing_binding_err,
        BackendError::Unsupported(INVALID_CONNECTION_PLAN)
    );

    payload
        .target
        .metadata
        .insert(METADATA_MEDIA_SESSION_ID.to_owned(), "media-1".to_owned());
    let (connection_result, desktop_size) = build_connection_result_for_probe(&plan, &credential);
    let mut session = finalized_connector_handoff_into_network_pump_session_for_probe(
        ConnectorFinalizedHandoff {
            framed: ironrdp_blocking::Framed::new(ScriptedStream::new(Vec::new())),
            connection_result,
            desktop_size,
        },
        io::sink(),
        &payload,
    )
    .expect("finalized network-pump session");

    {
        let session_trait: &mut dyn RdpBackendSession = &mut session;
        session_trait
            .input(&desktop_key_frame("Enter", true))
            .expect("finalized session routes input");
    }

    assert!(session.network_writes_len() > 0);
}
