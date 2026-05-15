mod backend;
#[cfg(feature = "ironrdp-backend")]
mod backend_ironrdp;
mod process_hardening;
mod protocol;

use std::error::Error;
use std::fmt;
use std::io::{self, ErrorKind, Read, Write};

pub use backend::{BackendError, RdpBackend, RdpBackendSession, UnavailableBackend};
#[cfg(feature = "ironrdp-backend")]
pub use backend_ironrdp::IronRdpBackend;
pub use protocol::{parse_open_payload, OpenPayload};
use zeroize::Zeroize;

pub const HELPER_CAPABILITIES_ARG: &str = "--capabilities";
pub const HELPER_CAPABILITIES_SCHEMA: &str = "serviceradar.rdp.helper.capabilities.v1";
pub const HELPER_PROTOCOL_VERSION: u32 = 1;

const HEADER_LEN: usize = 5;
const MAX_FRAME_LENGTH: u32 = 16 * 1024 * 1024;

const MSG_OPEN: u8 = 1;
const MSG_INPUT: u8 = 2;
const MSG_ACK: u8 = 4;
const MSG_CLOSE: u8 = 5;
const MSG_ERROR: u8 = 6;

#[derive(Debug)]
pub enum ProtocolError {
    Io(io::Error),
    InvalidFrameLength(u32),
    InvalidOpenPayload(protocol::OpenPayloadError),
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

pub fn harden_process_for_secrets() -> io::Result<()> {
    process_hardening::harden_process_for_secrets()
}

pub fn write_capabilities<W>(writer: &mut W) -> io::Result<()>
where
    W: Write,
{
    let ironrdp_backend_linked = cfg!(feature = "ironrdp-backend");
    let connector_ready = false;

    writeln!(
        writer,
        "{{\"schema\":\"{}\",\"protocol\":\"rdp\",\"helper_protocol_version\":{},\"ironrdp_backend_linked\":{},\"connector_ready\":{}}}",
        HELPER_CAPABILITIES_SCHEMA,
        HELPER_PROTOCOL_VERSION,
        ironrdp_backend_linked,
        connector_ready
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
    let mut active_session: Option<Box<dyn RdpBackendSession>> = None;

    while let Some(mut frame) = read_frame(reader)? {
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

                match backend.open(open) {
                    Ok(session) => {
                        active_session = Some(session);
                    }
                    Err(err) => {
                        write_error_frame(writer, err.safe_message())?;
                        return Err(err.into());
                    }
                }
            }
            MSG_INPUT => {
                let Some(session) = active_session.as_mut() else {
                    write_error_frame(writer, "rdp helper session is not open")?;
                    return Err(ProtocolError::UnexpectedMessage(frame.message_type));
                };
                if let Err(err) = session.input(&frame.payload) {
                    write_error_frame(writer, err.safe_message())?;
                    return Err(err.into());
                }
            }
            MSG_ACK => {
                let Some(session) = active_session.as_mut() else {
                    write_error_frame(writer, "rdp helper session is not open")?;
                    return Err(ProtocolError::UnexpectedMessage(frame.message_type));
                };
                if let Err(err) = session.ack(&frame.payload) {
                    write_error_frame(writer, err.safe_message())?;
                    return Err(err.into());
                }
            }
            MSG_CLOSE => {
                if let Some(mut session) = active_session.take() {
                    if let Err(err) = session.close(&frame.payload) {
                        write_error_frame(writer, err.safe_message())?;
                        return Err(err.into());
                    }
                }

                return Ok(());
            }
            message_type => {
                write_error_frame(writer, "rdp helper message type is unsupported")?;
                return Err(ProtocolError::UnexpectedMessage(message_type));
            }
        }
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
        input_payloads: Vec<Vec<u8>>,
        ack_payloads: Vec<Vec<u8>>,
        close_payloads: Vec<Vec<u8>>,
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
        fn input(&mut self, payload: &[u8]) -> Result<(), BackendError> {
            self.state
                .borrow_mut()
                .input_payloads
                .push(payload.to_vec());

            Ok(())
        }

        fn ack(&mut self, payload: &[u8]) -> Result<(), BackendError> {
            self.state.borrow_mut().ack_payloads.push(payload.to_vec());

            Ok(())
        }

        fn close(&mut self, payload: &[u8]) -> Result<(), BackendError> {
            self.state
                .borrow_mut()
                .close_payloads
                .push(payload.to_vec());

            Ok(())
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
        assert_eq!(state.close_payloads, vec![Vec::<u8>::new()]);
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
    fn run_stdio_routes_input_and_ack_after_open() {
        let mut input = Vec::new();
        write_frame(
            &mut input,
            MSG_OPEN,
            protocol::tests::valid_open_payload().as_bytes(),
        )
        .expect("write open frame");
        write_frame(&mut input, MSG_INPUT, br#"{"frame_type":"desktop.input"}"#)
            .expect("write input frame");
        write_frame(&mut input, MSG_ACK, b"ack").expect("write ack frame");
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
            state.input_payloads,
            vec![br#"{"frame_type":"desktop.input"}"#.to_vec()]
        );
        assert_eq!(state.ack_payloads, vec![b"ack".to_vec()]);
        assert_eq!(state.close_payloads, vec![br#"{"reason":"done"}"#.to_vec()]);
        assert!(output.is_empty());
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
}
