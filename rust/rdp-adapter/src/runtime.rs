use std::io::{Read, Write};
use std::sync::mpsc::{self, RecvTimeoutError};
use std::thread;
use std::time::Duration;

use zeroize::Zeroize;

use crate::ProtocolError;
#[cfg(not(feature = "ironrdp-backend"))]
use crate::backend::UnavailableBackend;
use crate::backend::{RdpBackend, RdpBackendSession};
#[cfg(feature = "ironrdp-backend")]
use crate::backend_ironrdp::IronRdpBackend;
use crate::protocol::{self, DesktopClosePayload, DesktopFrame, parse_open_payload};
use crate::protocol::{DesktopMediaAck, OpenPayload};
use crate::wire::{
    Frame, MSG_ACK, MSG_CLOSE, MSG_INPUT, MSG_MEDIA_FRAME, MSG_OPEN, read_frame, write_error_frame,
    write_frame,
};

const DEFAULT_BACKEND_PUMP_INTERVAL: Duration = Duration::from_millis(10);
const MAX_SESSION_ACK_CREDIT_BYTES: u64 = 64 * 1024 * 1024;

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

            if let Some(mut active) = active_session.take()
                && let Err(err) = active.session.close(&close)
            {
                write_error_frame(writer, err.safe_message())?;
                return Err(err.into());
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

pub(crate) fn parse_and_clear_open_payload(
    payload: &mut [u8],
) -> Result<OpenPayload, protocol::OpenPayloadError> {
    let result = parse_open_payload(payload);
    payload.zeroize();

    result
}

pub(crate) fn parse_and_clear_input_payload(
    payload: &mut [u8],
    session_id: &str,
    policy: &protocol::DesktopScreenPolicy,
) -> Result<DesktopFrame, protocol::DesktopFrameError> {
    let result = protocol::parse_desktop_frame(payload, session_id, policy);
    payload.zeroize();

    result
}

pub(crate) fn parse_and_clear_ack_payload(
    payload: &mut [u8],
    session_id: &str,
) -> Result<DesktopMediaAck, protocol::DesktopMediaAckError> {
    let result = protocol::parse_desktop_media_ack(payload, session_id);
    payload.zeroize();

    result
}

pub(crate) fn parse_and_clear_close_payload(
    payload: &mut [u8],
) -> Result<DesktopClosePayload, protocol::DesktopClosePayloadError> {
    let result = protocol::parse_desktop_close_payload(payload);
    payload.zeroize();

    result
}
