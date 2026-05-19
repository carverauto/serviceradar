use super::*;

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
fn rejects_unknown_open_payload_fields() {
    let raw = valid_open_payload().replace(
        r#""schema":"serviceradar.rdp.helper.open.v1","#,
        r#""schema":"serviceradar.rdp.helper.open.v1","unexpected":true,"#,
    );
    let err = crate::parse_service_radar_open_request(raw.as_bytes()).unwrap_err();

    assert_eq!(err, "open payload decode failed");
}
