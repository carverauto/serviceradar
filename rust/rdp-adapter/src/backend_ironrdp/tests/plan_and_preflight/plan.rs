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
fn nonsecret_connection_plan_accepts_ip_literal_tls_server_name() {
    let raw = valid_open_payload().replace(
        r#""tls":{"mode":"verify","nla_mode":"required","server_name":"win.example"}"#,
        r#""tls":{"mode":"verify","nla_mode":"required","server_name":"192.168.1.45"}"#,
    );
    let payload = parse_open_payload(raw.as_bytes()).expect("valid payload");

    let plan = build_nonsecret_connection_plan(&payload).expect("plan");

    assert_eq!(plan.tls_server_name, "192.168.1.45");
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
    assert_eq!(kerberos.hostname, "win.example");
}

#[cfg(serviceradar_rdp_connector_link_probe)]
#[test]
fn connector_probe_plan_rejects_invalid_kdc_proxy_url() {
    let mut payload = parse_open_payload(valid_open_payload().as_bytes()).expect("payload");
    payload
        .target
        .metadata
        .insert(METADATA_KDC_PROXY_URL.to_owned(), "not a url".to_owned());
    payload.target.metadata.insert(
        METADATA_KERBEROS_HOSTNAME.to_owned(),
        "win.example".to_owned(),
    );
    let plan = build_nonsecret_connection_plan(&payload).expect("plan");

    let err = match build_connector_kerberos_config_for_plan(&plan) {
        Ok(_) => panic!("invalid KDC proxy URL accepted"),
        Err(err) => err,
    };

    assert_eq!(err, BackendError::Unsupported(INVALID_CONNECTION_PLAN));
}

#[cfg(serviceradar_rdp_connector_link_probe)]
#[test]
fn connector_probe_kdc_proxy_requires_kerberos_hostname() {
    let mut payload = parse_open_payload(valid_open_payload().as_bytes()).expect("payload");
    payload.target.metadata.insert(
        METADATA_KDC_PROXY_URL.to_owned(),
        "tcp://kdc.example:88".to_owned(),
    );
    let plan = build_nonsecret_connection_plan(&payload).expect("plan");

    let err = build_connector_kerberos_config_for_plan(&plan)
        .expect_err("KDC proxy without a Kerberos hostname accepted");

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
    drifted.as_mut().expect("Kerberos config present").hostname = "changed.example".to_owned();

    let err = validate_connector_kerberos_binding(&binding, &drifted).expect_err("drift");

    assert!(matches!(
        err,
        BackendError::Unsupported(INVALID_CONNECTION_PLAN)
    ));
}
