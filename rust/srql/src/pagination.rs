//! Cursor encoding helpers for SRQL pagination.

use crate::error::{Result, ServiceError};
use base64::Engine as _;
use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use hmac::{Hmac, Mac};
use serde::{Deserialize, Serialize};
use sha2::Sha256;

type HmacSha256 = Hmac<Sha256>;

#[derive(Debug, Serialize, Deserialize)]
struct CursorPayload {
    v: u8,
    offset: i64,
    sig: String,
}

pub fn decode_cursor(cursor: &str, secret: &str, max_offset: i64) -> Result<i64> {
    let bytes = URL_SAFE_NO_PAD
        .decode(cursor)
        .map_err(|_| ServiceError::InvalidRequest("invalid cursor".into()))?;
    let payload: CursorPayload = serde_json::from_slice(&bytes)
        .map_err(|_| ServiceError::InvalidRequest("invalid cursor payload".into()))?;
    if payload.v != 2 {
        return Err(ServiceError::InvalidRequest(
            "unsupported cursor version".into(),
        ));
    }
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
    verify_offset_signature(payload.offset, secret, &payload.sig)?;
    Ok(payload.offset)
}

pub fn encode_cursor(offset: i64, secret: &str) -> Result<String> {
    let offset = offset.max(0);
    let payload = CursorPayload {
        v: 2,
        offset,
        sig: sign_offset(offset, secret)?,
    };
    let bytes = serde_json::to_vec(&payload)
        .map_err(|_| ServiceError::InvalidRequest("failed to encode cursor".into()))?;
    Ok(URL_SAFE_NO_PAD.encode(bytes))
}

fn sign_offset(offset: i64, secret: &str) -> Result<String> {
    Ok(URL_SAFE_NO_PAD.encode(cursor_mac(offset, secret)?.finalize().into_bytes()))
}

fn verify_offset_signature(offset: i64, secret: &str, signature: &str) -> Result<()> {
    let signature_bytes = URL_SAFE_NO_PAD
        .decode(signature.as_bytes())
        .map_err(|_| ServiceError::InvalidRequest("invalid cursor signature".into()))?;

    cursor_mac(offset, secret)?
        .verify_slice(&signature_bytes)
        .map_err(|_| ServiceError::InvalidRequest("invalid cursor signature".into()))
}

fn cursor_mac(offset: i64, secret: &str) -> Result<HmacSha256> {
    if secret.trim().is_empty() {
        return Err(ServiceError::InvalidRequest(
            "cursor signing secret must not be empty".into(),
        ));
    }
    let mut mac = HmacSha256::new_from_slice(secret.as_bytes())
        .map_err(|_| ServiceError::InvalidRequest("invalid cursor signing secret".into()))?;
    mac.update(b"srql-cursor-v2:");
    mac.update(offset.to_string().as_bytes());
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
}
