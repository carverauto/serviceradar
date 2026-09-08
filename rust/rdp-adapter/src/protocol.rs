mod constants;
mod errors;
mod parse;
mod types;
mod validation;

pub use errors::{
    DesktopClosePayloadError, DesktopFrameError, DesktopMediaAckError, OpenPayloadError,
};
pub use parse::{
    parse_desktop_close_payload, parse_desktop_frame, parse_desktop_media_ack, parse_open_payload,
};
#[allow(unused_imports)]
pub use types::{
    DesktopClosePayload, DesktopCredentialGrant, DesktopCredentialPolicy, DesktopFrame,
    DesktopInputEvent, DesktopMediaAck, DesktopMediaAckMessage, DesktopQuality,
    DesktopRecordingPolicy, DesktopRedirectionPolicy, DesktopRoute, DesktopScreenPolicy,
    DesktopTarget, DesktopTlsPolicy, DesktopUpstream, OpenPayload, SensitiveString,
};

#[cfg(test)]
pub(crate) mod tests;
