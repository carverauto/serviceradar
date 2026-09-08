use super::*;

#[test]
fn parse_open_payload_rejects_unsupported_schema() {
    let raw = valid_open_payload().replace(
        r#""schema":"serviceradar.rdp.helper.open.v1""#,
        r#""schema":"wrong""#,
    );
    let err = parse_open_payload(raw.as_bytes()).expect_err("schema rejected");

    assert_eq!(err, OpenPayloadError::InvalidSchema);
}

#[test]
fn parse_open_payload_rejects_missing_actor_binding() {
    let raw = valid_open_payload().replace(r#""actor_id":"user-1","#, "");
    let err = parse_open_payload(raw.as_bytes()).expect_err("actor rejected");

    assert_eq!(err, OpenPayloadError::MissingActor);
}

#[test]
fn parse_open_payload_rejects_grant_actor_mismatch() {
    let raw = valid_open_payload().replace(
        r#""actor_id":"user-1","session_id":"session-1""#,
        r#""actor_id":"user-2","session_id":"session-1""#,
    );
    let err = parse_open_payload(raw.as_bytes()).expect_err("credential rejected");

    assert_eq!(err, OpenPayloadError::InvalidCredentialGrant);
}

#[test]
fn parse_open_payload_rejects_memory_user_missing_password() {
    let raw = valid_open_payload().replace(r#""password":"secret","#, "");
    let err = parse_open_payload(raw.as_bytes()).expect_err("credential rejected");

    assert_eq!(err, OpenPayloadError::InvalidCredentialGrant);
}

#[test]
fn parse_open_payload_rejects_brokered_secret_with_password() {
    let raw = r#"{
            "schema":"serviceradar.rdp.helper.open.v1",
            "session_id":"session-1",
            "actor_id":"user-1",
            "local_agent_id":"agent-1",
            "start_unix":1778636531,
            "target":{
                "target_id":"target-1",
                "protocol":"rdp",
                "route":{"selected_agent_id":"agent-1"},
                "upstream":{"host":"win.example","port":3389},
                "tls":{"mode":"verify","nla_mode":"required"},
                "credential":{"mode":"brokered_secret","credential_secret_ref":"secret/ref"},
                "screen":{"max_width":1920,"max_height":1080,"frame_rate":30,"bitrate_bps":8000000,"idle_seconds":900,"ttl_seconds":3600},
                "redirection":{"clipboard_mode":"disabled"},
                "recording":{"metadata_enabled":true}
            },
            "credential_grant":{
                "mode":"brokered_secret",
                "credential_secret_ref":"secret/ref",
                "password":"not-allowed",
                "actor_id":"user-1",
                "session_id":"session-1",
                "target_id":"target-1",
                "route_id":"route-1",
                "expires_unix":1778640000
            }
        }"#;
    let err = parse_open_payload(raw.as_bytes()).expect_err("credential rejected");

    assert_eq!(err, OpenPayloadError::InvalidCredentialGrant);
}

#[test]
fn parse_open_payload_rejects_grant_session_mismatch() {
    let raw = valid_open_payload().replace(
        r#""session_id":"session-1","target_id":"target-1""#,
        r#""session_id":"other-session","target_id":"target-1""#,
    );
    let err = parse_open_payload(raw.as_bytes()).expect_err("credential rejected");

    assert_eq!(err, OpenPayloadError::InvalidCredentialGrant);
}

#[test]
fn parse_open_payload_rejects_memory_user_missing_binding() {
    let raw =
        valid_open_payload().replace(r#","session_id":"session-1","target_id":"target-1""#, "");
    let err = parse_open_payload(raw.as_bytes()).expect_err("credential rejected");

    assert_eq!(err, OpenPayloadError::InvalidCredentialGrant);
}

#[test]
fn parse_open_payload_rejects_memory_user_target_mismatch() {
    let raw = valid_open_payload().replace(
        r#""session_id":"session-1","target_id":"target-1""#,
        r#""session_id":"session-1","target_id":"other-target""#,
    );
    let err = parse_open_payload(raw.as_bytes()).expect_err("credential rejected");

    assert_eq!(err, OpenPayloadError::InvalidCredentialGrant);
}

#[test]
fn parse_open_payload_rejects_route_mismatch() {
    let raw = valid_open_payload().replace(
        r#""local_agent_id":"agent-1""#,
        r#""local_agent_id":"agent-2""#,
    );
    let err = parse_open_payload(raw.as_bytes()).expect_err("route rejected");

    assert_eq!(err, OpenPayloadError::MissingRoute);
}

#[test]
fn parse_open_payload_rejects_invalid_start_timestamp() {
    let raw = valid_open_payload().replace(r#""start_unix":1778636531"#, r#""start_unix":0"#);
    let err = parse_open_payload(raw.as_bytes()).expect_err("session policy rejected");

    assert_eq!(err, OpenPayloadError::InvalidSessionPolicy);
}

#[test]
fn parse_open_payload_rejects_selected_agent_outside_allowed_route_set() {
    let raw = valid_open_payload().replace(
            r#""route":{"selected_agent_id":"agent-1","selected_gateway_id":"gateway-1"}"#,
            r#""route":{"selected_agent_id":"agent-1","selected_gateway_id":"gateway-1","allowed_agent_ids":["agent-2"]}"#,
        );
    let err = parse_open_payload(raw.as_bytes()).expect_err("route allowlist rejected");

    assert_eq!(err, OpenPayloadError::MissingRoute);
}

#[test]
fn parse_open_payload_rejects_unsupported_tls_policy() {
    let raw = valid_open_payload().replace(
        r#""tls":{"mode":"verify","nla_mode":"required","server_name":"win.example"}"#,
        r#""tls":{"mode":"insecure","nla_mode":"disabled","server_name":"win.example"}"#,
    );
    let err = parse_open_payload(raw.as_bytes()).expect_err("tls policy rejected");

    assert_eq!(err, OpenPayloadError::UnsupportedTlsPolicy);
}

#[test]
fn parse_open_payload_rejects_pinned_ca_without_bundle_id() {
    let raw = valid_open_payload().replace(
        r#""tls":{"mode":"verify","nla_mode":"required","server_name":"win.example"}"#,
        r#""tls":{"mode":"pinned_ca","nla_mode":"required","server_name":"win.example"}"#,
    );
    let err = parse_open_payload(raw.as_bytes()).expect_err("tls policy rejected");

    assert_eq!(err, OpenPayloadError::UnsupportedTlsPolicy);
}

#[test]
fn parse_open_payload_rejects_ca_bundle_id_without_material() {
    let raw = valid_open_payload().replace(
            r#""tls":{"mode":"verify","nla_mode":"required","server_name":"win.example"}"#,
            r#""tls":{"mode":"verify","ca_bundle_id":"corp-rdp-ca","nla_mode":"required","server_name":"win.example"}"#,
        );
    let err = parse_open_payload(raw.as_bytes()).expect_err("tls policy rejected");

    assert_eq!(err, OpenPayloadError::UnsupportedTlsPolicy);
}

#[test]
fn parse_open_payload_rejects_ca_bundle_material_without_id() {
    let raw = valid_open_payload().replace(
            r#""tls":{"mode":"verify","nla_mode":"required","server_name":"win.example"}"#,
            r#""tls":{"mode":"verify","ca_bundle_pem":"-----BEGIN CERTIFICATE-----\nMIIB\n-----END CERTIFICATE-----","nla_mode":"required","server_name":"win.example"}"#,
        );
    let err = parse_open_payload(raw.as_bytes()).expect_err("tls policy rejected");

    assert_eq!(err, OpenPayloadError::UnsupportedTlsPolicy);
}

#[test]
fn parse_open_payload_rejects_whitespace_only_ca_bundle_pair() {
    let raw = valid_open_payload().replace(
            r#""tls":{"mode":"verify","nla_mode":"required","server_name":"win.example"}"#,
            r#""tls":{"mode":"verify","ca_bundle_id":"   ","ca_bundle_pem":"   ","nla_mode":"required","server_name":"win.example"}"#,
        );
    let err = parse_open_payload(raw.as_bytes()).expect_err("tls policy rejected");

    assert_eq!(err, OpenPayloadError::UnsupportedTlsPolicy);
}

#[test]
fn parse_open_payload_rejects_oversized_ca_bundle_material() {
    let oversized = "a".repeat(MAX_TLS_CA_BUNDLE_PEM_BYTES + 1);
    let replacement = format!(
        r#""tls":{{"mode":"verify","ca_bundle_id":"corp-rdp-ca","ca_bundle_pem":"{}","nla_mode":"required","server_name":"win.example"}}"#,
        oversized
    );
    let raw = valid_open_payload().replace(
        r#""tls":{"mode":"verify","nla_mode":"required","server_name":"win.example"}"#,
        &replacement,
    );
    let err = parse_open_payload(raw.as_bytes()).expect_err("tls policy rejected");

    assert_eq!(err, OpenPayloadError::Decode);
}

#[test]
fn parse_open_payload_rejects_unsupported_credential_policy() {
    let raw = valid_open_payload().replace(
        r#""credential":{"mode":"memory_user","allowed_principals":["alice"]}"#,
        r#""credential":{"mode":"domain_delegation","allowed_principals":["alice"]}"#,
    );
    let err = parse_open_payload(raw.as_bytes()).expect_err("credential policy rejected");

    assert_eq!(err, OpenPayloadError::UnsupportedCredentialMode);
}

#[test]
fn parse_open_payload_rejects_invalid_screen_policy() {
    let raw = valid_open_payload().replace(
            r#""screen":{"max_width":1920,"max_height":1080,"frame_rate":30,"bitrate_bps":8000000,"idle_seconds":900,"ttl_seconds":3600}"#,
            r#""screen":{"max_width":7681,"max_height":1080,"frame_rate":30,"bitrate_bps":8000000,"idle_seconds":900,"ttl_seconds":3600}"#,
        );
    let err = parse_open_payload(raw.as_bytes()).expect_err("screen policy rejected");

    assert_eq!(err, OpenPayloadError::InvalidScreenPolicy);
}

#[test]
fn parse_open_payload_rejects_unsupported_redirection_policy() {
    let raw = valid_open_payload().replace(
        r#""redirection":{"clipboard_mode":"disabled"}"#,
        r#""redirection":{"clipboard_mode":"text_bidirectional","drive":true}"#,
    );
    let err = parse_open_payload(raw.as_bytes()).expect_err("redirection policy rejected");

    assert_eq!(err, OpenPayloadError::UnsupportedRedirection);
}

#[test]
fn parse_open_payload_rejects_content_recording_policy() {
    let raw = valid_open_payload().replace(
        r#""recording":{"metadata_enabled":true}"#,
        r#""recording":{"metadata_enabled":true,"screen_enabled":true}"#,
    );
    let err = parse_open_payload(raw.as_bytes()).expect_err("recording policy rejected");

    assert_eq!(err, OpenPayloadError::UnsupportedRecordingPolicy);
}

#[test]
fn parse_open_payload_rejects_out_of_range_upstream_port() {
    let raw = valid_open_payload().replace(
        r#""upstream":{"host":"win.example","port":3389}"#,
        r#""upstream":{"host":"win.example","port":70000}"#,
    );
    let err = parse_open_payload(raw.as_bytes()).expect_err("upstream port rejected");

    assert_eq!(err, OpenPayloadError::MissingUpstream);
}
