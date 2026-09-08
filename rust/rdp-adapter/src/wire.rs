use std::io::{ErrorKind, Read, Write};

use crate::ProtocolError;

const HEADER_LEN: usize = 5;

pub(crate) const MAX_FRAME_LENGTH: u32 = 16 * 1024 * 1024;
pub(crate) const MAX_CONTROL_FRAME_LENGTH: u32 = 512 * 1024;

pub(crate) const MSG_OPEN: u8 = 1;
pub(crate) const MSG_INPUT: u8 = 2;
pub(crate) const MSG_MEDIA_FRAME: u8 = 3;
pub(crate) const MSG_ACK: u8 = 4;
pub(crate) const MSG_CLOSE: u8 = 5;
pub(crate) const MSG_ERROR: u8 = 6;

#[derive(Debug, Eq, PartialEq)]
pub(crate) struct Frame {
    pub(crate) message_type: u8,
    pub(crate) payload: Vec<u8>,
}

pub(crate) fn read_frame<R: Read>(reader: &mut R) -> Result<Option<Frame>, ProtocolError> {
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

pub(crate) fn write_error_frame<W: Write>(
    writer: &mut W,
    message: &str,
) -> Result<(), ProtocolError> {
    write_frame(writer, MSG_ERROR, message.as_bytes())
}

pub(crate) fn write_frame<W: Write>(
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
