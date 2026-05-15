mod backend;
mod protocol;

use std::error::Error;
use std::fmt;
use std::io::{self, ErrorKind, Read, Write};

pub use backend::{BackendError, RdpBackend, UnavailableBackend};
pub use protocol::{parse_open_payload, OpenPayload};

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
    let mut backend = UnavailableBackend;

    run_stdio_with_backend(reader, writer, &mut backend)
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
    while let Some(frame) = read_frame(reader)? {
        match frame.message_type {
            MSG_OPEN => {
                let open = match parse_open_payload(&frame.payload) {
                    Ok(open) => open,
                    Err(err) => {
                        write_error_frame(writer, "invalid rdp helper open payload")?;
                        return Err(err.into());
                    }
                };

                if let Err(err) = backend.open(open) {
                    write_error_frame(writer, err.safe_message())?;
                    return Err(err.into());
                }
            }
            MSG_CLOSE => return Ok(()),
            MSG_INPUT | MSG_ACK => {
                write_error_frame(writer, "rdp helper session is not open")?;
                return Err(ProtocolError::UnexpectedMessage(frame.message_type));
            }
            message_type => {
                write_error_frame(writer, "rdp helper message type is unsupported")?;
                return Err(ProtocolError::UnexpectedMessage(message_type));
            }
        }
    }

    Ok(())
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

    struct RecordingBackend {
        opened_session: Option<String>,
    }

    impl RdpBackend for RecordingBackend {
        fn open(&mut self, request: OpenPayload) -> Result<(), BackendError> {
            self.opened_session = Some(request.session_id);

            Ok(())
        }
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
        let mut backend = RecordingBackend {
            opened_session: None,
        };

        run_stdio_with_backend(&mut input.as_slice(), &mut output, &mut backend)
            .expect("open then close succeeds");

        assert_eq!(backend.opened_session.as_deref(), Some("session-1"));
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

        assert!(matches!(
            err,
            ProtocolError::Backend(BackendError::Unavailable)
        ));
        assert_eq!(
            read_frame(&mut output.as_slice()).expect("read error frame"),
            Some(Frame {
                message_type: MSG_ERROR,
                payload: BackendError::Unavailable.safe_message().as_bytes().to_vec(),
            })
        );
    }

    #[test]
    fn run_stdio_rejects_invalid_open_payload_before_backend() {
        let mut input = Vec::new();
        write_frame(&mut input, MSG_OPEN, br#"{"schema":"wrong"}"#).expect("write open frame");

        let mut output = Vec::new();
        let mut backend = RecordingBackend {
            opened_session: None,
        };
        let err = run_stdio_with_backend(&mut input.as_slice(), &mut output, &mut backend)
            .expect_err("open payload rejected");

        assert!(matches!(err, ProtocolError::InvalidOpenPayload(_)));
        assert!(backend.opened_session.is_none());
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
