use super::*;

#[test]
fn parse_open_payload_accepts_valid_memory_user_payload() {
    let payload = parse_open_payload(valid_open_payload().as_bytes()).expect("valid payload");

    assert_eq!(payload.session_id, "session-1");
    assert_eq!(payload.target.upstream.host, "win.example");
    assert_eq!(
        payload
            .credential_grant
            .as_ref()
            .map(|grant| grant.username.as_str()),
        Some("alice")
    );
}

#[test]
fn parse_open_payload_accepts_verify_ca_bundle_material() {
    let raw = valid_open_payload().replace(
            r#""tls":{"mode":"verify","nla_mode":"required","server_name":"win.example"}"#,
            r#""tls":{"mode":"verify","ca_bundle_id":"corp-rdp-ca","ca_bundle_pem":"-----BEGIN CERTIFICATE-----\nMIIB\n-----END CERTIFICATE-----","nla_mode":"required","server_name":"win.example"}"#,
        );
    let payload = parse_open_payload(raw.as_bytes()).expect("valid payload");

    assert_eq!(payload.target.tls.ca_bundle_id, "corp-rdp-ca");
    assert!(
        payload
            .target
            .tls
            .ca_bundle_pem
            .starts_with("-----BEGIN CERTIFICATE-----")
    );
}
