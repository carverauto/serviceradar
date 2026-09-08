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
