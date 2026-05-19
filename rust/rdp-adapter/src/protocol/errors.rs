use std::error::Error;
use std::fmt;

#[derive(Debug, Eq, PartialEq)]
pub enum OpenPayloadError {
    Decode,
    InvalidSchema,
    MissingSession,
    MissingActor,
    InvalidSessionPolicy,
    MissingAgent,
    UnsupportedProtocol,
    MissingRoute,
    MissingTarget,
    MissingUpstream,
    UnsupportedTlsPolicy,
    UnsupportedCredentialMode,
    InvalidScreenPolicy,
    UnsupportedRedirection,
    UnsupportedRecordingPolicy,
    InvalidCredentialGrant,
}

#[derive(Debug, Eq, PartialEq)]
pub enum DesktopMediaAckError {
    Decode,
    InvalidType,
    MissingSession,
    SessionMismatch,
    MissingMediaSession,
    AmbiguousFlowControl,
    UnsupportedQuality,
    CreditTooLarge,
    CloseReasonTooLarge,
}

#[derive(Debug, Eq, PartialEq)]
pub enum DesktopFrameError {
    Decode,
    MissingSession,
    SessionMismatch,
    UnsupportedProtocol,
    UnsupportedFrameType,
    InvalidDimensions,
    InvalidInputEvent,
    InputTokenTooLarge,
    PointerOutOfBounds,
    MissingQualityRequest,
    QualityExceedsPolicy,
    ReasonTooLarge,
}

#[derive(Debug, Eq, PartialEq)]
pub enum DesktopClosePayloadError {
    Decode,
    ReasonTooLarge,
}

impl fmt::Display for DesktopMediaAckError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Decode => f.write_str("decode failed"),
            Self::InvalidType => f.write_str("ack type is unsupported"),
            Self::MissingSession => f.write_str("session binding id is required"),
            Self::SessionMismatch => f.write_str("session binding mismatch"),
            Self::MissingMediaSession => f.write_str("media session id is required"),
            Self::AmbiguousFlowControl => f.write_str("pause and resume cannot both be set"),
            Self::UnsupportedQuality => f.write_str("quality level is unsupported"),
            Self::CreditTooLarge => f.write_str("ack credit is too large"),
            Self::CloseReasonTooLarge => f.write_str("close reason is too large"),
        }
    }
}

impl Error for DesktopMediaAckError {}

impl fmt::Display for DesktopFrameError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Decode => f.write_str("decode failed"),
            Self::MissingSession => f.write_str("session id is required"),
            Self::SessionMismatch => f.write_str("session binding mismatch"),
            Self::UnsupportedProtocol => f.write_str("desktop protocol is unsupported"),
            Self::UnsupportedFrameType => f.write_str("desktop frame type is unsupported"),
            Self::InvalidDimensions => f.write_str("desktop dimensions are invalid"),
            Self::InvalidInputEvent => f.write_str("desktop input event is invalid"),
            Self::InputTokenTooLarge => f.write_str("desktop input token is too large"),
            Self::PointerOutOfBounds => f.write_str("desktop pointer coordinates exceed policy"),
            Self::MissingQualityRequest => f.write_str("desktop quality request is required"),
            Self::QualityExceedsPolicy => f.write_str("desktop quality request exceeds policy"),
            Self::ReasonTooLarge => f.write_str("desktop reason is too large"),
        }
    }
}

impl Error for DesktopFrameError {}

impl fmt::Display for DesktopClosePayloadError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Decode => f.write_str("decode failed"),
            Self::ReasonTooLarge => f.write_str("close reason is too large"),
        }
    }
}

impl Error for DesktopClosePayloadError {}

impl fmt::Display for OpenPayloadError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Decode => f.write_str("decode failed"),
            Self::InvalidSchema => f.write_str("schema is unsupported"),
            Self::MissingSession => f.write_str("session id is required"),
            Self::MissingActor => f.write_str("actor id is required"),
            Self::InvalidSessionPolicy => f.write_str("session policy is invalid"),
            Self::MissingAgent => f.write_str("local agent id is required"),
            Self::UnsupportedProtocol => f.write_str("target protocol is unsupported"),
            Self::MissingRoute => f.write_str("selected agent route is required"),
            Self::MissingTarget => f.write_str("target id is required"),
            Self::MissingUpstream => f.write_str("upstream host and port are required"),
            Self::UnsupportedTlsPolicy => f.write_str("target TLS/NLA policy is unsupported"),
            Self::UnsupportedCredentialMode => f.write_str("credential mode is unsupported"),
            Self::InvalidScreenPolicy => f.write_str("desktop screen policy is invalid"),
            Self::UnsupportedRedirection => {
                f.write_str("desktop redirection policy is unsupported")
            }
            Self::UnsupportedRecordingPolicy => {
                f.write_str("desktop content recording policy is unsupported")
            }
            Self::InvalidCredentialGrant => f.write_str("credential grant is invalid"),
        }
    }
}

impl Error for OpenPayloadError {}
