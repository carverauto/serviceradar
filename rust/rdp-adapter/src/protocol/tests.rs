use super::*;

pub(crate) fn valid_open_payload() -> String {
    r#"{
            "schema":"serviceradar.rdp.helper.open.v1",
            "session_id":"session-1",
            "actor_id":"user-1",
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
            "credential_grant":{"mode":"memory_user","username":"alice","password":"secret","actor_id":"user-1","session_id":"session-1","target_id":"target-1"}
        }"#
        .to_string()
}

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
    assert!(payload
        .target
        .tls
        .ca_bundle_pem
        .starts_with("-----BEGIN CERTIFICATE-----"));
}

#[test]
fn parse_desktop_media_ack_accepts_valid_ack_payload() {
    let ack = parse_desktop_media_ack(
            br#"{"type":"desktop_media_ack","session_binding_id":"session-1","media_session_id":"media-1","last_accepted_seq":7,"credit_bytes":8192,"quality_level":"low","pause":true}"#,
            "session-1",
        )
        .expect("valid ack");

    assert_eq!(ack.session_binding_id, "session-1");
    assert_eq!(ack.media_session_id, "media-1");
    assert_eq!(ack.last_accepted_seq, 7);
    assert_eq!(ack.credit_bytes, 8192);
    assert_eq!(ack.quality_level, "low");
    assert!(ack.pause);
}

#[test]
fn parse_desktop_media_ack_normalizes_close_reason() {
    let ack = parse_desktop_media_ack(
            br#"{"type":"desktop_media_ack","session_binding_id":"session-1","media_session_id":"media-1","last_accepted_seq":7,"credit_bytes":8192,"close_reason":" browser\nclosed\t"}"#,
            "session-1",
        )
        .expect("valid ack");

    assert_eq!(ack.close_reason, "browser closed");
}

#[test]
fn parse_desktop_media_ack_rejects_session_mismatch() {
    let err = parse_desktop_media_ack(
            br#"{"type":"desktop_media_ack","session_binding_id":"other-session","media_session_id":"media-1","last_accepted_seq":7,"credit_bytes":8192}"#,
            "session-1",
        )
        .expect_err("ack rejected");

    assert_eq!(err, DesktopMediaAckError::SessionMismatch);
}

#[test]
fn parse_desktop_media_ack_rejects_unsupported_quality() {
    let err = parse_desktop_media_ack(
            br#"{"type":"desktop_media_ack","session_binding_id":"session-1","media_session_id":"media-1","last_accepted_seq":7,"credit_bytes":8192,"quality_level":"ultra"}"#,
            "session-1",
        )
        .expect_err("ack rejected");

    assert_eq!(err, DesktopMediaAckError::UnsupportedQuality);
}

#[test]
fn parse_desktop_media_ack_rejects_oversized_credit() {
    let err = parse_desktop_media_ack(
            br#"{"type":"desktop_media_ack","session_binding_id":"session-1","media_session_id":"media-1","last_accepted_seq":7,"credit_bytes":4194305}"#,
            "session-1",
        )
        .expect_err("ack rejected");

    assert_eq!(err, DesktopMediaAckError::CreditTooLarge);
}

#[test]
fn parse_desktop_media_ack_rejects_ambiguous_pause_resume() {
    let err = parse_desktop_media_ack(
            br#"{"type":"desktop_media_ack","session_binding_id":"session-1","media_session_id":"media-1","last_accepted_seq":7,"credit_bytes":8192,"pause":true,"resume":true}"#,
            "session-1",
        )
        .expect_err("ack rejected");

    assert_eq!(err, DesktopMediaAckError::AmbiguousFlowControl);
}

#[test]
fn parse_desktop_frame_accepts_valid_input_payload() {
    let policy = test_screen_policy();
    let frame = parse_desktop_frame(
            br#"{"session_id":"session-1","protocol":"rdp","frame_type":"desktop.input","input":{"kind":"pointer","x":640,"y":360}}"#,
            "session-1",
            &policy,
        )
        .expect("valid frame");

    assert_eq!(frame.session_id, "session-1");
    assert_eq!(frame.frame_type, FRAME_TYPE_INPUT);
    assert_eq!(
        frame.input.as_ref().map(|input| input.kind.as_str()),
        Some(INPUT_KIND_POINTER)
    );
}

#[test]
fn parse_desktop_frame_rejects_session_mismatch() {
    let policy = test_screen_policy();
    let err = parse_desktop_frame(
            br#"{"session_id":"other-session","protocol":"rdp","frame_type":"desktop.input","input":{"kind":"key","key":"Enter"}}"#,
            "session-1",
            &policy,
        )
        .expect_err("frame rejected");

    assert_eq!(err, DesktopFrameError::SessionMismatch);
}

#[test]
fn parse_desktop_frame_rejects_pointer_out_of_bounds() {
    let policy = test_screen_policy();
    let err = parse_desktop_frame(
            br#"{"session_id":"session-1","protocol":"rdp","frame_type":"desktop.input","input":{"kind":"pointer","x":1920,"y":360}}"#,
            "session-1",
            &policy,
        )
        .expect_err("frame rejected");

    assert_eq!(err, DesktopFrameError::PointerOutOfBounds);
}

#[test]
fn parse_desktop_frame_rejects_quality_above_policy() {
    let policy = test_screen_policy();
    let err = parse_desktop_frame(
            br#"{"session_id":"session-1","protocol":"rdp","frame_type":"desktop.quality","quality":{"max_frame_rate":61}}"#,
            "session-1",
            &policy,
        )
        .expect_err("frame rejected");

    assert_eq!(err, DesktopFrameError::QualityExceedsPolicy);
}

#[test]
fn parse_desktop_frame_rejects_screen_update_on_input_channel() {
    let policy = test_screen_policy();
    let err = parse_desktop_frame(
            br#"{"session_id":"session-1","protocol":"rdp","frame_type":"desktop.update","width":640,"height":360}"#,
            "session-1",
            &policy,
        )
        .expect_err("frame rejected");

    assert_eq!(err, DesktopFrameError::UnsupportedFrameType);
}

#[test]
fn parse_desktop_frame_normalizes_disconnect_reason() {
    let policy = test_screen_policy();
    let frame = parse_desktop_frame(
            br#"{"session_id":"session-1","protocol":"rdp","frame_type":"desktop.disconnect","reason":" browser\ndisconnect\t"}"#,
            "session-1",
            &policy,
        )
        .expect("valid disconnect frame");

    assert_eq!(frame.reason, "browser disconnect");
}

#[test]
fn parse_desktop_close_payload_accepts_empty_or_reason_payload() {
    let empty = parse_desktop_close_payload(b"").expect("empty close payload");
    let reason =
        parse_desktop_close_payload(br#"{"reason":"operator"}"#).expect("reason close payload");

    assert_eq!(empty, DesktopClosePayload::default());
    assert_eq!(
        reason,
        DesktopClosePayload {
            reason: "operator".to_owned()
        }
    );
}

#[test]
fn parse_desktop_close_payload_normalizes_reason() {
    let close = parse_desktop_close_payload(br#"{"reason":" operator\nclosed\t"}"#)
        .expect("valid close payload");

    assert_eq!(
        close,
        DesktopClosePayload {
            reason: "operator closed".to_owned()
        }
    );
}

#[test]
fn parse_desktop_close_payload_rejects_oversized_reason() {
    let reason = "x".repeat(MAX_CLOSE_REASON_BYTES + 1);
    let err = parse_desktop_close_payload(format!(r#"{{"reason":"{reason}"}}"#).as_bytes())
        .expect_err("close payload rejected");

    assert_eq!(err, DesktopClosePayloadError::ReasonTooLarge);
}

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

#[test]
fn credential_grant_clear_sensitive_drops_user_material() {
    let mut payload = parse_open_payload(valid_open_payload().as_bytes()).expect("valid payload");
    let grant = payload.credential_grant.as_mut().expect("credential grant");

    grant.clear_sensitive();

    assert!(grant.username.is_empty());
    assert!(grant.password.is_empty());
    assert!(grant.credential_secret_ref.is_empty());
}

#[test]
fn sensitive_string_debug_is_redacted() {
    let secret = SensitiveString::from("secret".to_string());

    assert_eq!(format!("{secret:?}"), "<redacted>");
}

#[test]
fn sensitive_string_expose_rejects_invalid_utf8() {
    let secret = SensitiveString { value: vec![0xff] };

    assert!(secret.expose().is_err());
}

fn test_screen_policy() -> DesktopScreenPolicy {
    DesktopScreenPolicy {
        max_width: 1920,
        max_height: 1080,
        color_depth: 0,
        frame_rate: 30,
        bitrate_bps: 8_000_000,
        idle_seconds: 900,
        ttl_seconds: 3600,
    }
}
