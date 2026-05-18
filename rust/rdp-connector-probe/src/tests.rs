use super::*;
use base64::{engine::general_purpose::STANDARD, Engine as _};
use ironrdp_connector::Credentials;

#[test]
fn links_connector_without_root_workspace_lockfile() {
    assert!(crate::connector_dependency_is_linked());
}

#[test]
fn links_active_stage_without_root_workspace_lockfile() {
    assert!(crate::active_stage_dependency_is_linked());
}

#[test]
fn builds_active_stage_from_service_radar_connector_plan() {
    let probe = crate::build_active_stage_smoke(open_request("EXAMPLE\\alice", "required"))
        .expect("active stage smoke");

    assert_eq!(probe.desktop_width, 1920);
    assert_eq!(probe.desktop_height, 1080);
    assert!(probe.accepts_mouse_position_update);
}

#[test]
fn active_stage_encodes_keyboard_input_response_frame() {
    let probe =
        crate::encode_active_stage_keyboard_input_smoke(open_request("EXAMPLE\\alice", "required"))
            .expect("active stage input");

    assert_eq!(probe.response_frames, 1);
    assert!(probe.response_bytes > 0);
    assert_eq!(probe.graphics_updates, 0);
}

#[test]
fn builds_nla_required_username_password_config() {
    let config =
        crate::build_connector_config(open_request("EXAMPLE\\alice", "required")).expect("config");

    assert!(!config.enable_tls);
    assert!(config.enable_credssp);
    assert_eq!(config.domain.as_deref(), Some("EXAMPLE"));
    assert_eq!(config.desktop_size.width, 1920);
    assert_eq!(config.desktop_size.height, 1080);
    assert_eq!(
        config.keyboard_type,
        ironrdp_pdu::gcc::KeyboardType::IbmEnhanced
    );

    match config.credentials {
        Credentials::UsernamePassword { username, password } => {
            assert_eq!(username, "alice");
            assert_eq!(password, "secret");
        }
        Credentials::SmartCard { .. } => panic!("unexpected smart-card config"),
    }
}

#[test]
fn connector_plan_uses_registered_endpoint_and_server_name() {
    let plan =
        crate::build_connector_plan(open_request("EXAMPLE\\alice", "required")).expect("plan");

    assert_eq!(plan.upstream_host, "win.example");
    assert_eq!(plan.upstream_port, 3389);
    assert_eq!(plan.tls_server_name, "win.example");
    assert!(plan.connector_config.enable_credssp);
}

#[test]
fn connector_plan_falls_back_to_upstream_host_for_tls_server_name() {
    let mut request = open_request("EXAMPLE\\alice", "required");
    request.target.upstream.host = "rdp.internal.example".to_owned();
    request.target.tls.server_name.clear();

    let plan = crate::build_connector_plan(request).expect("plan");

    assert_eq!(plan.upstream_host, "rdp.internal.example");
    assert_eq!(plan.tls_server_name, "rdp.internal.example");
}

#[test]
fn connector_plan_rejects_ip_literal_tls_server_name() {
    let mut request = open_request("EXAMPLE\\alice", "required");
    request.target.tls.server_name = "192.168.1.45".to_owned();

    let err = crate::build_connector_plan(request).expect_err("plan rejected");

    assert_eq!(err, "tls server name is invalid");
}

#[test]
fn connector_plan_rejects_invalid_tls_server_name_labels() {
    for server_name in [
        "-win.example",
        "win..example",
        "win.example-",
        "win_example",
    ] {
        let mut request = open_request("EXAMPLE\\alice", "required");
        request.target.tls.server_name = server_name.to_owned();

        let err = crate::build_connector_plan(request).expect_err("plan rejected");

        assert_eq!(err, "tls server name is invalid");
    }
}

#[test]
fn tls_upgrade_plan_uses_system_roots_by_default() {
    let request = open_request("EXAMPLE\\alice", "required");
    let plan = crate::build_tls_upgrade_plan(&request).expect("tls plan");

    assert_eq!(
        plan,
        TlsUpgradePlan {
            server_name: "win.example".to_owned(),
            trust_source: TlsTrustSource::SystemRoots,
        }
    );
}

#[test]
fn tls_upgrade_plan_uses_registered_ca_bundle_for_verify_mode() {
    let mut request = open_request("EXAMPLE\\alice", "required");
    request.target.tls.ca_bundle_id = "ca-bundle-1".to_owned();
    let plan = crate::build_tls_upgrade_plan(&request).expect("tls plan");

    assert_eq!(
        plan,
        TlsUpgradePlan {
            server_name: "win.example".to_owned(),
            trust_source: TlsTrustSource::RegisteredCaBundle("ca-bundle-1".to_owned()),
        }
    );
}

#[test]
fn tls_upgrade_plan_requires_registered_ca_for_pinned_ca_mode() {
    let mut request = open_request("EXAMPLE\\alice", "required");
    request.target.tls.mode = "pinned_ca".to_owned();

    let err = crate::build_tls_upgrade_plan(&request).unwrap_err();

    assert_eq!(err, "tls ca bundle is required");
}

#[test]
fn tls_upgrade_plan_rejects_insecure_modes() {
    let mut request = open_request("EXAMPLE\\alice", "required");
    request.target.tls.mode = "insecure".to_owned();

    let err = crate::build_tls_upgrade_plan(&request).unwrap_err();

    assert_eq!(err, "tls verification mode is unsupported");
}

#[test]
fn registered_ca_bundle_refuses_raw_der_bytes() {
    // Audit finding 1.A2.1: raw DER (or any non-PEM body) must be refused
    // with a structured ca_bundle_invalid reason. Previously the parser
    // wrapped the bytes as a CertificateDer and handed them to rustls,
    // which then failed opaquely at handshake time.
    let err = crate::build_verified_tls_client_config_for_registered_ca_bundle(
        &fixture_server_cert_der(),
    )
    .expect_err("raw DER must be refused");

    assert!(
        err.starts_with("ca_bundle_invalid"),
        "unexpected error: {err}"
    );
    assert!(
        err.contains("not PEM-encoded"),
        "error must explain the cause: {err}"
    );
}

#[test]
fn registered_ca_bundle_builds_verified_tls_client_config_from_pem_chain() {
    let cert_pem = fixture_server_cert_pem();
    let ca_bundle = format!("{cert_pem}\n{cert_pem}");
    let probe =
        crate::build_verified_tls_client_config_for_registered_ca_bundle(ca_bundle.as_bytes())
            .expect("verified TLS config");

    assert_eq!(
        probe,
        VerifiedTlsClientConfigProbe {
            trusted_root_count: 2,
            resumption_disabled_for_credssp: true,
        }
    );
}

#[test]
fn registered_ca_bundle_rejects_empty_or_invalid_material() {
    let empty = crate::build_verified_tls_client_config_for_registered_ca_bundle(b" \n\t")
        .expect_err("empty rejected");
    let invalid =
        crate::build_verified_tls_client_config_for_registered_ca_bundle(b"not a certificate")
            .expect_err("invalid rejected");

    // Every rejection from the CA-bundle parser carries the
    // ca_bundle_invalid prefix (audit finding 1.A2.1) so callers can
    // map it to a structured operator-facing reason.
    assert!(
        empty.starts_with("ca_bundle_invalid"),
        "unexpected empty-case error: {empty}"
    );
    assert!(
        invalid.starts_with("ca_bundle_invalid"),
        "unexpected invalid-case error: {invalid}"
    );
    assert!(
        invalid.contains("not PEM-encoded"),
        "non-PEM input must be rejected at the marker check: {invalid}"
    );
}

#[test]
fn system_roots_build_verified_tls_client_config() {
    let probe = crate::build_verified_tls_client_config_for_system_roots()
        .expect("system roots TLS config");

    assert!(probe.trusted_root_count > 0);
    assert!(probe.resumption_disabled_for_credssp);
}

#[test]
fn rejects_non_nla_connector_config() {
    let err = crate::build_connector_config(open_request("alice", "optional")).unwrap_err();

    assert_eq!(err, "nla is required");
}

#[test]
fn builds_initial_x224_negotiation_pdu() {
    let pdu = crate::build_initial_connector_pdu(open_request("EXAMPLE\\alice", "required"))
        .expect("initial pdu");

    assert_eq!(pdu.before_state, "ConnectionInitiationSendRequest");
    assert_eq!(pdu.after_state, "ConnectionInitiationWaitResponse");
    assert!(pdu.advertises_credssp);
    assert!(!pdu.advertises_tls_fallback);
    assert_eq!(pdu.mstshash_cookie.as_deref(), Some("alice"));
    assert!(!pdu.contains_cleartext_password);
    assert!(pdu.bytes.len() > 10);
    assert_eq!(&pdu.bytes[..2], &[0x03, 0x00]);
}

#[test]
fn initial_negotiation_includes_username_cookie_but_not_password() {
    let pdu = crate::build_initial_connector_pdu(open_request("EXAMPLE\\alice", "required"))
        .expect("initial pdu");

    assert_eq!(pdu.mstshash_cookie.as_deref(), Some("alice"));
    assert!(!pdu.contains_cleartext_password);
    assert!(!pdu
        .bytes
        .windows(b"secret".len())
        .any(|window| window == b"secret"));
}

#[test]
fn parses_full_helper_open_payload_and_builds_initial_pdu() {
    let request =
        crate::parse_service_radar_open_request(valid_open_payload().as_bytes()).expect("open");
    let pdu = crate::build_initial_connector_pdu(request).expect("initial pdu");

    assert_eq!(pdu.after_state, "ConnectionInitiationWaitResponse");
    assert_eq!(&pdu.bytes[..2], &[0x03, 0x00]);
}

#[test]
fn server_nla_confirm_reaches_tls_upgrade_boundary_then_credssp() {
    let boundary =
        crate::drive_connector_to_credssp_boundary(open_request("EXAMPLE\\alice", "required"))
            .expect("boundary");

    assert_eq!(
        boundary.before_confirm_state,
        "ConnectionInitiationWaitResponse"
    );
    assert_eq!(boundary.after_confirm_state, "EnhancedSecurityUpgrade");
    assert!(boundary.requires_security_upgrade);
    assert_eq!(boundary.after_upgrade_state, "Credssp");
    assert!(boundary.requires_credssp);
}

#[test]
fn blocking_connect_begin_wrapper_reaches_tls_upgrade_boundary() {
    let boundary = crate::drive_blocking_connect_begin_to_tls_upgrade(open_request(
        "EXAMPLE\\alice",
        "required",
    ))
    .expect("boundary");

    assert_eq!(boundary.before_state, "ConnectionInitiationSendRequest");
    assert_eq!(boundary.after_state, "EnhancedSecurityUpgrade");
    assert!(boundary.requires_security_upgrade);
    assert!(!boundary.contains_cleartext_password);
    assert_eq!(&boundary.written_bytes[..2], &[0x03, 0x00]);
}

#[test]
fn live_blocking_connect_begin_reaches_tls_upgrade_boundary_when_configured() {
    let Some(target) = std::env::var("SERVICERADAR_RDP_LIVE_TARGET")
        .ok()
        .filter(|value| !value.trim().is_empty())
    else {
        eprintln!("skipping live RDP probe; SERVICERADAR_RDP_LIVE_TARGET is not set");
        return;
    };
    let (host, port) = parse_live_target(&target).expect("valid live RDP target");
    let mut request = open_request("EXAMPLE\\serviceradar-probe", "required");
    request.target.upstream.host = host;
    request.target.upstream.port = port;
    request.target.tls.server_name = std::env::var("SERVICERADAR_RDP_LIVE_SERVER_NAME")
        .ok()
        .filter(|value| !value.trim().is_empty())
        .unwrap_or_else(|| request.target.upstream.host.clone());

    let boundary =
        crate::drive_live_blocking_connect_begin_to_tls_upgrade(request, Duration::from_secs(5))
            .expect("live boundary");

    assert_eq!(boundary.before_state, "ConnectionInitiationSendRequest");
    assert_eq!(boundary.after_state, "EnhancedSecurityUpgrade");
    assert!(boundary.requires_security_upgrade);
    assert!(!boundary.contains_cleartext_password);
    assert_eq!(&boundary.written_bytes[..2], &[0x03, 0x00]);
}

#[test]
fn live_tls_upgrade_reaches_credssp_boundary_when_lab_insecure_is_enabled() {
    let Some(target) = std::env::var("SERVICERADAR_RDP_LIVE_TARGET")
        .ok()
        .filter(|value| !value.trim().is_empty())
    else {
        eprintln!("skipping live RDP TLS probe; SERVICERADAR_RDP_LIVE_TARGET is not set");
        return;
    };
    if std::env::var("SERVICERADAR_RDP_LIVE_TLS_INSECURE_ACCEPT_INVALID_CERTS").as_deref()
        != Ok("1")
    {
        eprintln!(
            "skipping live RDP TLS probe; \
                 SERVICERADAR_RDP_LIVE_TLS_INSECURE_ACCEPT_INVALID_CERTS=1 is required"
        );
        return;
    }

    let (host, port) = parse_live_target(&target).expect("valid live RDP target");
    let mut request = open_request("EXAMPLE\\serviceradar-probe", "required");
    request.target.upstream.host = host;
    request.target.upstream.port = port;
    request.target.tls.server_name = std::env::var("SERVICERADAR_RDP_LIVE_SERVER_NAME")
        .ok()
        .filter(|value| !value.trim().is_empty())
        .unwrap_or_else(|| request.target.upstream.host.clone());

    let probe = crate::drive_live_tls_upgrade_accepting_invalid_certificates_for_lab(
        request,
        Duration::from_secs(5),
    )
    .expect("live TLS upgrade");

    assert_eq!(probe.before_state, "ConnectionInitiationSendRequest");
    assert_eq!(probe.after_begin_state, "EnhancedSecurityUpgrade");
    assert_eq!(probe.after_upgrade_state, "Credssp");
    assert!(probe.peer_certificate_count > 0);
    assert!(probe.server_public_key_len > 0);
    assert!(probe.wrote_tls_bytes);
    assert!(!probe.contains_cleartext_password);
}

#[test]
fn live_verified_tls_upgrade_reaches_credssp_boundary_when_configured() {
    let Some(target) = std::env::var("SERVICERADAR_RDP_LIVE_TARGET")
        .ok()
        .filter(|value| !value.trim().is_empty())
    else {
        eprintln!("skipping live verified RDP TLS probe; SERVICERADAR_RDP_LIVE_TARGET is not set");
        return;
    };
    let Some(ca_bundle_file) = std::env::var("SERVICERADAR_RDP_LIVE_CA_BUNDLE_FILE")
        .ok()
        .filter(|value| !value.trim().is_empty())
    else {
        eprintln!(
            "skipping live verified RDP TLS probe; \
                 SERVICERADAR_RDP_LIVE_CA_BUNDLE_FILE is not set"
        );
        return;
    };

    let ca_bundle = std::fs::read(&ca_bundle_file).expect("read live CA bundle");
    let (host, port) = parse_live_target(&target).expect("valid live RDP target");
    let mut request = open_request("EXAMPLE\\serviceradar-probe", "required");
    request.target.upstream.host = host;
    request.target.upstream.port = port;
    request.target.tls.server_name = std::env::var("SERVICERADAR_RDP_LIVE_SERVER_NAME")
        .ok()
        .filter(|value| !value.trim().is_empty())
        .unwrap_or_else(|| request.target.upstream.host.clone());
    request.target.tls.ca_bundle_id = "live-ca-bundle-file".to_owned();

    let probe = crate::drive_live_tls_upgrade_with_registered_ca_bundle(
        request,
        &ca_bundle,
        Duration::from_secs(5),
    )
    .expect("live verified TLS upgrade");

    assert_eq!(probe.before_state, "ConnectionInitiationSendRequest");
    assert_eq!(probe.after_begin_state, "EnhancedSecurityUpgrade");
    assert_eq!(probe.after_upgrade_state, "Credssp");
    assert!(probe.peer_certificate_count > 0);
    assert!(probe.server_public_key_len > 0);
    assert!(probe.wrote_tls_bytes);
    assert!(!probe.contains_cleartext_password);
}

#[test]
fn extracts_tls_server_public_key_for_credssp_binding() {
    let public_key = crate::extract_credssp_server_public_key(&fixture_server_cert_der())
        .expect("server public key");

    assert_eq!(public_key.len(), 270);
    assert_eq!(&public_key[..2], &[0x30, 0x82]);
}

#[test]
fn rejects_invalid_tls_server_certificate_for_credssp_binding() {
    let err = crate::extract_credssp_server_public_key(b"not a certificate").unwrap_err();

    assert_eq!(err, "tls peer certificate decode failed");
}

#[test]
fn blocking_connect_finalize_writes_credssp_without_cleartext_password() {
    let server_public_key = crate::extract_credssp_server_public_key(&fixture_server_cert_der())
        .expect("server public key");
    let finalize = crate::drive_blocking_connect_finalize_until_server_input(
        open_request("EXAMPLE\\alice", "required"),
        server_public_key,
    )
    .expect("finalize probe");

    assert_eq!(finalize.after_upgrade_state, "Credssp");
    assert!(finalize.wrote_credssp_bytes);
    assert!(!finalize.contains_cleartext_password);
    assert!(!finalize
        .written_bytes
        .windows(b"secret".len())
        .any(|window| window == b"secret"));
}

#[test]
fn server_hybrid_confirm_reaches_tls_upgrade_boundary_then_credssp() {
    let boundary = crate::drive_connector_with_server_protocol(
        open_request("EXAMPLE\\alice", "required"),
        ironrdp_pdu::nego::SecurityProtocol::HYBRID,
    )
    .expect("boundary");

    assert_eq!(boundary.after_confirm_state, "EnhancedSecurityUpgrade");
    assert!(boundary.requires_security_upgrade);
    assert_eq!(boundary.after_upgrade_state, "Credssp");
    assert!(boundary.requires_credssp);
}

#[test]
fn server_tls_only_confirm_is_rejected_as_downgrade() {
    let err = crate::drive_connector_with_server_protocol(
        open_request("EXAMPLE\\alice", "required"),
        ironrdp_pdu::nego::SecurityProtocol::SSL,
    )
    .unwrap_err();

    assert_eq!(err, "server confirm step failed");
}

#[test]
fn server_standard_rdp_confirm_is_rejected() {
    let err = crate::drive_connector_with_server_protocol(
        open_request("EXAMPLE\\alice", "required"),
        ironrdp_pdu::nego::SecurityProtocol::empty(),
    )
    .unwrap_err();

    assert_eq!(err, "server confirm step failed");
}

#[test]
fn rejects_unknown_open_payload_fields() {
    let raw = valid_open_payload().replace(
        r#""schema":"serviceradar.rdp.helper.open.v1","#,
        r#""schema":"serviceradar.rdp.helper.open.v1","unexpected":true,"#,
    );
    let err = crate::parse_service_radar_open_request(raw.as_bytes()).unwrap_err();

    assert_eq!(err, "open payload decode failed");
}

fn open_request(username: &str, nla_mode: &str) -> crate::ServiceRadarOpenRequest {
    crate::ServiceRadarOpenRequest {
        schema: OPEN_SCHEMA.to_owned(),
        session_id: "session-1".to_owned(),
        local_agent_id: "agent-1".to_owned(),
        gateway_id: "gateway-1".to_owned(),
        start_unix: 1_778_636_531,
        target: crate::ServiceRadarTarget {
            target_id: "target-1".to_owned(),
            display_name: "Windows VM".to_owned(),
            device_uid: "device-1".to_owned(),
            protocol: "rdp".to_owned(),
            route: crate::ServiceRadarRoute {
                selected_agent_id: "agent-1".to_owned(),
                selected_gateway_id: "gateway-1".to_owned(),
                allowed_agent_ids: Vec::new(),
            },
            upstream: crate::ServiceRadarUpstream {
                host: "win.example".to_owned(),
                port: 3389,
            },
            screen: crate::ServiceRadarScreenPolicy {
                max_width: 1920,
                max_height: 1080,
                color_depth: 32,
                frame_rate: 30,
                bitrate_bps: 8_000_000,
                idle_seconds: 900,
                ttl_seconds: 3600,
            },
            tls: crate::ServiceRadarTlsPolicy {
                mode: "verify".to_owned(),
                ca_bundle_id: String::new(),
                nla_mode: nla_mode.to_owned(),
                server_name: "win.example".to_owned(),
            },
            credential: crate::ServiceRadarCredentialPolicy {
                mode: "memory_user".to_owned(),
                allowed_principals: vec![username.to_owned()],
                credential_secret_ref: String::new(),
            },
            redirection: crate::ServiceRadarRedirectionPolicy {
                clipboard_mode: "disabled".to_owned(),
                drive: false,
                printer: false,
                audio: false,
                smart_card: false,
                file_copy: false,
            },
            recording: crate::ServiceRadarRecordingPolicy {
                metadata_enabled: true,
                screen_enabled: false,
                clipboard_enabled: false,
                file_enabled: false,
                audio_enabled: false,
            },
            approval_required: false,
            metadata: BTreeMap::new(),
        },
        credential_grant: crate::ServiceRadarCredentialGrant {
            mode: "memory_user".to_owned(),
            username: username.to_owned(),
            password: "secret".to_owned(),
            credential_secret_ref: String::new(),
            actor_id: "user-1".to_owned(),
            session_id: "session-1".to_owned(),
            target_id: "target-1".to_owned(),
            route_id: "agent-1".to_owned(),
            expires_unix: 1_778_640_000,
        },
    }
}

fn valid_open_payload() -> String {
    r#"{
            "schema":"serviceradar.rdp.helper.open.v1",
            "session_id":"session-1",
            "local_agent_id":"agent-1",
            "gateway_id":"gateway-1",
            "start_unix":1778636531,
            "target":{
                "target_id":"target-1",
                "display_name":"Windows VM",
                "device_uid":"device-1",
                "protocol":"rdp",
                "route":{"selected_agent_id":"agent-1","selected_gateway_id":"gateway-1"},
                "upstream":{"host":"win.example","port":3389},
                "tls":{"mode":"verify","nla_mode":"required","server_name":"win.example"},
                "credential":{"mode":"memory_user","allowed_principals":["alice"]},
                "screen":{"max_width":1920,"max_height":1080,"frame_rate":30,"bitrate_bps":8000000,"idle_seconds":900,"ttl_seconds":3600},
                "redirection":{"clipboard_mode":"disabled"},
                "recording":{"metadata_enabled":true}
            },
            "credential_grant":{"mode":"memory_user","username":"alice","password":"secret","session_id":"session-1","target_id":"target-1","route_id":"agent-1"}
        }"#
        .to_owned()
}

fn parse_live_target(raw: &str) -> Result<(String, u16), &'static str> {
    let trimmed = raw.trim();
    if trimmed.is_empty() {
        return Err("live RDP target is empty");
    }

    if let Some((host, port)) = trimmed.rsplit_once(':') {
        let port = port
            .parse()
            .map_err(|_| "live RDP target port is invalid")?;
        if host.is_empty() || port == 0 {
            return Err("live RDP target is invalid");
        }

        return Ok((host.to_owned(), port));
    }

    Ok((trimmed.to_owned(), 3389))
}

fn fixture_server_cert_der() -> Vec<u8> {
    STANDARD
            .decode(
                "MIIDDTCCAfWgAwIBAgIUFaHwQBAFyvmfso6OPbcQ+2/fVSUwDQYJKoZIhvcNAQELBQAwFjEUMBIGA1UEAwwLd2luLmV4YW1wbGUwHhcNMjYwNTE2MTYzNzQ3WhcNMjYwNTE3MTYzNzQ3WjAWMRQwEgYDVQQDDAt3aW4uZXhhbXBsZTCCASIwDQYJKoZIhvcNAQEBBQADggEPADCCAQoCggEBALbcS3SPVJlbV5AwbziMjXX0Z5CXcOIMt67zeIzoh6hmiAou1IIVZ14FrWStQj4kJNcAwdYQWtZcjM0ya6Hx3fd/M4H3FIatWkrlZcwDtxPeMHxoLzJ0mP/yLdacyvjfKqQDn8f0JEd4KY5dN1eD/OFBGF+XuQyIBsAom6SFuo7uZA4+HmC01P5ac0zAyJKOVDpgdBWa9FYn+YszqAwjrRau1m4A8K5BgRPDBs1FQwjGhRGePEuRgOKsHdBGq/PJ1Iw4mES4pwStTgGvFHJnIPxxZHX0WHiDZnbNx+K+HJh0eaWEjYUazuQtvsyllNM6KmZIHb/bgcZ0VTRQZ87l9lUCAwEAAaNTMFEwHQYDVR0OBBYEFOEi76jfCExGDeYivuwXNMm6uGnAMB8GA1UdIwQYMBaAFOEi76jfCExGDeYivuwXNMm6uGnAMA8GA1UdEwEB/wQFMAMBAf8wDQYJKoZIhvcNAQELBQADggEBAI6IdjMvys+AEAoeZ31Lo0IbMsM4EChsvXwpE9BZ5zuPEtRwxoxLwVKrhfjkQjuX6CWFcMlWPvUqKU4t8G3b6/5ym67vJqYkLXgF5UG5Aj7AuiLIY6j8zBcZ4dFsx7hheXZC4em5e6D16eDgATWEBKf/kfbmnX8EET5gkqolAjYI4D1M3gT5yJrulhNmfXThW5A2Vvn70AhsrhMylogKRejaMOelRi1XA0AAXkZ53JWNTCJLJtRg/6PAeyT6nJwpTZi1iKJs0gRTv2TAnUFKeVfDV1CE63YM8953dq+xwqmrTmyZabWJb6yAXEepIUPMscB2UcHKFAqgWZ+4herSzfY=",
            )
            .expect("fixture certificate")
}

fn fixture_server_cert_pem() -> String {
    let body = STANDARD.encode(fixture_server_cert_der());
    let mut pem = String::from("-----BEGIN CERTIFICATE-----\n");
    for chunk in body.as_bytes().chunks(64) {
        pem.push_str(std::str::from_utf8(chunk).expect("base64 is utf8"));
        pem.push('\n');
    }
    pem.push_str("-----END CERTIFICATE-----\n");

    pem
}

#[test]
fn parse_registered_ca_bundle_rejects_empty_input() {
    let err = super::parse_registered_ca_bundle(b"").expect_err("empty CA bundle must be refused");
    assert!(
        err.starts_with("ca_bundle_invalid"),
        "unexpected error: {err}"
    );
}

#[test]
fn parse_registered_ca_bundle_rejects_raw_der_bytes() {
    // Audit finding 1.A2.1: a CA bundle whose body lacks a PEM marker
    // (raw DER, binary corruption, junk) MUST be refused with a structured
    // ca_bundle_invalid reason instead of being wrapped as a CertificateDer
    // and forwarded to rustls, which would later reject it opaquely.
    let der = fixture_server_cert_der();
    let err = super::parse_registered_ca_bundle(&der)
        .expect_err("raw DER bytes must be refused, no fallback path");
    assert!(
        err.starts_with("ca_bundle_invalid"),
        "unexpected error: {err}"
    );
    assert!(
        err.contains("not PEM-encoded"),
        "error must explain the cause: {err}"
    );
}

#[test]
fn parse_registered_ca_bundle_rejects_garbage_bytes() {
    let err = super::parse_registered_ca_bundle(b"\x00\x01\x02not a certificate\xff\xfe")
        .expect_err("non-PEM garbage must be refused");
    assert!(
        err.starts_with("ca_bundle_invalid"),
        "unexpected error: {err}"
    );
}

#[test]
fn parse_registered_ca_bundle_accepts_valid_pem() {
    let pem = fixture_server_cert_pem();
    let certs =
        super::parse_registered_ca_bundle(pem.as_bytes()).expect("valid PEM bundle must parse");
    assert_eq!(certs.len(), 1, "fixture is a single certificate");
}
