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
#[cfg(all(feature = "ironrdp-backend", serviceradar_rdp_connector_link_probe))]
pub use backend_ironrdp::run_live_helper_open_probe_from_env;
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
pub const HELPER_CONNECTOR_NOT_READY_REASON: &str = "live_auth_media_demo_not_validated";
pub const HELPER_BACKEND_NOT_LINKED_REASON: &str = "ironrdp_backend_not_linked";

const HEADER_LEN: usize = 5;
const MAX_FRAME_LENGTH: u32 = 16 * 1024 * 1024;
const MAX_CONTROL_FRAME_LENGTH: u32 = 512 * 1024;

const MSG_OPEN: u8 = 1;
const MSG_INPUT: u8 = 2;
const MSG_MEDIA_FRAME: u8 = 3;
const MSG_ACK: u8 = 4;
const MSG_CLOSE: u8 = 5;
const MSG_ERROR: u8 = 6;
const DEFAULT_BACKEND_PUMP_INTERVAL: Duration = Duration::from_millis(10);
const MAX_SESSION_ACK_CREDIT_BYTES: u64 = 64 * 1024 * 1024;

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
    ack_credit_bytes: u64,
    session: Box<dyn RdpBackendSession>,
}

impl ActiveSession {
    fn add_ack_credit(&mut self, credit_bytes: u64) -> Result<(), protocol::DesktopMediaAckError> {
        self.ack_credit_bytes = self
            .ack_credit_bytes
            .checked_add(credit_bytes)
            .ok_or(protocol::DesktopMediaAckError::CreditTooLarge)?;

        if self.ack_credit_bytes > MAX_SESSION_ACK_CREDIT_BYTES {
            return Err(protocol::DesktopMediaAckError::CreditTooLarge);
        }

        Ok(())
    }
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
                        ack_credit_bytes: 0,
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
            if let Err(err) = active.add_ack_credit(ack.credit_bytes) {
                write_error_frame(writer, "invalid rdp helper ack payload")?;
                return Err(err.into());
            }
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
    let message_type = header[4];
    if frame_length == 0 {
        return Err(ProtocolError::InvalidFrameLength(frame_length));
    }
    if !helper_message_type_supported(message_type) {
        return Err(ProtocolError::UnexpectedMessage(message_type));
    }
    if frame_length > max_frame_length_for_message(message_type) {
        return Err(ProtocolError::InvalidFrameLength(frame_length));
    }

    let payload_length = frame_length - 1;
    let mut payload = vec![0u8; payload_length as usize];
    reader.read_exact(&mut payload)?;

    Ok(Some(Frame {
        message_type,
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
    if !helper_message_type_supported(message_type) {
        return Err(ProtocolError::UnexpectedMessage(message_type));
    }
    if frame_length > max_frame_length_for_message(message_type) {
        return Err(ProtocolError::InvalidFrameLength(frame_length));
    }

    writer.write_all(&frame_length.to_be_bytes())?;
    writer.write_all(&[message_type])?;
    writer.write_all(payload)?;
    writer.flush()?;

    Ok(())
}

fn helper_message_type_supported(message_type: u8) -> bool {
    matches!(
        message_type,
        MSG_OPEN | MSG_INPUT | MSG_MEDIA_FRAME | MSG_ACK | MSG_CLOSE | MSG_ERROR
    )
}

fn max_frame_length_for_message(message_type: u8) -> u32 {
    if message_type == MSG_MEDIA_FRAME {
        MAX_FRAME_LENGTH
    } else {
        MAX_CONTROL_FRAME_LENGTH
    }
}

#[cfg(test)]
mod lib_tests;
