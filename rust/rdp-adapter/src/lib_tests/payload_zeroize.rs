use super::*;

#[test]
fn parse_and_clear_open_payload_zeroizes_raw_credential_frame() {
    let mut payload = protocol::tests::valid_open_payload().into_bytes();
    assert!(
        payload
            .windows(b"secret".len())
            .any(|window| window == b"secret")
    );

    let parsed = parse_and_clear_open_payload(&mut payload).expect("valid payload");

    assert_eq!(
        parsed
            .credential_grant
            .as_ref()
            .and_then(|grant| grant.password.expose().ok()),
        Some("secret")
    );
    assert!(payload.iter().all(|byte| *byte == 0));
}

#[test]
fn parse_and_clear_open_payload_zeroizes_invalid_raw_frame() {
    let mut payload = br#"{"schema":"wrong","credential_grant":{"password":"secret"}}"#.to_vec();

    let err = parse_and_clear_open_payload(&mut payload).expect_err("payload rejected");

    assert!(matches!(err, protocol::OpenPayloadError::Decode));
    assert!(payload.iter().all(|byte| *byte == 0));
}

#[test]
fn parse_and_clear_input_payload_zeroizes_raw_input_frame() {
    let policy = input_test_policy();
    let mut payload = valid_input_payload().into_bytes();
    assert!(
        payload
            .windows(b"Enter".len())
            .any(|window| window == b"Enter")
    );

    let frame =
        parse_and_clear_input_payload(&mut payload, "session-1", &policy).expect("valid input");

    assert_eq!(frame.session_id, "session-1");
    assert_eq!(frame.frame_type, "desktop.input");
    assert!(payload.iter().all(|byte| *byte == 0));
}

#[test]
fn parse_and_clear_input_payload_zeroizes_invalid_raw_input_frame() {
    let policy = input_test_policy();
    let mut payload =
            br#"{"session_id":"other-session","protocol":"rdp","frame_type":"desktop.input","input":{"kind":"key","key":"Enter","down":true}}"#.to_vec();

    let err = parse_and_clear_input_payload(&mut payload, "session-1", &policy)
        .expect_err("input rejected");

    assert!(matches!(err, protocol::DesktopFrameError::SessionMismatch));
    assert!(payload.iter().all(|byte| *byte == 0));
}

#[test]
fn parse_and_clear_ack_payload_zeroizes_raw_ack_frame() {
    let mut payload = valid_ack_payload().into_bytes();
    assert!(
        payload
            .windows(b"browser close".len())
            .any(|window| window == b"browser close")
    );

    let ack = parse_and_clear_ack_payload(&mut payload, "session-1").expect("valid ack");

    assert_eq!(ack.session_binding_id, "session-1");
    assert_eq!(ack.media_session_id, "media-1");
    assert_eq!(ack.last_accepted_seq, 7);
    assert!(payload.iter().all(|byte| *byte == 0));
}

#[test]
fn parse_and_clear_ack_payload_zeroizes_invalid_raw_ack_frame() {
    let mut payload =
            br#"{"type":"wrong","session_binding_id":"session-1","media_session_id":"media-1","last_accepted_seq":7,"credit_bytes":8192,"close_reason":"browser close"}"#.to_vec();

    let err = parse_and_clear_ack_payload(&mut payload, "session-1").expect_err("ack rejected");

    assert!(matches!(err, protocol::DesktopMediaAckError::InvalidType));
    assert!(payload.iter().all(|byte| *byte == 0));
}

#[test]
fn parse_and_clear_ack_payload_normalizes_close_reason_before_backend() {
    let mut payload =
            br#"{"type":"desktop_media_ack","session_binding_id":"session-1","media_session_id":"media-1","last_accepted_seq":7,"credit_bytes":8192,"close_reason":" browser\nclosed\t"}"#.to_vec();

    let ack = parse_and_clear_ack_payload(&mut payload, "session-1").expect("valid ack");

    assert_eq!(ack.close_reason, "browser closed");
    assert!(payload.iter().all(|byte| *byte == 0));
}

#[test]
fn parse_and_clear_close_payload_zeroizes_raw_close_frame() {
    let mut payload = br#"{"reason":"operator close"}"#.to_vec();
    assert!(
        payload
            .windows(b"operator close".len())
            .any(|window| window == b"operator close")
    );

    let close = parse_and_clear_close_payload(&mut payload).expect("valid close");

    assert_eq!(close.reason, "operator close");
    assert!(payload.iter().all(|byte| *byte == 0));
}

#[test]
fn parse_and_clear_close_payload_normalizes_reason_before_backend() {
    let mut payload = br#"{"reason":" operator\nclosed\t"}"#.to_vec();

    let close = parse_and_clear_close_payload(&mut payload).expect("valid close");

    assert_eq!(close.reason, "operator closed");
    assert!(payload.iter().all(|byte| *byte == 0));
}

#[test]
fn parse_and_clear_close_payload_zeroizes_invalid_raw_close_frame() {
    let reason = "x".repeat(257);
    let mut payload = format!(r#"{{"reason":"{reason}"}}"#).into_bytes();

    let err = parse_and_clear_close_payload(&mut payload).expect_err("close rejected");

    assert!(matches!(
        err,
        protocol::DesktopClosePayloadError::ReasonTooLarge
    ));
    assert!(payload.iter().all(|byte| *byte == 0));
}
