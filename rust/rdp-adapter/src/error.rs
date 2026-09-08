use std::error::Error;
use std::fmt;
use std::io;

use crate::{BackendError, protocol};

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
