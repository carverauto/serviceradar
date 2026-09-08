use super::*;

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
