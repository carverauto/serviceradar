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

#[cfg(serviceradar_rdp_connector_link_probe)]
fn desktop_key_frame(key: &str, down: bool) -> DesktopFrame {
    DesktopFrame {
        session_id: "session-1".to_owned(),
        protocol: "rdp".to_owned(),
        frame_type: "desktop.input".to_owned(),
        width: 0,
        height: 0,
        input: Some(crate::protocol::DesktopInputEvent {
            kind: "key".to_owned(),
            key: key.to_owned(),
            down,
            button: String::new(),
            x: 0,
            y: 0,
            focused: false,
        }),
        quality: None,
        reason: String::new(),
        timestamp: 0,
        metadata: Default::default(),
    }
}

#[cfg(serviceradar_rdp_connector_link_probe)]
fn desktop_pointer_frame(button: &str, down: bool, x: u32, y: u32) -> DesktopFrame {
    DesktopFrame {
        session_id: "session-1".to_owned(),
        protocol: "rdp".to_owned(),
        frame_type: "desktop.input".to_owned(),
        width: 0,
        height: 0,
        input: Some(crate::protocol::DesktopInputEvent {
            kind: "pointer".to_owned(),
            key: String::new(),
            down,
            button: button.to_owned(),
            x,
            y,
            focused: false,
        }),
        quality: None,
        reason: String::new(),
        timestamp: 0,
        metadata: Default::default(),
    }
}

#[cfg(serviceradar_rdp_connector_link_probe)]
struct FailingWriter;

#[cfg(serviceradar_rdp_connector_link_probe)]
impl Write for FailingWriter {
    fn write(&mut self, _buf: &[u8]) -> io::Result<usize> {
        Err(io::Error::new(io::ErrorKind::BrokenPipe, "closed"))
    }

    fn flush(&mut self) -> io::Result<()> {
        Ok(())
    }
}

#[cfg(serviceradar_rdp_connector_link_probe)]
fn fixture_server_cert_der() -> Vec<u8> {
    use base64::{engine::general_purpose::STANDARD, Engine as _};

    STANDARD
            .decode(
                "MIIDDTCCAfWgAwIBAgIUFaHwQBAFyvmfso6OPbcQ+2/fVSUwDQYJKoZIhvcNAQELBQAwFjEUMBIGA1UEAwwLd2luLmV4YW1wbGUwHhcNMjYwNTE2MTYzNzQ3WhcNMjYwNTE3MTYzNzQ3WjAWMRQwEgYDVQQDDAt3aW4uZXhhbXBsZTCCASIwDQYJKoZIhvcNAQEBBQADggEPADCCAQoCggEBALbcS3SPVJlbV5AwbziMjXX0Z5CXcOIMt67zeIzoh6hmiAou1IIVZ14FrWStQj4kJNcAwdYQWtZcjM0ya6Hx3fd/M4H3FIatWkrlZcwDtxPeMHxoLzJ0mP/yLdacyvjfKqQDn8f0JEd4KY5dN1eD/OFBGF+XuQyIBsAom6SFuo7uZA4+HmC01P5ac0zAyJKOVDpgdBWa9FYn+YszqAwjrRau1m4A8K5BgRPDBs1FQwjGhRGePEuRgOKsHdBGq/PJ1Iw4mES4pwStTgGvFHJnIPxxZHX0WHiDZnbNx+K+HJh0eaWEjYUazuQtvsyllNM6KmZIHb/bgcZ0VTRQZ87l9lUCAwEAAaNTMFEwHQYDVR0OBBYEFOEi76jfCExGDeYivuwXNMm6uGnAMB8GA1UdIwQYMBaAFOEi76jfCExGDeYivuwXNMm6uGnAMA8GA1UdEwEB/wQFMAMBAf8wDQYJKoZIhvcNAQELBQADggEBAI6IdjMvys+AEAoeZ31Lo0IbMsM4EChsvXwpE9BZ5zuPEtRwxoxLwVKrhfjkQjuX6CWFcMlWPvUqKU4t8G3b6/5ym67vJqYkLXgF5UG5Aj7AuiLIY6j8zBcZ4dFsx7hheXZC4em5e6D16eDgATWEBKf/kfbmnX8EET5gkqolAjYI4D1M3gT5yJrulhNmfXThW5A2Vvn70AhsrhMylogKRejaMOelRi1XA0AAXkZ53JWNTCJLJtRg/6PAeyT6nJwpTZi1iKJs0gRTv2TAnUFKeVfDV1CE63YM8953dq+xwqmrTmyZabWJb6yAXEepIUPMscB2UcHKFAqgWZ+4herSzfY=",
            )
            .expect("fixture certificate")
}

#[cfg(serviceradar_rdp_connector_link_probe)]
fn fixture_server_cert_pem() -> String {
    use base64::{engine::general_purpose::STANDARD, Engine as _};

    let body = STANDARD.encode(fixture_server_cert_der());
    let mut pem = String::from("-----BEGIN CERTIFICATE-----\n");
    for chunk in body.as_bytes().chunks(64) {
        pem.push_str(std::str::from_utf8(chunk).expect("base64 is utf8"));
        pem.push('\n');
    }
    pem.push_str("-----END CERTIFICATE-----\n");

    pem
}

#[cfg(serviceradar_rdp_connector_link_probe)]
struct HybridExTlsProbeCapture {
    initial_request: Vec<u8>,
    tls_plaintext: Vec<u8>,
}

#[cfg(serviceradar_rdp_connector_link_probe)]
fn spawn_hybrid_ex_tls_probe_server(
    listener: std::net::TcpListener,
) -> std::thread::JoinHandle<Vec<u8>> {
    use std::io::{Read as _, Write as _};

    let server_confirm =
        encode_server_confirm_for_probe(ironrdp_pdu::nego::SecurityProtocol::HYBRID_EX)
            .expect("server confirm");

    std::thread::spawn(move || {
        let (mut stream, _) = listener.accept().expect("accepted connection");
        stream
            .set_read_timeout(Some(Duration::from_secs(1)))
            .expect("read timeout");
        stream
            .set_write_timeout(Some(Duration::from_secs(1)))
            .expect("write timeout");
        let mut initial_request = [0_u8; 4096];
        let read = stream
            .read(&mut initial_request)
            .expect("initial connector request");
        stream
            .write_all(&server_confirm)
            .expect("server confirm write");
        let server_config = fixture_tls_server_config_for_probe();
        let mut server_connection =
            rustls::ServerConnection::new(Arc::new(server_config)).expect("server connection");
        while server_connection.is_handshaking() {
            if server_connection.complete_io(&mut stream).is_err() {
                break;
            }
        }

        initial_request[..read].to_vec()
    })
}

#[cfg(serviceradar_rdp_connector_link_probe)]
fn spawn_hybrid_ex_tls_capture_server(
    listener: std::net::TcpListener,
) -> std::thread::JoinHandle<HybridExTlsProbeCapture> {
    use std::io::{Read as _, Write as _};

    let server_confirm =
        encode_server_confirm_for_probe(ironrdp_pdu::nego::SecurityProtocol::HYBRID_EX)
            .expect("server confirm");

    std::thread::spawn(move || {
        let (mut stream, _) = listener.accept().expect("accepted connection");
        stream
            .set_read_timeout(Some(Duration::from_secs(1)))
            .expect("read timeout");
        stream
            .set_write_timeout(Some(Duration::from_secs(1)))
            .expect("write timeout");
        let mut initial_request = [0_u8; 4096];
        let read = stream
            .read(&mut initial_request)
            .expect("initial connector request");
        stream
            .write_all(&server_confirm)
            .expect("server confirm write");
        let server_config = fixture_tls_server_config_for_probe();
        let mut server_connection =
            rustls::ServerConnection::new(Arc::new(server_config)).expect("server connection");
        while server_connection.is_handshaking() {
            server_connection
                .complete_io(&mut stream)
                .expect("server TLS handshake");
        }

        let mut tls_plaintext = Vec::new();
        let _ = server_connection.complete_io(&mut stream);
        let mut plaintext = [0_u8; 4096];
        loop {
            match server_connection.reader().read(&mut plaintext) {
                Ok(0) => break,
                Ok(count) => tls_plaintext.extend_from_slice(&plaintext[..count]),
                Err(err) if err.kind() == io::ErrorKind::WouldBlock => break,
                Err(_) => break,
            }
        }

        HybridExTlsProbeCapture {
            initial_request: initial_request[..read].to_vec(),
            tls_plaintext,
        }
    })
}

#[cfg(serviceradar_rdp_connector_link_probe)]
fn fixture_tls_server_config_for_probe() -> rustls::ServerConfig {
    let cert = rustls::pki_types::CertificateDer::from(fixture_tls_server_cert_der());
    let key = rustls::pki_types::PrivateKeyDer::Pkcs8(rustls::pki_types::PrivatePkcs8KeyDer::from(
        fixture_tls_server_key_der(),
    ));

    rustls::ServerConfig::builder()
        .with_no_client_auth()
        .with_single_cert(vec![cert], key)
        .expect("fixture TLS server config")
}

#[cfg(serviceradar_rdp_connector_link_probe)]
fn fixture_tls_server_cert_der() -> Vec<u8> {
    use base64::{engine::general_purpose::STANDARD, Engine as _};

    STANDARD
            .decode(
                "MIIDJTCCAg2gAwIBAgIUaVf+hJE9biQOeCj7Hlnyp0pWaqAwDQYJKoZIhvcNAQELBQAwFjEUMBIGA1UEAwwLd2luLmV4YW1wbGUwHhcNMjYwNTE3MDUxMDQxWhcNMjYwNTE4MDUxMDQxWjAWMRQwEgYDVQQDDAt3aW4uZXhhbXBsZTCCASIwDQYJKoZIhvcNAQEBBQADggEPADCCAQoCggEBAKGuZfZ1QqXmZtoBDjgHfUW7AqXIsIP9AaWsECA7SFNDwVLAzrlw3s1GauZFzpRkByxC73+Tf9P4eqhBlR23zY9AZ9I//fJVOKLDJIHQjjUZba2y4ipb+/ns4GRFBsu7hw3QQd8l+egLZrDzZEYuaZQxtTtSjFcZadDZPSzkGuJ4Q1YqAryl6yrLKeLlsxonUNfnCu7rEgiRRfl6fUAzHLz9/Ewi69NpmykR3AGwbS9pf1FmYIBxhlpIw4fqQGw+pVRaCz6XnCWCaut4sEhBEDIShfRW8ZxXfrdJ4C5Ndw4rKbny9vrr2X65OW8i9vq4jctJvGq2CV5s09A9udoEpecCAwEAAaNrMGkwHQYDVR0OBBYEFEnORq1zs4ze0Cjw9dYRSpM0U3ZfMB8GA1UdIwQYMBaAFEnORq1zs4ze0Cjw9dYRSpM0U3ZfMA8GA1UdEwEB/wQFMAMBAf8wFgYDVR0RBA8wDYILd2luLmV4YW1wbGUwDQYJKoZIhvcNAQELBQADggEBADq9Cr8CFhXREqA1+UJNjkm4LrsiSSfTEzOkjExutLshFzfA9jJbtDyfVNF+9mYQlGpJJIFy3FVlL4GsVxG9wtHgL6c3jwWaFjT3RJCo37eqUGfwGI9lbxlSvdfqPZmmpGHv+3pqE9zs7s1nPicIwHs9V21TH8EsJrI/p8bGayx2hW7hKiRZ+lHdyc6T0JYGorMOUNzrabd8FLAt+tlQN0PKx8d1AvbQ2liADhBrUqfSZnSge5q/Ei8/BXtpO2QIR+0aR6gCABEgCh9Dn8hF3rYhShl7dSmaaZw7sB/oetco1b+hS1/trjsG6tdnQhvpcy206OmzMsuCsWj+nLhodXw=",
            )
            .expect("fixture TLS certificate")
}

#[cfg(serviceradar_rdp_connector_link_probe)]
fn fixture_tls_server_cert_pem() -> String {
    use base64::{engine::general_purpose::STANDARD, Engine as _};

    let body = STANDARD.encode(fixture_tls_server_cert_der());
    let mut pem = String::from("-----BEGIN CERTIFICATE-----\n");
    for chunk in body.as_bytes().chunks(64) {
        pem.push_str(std::str::from_utf8(chunk).expect("base64 is utf8"));
        pem.push('\n');
    }
    pem.push_str("-----END CERTIFICATE-----\n");

    pem
}

#[cfg(serviceradar_rdp_connector_link_probe)]
fn fixture_tls_server_key_der() -> Vec<u8> {
    use base64::{engine::general_purpose::STANDARD, Engine as _};

    STANDARD
            .decode(
                "MIIEvQIBADANBgkqhkiG9w0BAQEFAASCBKcwggSjAgEAAoIBAQChrmX2dUKl5mbaAQ44B31FuwKlyLCD/QGlrBAgO0hTQ8FSwM65cN7NRmrmRc6UZAcsQu9/k3/T+HqoQZUdt82PQGfSP/3yVTiiwySB0I41GW2tsuIqW/v57OBkRQbLu4cN0EHfJfnoC2aw82RGLmmUMbU7UoxXGWnQ2T0s5BrieENWKgK8pesqyyni5bMaJ1DX5wru6xIIkUX5en1AMxy8/fxMIuvTaZspEdwBsG0vaX9RZmCAcYZaSMOH6kBsPqVUWgs+l5wlgmrreLBIQRAyEoX0VvGcV363SeAuTXcOKym58vb669l+uTlvIvb6uI3LSbxqtglebNPQPbnaBKXnAgMBAAECggEAQadUbzahmEWNqWP5VqYv6ANvKUvr5cT1CMXsjHIWRf2DAOwbZfEgAEJigVyCbP6LbR1HLMqEA1roz+9FspojJlMUdauXnvKdO3a7md1LCePoBjtYHLRah1v5qK3g+xUM2/6f6RH+P4x1qFBFfTw2kj93JP45z9qZff3hGhwMkL54rp+ObfwGnu97Egy51Xzx94C5LK86KmwgfytGOpKAHLWijf+md61exTn+4danJcMkx550ynKBFoXEqRFZ2phiKP3/I8Ni9k67vktJ6mrpR1ymGtcBmDwZDqhc1IpWIZLmbf6iSSvmrunImDdYelZgINh+fD3oU28duou9IYhKtQKBgQDYCpOyaACRNc66xlzThE2JknN/8wm6nCvDyNIfAdMXgITRezuOoEPoHRSxGc87GZ/oIlQ72Jicp390U50YC4Q/vCXHi9omTycuH62Cd8+CrI7HjWons5989p8uDn+cRQLNtZqtotFY/tH/nQwH3zG5rp7GoR8couqTMRKFuTUtZQKBgQC/lefKcNExAcitENlQJrG5G2XPLrmqyit3DDxJ7byxfcXu9kObLOLx8rTLQCwaZxHcnEFT8QGByuxVFpYmy8MvyLbH9aYGYitydpVeu3+prODj3FNX3zVAHRZX50weerXDB2EUs/4Meupyxe0e7ecRTLxIHmulUYpeqD6/s0THWwKBgGoHJt2UNVMO+VqpJ72XXQZ7nbvZ55hyNPhtgtI87wDFzmmQ9XXWKf2s6A7S/+WdeeFPl8+XSa74dZD9yEeYv1sYV+JLPNE4X54/ZcR2UJ1tWtWNDeBWQ5vs3cqYywBCzlFvI268TcpDpYSx6smiPKFIlhwdz0samc2Lc++1KegRAoGBALK4VJI0y/C7iUho/1AVyJS1SjQLkogQMJvNfjA45l1sxsg0UrzfEpZBowY3xuyaWb9CxG5Z1N4PPofhmhB25I4e3uOJ9GbgDUep9413u4+9Bc2KKvU9857rg3xc+FU2g3h72cRGZCegQjTvDlRb+cHZo4pjVmfRuRK0QFT0FqUhAoGAFaZzpX5A75HegMY2RfGIivRPgWdDquAHzlsUHYPbfOYVAABAnUOvWD6tZzTxDfrwixfALYIa/4sU0j+H2mun+8ypmU7jMh/B/OzW6gltNgUkgXfiqxfRBoMXIPydwlFKgqOOryEFJjf14YBQv7OLd80BXXOmbIaY0+tOYOwX1ME=",
            )
            .expect("fixture TLS key")
}
