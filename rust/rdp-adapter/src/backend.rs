use std::error::Error;
use std::fmt;

use crate::protocol::{DesktopMediaAck, OpenPayload};

const BACKEND_UNAVAILABLE: &str = "IronRDP backend is not linked into this helper build";

pub trait RdpBackend {
    fn open(&mut self, request: OpenPayload) -> Result<Box<dyn RdpBackendSession>, BackendError>;
}

pub trait RdpBackendSession {
    fn input(&mut self, payload: &[u8]) -> Result<(), BackendError>;
    fn ack(&mut self, ack: &DesktopMediaAck) -> Result<(), BackendError>;
    fn close(&mut self, payload: &[u8]) -> Result<(), BackendError>;
}

#[derive(Default)]
pub struct UnavailableBackend;

impl RdpBackend for UnavailableBackend {
    fn open(&mut self, _request: OpenPayload) -> Result<Box<dyn RdpBackendSession>, BackendError> {
        Err(BackendError::Unavailable)
    }
}

#[derive(Debug, Eq, PartialEq)]
pub enum BackendError {
    Unavailable,
    Unsupported(&'static str),
}

impl BackendError {
    pub fn safe_message(&self) -> &'static str {
        match self {
            Self::Unavailable => BACKEND_UNAVAILABLE,
            Self::Unsupported(message) => message,
        }
    }
}

impl fmt::Display for BackendError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.safe_message())
    }
}

impl Error for BackendError {}
