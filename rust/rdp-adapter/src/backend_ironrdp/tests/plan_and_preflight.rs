
use super::*;
use crate::protocol::{parse_open_payload, tests::valid_open_payload};
use ironrdp_pdu::gcc::KeyboardType;
use ironrdp_pdu::rdp::capability_sets::MajorPlatformType;
use ironrdp_pdu::rdp::client_info::PerformanceFlags;

#[test]
fn ironrdp_core_pdu_types_are_linked() {
    let _buffer = ironrdp_core::WriteBuf::new();

    assert_eq!(KeyboardType::IbmEnhanced.as_u32(), 4);
    assert_eq!(
        format!("{:?}", MajorPlatformType::UNIX),
        "MajorPlatformType(0x04-UNIX)"
    );
    assert!(PerformanceFlags::default().contains(PerformanceFlags::ENABLE_FONT_SMOOTHING));
}

#[test]
fn nonsecret_connection_plan_uses_registered_endpoint_and_server_name() {
    let payload = parse_open_payload(valid_open_payload().as_bytes()).expect("valid payload");
    let plan = build_nonsecret_connection_plan(&payload).expect("plan");

    assert_eq!(
        plan,
        NonSecretConnectionPlan {
            upstream_host: "win.example".to_owned(),
            upstream_port: 3389,
            tls_server_name: "win.example".to_owned(),
            tls_trust_source: TlsTrustSource::SystemRoots,
            kdc_proxy_url: None,
            kerberos_hostname: None,
            desktop_width: 1920,
            desktop_height: 1080,
        }
    );
}

#[test]
fn nonsecret_connection_plan_falls_back_to_upstream_host_for_tls_name() {
    let raw = valid_open_payload().replace(
        r#""tls":{"mode":"verify","nla_mode":"required","server_name":"win.example"}"#,
        r#""tls":{"mode":"verify","nla_mode":"required"}"#,
    );
    let payload = parse_open_payload(raw.as_bytes()).expect("valid payload");
    let plan = build_nonsecret_connection_plan(&payload).expect("plan");

    assert_eq!(plan.upstream_host, "win.example");
    assert_eq!(plan.tls_server_name, "win.example");
}

#[test]
fn nonsecret_connection_plan_rejects_ip_literal_tls_server_name() {
    let raw = valid_open_payload().replace(
        r#""tls":{"mode":"verify","nla_mode":"required","server_name":"win.example"}"#,
        r#""tls":{"mode":"verify","nla_mode":"required","server_name":"192.168.1.45"}"#,
    );
    let payload = parse_open_payload(raw.as_bytes()).expect("valid payload");

    let err = build_nonsecret_connection_plan(&payload).expect_err("plan rejected");

    assert!(matches!(
        err,
        BackendError::Unsupported(INVALID_CONNECTION_PLAN)
    ));
}

#[test]
fn nonsecret_connection_plan_rejects_invalid_tls_server_name_labels() {
    for server_name in [
        "-win.example",
        "win..example",
        "win.example-",
        "win_example",
    ] {
        let raw = valid_open_payload().replace(
            r#""tls":{"mode":"verify","nla_mode":"required","server_name":"win.example"}"#,
            &format!(
                r#""tls":{{"mode":"verify","nla_mode":"required","server_name":"{server_name}"}}"#
            ),
        );
        let payload = parse_open_payload(raw.as_bytes()).expect("valid payload");

        let err = build_nonsecret_connection_plan(&payload).expect_err("plan rejected");

        assert!(matches!(
            err,
            BackendError::Unsupported(INVALID_CONNECTION_PLAN)
        ));
    }
}

#[cfg(serviceradar_rdp_connector_link_probe)]
#[test]
fn connector_probe_plan_carries_kerberos_metadata() {
    let mut payload = parse_open_payload(valid_open_payload().as_bytes()).expect("payload");
    payload.target.metadata.insert(
        METADATA_KDC_PROXY_URL.to_owned(),
        "tcp://kdc.example:88".to_owned(),
    );
    payload.target.metadata.insert(
        METADATA_KERBEROS_HOSTNAME.to_owned(),
        "win.example".to_owned(),
    );
    let plan = build_nonsecret_connection_plan(&payload).expect("plan");

    assert_eq!(plan.kdc_proxy_url.as_deref(), Some("tcp://kdc.example:88"));
    assert_eq!(plan.kerberos_hostname.as_deref(), Some("win.example"));

    let kerberos = build_connector_kerberos_config_for_plan(&plan)
        .expect("Kerberos config")
        .expect("Kerberos config present");

    assert!(kerberos.kdc_proxy_url.is_some());
    assert_eq!(kerberos.hostname.as_deref(), Some("win.example"));
}

#[cfg(serviceradar_rdp_connector_link_probe)]
#[test]
fn connector_probe_plan_rejects_invalid_kdc_proxy_url() {
    let mut payload = parse_open_payload(valid_open_payload().as_bytes()).expect("payload");
    payload
        .target
        .metadata
        .insert(METADATA_KDC_PROXY_URL.to_owned(), "not a url".to_owned());
    let plan = build_nonsecret_connection_plan(&payload).expect("plan");

    let err = match build_connector_kerberos_config_for_plan(&plan) {
        Ok(_) => panic!("invalid KDC proxy URL accepted"),
        Err(err) => err,
    };

    assert_eq!(err, BackendError::Unsupported(INVALID_CONNECTION_PLAN));
}

#[cfg(serviceradar_rdp_connector_link_probe)]
#[test]
fn connector_kerberos_binding_revalidation_rejects_drift() {
    let mut payload = parse_open_payload(valid_open_payload().as_bytes()).expect("payload");
    payload.target.metadata.insert(
        METADATA_KDC_PROXY_URL.to_owned(),
        "tcp://kdc.example:88".to_owned(),
    );
    payload.target.metadata.insert(
        METADATA_KERBEROS_HOSTNAME.to_owned(),
        "win.example".to_owned(),
    );
    let plan = build_nonsecret_connection_plan(&payload).expect("plan");
    let config = build_connector_kerberos_config_for_plan(&plan).expect("Kerberos config");
    let binding = connector_kerberos_binding_from_config(&config);
    let mut drifted = config.clone();
    drifted.as_mut().expect("Kerberos config present").hostname =
        Some("changed.example".to_owned());

    let err = validate_connector_kerberos_binding(&binding, &drifted).expect_err("drift");

    assert!(matches!(
        err,
        BackendError::Unsupported(INVALID_CONNECTION_PLAN)
    ));
}

#[cfg(serviceradar_rdp_connector_link_probe)]
#[test]
fn connector_runtime_policy_uses_bounded_stage_timeout_metadata() {
    let mut payload = parse_open_payload(valid_open_payload().as_bytes()).expect("payload");
    payload
        .target
        .metadata
        .insert(METADATA_DIAL_TIMEOUT_MS.to_owned(), "1500".to_owned());
    payload
        .target
        .metadata
        .insert(METADATA_KDC_TIMEOUT_MS.to_owned(), "2500".to_owned());

    let runtime = connector_runtime_policy_from_request(&payload).expect("runtime policy");

    assert_eq!(runtime.dial_timeout, Duration::from_millis(1500));
    assert_eq!(runtime.kdc_timeout, Duration::from_millis(2500));
}

#[cfg(serviceradar_rdp_connector_link_probe)]
#[test]
fn connector_runtime_policy_rejects_unbounded_stage_timeout_metadata() {
    let mut payload = parse_open_payload(valid_open_payload().as_bytes()).expect("payload");
    payload.target.metadata.insert(
        METADATA_KDC_TIMEOUT_MS.to_owned(),
        (MAX_CONNECTOR_STAGE_TIMEOUT.as_millis() + 1).to_string(),
    );

    let err = connector_runtime_policy_from_request(&payload).expect_err("runtime rejected");

    assert!(matches!(
        err,
        BackendError::Unsupported(INVALID_CONNECTION_PLAN)
    ));
}

#[test]
fn nonsecret_connection_plan_uses_registered_ca_bundle_for_verify_mode() {
    let raw = valid_open_payload().replace(
            r#""tls":{"mode":"verify","nla_mode":"required","server_name":"win.example"}"#,
            r#""tls":{"mode":"verify","ca_bundle_id":"ca-rdp-prod","ca_bundle_pem":"-----BEGIN CERTIFICATE-----\nMIIB\n-----END CERTIFICATE-----","nla_mode":"required","server_name":"win.example"}"#,
        );
    let payload = parse_open_payload(raw.as_bytes()).expect("valid payload");
    let plan = build_nonsecret_connection_plan(&payload).expect("plan");

    assert_eq!(
        plan.tls_trust_source,
        TlsTrustSource::RegisteredCaBundle {
            id: "ca-rdp-prod".to_owned(),
            pem: "-----BEGIN CERTIFICATE-----\nMIIB\n-----END CERTIFICATE-----".to_owned(),
        }
    );
}

#[test]
fn nonsecret_connection_plan_requires_registered_ca_bundle_material_for_pinned_ca() {
    let raw = valid_open_payload().replace(
            r#""tls":{"mode":"verify","nla_mode":"required","server_name":"win.example"}"#,
            r#""tls":{"mode":"pinned_ca","ca_bundle_id":"ca-rdp-prod","nla_mode":"required","server_name":"win.example"}"#,
        );
    let err = parse_open_payload(raw.as_bytes()).expect_err("pinned CA rejected");

    assert_eq!(err, crate::protocol::OpenPayloadError::UnsupportedTlsPolicy);
}

#[test]
fn nonsecret_connection_plan_uses_registered_ca_bundle_for_pinned_ca() {
    let raw = valid_open_payload().replace(
            r#""tls":{"mode":"verify","nla_mode":"required","server_name":"win.example"}"#,
            r#""tls":{"mode":"pinned_ca","ca_bundle_id":"ca-rdp-prod","ca_bundle_pem":"-----BEGIN CERTIFICATE-----\nMIIB\n-----END CERTIFICATE-----","nla_mode":"required","server_name":"win.example"}"#,
        );
    let payload = parse_open_payload(raw.as_bytes()).expect("valid payload");
    let plan = build_nonsecret_connection_plan(&payload).expect("plan");

    assert_eq!(
        plan.tls_trust_source,
        TlsTrustSource::RegisteredCaBundle {
            id: "ca-rdp-prod".to_owned(),
            pem: "-----BEGIN CERTIFICATE-----\nMIIB\n-----END CERTIFICATE-----".to_owned(),
        }
    );
}

#[test]
fn memory_user_credential_uses_zeroizing_redacted_storage() {
    let payload = parse_open_payload(valid_open_payload().as_bytes()).expect("valid payload");
    let credential = build_memory_user_credential(
        payload
            .credential_grant
            .as_ref()
            .expect("memory user credential grant"),
        &payload.actor_id,
    )
    .expect("credential");

    assert!(credential.domain.is_none());
    assert_eq!(credential.username.as_str(), "alice");
    assert_eq!(credential.password.value.as_str(), "secret");
    assert_eq!(
        format!("{credential:?}"),
        r#"MemoryUserCredential { domain: "<redacted>", username: "<redacted>", password: <redacted> }"#
    );
}

#[test]
fn memory_user_credential_splits_windows_domain_username() {
    let raw = valid_open_payload()
        .replace(r#""username":"alice""#, r#""username":"EXAMPLE\\alice""#)
        .replace(
            r#""allowed_principals":["alice"]"#,
            r#""allowed_principals":["EXAMPLE\\alice"]"#,
        );
    let payload = parse_open_payload(raw.as_bytes()).expect("valid payload");
    let credential = build_memory_user_credential(
        payload
            .credential_grant
            .as_ref()
            .expect("memory user credential grant"),
        &payload.actor_id,
    )
    .expect("credential");

    assert_eq!(
        credential.domain.as_ref().map(|domain| domain.as_str()),
        Some("EXAMPLE")
    );
    assert_eq!(credential.username.as_str(), "alice");
    assert_eq!(credential.password.value.as_str(), "secret");
    assert!(!format!("{credential:?}").contains("EXAMPLE"));
    assert!(!format!("{credential:?}").contains("alice"));
    assert!(!format!("{credential:?}").contains("secret"));
}

#[cfg(serviceradar_rdp_connector_link_probe)]
#[test]
fn connector_probe_builds_config_from_validated_open_payload() {
    let raw = valid_open_payload()
        .replace(r#""username":"alice""#, r#""username":"EXAMPLE\\alice""#)
        .replace(
            r#""allowed_principals":["alice"]"#,
            r#""allowed_principals":["EXAMPLE\\alice"]"#,
        );
    let payload = parse_open_payload(raw.as_bytes()).expect("valid payload");
    let plan = build_nonsecret_connection_plan(&payload).expect("plan");
    let credential = build_memory_user_credential(
        payload
            .credential_grant
            .as_ref()
            .expect("memory user credential grant"),
        &payload.actor_id,
    )
    .expect("credential");

    let config = build_connector_config_for_probe(&plan, &credential);

    assert_eq!(config.desktop_size.width, 1920);
    assert_eq!(config.desktop_size.height, 1080);
    assert!(!config.enable_tls);
    assert!(config.enable_credssp);
    assert_eq!(config.domain.as_deref(), Some("EXAMPLE"));
    let ironrdp_connector::Credentials::UsernamePassword { username, .. } = config.credentials;
    assert_eq!(username, "alice");
}

#[cfg(serviceradar_rdp_connector_link_probe)]
#[test]
fn connector_probe_experimental_open_preflight_omits_password_copy() {
    let raw = valid_open_payload()
        .replace(r#""username":"alice""#, r#""username":"EXAMPLE\\alice""#)
        .replace(
            r#""allowed_principals":["alice"]"#,
            r#""allowed_principals":["EXAMPLE\\alice"]"#,
        );
    let payload = parse_open_payload(raw.as_bytes()).expect("valid payload");
    let plan = build_nonsecret_connection_plan(&payload).expect("plan");
    let credential = build_memory_user_credential(
        payload
            .credential_grant
            .as_ref()
            .expect("memory user credential grant"),
        &payload.actor_id,
    )
    .expect("credential");

    let preflight =
        build_connector_config_preflight_for_experimental(&plan, &credential).expect("preflight");
    let debug = format!("{preflight:?}");

    assert_eq!(preflight.domain.as_deref(), Some("EXAMPLE"));
    assert_eq!(preflight.username, "alice");
    assert_eq!(preflight.upstream_endpoint, "win.example:3389");
    assert!(!debug.contains("secret"));
}

#[cfg(serviceradar_rdp_connector_link_probe)]
#[test]
fn connector_probe_dial_target_formats_ipv6_endpoint_without_dns() {
    let payload = parse_open_payload(valid_open_payload().as_bytes()).expect("valid payload");
    let mut plan = build_nonsecret_connection_plan(&payload).expect("plan");
    plan.upstream_host = "2001:db8::45".to_owned();

    let dial_target = build_connector_dial_target_for_plan(&plan).expect("dial target");

    assert_eq!(
        dial_target,
        ConnectorDialTarget {
            host: "2001:db8::45".to_owned(),
            port: 3389,
            endpoint: "[2001:db8::45]:3389".to_owned(),
        }
    );
}

#[cfg(serviceradar_rdp_connector_link_probe)]
#[test]
fn connector_probe_dial_target_rejects_invalid_host_text() {
    let payload = parse_open_payload(valid_open_payload().as_bytes()).expect("valid payload");
    let mut plan = build_nonsecret_connection_plan(&payload).expect("plan");
    plan.upstream_host = "bad host.example".to_owned();

    let err = build_connector_dial_target_for_plan(&plan)
        .expect_err("host text with whitespace rejected");

    assert_eq!(err, BackendError::Unsupported(INVALID_CONNECTION_PLAN));
}

#[cfg(serviceradar_rdp_connector_link_probe)]
#[test]
fn connector_probe_tcp_dial_returns_dialed_stream_for_registered_target() {
    let payload = parse_open_payload(valid_open_payload().as_bytes()).expect("valid payload");
    let mut plan = build_nonsecret_connection_plan(&payload).expect("plan");
    let listener = std::net::TcpListener::bind("127.0.0.1:0").expect("listener");
    let listener_addr = listener.local_addr().expect("listener addr");
    plan.upstream_host = listener_addr.ip().to_string();
    plan.upstream_port = listener_addr.port();

    let dialed =
        dial_connector_tcp_for_probe(&plan, Duration::from_secs(1)).expect("dialed stream");

    assert_eq!(
        dialed.endpoint(),
        format!("{}:{}", plan.upstream_host, plan.upstream_port)
    );
    assert_eq!(dialed.client_addr().ip(), listener_addr.ip());
    assert_ne!(dialed.client_addr().port(), 0);
    assert_eq!(
        dialed
            .stream
            .read_timeout()
            .expect("read timeout configured"),
        Some(Duration::from_secs(1))
    );
    assert_eq!(
        dialed
            .stream
            .write_timeout()
            .expect("write timeout configured"),
        Some(Duration::from_secs(1))
    );
}

#[cfg(serviceradar_rdp_connector_link_probe)]
#[test]
fn connector_probe_tcp_connect_begin_reaches_upgrade_boundary_without_password() {
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
    let server_confirm =
        encode_server_confirm_for_probe(ironrdp_pdu::nego::SecurityProtocol::HYBRID_EX)
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

    let handoff =
        begin_connector_handoff_with_tcp_dial_for_probe(&plan, &credential, Duration::from_secs(1))
            .expect("connector begin handoff");
    let initial_request = server.join().expect("server thread");

    assert!(handoff.requires_security_upgrade());
    assert_eq!(
        handoff.remote_endpoint(),
        format!("{}:{}", plan.upstream_host, plan.upstream_port)
    );
    assert_eq!(handoff.client_addr().ip(), listener_addr.ip());
    assert_ne!(handoff.client_addr().port(), 0);
    assert!(!initial_request.is_empty());
    assert!(!bytes_contain_secret(
        &initial_request,
        credential.password.value.as_str().as_bytes(),
    ));
}

#[cfg(serviceradar_rdp_connector_link_probe)]
#[test]
fn connector_probe_tcp_tls_upgrade_enters_credssp_state_without_password() {
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

    let begin_handoff =
        begin_connector_handoff_with_tcp_dial_for_probe(&plan, &credential, Duration::from_secs(1))
            .expect("connector begin handoff");
    let credssp_handoff =
        upgrade_connector_handoff_tls_for_probe(begin_handoff).expect("TLS upgrade");
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

#[cfg(serviceradar_rdp_connector_link_probe)]
#[test]
fn connector_probe_tcp_tls_upgrade_rejects_server_name_mismatch_without_password() {
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
    plan.tls_server_name = "rdp-wrong.example".to_owned();
    let server = spawn_hybrid_ex_tls_probe_server(listener);

    let begin_handoff =
        begin_connector_handoff_with_tcp_dial_for_probe(&plan, &credential, Duration::from_secs(1))
            .expect("connector begin handoff");
    let err = upgrade_connector_handoff_tls_for_probe(begin_handoff)
        .expect_err("server name mismatch rejected");
    let initial_request = server.join().expect("server thread");

    assert_eq!(err, BackendError::Unsupported(CONNECTOR_NOT_IMPLEMENTED));
    assert!(!initial_request.is_empty());
    assert!(!bytes_contain_secret(
        &initial_request,
        credential.password.value.as_str().as_bytes(),
    ));
}

#[cfg(serviceradar_rdp_connector_link_probe)]
#[test]
fn connector_probe_tcp_tls_upgrade_rejects_untrusted_ca_without_password() {
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
    plan.tls_server_name = "win.example".to_owned();
    let server = spawn_hybrid_ex_tls_probe_server(listener);

    let begin_handoff =
        begin_connector_handoff_with_tcp_dial_for_probe(&plan, &credential, Duration::from_secs(1))
            .expect("connector begin handoff");
    let err =
        upgrade_connector_handoff_tls_for_probe(begin_handoff).expect_err("untrusted CA rejected");
    let initial_request = server.join().expect("server thread");

    assert_eq!(err, BackendError::Unsupported(CONNECTOR_NOT_IMPLEMENTED));
    assert!(!initial_request.is_empty());
    assert!(!bytes_contain_secret(
        &initial_request,
        credential.password.value.as_str().as_bytes(),
    ));
}

