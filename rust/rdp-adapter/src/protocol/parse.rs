use super::constants::{FRAME_TYPE_DISCONNECT, MAX_ACK_CLOSE_REASON_BYTES, MAX_CLOSE_REASON_BYTES};
use super::errors::{
    DesktopClosePayloadError, DesktopFrameError, DesktopMediaAckError, OpenPayloadError,
};
use super::types::{
    DesktopClosePayload, DesktopFrame, DesktopMediaAck, DesktopMediaAckMessage,
    DesktopScreenPolicy, OpenPayload,
};
use super::validation::{
    validate_desktop_frame, validate_desktop_media_ack_message, validate_open_payload,
};

pub fn parse_open_payload(payload: &[u8]) -> Result<OpenPayload, OpenPayloadError> {
    let parsed: OpenPayload =
        serde_json::from_slice(payload).map_err(|_| OpenPayloadError::Decode)?;
    validate_open_payload(&parsed)?;

    Ok(parsed)
}

pub fn parse_desktop_media_ack(
    payload: &[u8],
    session_id: &str,
) -> Result<DesktopMediaAck, DesktopMediaAckError> {
    let mut parsed: DesktopMediaAckMessage =
        serde_json::from_slice(payload).map_err(|_| DesktopMediaAckError::Decode)?;
    validate_desktop_media_ack_message(&parsed, session_id)?;
    parsed.ack.close_reason =
        normalize_terminal_reason(&parsed.ack.close_reason, MAX_ACK_CLOSE_REASON_BYTES);

    Ok(parsed.ack)
}

pub fn parse_desktop_frame(
    payload: &[u8],
    session_id: &str,
    policy: &DesktopScreenPolicy,
) -> Result<DesktopFrame, DesktopFrameError> {
    let mut parsed: DesktopFrame =
        serde_json::from_slice(payload).map_err(|_| DesktopFrameError::Decode)?;
    validate_desktop_frame(&parsed, session_id, policy)?;
    if parsed.frame_type == FRAME_TYPE_DISCONNECT {
        parsed.reason = normalize_terminal_reason(&parsed.reason, MAX_CLOSE_REASON_BYTES);
    }

    Ok(parsed)
}

pub fn parse_desktop_close_payload(
    payload: &[u8],
) -> Result<DesktopClosePayload, DesktopClosePayloadError> {
    if payload.is_empty() {
        return Ok(DesktopClosePayload::default());
    }

    let mut parsed: DesktopClosePayload =
        serde_json::from_slice(payload).map_err(|_| DesktopClosePayloadError::Decode)?;
    if parsed.reason.trim().len() > MAX_CLOSE_REASON_BYTES {
        return Err(DesktopClosePayloadError::ReasonTooLarge);
    }
    parsed.reason = normalize_terminal_reason(&parsed.reason, MAX_CLOSE_REASON_BYTES);

    Ok(parsed)
}

fn normalize_terminal_reason(reason: &str, max_bytes: usize) -> String {
    let reason = reason.trim();
    if reason.is_empty() {
        return String::new();
    }

    let mut normalized = String::with_capacity(reason.len().min(max_bytes));
    for ch in reason.chars() {
        let ch = if ch.is_control() { ' ' } else { ch };
        let mut encoded = [0; 4];
        let rendered = ch.encode_utf8(&mut encoded);
        if normalized.len() + rendered.len() > max_bytes {
            break;
        }
        normalized.push(ch);
    }

    normalized.trim().to_owned()
}
