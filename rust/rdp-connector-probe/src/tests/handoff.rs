use super::*;

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
