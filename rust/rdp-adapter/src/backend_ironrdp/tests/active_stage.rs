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
            connection_result: connection_result.clone(),
            desktop_size,
        },
        io::sink(),
        &payload,
    )
    .expect_err("missing media binding rejected");

    assert_eq!(
        missing_binding_err,
        BackendError::Unsupported(INVALID_CONNECTION_PLAN)
    );

    payload
        .target
        .metadata
        .insert(METADATA_MEDIA_SESSION_ID.to_owned(), "media-1".to_owned());
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
        .expect_err("der material rejected");

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
        .expect_err("empty rejected");
    let invalid = build_verified_tls_client_config_for_registered_ca_bundle(b"not a certificate")
        .expect_err("invalid rejected");

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

    let err =
        build_verified_tls_client_config_for_plan(&plan).expect_err("invalid plan bundle rejected");

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

#[cfg(serviceradar_rdp_connector_link_probe)]
#[test]
fn connector_probe_active_stage_encodes_keyboard_input_response_frame() {
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

    let probe = encode_active_stage_keyboard_input_for_probe(&plan, &credential)
        .expect("active stage input");

    assert_eq!(probe.response_frames, 1);
    assert!(probe.response_bytes > 0);
    assert_eq!(probe.graphics_updates, 0);
}

#[cfg(serviceradar_rdp_connector_link_probe)]
#[test]
fn connector_probe_active_stage_session_routes_browser_input_to_upstream() {
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
    let mut session = ActiveStageSessionProbe::new(
        &plan,
        &credential,
        Vec::<u8>::new(),
        &payload.target.screen,
        "session-1".to_owned(),
        "media-1".to_owned(),
    );

    let probe = session
        .input(&desktop_key_frame("Enter", true))
        .expect("input routed");

    assert_eq!(probe.rdp_response_frames, 1);
    assert!(probe.rdp_response_bytes > 0);
    assert_eq!(probe.queued_media_frames, 0);
    assert_eq!(session.upstream_ref().len(), probe.rdp_response_bytes);
    assert!(session.drain_media_frames().is_empty());
}

#[cfg(serviceradar_rdp_connector_link_probe)]
#[test]
fn connector_probe_active_stage_session_accepts_connection_result_handoff() {
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
    let mut session = ActiveStageSessionProbe::from_connection_result(
        connection_result,
        desktop_size,
        Vec::<u8>::new(),
        &payload.target.screen,
        "session-1".to_owned(),
        "media-1".to_owned(),
    );

    let probe = session
        .input(&desktop_key_frame("Enter", true))
        .expect("input routed after connection-result handoff");

    assert_eq!(probe.rdp_response_frames, 1);
    assert!(probe.rdp_response_bytes > 0);
    assert_eq!(probe.queued_media_frames, 0);
    assert_eq!(session.upstream_ref().len(), probe.rdp_response_bytes);
    assert!(session.drain_media_frames().is_empty());
}

#[cfg(serviceradar_rdp_connector_link_probe)]
#[test]
fn connector_probe_active_stage_session_rejects_unsupported_browser_input() {
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
    let mut session = ActiveStageSessionProbe::new(
        &plan,
        &credential,
        Vec::<u8>::new(),
        &payload.target.screen,
        "session-1".to_owned(),
        "media-1".to_owned(),
    );

    let err = session
        .input(&desktop_key_frame("F13", true))
        .expect_err("unsupported input rejected");

    assert_eq!(err, BackendError::Unsupported(UNSUPPORTED_INPUT_EVENT));
    assert!(session.upstream_ref().is_empty());
    assert!(session.drain_media_frames().is_empty());
}

#[cfg(serviceradar_rdp_connector_link_probe)]
#[test]
fn connector_probe_active_stage_session_implements_backend_session_contract() {
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
    let mut session = ActiveStageSessionProbe::new(
        &plan,
        &credential,
        Vec::<u8>::new(),
        &payload.target.screen,
        "session-1".to_owned(),
        "media-1".to_owned(),
    );

    {
        let session_trait: &mut dyn RdpBackendSession = &mut session;
        session_trait
            .input(&desktop_key_frame("Enter", true))
            .expect("input routed through trait");
        session_trait
            .ack(&crate::protocol::DesktopMediaAck {
                session_binding_id: "session-1".to_owned(),
                media_session_id: "media-1".to_owned(),
                last_accepted_seq: 0,
                credit_bytes: 4096,
                quality_level: String::new(),
                pause: false,
                resume: false,
                close_reason: String::new(),
            })
            .expect("ack accepted through trait");
        assert!(session_trait
            .drain_media_frames()
            .expect("drain through trait")
            .is_empty());
        session_trait
            .close(&DesktopClosePayload {
                reason: "done".to_owned(),
            })
            .expect("graceful close through trait");
    }

    assert!(!session.upstream_ref().is_empty());
}

