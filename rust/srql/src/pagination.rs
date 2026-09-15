//! Cursor encoding helpers for SRQL pagination.

use crate::error::{Result, ServiceError};
use crate::time::TimeRange;
use base64::Engine as _;
use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use chrono::{DateTime, Utc};
use hmac::{Hmac, Mac};
use serde::{Deserialize, Serialize};
use sha2::Sha256;

type HmacSha256 = Hmac<Sha256>;

#[derive(Debug, Serialize, Deserialize)]
struct CursorPayload {
    v: u8,
    offset: i64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    start: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    end: Option<String>,
    sig: String,
}

/// Offset plus optional pinned time window (duckdb dialect, cursor v3).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CursorState {
    pub offset: i64,
    pub time_range: Option<TimeRange>,
}

pub fn decode_cursor(cursor: &str, secret: &str, max_offset: i64) -> Result<i64> {
    Ok(decode_cursor_state(cursor, secret, max_offset)?.offset)
}

pub fn decode_cursor_state(cursor: &str, secret: &str, max_offset: i64) -> Result<CursorState> {
    let bytes = URL_SAFE_NO_PAD
        .decode(cursor)
        .map_err(|_| ServiceError::InvalidRequest("invalid cursor".into()))?;
    let payload: CursorPayload = serde_json::from_slice(&bytes)
        .map_err(|_| ServiceError::InvalidRequest("invalid cursor payload".into()))?;
    if payload.offset < 0 {
        return Err(ServiceError::InvalidRequest(
            "cursor offset must be non-negative".into(),
        ));
    }
    if payload.offset > max_offset {
        return Err(ServiceError::InvalidRequest(format!(
            "cursor offset exceeds maximum of {max_offset}"
        )));
    }
    match payload.v {
        2 => {
            verify_signature(&payload, secret)?;
            Ok(CursorState {
                offset: payload.offset,
                time_range: None,
            })
        }
        3 => {
            verify_signature(&payload, secret)?;
            let start = parse_window_instant(payload.start.as_deref(), "start")?;
            let end = parse_window_instant(payload.end.as_deref(), "end")?;
            Ok(CursorState {
                offset: payload.offset,
                time_range: Some(TimeRange { start, end }),
            })
        }
        _ => Err(ServiceError::InvalidRequest(
            "unsupported cursor version".into(),
        )),
    }
}

pub fn encode_cursor(offset: i64, secret: &str) -> Result<String> {
    encode_cursor_maybe_window(offset, secret, None)
}

pub fn encode_cursor_maybe_window(
    offset: i64,
    secret: &str,
    window: Option<&TimeRange>,
) -> Result<String> {
    let offset = offset.max(0);
    let (v, start, end) = match window {
        Some(range) => (
            3,
            Some(range.start.to_rfc3339()),
            Some(range.end.to_rfc3339()),
        ),
        None => (2, None, None),
    };
    let mut payload = CursorPayload {
        v,
        offset,
        start,
        end,
        sig: String::new(),
    };
    payload.sig = sign_payload(&payload, secret)?;
    let bytes = serde_json::to_vec(&payload)
        .map_err(|_| ServiceError::InvalidRequest("failed to encode cursor".into()))?;
    Ok(URL_SAFE_NO_PAD.encode(bytes))
}

fn parse_window_instant(value: Option<&str>, field: &str) -> Result<DateTime<Utc>> {
    let raw = value
        .ok_or_else(|| ServiceError::InvalidRequest(format!("cursor window missing {field}")))?;
    DateTime::parse_from_rfc3339(raw)
        .map(|dt| dt.with_timezone(&Utc))
        .map_err(|_| ServiceError::InvalidRequest(format!("invalid cursor window {field}")))
}

fn sign_payload(payload: &CursorPayload, secret: &str) -> Result<String> {
    Ok(URL_SAFE_NO_PAD.encode(cursor_mac(payload, secret)?.finalize().into_bytes()))
}

fn verify_signature(payload: &CursorPayload, secret: &str) -> Result<()> {
    let signature_bytes = URL_SAFE_NO_PAD
        .decode(payload.sig.as_bytes())
        .map_err(|_| ServiceError::InvalidRequest("invalid cursor signature".into()))?;

    cursor_mac(payload, secret)?
        .verify_slice(&signature_bytes)
        .map_err(|_| ServiceError::InvalidRequest("invalid cursor signature".into()))
}

fn cursor_mac(payload: &CursorPayload, secret: &str) -> Result<HmacSha256> {
    if secret.trim().is_empty() {
        return Err(ServiceError::InvalidRequest(
            "cursor signing secret must not be empty".into(),
        ));
    }
    let mut mac = HmacSha256::new_from_slice(secret.as_bytes())
        .map_err(|_| ServiceError::InvalidRequest("invalid cursor signing secret".into()))?;
    match payload.v {
        2 => {
            mac.update(b"srql-cursor-v2:");
            mac.update(payload.offset.to_string().as_bytes());
        }
        3 => {
            mac.update(b"srql-cursor-v3:");
            mac.update(payload.offset.to_string().as_bytes());
            mac.update(b":");
            mac.update(payload.start.as_deref().unwrap_or_default().as_bytes());
            mac.update(b":");
            mac.update(payload.end.as_deref().unwrap_or_default().as_bytes());
        }
        _ => {
            return Err(ServiceError::InvalidRequest(
                "unsupported cursor version".into(),
            ));
        }
    }
    Ok(mac)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn round_trip_cursor() {
        let encoded = encode_cursor(250, "secret").unwrap();
        let decoded = decode_cursor(&encoded, "secret", 1_000).unwrap();
        assert_eq!(decoded, 250);
    }

    #[test]
    fn decode_rejects_bad_data() {
        let err = decode_cursor("$$$", "secret", 1_000).unwrap_err();
        assert!(matches!(err, ServiceError::InvalidRequest(_)));
    }

    #[test]
    fn decode_rejects_tampered_signature() {
        let encoded = encode_cursor(250, "secret").unwrap();
        let err = decode_cursor(&encoded, "other-secret", 1_000).unwrap_err();
        assert!(matches!(err, ServiceError::InvalidRequest(_)));
    }

    #[test]
    fn decode_rejects_offset_above_bound() {
        let encoded = encode_cursor(1_001, "secret").unwrap();
        let err = decode_cursor(&encoded, "secret", 1_000).unwrap_err();
        assert!(matches!(err, ServiceError::InvalidRequest(_)));
    }

    #[test]
    fn decode_rejects_malformed_signature_encoding() {
        let payload = CursorPayload {
            v: 2,
            offset: 250,
            start: None,
            end: None,
            sig: "$$$".to_string(),
        };
        let encoded = URL_SAFE_NO_PAD.encode(serde_json::to_vec(&payload).unwrap());

        let err = decode_cursor(&encoded, "secret", 1_000).unwrap_err();
        assert!(matches!(err, ServiceError::InvalidRequest(_)));
    }

    #[test]
    fn encode_rejects_empty_secret() {
        let err = encode_cursor(250, "   ").unwrap_err();
        assert!(matches!(err, ServiceError::InvalidRequest(_)));
    }

    #[test]
    fn windowed_cursor_round_trips_the_absolute_range() {
        let range = TimeRange {
            start: DateTime::parse_from_rfc3339("2026-09-14T12:00:00Z")
                .unwrap()
                .with_timezone(&Utc),
            end: DateTime::parse_from_rfc3339("2026-09-14T18:00:00Z")
                .unwrap()
                .with_timezone(&Utc),
        };
        let encoded = encode_cursor_maybe_window(50, "secret", Some(&range)).unwrap();
        let state = decode_cursor_state(&encoded, "secret", 1_000).unwrap();
        assert_eq!(state.offset, 50);
        assert_eq!(state.time_range.as_ref(), Some(&range));
        assert_eq!(decode_cursor(&encoded, "secret", 1_000).unwrap(), 50);
    }

    #[test]
    fn windowed_cursor_rejects_a_swapped_range() {
        let range = TimeRange {
            start: DateTime::parse_from_rfc3339("2026-09-14T12:00:00Z")
                .unwrap()
                .with_timezone(&Utc),
            end: DateTime::parse_from_rfc3339("2026-09-14T18:00:00Z")
                .unwrap()
                .with_timezone(&Utc),
        };
        let encoded = encode_cursor_maybe_window(50, "secret", Some(&range)).unwrap();
        let bytes = URL_SAFE_NO_PAD.decode(&encoded).unwrap();
        let mut payload: CursorPayload = serde_json::from_slice(&bytes).unwrap();
        payload.end = Some("2026-09-15T00:00:00Z".into());
        let tampered = URL_SAFE_NO_PAD.encode(serde_json::to_vec(&payload).unwrap());
        let err = decode_cursor_state(&tampered, "secret", 1_000).unwrap_err();
        assert!(matches!(err, ServiceError::InvalidRequest(_)));
    }
}
