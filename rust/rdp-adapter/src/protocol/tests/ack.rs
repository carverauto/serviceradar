use super::*;

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
