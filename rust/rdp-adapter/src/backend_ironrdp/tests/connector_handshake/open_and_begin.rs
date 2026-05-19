#[cfg(serviceradar_rdp_connector_link_probe)]
#[test]
fn connector_probe_open_path_attempts_finalization_and_session_handoff() {
    let mut payload = parse_open_payload(valid_open_payload().as_bytes()).expect("payload");
    payload.target.tls.ca_bundle_id = "ca-rdp-prod".to_owned();
    payload.target.tls.ca_bundle_pem = fixture_tls_server_cert_pem();
    payload
        .target
        .metadata
        .insert(METADATA_MEDIA_SESSION_ID.to_owned(), "media-1".to_owned());
    let listener = std::net::TcpListener::bind("127.0.0.1:0").expect("listener");
    let listener_addr = listener.local_addr().expect("listener addr");
    payload.target.upstream.host = listener_addr.ip().to_string();
    payload.target.upstream.port = u32::from(listener_addr.port());
    payload.target.tls.server_name = "win.example".to_owned();
    let credential_password = payload
        .credential_grant
        .as_ref()
        .expect("credential grant")
        .password
        .expose()
        .expect("password utf8")
        .as_bytes()
        .to_vec();
    let server = spawn_hybrid_ex_tls_capture_server(listener);
    let runtime = ConnectorRuntimePolicy {
        dial_timeout: Duration::from_secs(1),
        kdc_timeout: Duration::from_secs(1),
    };
    let plan = build_nonsecret_connection_plan(&payload).expect("plan");
    let credential = build_memory_user_credential(
        payload
            .credential_grant
            .as_ref()
            .expect("memory user credential grant"),
        &payload.actor_id,
    )
    .expect("credential");

    let err =
        match open_connector_for_experimental_with_runtime(&payload, &plan, &credential, runtime) {
            Ok(_) => panic!("incomplete loopback server should not finalize"),
            Err(err) => err,
        };
    let capture = server.join().expect("server thread");

    assert_eq!(err, BackendError::Unsupported(CONNECTOR_NOT_IMPLEMENTED));
    assert!(!capture.initial_request.is_empty());
    assert!(!bytes_contain_secret(
        &capture.initial_request,
        &credential_password
    ));
    assert!(!bytes_contain_secret(
        &capture.tls_plaintext,
        &credential_password
    ));
}

#[cfg(serviceradar_rdp_connector_link_probe)]
#[test]
fn connector_probe_tcp_connect_begin_rejects_tls_only_confirm_without_password() {
    use std::io::{Read as _, Write as _};

    let mut payload = parse_open_payload(valid_open_payload().as_bytes()).expect("payload");
    payload.target.tls.ca_bundle_id = "ca-rdp-prod".to_owned();
    payload.target.tls.ca_bundle_pem = fixture_server_cert_pem();
    let mut plan = build_nonsecret_connection_plan(&payload).expect("plan");
    let credential = build_memory_user_credential(
        payload
            .credential_grant
            .as_ref()
            .expect("memory user credential grant"),
        &payload.actor_id,
    )
    .expect("credential");
    let listener = std::net::TcpListener::bind("127.0.0.1:0").expect("listener");
    let listener_addr = listener.local_addr().expect("listener addr");
    plan.upstream_host = listener_addr.ip().to_string();
    plan.upstream_port = listener_addr.port();
    let server_confirm = encode_server_confirm_for_probe(ironrdp_pdu::nego::SecurityProtocol::SSL)
        .expect("server confirm");
    let server = std::thread::spawn(move || {
        let (mut stream, _) = listener.accept().expect("accepted connection");
        stream
            .set_read_timeout(Some(Duration::from_secs(1)))
            .expect("read timeout");
        let mut initial_request = [0_u8; 4096];
        let read = stream
            .read(&mut initial_request)
            .expect("initial connector request");
        stream
            .write_all(&server_confirm)
            .expect("server confirm write");

        initial_request[..read].to_vec()
    });

    let err = match begin_connector_handoff_with_tcp_dial_for_probe(
        &plan,
        &credential,
        Duration::from_secs(1),
    ) {
        Ok(_) => panic!("tls-only confirm should be rejected"),
        Err(err) => err,
    };
    let initial_request = server.join().expect("server thread");

    assert_eq!(err, BackendError::Unsupported(CONNECTOR_NOT_IMPLEMENTED));
    assert!(!initial_request.is_empty());
    assert!(!bytes_contain_secret(
        &initial_request,
        credential.password.value.as_str().as_bytes(),
    ));
}
