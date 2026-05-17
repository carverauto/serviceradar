mod backend;
#[cfg(feature = "ironrdp-backend")]
mod backend_ironrdp;
#[cfg(serviceradar_rdp_connector_link_probe)]
mod connector_link_probe;
mod media_frame;
mod process_hardening;
mod protocol;

use std::error::Error;
use std::fmt;
use std::io::{self, ErrorKind, Read, Write};
use std::sync::mpsc::{self, RecvTimeoutError};
use std::thread;
use std::time::Duration;

pub use backend::{BackendError, RdpBackend, RdpBackendSession, UnavailableBackend};
#[cfg(feature = "ironrdp-backend")]
pub use backend_ironrdp::IronRdpBackend;
#[cfg(serviceradar_rdp_connector_link_probe)]
pub use connector_link_probe::connector_link_probe_capabilities;
pub use protocol::{
    parse_open_payload, DesktopClosePayload, DesktopFrame, DesktopMediaAck, OpenPayload,
};
use zeroize::Zeroize;

pub const HELPER_CAPABILITIES_ARG: &str = "--capabilities";
pub const HELPER_CAPABILITIES_SCHEMA: &str = "serviceradar.rdp.helper.capabilities.v1";
pub const HELPER_PROTOCOL_VERSION: u32 = 1;
pub const HELPER_CONNECTOR_NOT_READY_REASON: &str = "connector_loop_not_implemented";
pub const HELPER_BACKEND_NOT_LINKED_REASON: &str = "ironrdp_backend_not_linked";

const HEADER_LEN: usize = 5;
const MAX_FRAME_LENGTH: u32 = 16 * 1024 * 1024;

const MSG_OPEN: u8 = 1;
const MSG_INPUT: u8 = 2;
const MSG_MEDIA_FRAME: u8 = 3;
const MSG_ACK: u8 = 4;
const MSG_CLOSE: u8 = 5;
const MSG_ERROR: u8 = 6;
const DEFAULT_BACKEND_PUMP_INTERVAL: Duration = Duration::from_millis(10);

#[derive(Debug)]
pub enum ProtocolError {
    Io(io::Error),
    InvalidFrameLength(u32),
    InvalidOpenPayload(protocol::OpenPayloadError),
    InvalidInputPayload(protocol::DesktopFrameError),
    InvalidAckPayload(protocol::DesktopMediaAckError),
    InvalidClosePayload(protocol::DesktopClosePayloadError),
    Backend(BackendError),
    UnexpectedMessage(u8),
}

impl fmt::Display for ProtocolError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Io(err) => write!(f, "rdp helper io error: {err}"),
            Self::InvalidFrameLength(length) => {
                write!(f, "rdp helper frame length is invalid: {length}")
            }
            Self::InvalidOpenPayload(err) => write!(f, "invalid rdp helper open payload: {err}"),
            Self::InvalidInputPayload(err) => write!(f, "invalid rdp helper input payload: {err}"),
            Self::InvalidAckPayload(err) => write!(f, "invalid rdp helper ack payload: {err}"),
            Self::InvalidClosePayload(err) => write!(f, "invalid rdp helper close payload: {err}"),
            Self::Backend(err) => write!(f, "{err}"),
            Self::UnexpectedMessage(message_type) => {
                write!(
                    f,
                    "rdp helper received unexpected message type: {message_type}"
                )
            }
        }
    }
}

impl Error for ProtocolError {
    fn source(&self) -> Option<&(dyn Error + 'static)> {
        match self {
            Self::Io(err) => Some(err),
            Self::InvalidOpenPayload(err) => Some(err),
            Self::InvalidInputPayload(err) => Some(err),
            Self::InvalidAckPayload(err) => Some(err),
            Self::InvalidClosePayload(err) => Some(err),
            Self::Backend(err) => Some(err),
            _ => None,
        }
    }
}

impl From<io::Error> for ProtocolError {
    fn from(err: io::Error) -> Self {
        Self::Io(err)
    }
}

impl From<protocol::OpenPayloadError> for ProtocolError {
    fn from(err: protocol::OpenPayloadError) -> Self {
        Self::InvalidOpenPayload(err)
    }
}

impl From<protocol::DesktopFrameError> for ProtocolError {
    fn from(err: protocol::DesktopFrameError) -> Self {
        Self::InvalidInputPayload(err)
    }
}

impl From<protocol::DesktopMediaAckError> for ProtocolError {
    fn from(err: protocol::DesktopMediaAckError) -> Self {
        Self::InvalidAckPayload(err)
    }
}

impl From<protocol::DesktopClosePayloadError> for ProtocolError {
    fn from(err: protocol::DesktopClosePayloadError) -> Self {
        Self::InvalidClosePayload(err)
    }
}

impl From<BackendError> for ProtocolError {
    fn from(err: BackendError) -> Self {
        Self::Backend(err)
    }
}

#[derive(Debug, Eq, PartialEq)]
struct Frame {
    message_type: u8,
    payload: Vec<u8>,
}

struct ActiveSession {
    session_id: String,
    screen_policy: protocol::DesktopScreenPolicy,
    session: Box<dyn RdpBackendSession>,
}

enum FrameAction {
    Continue,
    Close,
}

pub fn run_stdio<R, W>(reader: &mut R, writer: &mut W) -> Result<(), ProtocolError>
where
    R: Read,
    W: Write,
{
    #[cfg(feature = "ironrdp-backend")]
    let mut backend = IronRdpBackend;

    #[cfg(not(feature = "ironrdp-backend"))]
    let mut backend = UnavailableBackend;

    run_stdio_with_backend(reader, writer, &mut backend)
}

pub fn run_stdio_pumped<R, W>(reader: R, writer: &mut W) -> Result<(), ProtocolError>
where
    R: Read + Send + 'static,
    W: Write,
{
    #[cfg(feature = "ironrdp-backend")]
    let mut backend = IronRdpBackend;

    #[cfg(not(feature = "ironrdp-backend"))]
    let mut backend = UnavailableBackend;

    run_stdio_with_backend_pump(reader, writer, &mut backend, DEFAULT_BACKEND_PUMP_INTERVAL)
}

pub fn harden_process_for_secrets() -> io::Result<()> {
    process_hardening::harden_process_for_secrets()
}

pub fn write_capabilities<W>(writer: &mut W) -> io::Result<()>
where
    W: Write,
{
    let ironrdp_backend_linked = cfg!(feature = "ironrdp-backend");
    let connector_ready = false;
    let connector_ready_reason = if ironrdp_backend_linked {
        HELPER_CONNECTOR_NOT_READY_REASON
    } else {
        HELPER_BACKEND_NOT_LINKED_REASON
    };

    writeln!(
        writer,
        "{{\"schema\":\"{}\",\"protocol\":\"rdp\",\"helper_protocol_version\":{},\"ironrdp_backend_linked\":{},\"connector_ready\":{},\"connector_ready_reason\":\"{}\"}}",
        HELPER_CAPABILITIES_SCHEMA,
        HELPER_PROTOCOL_VERSION,
        ironrdp_backend_linked,
        connector_ready,
        connector_ready_reason
    )
}

pub fn run_stdio_with_backend<R, W, B>(
    reader: &mut R,
    writer: &mut W,
    backend: &mut B,
) -> Result<(), ProtocolError>
where
    R: Read,
    W: Write,
    B: RdpBackend,
{
    let mut active_session: Option<ActiveSession> = None;

    while let Some(frame) = read_frame(reader)? {
        if let FrameAction::Close = process_frame(frame, writer, backend, &mut active_session)? {
            return Ok(());
        }
    }

    Ok(())
}

pub fn run_stdio_with_backend_pump<R, W, B>(
    reader: R,
    writer: &mut W,
    backend: &mut B,
    pump_interval: Duration,
) -> Result<(), ProtocolError>
where
    R: Read + Send + 'static,
    W: Write,
    B: RdpBackend,
{
    let (sender, receiver) = mpsc::channel();
    thread::spawn(move || read_frames_into_channel(reader, sender));
    let mut active_session: Option<ActiveSession> = None;
    let interval = if pump_interval.is_zero() {
        DEFAULT_BACKEND_PUMP_INTERVAL
    } else {
        pump_interval
    };

    loop {
        match receiver.recv_timeout(interval) {
            Ok(Ok(Some(frame))) => {
                if let FrameAction::Close =
                    process_frame(frame, writer, backend, &mut active_session)?
                {
                    return Ok(());
                }
            }
            Ok(Ok(None)) => return Ok(()),
            Ok(Err(err)) => return Err(err),
            Err(RecvTimeoutError::Timeout) => {
                if let Some(active) = active_session.as_mut() {
                    pump_and_write_media_frames(writer, active.session.as_mut())?;
                }
            }
            Err(RecvTimeoutError::Disconnected) => return Ok(()),
        }
    }
}

fn read_frames_into_channel<R>(
    mut reader: R,
    sender: mpsc::Sender<Result<Option<Frame>, ProtocolError>>,
) where
    R: Read,
{
    loop {
        match read_frame(&mut reader) {
            Ok(Some(frame)) => {
                if sender.send(Ok(Some(frame))).is_err() {
                    return;
                }
            }
            Ok(None) => {
                let _ = sender.send(Ok(None));
                return;
            }
            Err(err) => {
                let _ = sender.send(Err(err));
                return;
            }
        }
    }
}

fn process_frame<W, B>(
    mut frame: Frame,
    writer: &mut W,
    backend: &mut B,
    active_session: &mut Option<ActiveSession>,
) -> Result<FrameAction, ProtocolError>
where
    W: Write,
    B: RdpBackend,
{
    match frame.message_type {
        MSG_OPEN => {
            if active_session.is_some() {
                write_error_frame(writer, "rdp helper session is already open")?;
                return Err(ProtocolError::UnexpectedMessage(frame.message_type));
            }

            let open = match parse_and_clear_open_payload(&mut frame.payload) {
                Ok(open) => open,
                Err(err) => {
                    write_error_frame(writer, "invalid rdp helper open payload")?;
                    return Err(err.into());
                }
            };

            let session_id = open.session_id.clone();
            let screen_policy = protocol::DesktopScreenPolicy {
                max_width: open.target.screen.max_width,
                max_height: open.target.screen.max_height,
                color_depth: open.target.screen.color_depth,
                frame_rate: open.target.screen.frame_rate,
                bitrate_bps: open.target.screen.bitrate_bps,
                idle_seconds: open.target.screen.idle_seconds,
                ttl_seconds: open.target.screen.ttl_seconds,
            };

            match backend.open(open) {
                Ok(session) => {
                    *active_session = Some(ActiveSession {
                        session_id,
                        screen_policy,
                        session,
                    });
                    if let Some(active) = active_session.as_mut() {
                        drain_and_write_media_frames(writer, active.session.as_mut())?;
                    }
                }
                Err(err) => {
                    write_error_frame(writer, err.safe_message())?;
                    return Err(err.into());
                }
            }
        }
        MSG_INPUT => {
            let Some(active) = active_session.as_mut() else {
                write_error_frame(writer, "rdp helper session is not open")?;
                return Err(ProtocolError::UnexpectedMessage(frame.message_type));
            };
            let input = match parse_and_clear_input_payload(
                &mut frame.payload,
                &active.session_id,
                &active.screen_policy,
            ) {
                Ok(input) => input,
                Err(err) => {
                    write_error_frame(writer, "invalid rdp helper input payload")?;
                    return Err(err.into());
                }
            };
            if let Err(err) = active.session.input(&input) {
                write_error_frame(writer, err.safe_message())?;
                return Err(err.into());
            }
            drain_and_write_media_frames(writer, active.session.as_mut())?;
        }
        MSG_ACK => {
            let Some(active) = active_session.as_mut() else {
                write_error_frame(writer, "rdp helper session is not open")?;
                return Err(ProtocolError::UnexpectedMessage(frame.message_type));
            };
            let ack = match parse_and_clear_ack_payload(&mut frame.payload, &active.session_id) {
                Ok(ack) => ack,
                Err(err) => {
                    write_error_frame(writer, "invalid rdp helper ack payload")?;
                    return Err(err.into());
                }
            };
            if let Err(err) = active.session.ack(&ack) {
                write_error_frame(writer, err.safe_message())?;
                return Err(err.into());
            }
            drain_and_write_media_frames(writer, active.session.as_mut())?;
        }
        MSG_CLOSE => {
            let close = match parse_and_clear_close_payload(&mut frame.payload) {
                Ok(close) => close,
                Err(err) => {
                    write_error_frame(writer, "invalid rdp helper close payload")?;
                    return Err(err.into());
                }
            };

            if let Some(mut active) = active_session.take() {
                if let Err(err) = active.session.close(&close) {
                    write_error_frame(writer, err.safe_message())?;
                    return Err(err.into());
                }
            }

            return Ok(FrameAction::Close);
        }
        message_type => {
            write_error_frame(writer, "rdp helper message type is unsupported")?;
            return Err(ProtocolError::UnexpectedMessage(message_type));
        }
    }

    Ok(FrameAction::Continue)
}

fn pump_and_write_media_frames<W: Write>(
    writer: &mut W,
    session: &mut dyn RdpBackendSession,
) -> Result<(), ProtocolError> {
    if let Err(err) = session.pump() {
        write_error_frame(writer, err.safe_message())?;
        return Err(err.into());
    }

    drain_and_write_media_frames(writer, session)
}

fn drain_and_write_media_frames<W: Write>(
    writer: &mut W,
    session: &mut dyn RdpBackendSession,
) -> Result<(), ProtocolError> {
    let media_frames = match session.drain_media_frames() {
        Ok(media_frames) => media_frames,
        Err(err) => {
            write_error_frame(writer, err.safe_message())?;
            return Err(err.into());
        }
    };

    for payload in media_frames {
        write_frame(writer, MSG_MEDIA_FRAME, &payload)?;
    }

    Ok(())
}

fn parse_and_clear_open_payload(
    payload: &mut [u8],
) -> Result<OpenPayload, protocol::OpenPayloadError> {
    let result = parse_open_payload(payload);
    payload.zeroize();

    result
}

fn parse_and_clear_input_payload(
    payload: &mut [u8],
    session_id: &str,
    policy: &protocol::DesktopScreenPolicy,
) -> Result<DesktopFrame, protocol::DesktopFrameError> {
    let result = protocol::parse_desktop_frame(payload, session_id, policy);
    payload.zeroize();

    result
}

fn parse_and_clear_ack_payload(
    payload: &mut [u8],
    session_id: &str,
) -> Result<DesktopMediaAck, protocol::DesktopMediaAckError> {
    let result = protocol::parse_desktop_media_ack(payload, session_id);
    payload.zeroize();

    result
}

fn parse_and_clear_close_payload(
    payload: &mut [u8],
) -> Result<DesktopClosePayload, protocol::DesktopClosePayloadError> {
    let result = protocol::parse_desktop_close_payload(payload);
    payload.zeroize();

    result
}

fn read_frame<R: Read>(reader: &mut R) -> Result<Option<Frame>, ProtocolError> {
    let mut header = [0u8; HEADER_LEN];

    match reader.read_exact(&mut header[..1]) {
        Ok(()) => {}
        Err(err) if err.kind() == ErrorKind::UnexpectedEof => return Ok(None),
        Err(err) => return Err(ProtocolError::Io(err)),
    }

    reader.read_exact(&mut header[1..])?;

    let frame_length = u32::from_be_bytes([header[0], header[1], header[2], header[3]]);
    if frame_length == 0 || frame_length > MAX_FRAME_LENGTH {
        return Err(ProtocolError::InvalidFrameLength(frame_length));
    }

    let payload_length = frame_length - 1;
    let mut payload = vec![0u8; payload_length as usize];
    reader.read_exact(&mut payload)?;

    Ok(Some(Frame {
        message_type: header[4],
        payload,
    }))
}

fn write_error_frame<W: Write>(writer: &mut W, message: &str) -> Result<(), ProtocolError> {
    write_frame(writer, MSG_ERROR, message.as_bytes())
}

fn write_frame<W: Write>(
    writer: &mut W,
    message_type: u8,
    payload: &[u8],
) -> Result<(), ProtocolError> {
    let frame_length = payload
        .len()
        .checked_add(1)
        .and_then(|length| u32::try_from(length).ok())
        .ok_or(ProtocolError::InvalidFrameLength(u32::MAX))?;

    if frame_length > MAX_FRAME_LENGTH {
        return Err(ProtocolError::InvalidFrameLength(frame_length));
    }

    writer.write_all(&frame_length.to_be_bytes())?;
    writer.write_all(&[message_type])?;
    writer.write_all(payload)?;
    writer.flush()?;

    Ok(())
}

#[cfg(test)]
mod tests {
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
        fn open(
            &mut self,
            request: OpenPayload,
        ) -> Result<Box<dyn RdpBackendSession>, BackendError> {
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
                .map(|grant| grant.password.expose()),
            Some("secret")
        );
        assert!(payload.iter().all(|byte| *byte == 0));
    }

    #[test]
    fn parse_and_clear_open_payload_zeroizes_invalid_raw_frame() {
        let mut payload =
            br#"{"schema":"wrong","credential_grant":{"password":"secret"}}"#.to_vec();

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
        input.push(MSG_OPEN);

        let err = read_frame(&mut input.as_slice()).expect_err("oversized frame rejected");

        assert!(matches!(
            err,
            ProtocolError::InvalidFrameLength(length) if length == MAX_FRAME_LENGTH + 1
        ));
    }

    #[test]
    fn write_frame_rejects_oversized_payload() {
        let payload = vec![0u8; MAX_FRAME_LENGTH as usize];
        let mut output = Vec::new();

        let err = write_frame(&mut output, MSG_ERROR, &payload).expect_err("payload rejected");

        assert!(matches!(
            err,
            ProtocolError::InvalidFrameLength(length) if length == MAX_FRAME_LENGTH + 1
        ));
        assert!(output.is_empty());
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
}
