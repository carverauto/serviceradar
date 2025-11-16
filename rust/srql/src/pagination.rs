//! Cursor encoding helpers for SRQL pagination.

use crate::error::{Result, ServiceError};
use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use base64::Engine as _;
use serde::{Deserialize, Serialize};

#[derive(Debug, Serialize, Deserialize)]
struct CursorPayload {
    offset: i64,
}

pub fn decode_cursor(cursor: &str) -> Result<i64> {
    let bytes = URL_SAFE_NO_PAD
        .decode(cursor)
        .map_err(|_| ServiceError::InvalidRequest("invalid cursor".into()))?;
    let payload: CursorPayload = serde_json::from_slice(&bytes)
        .map_err(|_| ServiceError::InvalidRequest("invalid cursor payload".into()))?;
    Ok(payload.offset.max(0))
}

pub fn encode_cursor(offset: i64) -> String {
    let payload = CursorPayload {
        offset: offset.max(0),
    };
    URL_SAFE_NO_PAD.encode(serde_json::to_vec(&payload).unwrap_or_default())
}
