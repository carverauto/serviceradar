#[cfg(serviceradar_rdp_connector_link_probe)]
#[test]
fn connector_probe_active_stage_session_rejects_malformed_server_frames() {
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
        .server_frame(ironrdp_pdu::Action::X224, b"not-a-valid-pdu", 1234)
        .expect_err("malformed server frame rejected");

    assert_eq!(err, BackendError::Unsupported(CONNECTOR_NOT_IMPLEMENTED));
    assert!(session.upstream_ref().is_empty());
    assert!(session.drain_media_frames().is_empty());
}

#[cfg(serviceradar_rdp_connector_link_probe)]
#[test]
fn connector_probe_server_read_loop_rejects_malformed_pdu_before_active_stage() {
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
    let mut framed =
        ironrdp_blocking::Framed::new(ScriptedStream::new(vec![b"not-a-pdu".to_vec()]));

    let err = read_active_stage_server_frame_for_probe(&mut framed, &mut session, 1234)
        .expect_err("malformed pdu rejected");

    assert_eq!(err, BackendError::Unsupported(CONNECTOR_NOT_IMPLEMENTED));
    assert!(session.upstream_ref().is_empty());
    assert!(session.drain_media_frames().is_empty());
}

#[cfg(serviceradar_rdp_connector_link_probe)]
#[test]
fn connector_probe_backend_session_pump_reads_server_frames() {
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
    let inner = ActiveStageSessionProbe::new(
        &plan,
        &credential,
        Vec::<u8>::new(),
        &payload.target.screen,
        "session-1".to_owned(),
        "media-1".to_owned(),
    );
    let framed = ironrdp_blocking::Framed::new(ScriptedStream::new(vec![b"not-a-pdu".to_vec()]));
    let mut session = ActiveStageNetworkPumpSessionProbe::new(framed, inner, 1234);

    let err = {
        let session_trait: &mut dyn RdpBackendSession = &mut session;
        session_trait
            .pump()
            .expect_err("malformed pumped server frame rejected")
    };

    assert_eq!(err, BackendError::Unsupported(CONNECTOR_NOT_IMPLEMENTED));
    assert!(session.upstream_ref().is_empty());
    assert!(session.drain_media_frames().is_empty());
}

#[cfg(serviceradar_rdp_connector_link_probe)]
#[test]
fn connector_probe_network_pump_session_accepts_connection_result_handoff() {
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
    let framed = ironrdp_blocking::Framed::new(ScriptedStream::new(Vec::new()));
    let mut session = ActiveStageNetworkPumpSessionProbe::from_connection_result(
        framed,
        connection_result,
        desktop_size,
        Vec::<u8>::new(),
        &payload.target.screen,
        "session-1".to_owned(),
        "media-1".to_owned(),
        1234,
    );

    {
        let session_trait: &mut dyn RdpBackendSession = &mut session;
        session_trait
            .input(&desktop_key_frame("Enter", true))
            .expect("input routed after network-pump handoff");
    }

    assert!(session.upstream_ref().is_empty());
    assert!(session.network_writes_len() > 0);
    assert!(session.drain_media_frames().is_empty());
}

#[cfg(serviceradar_rdp_connector_link_probe)]
#[test]
fn connector_probe_encodes_graphics_update_as_srdp_dirty_rect_frame() {
    let payload = parse_open_payload(valid_open_payload().as_bytes()).expect("valid payload");
    let image = ironrdp_session::image::DecodedImage::new(
        ironrdp_graphics::image_processing::PixelFormat::RgbA32,
        800,
        600,
    );
    let rect = ironrdp_pdu::geometry::InclusiveRectangle {
        left: 4,
        top: 6,
        right: 7,
        bottom: 8,
    };

    let encoded = encode_graphics_update_for_probe(
        "session-1",
        "media-1",
        99,
        1234,
        &image,
        &rect,
        &payload.target.screen,
    )
    .expect("graphics update encoded");

    assert_eq!(&encoded[0..4], b"SRDP");
    assert_eq!(encoded[4], 1);
    assert_eq!(encoded[6], 2);
    assert_eq!(u64::from_be_bytes(encoded[8..16].try_into().unwrap()), 99);
    assert_eq!(
        i64::from_be_bytes(encoded[16..24].try_into().unwrap()),
        1234
    );
    assert_eq!(u32::from_be_bytes(encoded[24..28].try_into().unwrap()), 800);
    assert_eq!(u32::from_be_bytes(encoded[28..32].try_into().unwrap()), 600);

    let metadata_len = u32::from_be_bytes(encoded[32..36].try_into().unwrap()) as usize;
    let payload_len = u32::from_be_bytes(encoded[36..40].try_into().unwrap()) as usize;
    let encoding_len = u16::from_be_bytes(encoded[40..42].try_into().unwrap()) as usize;
    let session_len = u16::from_be_bytes(encoded[42..44].try_into().unwrap()) as usize;
    let media_len = u16::from_be_bytes(encoded[44..46].try_into().unwrap()) as usize;
    let metadata_offset = 48 + session_len + media_len + encoding_len;
    let metadata = std::str::from_utf8(&encoded[metadata_offset..metadata_offset + metadata_len])
        .expect("metadata utf8");

    assert_eq!(&encoded[48..48 + session_len], b"session-1");
    assert_eq!(
        &encoded[48 + session_len..48 + session_len + media_len],
        b"media-1"
    );
    assert_eq!(
        &encoded[48 + session_len + media_len..metadata_offset],
        b"rgba"
    );
    assert!(metadata.contains(r#""dirtyRects":[{"x":4,"y":6,"width":4,"height":3"#));
    assert!(metadata.contains(r#""payloadOffset":0"#));
    assert!(metadata.contains(r#""payloadLength":6416"#));
    assert!(metadata.contains(r#""bytesPerRow":3200"#));
    assert!(metadata.contains(r#""pixelFormat":"rgba""#));
    assert_eq!(payload_len, 6416);
    assert_eq!(encoded.len(), metadata_offset + metadata_len + payload_len);
}

#[cfg(serviceradar_rdp_connector_link_probe)]
#[test]
fn connector_probe_rejects_invalid_graphics_update_rectangles() {
    let payload = parse_open_payload(valid_open_payload().as_bytes()).expect("valid payload");
    let image = ironrdp_session::image::DecodedImage::new(
        ironrdp_graphics::image_processing::PixelFormat::RgbA32,
        800,
        600,
    );
    let rect = ironrdp_pdu::geometry::InclusiveRectangle {
        left: 4,
        top: 6,
        right: 801,
        bottom: 8,
    };

    let err = encode_graphics_update_for_probe(
        "session-1",
        "media-1",
        99,
        1234,
        &image,
        &rect,
        &payload.target.screen,
    )
    .expect_err("invalid graphics rect rejected");

    assert_eq!(err, BackendError::Unsupported(INVALID_GRAPHICS_UPDATE));
}

#[cfg(serviceradar_rdp_connector_link_probe)]
#[test]
fn connector_probe_routes_active_stage_outputs_to_upstream_and_media_queue() {
    let payload = parse_open_payload(valid_open_payload().as_bytes()).expect("valid payload");
    let image = ironrdp_session::image::DecodedImage::new(
        ironrdp_graphics::image_processing::PixelFormat::RgbA32,
        800,
        600,
    );
    let rect = ironrdp_pdu::geometry::InclusiveRectangle {
        left: 4,
        top: 6,
        right: 7,
        bottom: 8,
    };
    let mut upstream = Vec::new();
    let mut media_queue = VecDeque::new();
    let mut next_sequence = 7;

    let probe = handle_active_stage_outputs_for_probe(
        vec![
            ironrdp_session::ActiveStageOutput::ResponseFrame(vec![0xaa, 0xbb]),
            ironrdp_session::ActiveStageOutput::GraphicsUpdate(rect),
            ironrdp_session::ActiveStageOutput::PointerHidden,
        ],
        &mut upstream,
        &mut media_queue,
        &image,
        &payload.target.screen,
        "session-1",
        "media-1",
        &mut next_sequence,
        1234,
    )
    .expect("active stage outputs routed");

    assert_eq!(upstream, vec![0xaa, 0xbb]);
    assert_eq!(next_sequence, 8);
    assert_eq!(media_queue.len(), 1);
    assert_eq!(
        probe,
        ActiveStageOutputProbe {
            rdp_response_frames: 1,
            rdp_response_bytes: 2,
            queued_media_frames: 1,
            queued_media_bytes: media_queue.front().expect("media frame").len(),
            terminal_outputs: 0,
        }
    );

    let media = media_queue.pop_front().expect("queued media");
    assert_eq!(&media[0..4], b"SRDP");
    assert_eq!(u64::from_be_bytes(media[8..16].try_into().unwrap()), 7);
    assert_eq!(u32::from_be_bytes(media[24..28].try_into().unwrap()), 800);
    assert_eq!(u32::from_be_bytes(media[28..32].try_into().unwrap()), 600);
}

#[cfg(serviceradar_rdp_connector_link_probe)]
#[test]
fn connector_probe_fails_closed_on_server_deactivation() {
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
    let image = ironrdp_session::image::DecodedImage::new(
        ironrdp_graphics::image_processing::PixelFormat::RgbA32,
        800,
        600,
    );
    let mut media_queue = VecDeque::new();
    let mut next_sequence = 7;

    let probe = handle_active_stage_outputs_with_writer_for_probe(
        vec![ironrdp_session::ActiveStageOutput::DeactivateAll],
        |_frame| Ok(()),
        &mut media_queue,
        &image,
        &payload.target.screen,
        "session-1",
        "media-1",
        &mut next_sequence,
        1234,
    )
    .expect("server deactivation classified");

    let err = session
        .observe_outputs(probe)
        .expect_err("server deactivation must fail closed");

    assert_eq!(err, BackendError::Unsupported(ACTIVE_SESSION_TERMINATED));
    assert_eq!(
        session
            .input(&desktop_key_frame("Enter", true))
            .expect_err("input after deactivation must remain rejected"),
        BackendError::Unsupported(ACTIVE_SESSION_TERMINATED)
    );
    assert!(media_queue.is_empty());
    assert_eq!(next_sequence, 7);
}

#[cfg(serviceradar_rdp_connector_link_probe)]
#[test]
fn connector_probe_rejects_active_stage_response_write_failures() {
    let payload = parse_open_payload(valid_open_payload().as_bytes()).expect("valid payload");
    let image = ironrdp_session::image::DecodedImage::new(
        ironrdp_graphics::image_processing::PixelFormat::RgbA32,
        800,
        600,
    );
    let mut upstream = FailingWriter;
    let mut media_queue = VecDeque::new();
    let mut next_sequence = 7;

    let err = handle_active_stage_outputs_for_probe(
        vec![ironrdp_session::ActiveStageOutput::ResponseFrame(vec![
            0xaa, 0xbb,
        ])],
        &mut upstream,
        &mut media_queue,
        &image,
        &payload.target.screen,
        "session-1",
        "media-1",
        &mut next_sequence,
        1234,
    )
    .expect_err("write failure rejected");

    assert_eq!(err, BackendError::Unsupported(CONNECTOR_NOT_IMPLEMENTED));
    assert!(media_queue.is_empty());
    assert_eq!(next_sequence, 7);
}

#[cfg(serviceradar_rdp_connector_link_probe)]
#[test]
fn connector_probe_maps_browser_key_input_to_rdp_scancode_events() {
    let events = map_desktop_input_events_for_probe(&desktop_key_frame("Enter", true))
        .expect("key down event");

    assert_eq!(
        events,
        vec![
            ironrdp_pdu::input::fast_path::FastPathInputEvent::KeyboardEvent(
                ironrdp_pdu::input::fast_path::KeyboardFlags::empty(),
                0x1c,
            ),
        ]
    );

    let events = map_desktop_input_events_for_probe(&desktop_key_frame("Enter", false))
        .expect("key up event");

    assert_eq!(
        events,
        vec![
            ironrdp_pdu::input::fast_path::FastPathInputEvent::KeyboardEvent(
                ironrdp_pdu::input::fast_path::KeyboardFlags::RELEASE,
                0x1c,
            ),
        ]
    );
}

#[cfg(serviceradar_rdp_connector_link_probe)]
#[test]
fn connector_probe_maps_browser_pointer_input_to_rdp_mouse_events() {
    let events = map_desktop_input_events_for_probe(&desktop_pointer_frame("left", true, 100, 200))
        .expect("pointer event");

    assert_eq!(
        events,
        vec![
            ironrdp_pdu::input::fast_path::FastPathInputEvent::MouseEvent(
                ironrdp_pdu::input::MousePdu {
                    flags: ironrdp_pdu::input::mouse::PointerFlags::MOVE
                        | ironrdp_pdu::input::mouse::PointerFlags::LEFT_BUTTON
                        | ironrdp_pdu::input::mouse::PointerFlags::DOWN,
                    number_of_wheel_rotation_units: 0,
                    x_position: 100,
                    y_position: 200,
                },
            ),
        ]
    );
}

#[cfg(serviceradar_rdp_connector_link_probe)]
#[test]
fn connector_probe_rejects_unsupported_browser_input_tokens() {
    let err = map_desktop_input_events_for_probe(&desktop_key_frame("F13", true))
        .expect_err("unsupported key rejected");

    assert_eq!(err, BackendError::Unsupported(UNSUPPORTED_INPUT_EVENT));

    let err = map_desktop_input_events_for_probe(&desktop_pointer_frame("side", true, 100, 200))
        .expect_err("unsupported pointer button rejected");

    assert_eq!(err, BackendError::Unsupported(UNSUPPORTED_INPUT_EVENT));
}

#[cfg(serviceradar_rdp_connector_link_probe)]
#[test]
fn connector_probe_focus_input_does_not_emit_rdp_events() {
    let events = map_desktop_input_events_for_probe(&DesktopFrame {
        session_id: "session-1".to_owned(),
        protocol: "rdp".to_owned(),
        frame_type: "desktop.input".to_owned(),
        width: 0,
        height: 0,
        input: Some(crate::protocol::DesktopInputEvent {
            kind: "focus".to_owned(),
            key: String::new(),
            down: false,
            button: String::new(),
            x: 0,
            y: 0,
            focused: true,
        }),
        quality: None,
        reason: String::new(),
        timestamp: 0,
        metadata: Default::default(),
    })
    .expect("focus event");

    assert!(events.is_empty());
}
