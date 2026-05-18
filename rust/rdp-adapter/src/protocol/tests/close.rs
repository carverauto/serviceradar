use super::*;

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
