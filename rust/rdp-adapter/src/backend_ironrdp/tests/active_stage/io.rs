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
