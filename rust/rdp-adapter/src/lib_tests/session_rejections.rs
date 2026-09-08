use super::*;

#[test]
fn run_stdio_rejects_invalid_input_before_backend_session() {
    let mut input = Vec::new();
    write_frame(
        &mut input,
        MSG_OPEN,
        protocol::tests::valid_open_payload().as_bytes(),
    )
    .expect("write open frame");
    write_frame(
            &mut input,
            MSG_INPUT,
            br#"{"session_id":"session-1","protocol":"rdp","frame_type":"desktop.input","input":{"kind":"pointer","x":9999,"y":1}}"#,
        )
        .expect("write input frame");

    let state = Rc::new(RefCell::new(RecordingState::default()));
    let mut output = Vec::new();
    let mut backend = RecordingBackend {
        state: Rc::clone(&state),
    };

    let err = run_stdio_with_backend(&mut input.as_slice(), &mut output, &mut backend)
        .expect_err("input rejected");

    assert!(matches!(
        err,
        ProtocolError::InvalidInputPayload(protocol::DesktopFrameError::PointerOutOfBounds)
    ));
    assert!(state.borrow().input_frames.is_empty());
    assert_eq!(
        read_frame(&mut output.as_slice()).expect("read error frame"),
        Some(Frame {
            message_type: MSG_ERROR,
            payload: b"invalid rdp helper input payload".to_vec(),
        })
    );
}

#[test]
fn run_stdio_rejects_invalid_ack_before_backend_session() {
    let mut input = Vec::new();
    write_frame(
        &mut input,
        MSG_OPEN,
        protocol::tests::valid_open_payload().as_bytes(),
    )
    .expect("write open frame");
    write_frame(
            &mut input,
            MSG_ACK,
            br#"{"type":"desktop_media_ack","session_binding_id":"other-session","media_session_id":"media-1","last_accepted_seq":7,"credit_bytes":8192}"#,
        )
        .expect("write ack frame");

    let state = Rc::new(RefCell::new(RecordingState::default()));
    let mut output = Vec::new();
    let mut backend = RecordingBackend {
        state: Rc::clone(&state),
    };

    let err = run_stdio_with_backend(&mut input.as_slice(), &mut output, &mut backend)
        .expect_err("ack rejected");

    assert!(matches!(
        err,
        ProtocolError::InvalidAckPayload(protocol::DesktopMediaAckError::SessionMismatch)
    ));
    assert!(state.borrow().acks.is_empty());
    assert_eq!(
        read_frame(&mut output.as_slice()).expect("read error frame"),
        Some(Frame {
            message_type: MSG_ERROR,
            payload: b"invalid rdp helper ack payload".to_vec(),
        })
    );
}

#[test]
fn run_stdio_rejects_excessive_session_ack_credit_before_backend_session() {
    let mut input = Vec::new();
    write_frame(
        &mut input,
        MSG_OPEN,
        protocol::tests::valid_open_payload().as_bytes(),
    )
    .expect("write open frame");
    let max_ack_payload =
        valid_ack_payload().replace(r#""credit_bytes":8192"#, r#""credit_bytes":4194304"#);
    for _ in 0..17 {
        write_frame(&mut input, MSG_ACK, max_ack_payload.as_bytes()).expect("write ack frame");
    }

    let state = Rc::new(RefCell::new(RecordingState::default()));
    let mut output = Vec::new();
    let mut backend = RecordingBackend {
        state: Rc::clone(&state),
    };

    let err = run_stdio_with_backend(&mut input.as_slice(), &mut output, &mut backend)
        .expect_err("ack rejected");

    assert!(matches!(
        err,
        ProtocolError::InvalidAckPayload(protocol::DesktopMediaAckError::CreditTooLarge)
    ));
    assert_eq!(state.borrow().acks.len(), 16);
    assert_eq!(
        read_frame(&mut output.as_slice()).expect("read error frame"),
        Some(Frame {
            message_type: MSG_ERROR,
            payload: b"invalid rdp helper ack payload".to_vec(),
        })
    );
}

#[test]
fn run_stdio_rejects_invalid_close_before_backend_session() {
    let mut input = Vec::new();
    write_frame(
        &mut input,
        MSG_OPEN,
        protocol::tests::valid_open_payload().as_bytes(),
    )
    .expect("write open frame");
    let reason = "x".repeat(257);
    write_frame(
        &mut input,
        MSG_CLOSE,
        format!(r#"{{"reason":"{reason}"}}"#).as_bytes(),
    )
    .expect("write close frame");

    let state = Rc::new(RefCell::new(RecordingState::default()));
    let mut output = Vec::new();
    let mut backend = RecordingBackend {
        state: Rc::clone(&state),
    };

    let err = run_stdio_with_backend(&mut input.as_slice(), &mut output, &mut backend)
        .expect_err("close rejected");

    assert!(matches!(
        err,
        ProtocolError::InvalidClosePayload(protocol::DesktopClosePayloadError::ReasonTooLarge)
    ));
    assert!(state.borrow().close_payloads.is_empty());
    assert_eq!(
        read_frame(&mut output.as_slice()).expect("read error frame"),
        Some(Frame {
            message_type: MSG_ERROR,
            payload: b"invalid rdp helper close payload".to_vec(),
        })
    );
}

#[test]
fn run_stdio_writes_error_for_unavailable_backend() {
    let mut input = Vec::new();
    write_frame(
        &mut input,
        MSG_OPEN,
        protocol::tests::valid_open_payload().as_bytes(),
    )
    .expect("write open frame");

    let mut output = Vec::new();
    let err = run_stdio(&mut input.as_slice(), &mut output).expect_err("backend unavailable");

    assert!(matches!(err, ProtocolError::Backend(_)));
    #[cfg(not(feature = "ironrdp-backend"))]
    assert!(matches!(
        err,
        ProtocolError::Backend(BackendError::Unavailable)
    ));
    assert_eq!(
        read_frame(&mut output.as_slice()).expect("read error frame"),
        Some(Frame {
            message_type: MSG_ERROR,
            payload: match err {
                ProtocolError::Backend(err) => err.safe_message().as_bytes().to_vec(),
                _ => unreachable!("matched backend error above"),
            },
        })
    );
}

#[test]
fn run_stdio_rejects_invalid_open_payload_before_backend() {
    let mut input = Vec::new();
    write_frame(&mut input, MSG_OPEN, br#"{"schema":"wrong"}"#).expect("write open frame");

    let mut output = Vec::new();
    let state = Rc::new(RefCell::new(RecordingState::default()));
    let mut backend = RecordingBackend {
        state: Rc::clone(&state),
    };
    let err = run_stdio_with_backend(&mut input.as_slice(), &mut output, &mut backend)
        .expect_err("open payload rejected");

    assert!(matches!(err, ProtocolError::InvalidOpenPayload(_)));
    assert!(state.borrow().opened_session.is_none());
    assert_eq!(
        read_frame(&mut output.as_slice()).expect("read error frame"),
        Some(Frame {
            message_type: MSG_ERROR,
            payload: b"invalid rdp helper open payload".to_vec(),
        })
    );
}

#[test]
fn run_stdio_accepts_close_before_open() {
    let mut input = Vec::new();
    write_frame(&mut input, MSG_CLOSE, b"").expect("write close frame");

    let mut output = Vec::new();

    run_stdio(&mut input.as_slice(), &mut output).expect("close succeeds");
    assert!(output.is_empty());
}

#[test]
fn run_stdio_accepts_valid_close_payload_before_open() {
    let mut input = Vec::new();
    write_frame(&mut input, MSG_CLOSE, br#"{"reason":"client closed"}"#)
        .expect("write close frame");

    let mut output = Vec::new();

    run_stdio(&mut input.as_slice(), &mut output).expect("close succeeds");
    assert!(output.is_empty());
}

#[test]
fn run_stdio_rejects_invalid_close_payload_before_open() {
    let reason = "x".repeat(257);
    let mut input = Vec::new();
    write_frame(
        &mut input,
        MSG_CLOSE,
        format!(r#"{{"reason":"{reason}"}}"#).as_bytes(),
    )
    .expect("write close frame");

    let mut output = Vec::new();

    let err = run_stdio(&mut input.as_slice(), &mut output).expect_err("close rejected");

    assert!(matches!(
        err,
        ProtocolError::InvalidClosePayload(protocol::DesktopClosePayloadError::ReasonTooLarge)
    ));
    assert_eq!(
        read_frame(&mut output.as_slice()).expect("read error frame"),
        Some(Frame {
            message_type: MSG_ERROR,
            payload: b"invalid rdp helper close payload".to_vec(),
        })
    );
}
