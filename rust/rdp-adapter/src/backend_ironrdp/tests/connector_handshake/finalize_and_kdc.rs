#[cfg(serviceradar_rdp_connector_link_probe)]
#[test]
fn connector_probe_tcp_tls_finalize_writes_credssp_without_password() {
    let mut payload = parse_open_payload(valid_open_payload().as_bytes()).expect("payload");
    payload.target.tls.ca_bundle_id = "ca-rdp-prod".to_owned();
    payload.target.tls.ca_bundle_pem = fixture_tls_server_cert_pem();
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
    plan.tls_server_name = "win.example".to_owned();
    let server = spawn_hybrid_ex_tls_capture_server(listener);

    let begin_handoff =
        begin_connector_handoff_with_tcp_dial_for_probe(&plan, &credential, Duration::from_secs(1))
            .expect("connector begin handoff");
    let credssp_handoff =
        upgrade_connector_handoff_tls_for_probe(begin_handoff).expect("TLS upgrade");
    let mut network_client = RejectingNetworkClient;
    let failure = match finalize_connector_handoff_for_probe(credssp_handoff, &mut network_client) {
        Ok(_) => panic!("rejecting network client should not finalize"),
        Err(failure) => failure,
    };
    let capture = server.join().expect("server thread");

    assert_eq!(
        failure.error,
        BackendError::Unsupported(CONNECTOR_NOT_IMPLEMENTED)
    );
    assert!(!capture.initial_request.is_empty());
    assert!(!bytes_contain_secret(
        &capture.initial_request,
        credential.password.value.as_str().as_bytes(),
    ));
    assert!(!bytes_contain_secret(
        &capture.tls_plaintext,
        credential.password.value.as_str().as_bytes(),
    ));
}

#[cfg(serviceradar_rdp_connector_link_probe)]
#[test]
fn connector_probe_experimental_finalize_uses_bounded_kdc_client_without_password() {
    let mut payload = parse_open_payload(valid_open_payload().as_bytes()).expect("payload");
    payload.target.tls.ca_bundle_id = "ca-rdp-prod".to_owned();
    payload.target.tls.ca_bundle_pem = fixture_tls_server_cert_pem();
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
    plan.tls_server_name = "win.example".to_owned();
    let runtime = ConnectorRuntimePolicy {
        dial_timeout: Duration::from_secs(1),
        kdc_timeout: Duration::from_millis(100),
    };
    let server = spawn_hybrid_ex_tls_capture_server(listener);

    let credssp_handoff =
        connect_verified_credssp_handoff_for_experimental(&plan, &credential, runtime)
            .expect("CredSSP-ready handoff");
    let failure = match finalize_verified_connector_for_experimental(credssp_handoff, runtime) {
        Ok(_) => panic!("incomplete loopback server should not finalize"),
        Err(failure) => failure,
    };
    let capture = server.join().expect("server thread");

    assert_eq!(
        failure.error,
        BackendError::Unsupported(CONNECTOR_NOT_IMPLEMENTED)
    );
    assert!(!capture.initial_request.is_empty());
    assert!(!bytes_contain_secret(
        &capture.initial_request,
        credential.password.value.as_str().as_bytes(),
    ));
    assert!(!bytes_contain_secret(
        &capture.tls_plaintext,
        credential.password.value.as_str().as_bytes(),
    ));
}

#[cfg(serviceradar_rdp_connector_link_probe)]
#[test]
fn connector_probe_kdc_network_client_tcp_round_trip_is_bounded() {
    use ironrdp_connector::sspi::network_client::NetworkClient as _;
    use std::io::{Read as _, Write as _};

    let listener = std::net::TcpListener::bind("127.0.0.1:0").expect("listener");
    let listener_addr = listener.local_addr().expect("listener addr");
    let server = std::thread::spawn(move || {
        let (mut stream, _) = listener.accept().expect("accepted connection");
        stream
            .set_read_timeout(Some(Duration::from_secs(1)))
            .expect("read timeout");
        let mut request = [0_u8; 14];
        stream.read_exact(&mut request).expect("KDC request");
        stream
            .write_all(&3_u32.to_be_bytes())
            .expect("KDC response length");
        stream.write_all(b"kdc").expect("KDC response body");

        request.to_vec()
    });
    let client = ServiceRadarKdcNetworkClient {
        timeout: Duration::from_secs(1),
    };
    let request = ironrdp_connector::sspi::generator::NetworkRequest {
        protocol: ironrdp_connector::sspi::network_client::NetworkProtocol::Tcp,
        url: format!("tcp://{}", listener_addr).parse().expect("url"),
        data: b"kerberos-token".to_vec(),
    };

    let response = client.send(&request).expect("KDC response");
    let captured_request = server.join().expect("server thread");

    assert_eq!(captured_request, b"kerberos-token");
    assert_eq!(&response[..4], &3_u32.to_be_bytes());
    assert_eq!(&response[4..], b"kdc");
}

#[cfg(serviceradar_rdp_connector_link_probe)]
#[test]
fn connector_probe_kdc_network_client_rejects_unsupported_protocol() {
    use ironrdp_connector::sspi::network_client::NetworkClient as _;

    let client = ServiceRadarKdcNetworkClient {
        timeout: Duration::from_secs(1),
    };
    let request = ironrdp_connector::sspi::generator::NetworkRequest {
        protocol: ironrdp_connector::sspi::network_client::NetworkProtocol::Udp,
        url: "udp://127.0.0.1:88".parse().expect("url"),
        data: b"kerberos-token".to_vec(),
    };

    client
        .send(&request)
        .expect_err("unsupported KDC protocol rejected");
}

#[cfg(serviceradar_rdp_connector_link_probe)]
#[test]
fn connector_probe_kdc_network_client_rejects_oversized_response() {
    use ironrdp_connector::sspi::network_client::NetworkClient as _;
    use std::io::{Read as _, Write as _};

    let listener = std::net::TcpListener::bind("127.0.0.1:0").expect("listener");
    let listener_addr = listener.local_addr().expect("listener addr");
    let server = std::thread::spawn(move || {
        let (mut stream, _) = listener.accept().expect("accepted connection");
        stream
            .set_read_timeout(Some(Duration::from_secs(1)))
            .expect("read timeout");
        let mut request = [0_u8; 14];
        stream.read_exact(&mut request).expect("KDC request");
        stream
            .write_all(&(MAX_KDC_RESPONSE_BYTES + 1).to_be_bytes())
            .expect("oversized KDC response length");
    });
    let client = ServiceRadarKdcNetworkClient {
        timeout: Duration::from_secs(1),
    };
    let request = ironrdp_connector::sspi::generator::NetworkRequest {
        protocol: ironrdp_connector::sspi::network_client::NetworkProtocol::Tcp,
        url: format!("tcp://{}", listener_addr).parse().expect("url"),
        data: b"kerberos-token".to_vec(),
    };

    client
        .send(&request)
        .expect_err("oversized KDC response rejected");
    server.join().expect("server thread");
}

#[cfg(serviceradar_rdp_connector_link_probe)]
#[test]
fn connector_probe_experimental_open_boundary_reaches_credssp_handoff_without_password() {
    let mut payload = parse_open_payload(valid_open_payload().as_bytes()).expect("payload");
    payload.target.tls.ca_bundle_id = "ca-rdp-prod".to_owned();
    payload.target.tls.ca_bundle_pem = fixture_tls_server_cert_pem();
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
    plan.tls_server_name = "win.example".to_owned();
    let server = spawn_hybrid_ex_tls_probe_server(listener);
    let runtime = ConnectorRuntimePolicy {
        dial_timeout: Duration::from_secs(1),
        kdc_timeout: Duration::from_secs(1),
    };

    let credssp_handoff =
        connect_verified_credssp_handoff_for_experimental(&plan, &credential, runtime)
            .expect("CredSSP-ready handoff");
    let initial_request = server.join().expect("server thread");
    let (_tls_stream, leftover) = credssp_handoff.framed.get_inner();

    assert!(credssp_handoff.requires_credssp());
    assert_eq!(credssp_handoff.server_name(), "win.example");
    assert!(leftover.is_empty());
    assert!(!initial_request.is_empty());
    assert!(!bytes_contain_secret(
        &initial_request,
        credential.password.value.as_str().as_bytes(),
    ));
}
