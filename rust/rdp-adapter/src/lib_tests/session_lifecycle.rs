use super::*;

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
