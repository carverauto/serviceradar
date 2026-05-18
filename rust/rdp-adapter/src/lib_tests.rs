use super::*;
use std::cell::RefCell;
use std::rc::Rc;

struct RecordingBackend {
    state: Rc<RefCell<RecordingState>>,
}

#[derive(Default)]
struct RecordingState {
    opened_session: Option<String>,
    input_frames: Vec<DesktopFrame>,
    acks: Vec<DesktopMediaAck>,
    close_payloads: Vec<DesktopClosePayload>,
    pending_media_frames: Vec<Vec<u8>>,
    pump_count: usize,
    pump_media_frames: Vec<Vec<u8>>,
    media_drain_error: Option<&'static str>,
}

impl RdpBackend for RecordingBackend {
    fn open(&mut self, request: OpenPayload) -> Result<Box<dyn RdpBackendSession>, BackendError> {
        self.state.borrow_mut().opened_session = Some(request.session_id);

        Ok(Box::new(RecordingSession {
            state: Rc::clone(&self.state),
        }))
    }
}

struct RecordingSession {
    state: Rc<RefCell<RecordingState>>,
}

impl RdpBackendSession for RecordingSession {
    fn input(&mut self, frame: &DesktopFrame) -> Result<(), BackendError> {
        self.state.borrow_mut().input_frames.push(frame.clone());

        Ok(())
    }

    fn ack(&mut self, ack: &DesktopMediaAck) -> Result<(), BackendError> {
        self.state.borrow_mut().acks.push(DesktopMediaAck {
            session_binding_id: ack.session_binding_id.clone(),
            media_session_id: ack.media_session_id.clone(),
            last_accepted_seq: ack.last_accepted_seq,
            credit_bytes: ack.credit_bytes,
            quality_level: ack.quality_level.clone(),
            pause: ack.pause,
            resume: ack.resume,
            close_reason: ack.close_reason.clone(),
        });

        Ok(())
    }

    fn close(&mut self, payload: &DesktopClosePayload) -> Result<(), BackendError> {
        self.state.borrow_mut().close_payloads.push(payload.clone());

        Ok(())
    }

    fn pump(&mut self) -> Result<(), BackendError> {
        let mut state = self.state.borrow_mut();
        state.pump_count += 1;
        let pump_media_frames = std::mem::take(&mut state.pump_media_frames);
        state.pending_media_frames.extend(pump_media_frames);

        Ok(())
    }

    fn drain_media_frames(&mut self) -> Result<Vec<Vec<u8>>, BackendError> {
        let mut state = self.state.borrow_mut();

        if let Some(message) = state.media_drain_error.take() {
            return Err(BackendError::Unsupported(message));
        }

        Ok(std::mem::take(&mut state.pending_media_frames))
    }
}

#[test]
fn write_capabilities_reports_connector_not_ready() {
    let mut output = Vec::new();

    write_capabilities(&mut output).expect("write capabilities");

    let payload = String::from_utf8(output).expect("utf8 capabilities");
    assert!(payload.contains(HELPER_CAPABILITIES_SCHEMA));
    assert!(payload.contains("\"protocol\":\"rdp\""));
    assert!(payload.contains("\"helper_protocol_version\":1"));
    assert!(payload.contains("\"connector_ready\":false"));
    let expected_reason = if cfg!(feature = "ironrdp-backend") {
        HELPER_CONNECTOR_NOT_READY_REASON
    } else {
        HELPER_BACKEND_NOT_LINKED_REASON
    };
    assert!(payload.contains(&format!("\"connector_ready_reason\":\"{expected_reason}\"")));
}

#[test]
fn run_stdio_parses_open_payload_before_backend_open() {
    let mut input = Vec::new();
    write_frame(
        &mut input,
        MSG_OPEN,
        protocol::tests::valid_open_payload().as_bytes(),
    )
    .expect("write open frame");
    write_frame(&mut input, MSG_CLOSE, b"").expect("write close frame");

    let mut output = Vec::new();
    let state = Rc::new(RefCell::new(RecordingState::default()));
    let mut backend = RecordingBackend {
        state: Rc::clone(&state),
    };

    run_stdio_with_backend(&mut input.as_slice(), &mut output, &mut backend)
        .expect("open then close succeeds");

    let state = state.borrow();

    assert_eq!(state.opened_session.as_deref(), Some("session-1"));
    assert_eq!(state.close_payloads, vec![DesktopClosePayload::default()]);
    assert!(output.is_empty());
}

#[test]
fn parse_and_clear_open_payload_zeroizes_raw_credential_frame() {
    let mut payload = protocol::tests::valid_open_payload().into_bytes();
    assert!(payload
        .windows(b"secret".len())
        .any(|window| window == b"secret"));

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
    assert!(payload
        .windows(b"Enter".len())
        .any(|window| window == b"Enter"));

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
    assert!(payload
        .windows(b"browser close".len())
        .any(|window| window == b"browser close"));

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
    assert!(payload
        .windows(b"operator close".len())
        .any(|window| window == b"operator close"));

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

#[test]
fn run_stdio_routes_input_ack_and_close_after_open() {
    let mut input = Vec::new();
    write_frame(
        &mut input,
        MSG_OPEN,
        protocol::tests::valid_open_payload().as_bytes(),
    )
    .expect("write open frame");
    write_frame(&mut input, MSG_INPUT, valid_input_payload().as_bytes())
        .expect("write input frame");
    write_frame(&mut input, MSG_ACK, valid_ack_payload().as_bytes()).expect("write ack frame");
    write_frame(&mut input, MSG_CLOSE, br#"{"reason":"done"}"#).expect("write close frame");

    let state = Rc::new(RefCell::new(RecordingState::default()));
    let mut output = Vec::new();
    let mut backend = RecordingBackend {
        state: Rc::clone(&state),
    };

    run_stdio_with_backend(&mut input.as_slice(), &mut output, &mut backend)
        .expect("session frames succeed");

    let state = state.borrow();

    assert_eq!(
        state.input_frames,
        vec![DesktopFrame {
            session_id: "session-1".to_owned(),
            protocol: "rdp".to_owned(),
            frame_type: "desktop.input".to_owned(),
            width: 0,
            height: 0,
            input: Some(protocol::DesktopInputEvent {
                kind: "key".to_owned(),
                key: "Enter".to_owned(),
                down: true,
                button: String::new(),
                x: 0,
                y: 0,
                focused: false,
            }),
            quality: None,
            reason: String::new(),
            timestamp: 0,
            metadata: Default::default(),
        }]
    );
    assert_eq!(
        state.acks,
        vec![DesktopMediaAck {
            session_binding_id: "session-1".to_owned(),
            media_session_id: "media-1".to_owned(),
            last_accepted_seq: 7,
            credit_bytes: 8192,
            quality_level: "low".to_owned(),
            pause: true,
            resume: false,
            close_reason: "browser close".to_owned(),
        }]
    );
    assert_eq!(
        state.close_payloads,
        vec![DesktopClosePayload {
            reason: "done".to_owned()
        }]
    );
    assert!(output.is_empty());
}

#[test]
fn run_stdio_emits_backend_media_frames_after_input() {
    let mut input = Vec::new();
    write_frame(
        &mut input,
        MSG_OPEN,
        protocol::tests::valid_open_payload().as_bytes(),
    )
    .expect("write open frame");
    write_frame(&mut input, MSG_INPUT, valid_input_payload().as_bytes())
        .expect("write input frame");

    let state = Rc::new(RefCell::new(RecordingState {
        pending_media_frames: vec![b"srdp-frame-1".to_vec(), b"srdp-frame-2".to_vec()],
        ..RecordingState::default()
    }));
    let mut output = Vec::new();
    let mut backend = RecordingBackend {
        state: Rc::clone(&state),
    };

    run_stdio_with_backend(&mut input.as_slice(), &mut output, &mut backend)
        .expect("session frames succeed");

    let mut output = output.as_slice();
    assert_eq!(
        read_frame(&mut output).expect("read first media frame"),
        Some(Frame {
            message_type: MSG_MEDIA_FRAME,
            payload: b"srdp-frame-1".to_vec(),
        })
    );
    assert_eq!(
        read_frame(&mut output).expect("read second media frame"),
        Some(Frame {
            message_type: MSG_MEDIA_FRAME,
            payload: b"srdp-frame-2".to_vec(),
        })
    );
    assert_eq!(read_frame(&mut output).expect("read eof"), None);
}

#[cfg(unix)]
#[test]
fn run_stdio_pump_emits_backend_media_while_ipc_reader_is_idle() {
    use std::os::unix::net::UnixStream;
    use std::thread;
    use std::time::Duration;

    let (mut writer_pipe, reader_pipe) = UnixStream::pair().expect("unix stream pair");
    let input_thread = thread::spawn(move || {
        write_frame(
            &mut writer_pipe,
            MSG_OPEN,
            protocol::tests::valid_open_payload().as_bytes(),
        )
        .expect("write open frame");
        thread::sleep(Duration::from_millis(40));
        write_frame(&mut writer_pipe, MSG_CLOSE, br#"{"reason":"done"}"#)
            .expect("write close frame");
    });
    let state = Rc::new(RefCell::new(RecordingState {
        pump_media_frames: vec![b"server-driven-srdp-frame".to_vec()],
        ..RecordingState::default()
    }));
    let mut output = Vec::new();
    let mut backend = RecordingBackend {
        state: Rc::clone(&state),
    };

    run_stdio_with_backend_pump(
        reader_pipe,
        &mut output,
        &mut backend,
        Duration::from_millis(5),
    )
    .expect("pumped session succeeds");
    input_thread.join().expect("input thread joins");

    assert!(state.borrow().pump_count > 0);
    let mut output = output.as_slice();
    assert_eq!(
        read_frame(&mut output).expect("read pumped media frame"),
        Some(Frame {
            message_type: MSG_MEDIA_FRAME,
            payload: b"server-driven-srdp-frame".to_vec(),
        })
    );
}

#[test]
fn run_stdio_emits_backend_media_frames_after_open() {
    let mut input = Vec::new();
    write_frame(
        &mut input,
        MSG_OPEN,
        protocol::tests::valid_open_payload().as_bytes(),
    )
    .expect("write open frame");

    let state = Rc::new(RefCell::new(RecordingState {
        pending_media_frames: vec![b"initial-srdp-frame".to_vec()],
        ..RecordingState::default()
    }));
    let mut output = Vec::new();
    let mut backend = RecordingBackend {
        state: Rc::clone(&state),
    };

    run_stdio_with_backend(&mut input.as_slice(), &mut output, &mut backend)
        .expect("open emits initial media");

    assert_eq!(
        read_frame(&mut output.as_slice()).expect("read initial media frame"),
        Some(Frame {
            message_type: MSG_MEDIA_FRAME,
            payload: b"initial-srdp-frame".to_vec(),
        })
    );
}

#[test]
fn run_stdio_writes_error_when_backend_media_drain_fails() {
    let mut input = Vec::new();
    write_frame(
        &mut input,
        MSG_OPEN,
        protocol::tests::valid_open_payload().as_bytes(),
    )
    .expect("write open frame");
    write_frame(&mut input, MSG_INPUT, valid_input_payload().as_bytes())
        .expect("write input frame");

    let state = Rc::new(RefCell::new(RecordingState {
        media_drain_error: Some("rdp media drain failed"),
        ..RecordingState::default()
    }));
    let mut output = Vec::new();
    let mut backend = RecordingBackend {
        state: Rc::clone(&state),
    };

    let err = run_stdio_with_backend(&mut input.as_slice(), &mut output, &mut backend)
        .expect_err("media drain rejected");

    assert!(matches!(
        err,
        ProtocolError::Backend(BackendError::Unsupported("rdp media drain failed"))
    ));
    assert_eq!(
        read_frame(&mut output.as_slice()).expect("read error frame"),
        Some(Frame {
            message_type: MSG_ERROR,
            payload: b"rdp media drain failed".to_vec(),
        })
    );
}

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

#[test]
fn read_frame_rejects_oversized_frame() {
    let mut input = Vec::new();
    input.extend_from_slice(&(MAX_FRAME_LENGTH + 1).to_be_bytes());
    input.push(MSG_MEDIA_FRAME);

    let err = read_frame(&mut input.as_slice()).expect_err("oversized frame rejected");

    assert!(matches!(
        err,
        ProtocolError::InvalidFrameLength(length) if length == MAX_FRAME_LENGTH + 1
    ));
}

#[test]
fn read_frame_rejects_oversized_control_frame_before_payload_read() {
    let mut input = Vec::new();
    input.extend_from_slice(&(MAX_CONTROL_FRAME_LENGTH + 1).to_be_bytes());
    input.push(MSG_ERROR);

    let err = read_frame(&mut input.as_slice()).expect_err("oversized control frame rejected");

    assert!(matches!(
        err,
        ProtocolError::InvalidFrameLength(length) if length == MAX_CONTROL_FRAME_LENGTH + 1
    ));
}

#[test]
fn read_frame_rejects_zero_length_before_message_type() {
    let mut input = Vec::new();
    input.extend_from_slice(&0u32.to_be_bytes());
    input.push(99);

    let err = read_frame(&mut input.as_slice()).expect_err("zero-length frame rejected");

    assert!(matches!(err, ProtocolError::InvalidFrameLength(0)));
}

#[test]
fn read_frame_rejects_unsupported_type_before_payload_read() {
    let mut input = Vec::new();
    input.extend_from_slice(&1024u32.to_be_bytes());
    input.push(99);

    let err = read_frame(&mut input.as_slice()).expect_err("unsupported frame rejected");

    assert!(matches!(err, ProtocolError::UnexpectedMessage(99)));
}

#[test]
fn write_frame_rejects_oversized_media_payload() {
    let payload = vec![0u8; MAX_FRAME_LENGTH as usize];
    let mut output = Vec::new();

    let err = write_frame(&mut output, MSG_MEDIA_FRAME, &payload).expect_err("payload rejected");

    assert!(matches!(
        err,
        ProtocolError::InvalidFrameLength(length) if length == MAX_FRAME_LENGTH + 1
    ));
    assert!(output.is_empty());
}

#[test]
fn write_frame_keeps_large_payloads_media_only() {
    let payload = vec![0u8; MAX_CONTROL_FRAME_LENGTH as usize];
    let mut output = Vec::new();

    let err = write_frame(&mut output, MSG_CLOSE, &payload).expect_err("control rejected");

    assert!(matches!(
        err,
        ProtocolError::InvalidFrameLength(length) if length == MAX_CONTROL_FRAME_LENGTH + 1
    ));
    assert!(output.is_empty());

    write_frame(&mut output, MSG_MEDIA_FRAME, &payload).expect("media accepted");
    let frame = read_frame(&mut output.as_slice())
        .expect("media read")
        .expect("media frame");
    assert_eq!(frame.message_type, MSG_MEDIA_FRAME);
    assert_eq!(frame.payload.len(), payload.len());
}

#[test]
fn write_frame_allows_bounded_open_payloads_for_ca_bundles() {
    let payload = vec![0u8; 256 * 1024];
    let mut output = Vec::new();

    write_frame(&mut output, MSG_OPEN, &payload).expect("bounded open accepted");
    let frame = read_frame(&mut output.as_slice())
        .expect("open read")
        .expect("open frame");
    assert_eq!(frame.message_type, MSG_OPEN);
    assert_eq!(frame.payload.len(), payload.len());
}

fn valid_ack_payload() -> String {
    r#"{"type":"desktop_media_ack","session_binding_id":"session-1","media_session_id":"media-1","last_accepted_seq":7,"credit_bytes":8192,"quality_level":"low","pause":true,"close_reason":"browser close"}"#.to_owned()
}

fn valid_input_payload() -> String {
    r#"{"session_id":"session-1","protocol":"rdp","frame_type":"desktop.input","input":{"kind":"key","key":"Enter","down":true}}"#.to_owned()
}

fn input_test_policy() -> protocol::DesktopScreenPolicy {
    protocol::DesktopScreenPolicy {
        max_width: 1920,
        max_height: 1080,
        color_depth: 0,
        frame_rate: 30,
        bitrate_bps: 8_000_000,
        idle_seconds: 900,
        ttl_seconds: 3600,
    }
}
