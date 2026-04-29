use super::AppState;
use super::models::ErrorResponse;
use crate::runtime_config::load_runtime_config;
use axum::Json;
use axum::http::{HeaderMap, StatusCode};
use sha2::{Digest, Sha256};
use std::io::Read;
use std::time::{SystemTime, UNIX_EPOCH};

pub(super) fn internal_error(error: String) -> (StatusCode, Json<ErrorResponse>) {
    (
        StatusCode::INTERNAL_SERVER_ERROR,
        Json(ErrorResponse { error }),
    )
}

pub(super) async fn require_auth(
    state: &AppState,
    headers: &HeaderMap,
) -> Result<(), (StatusCode, Json<ErrorResponse>)> {
    let actual = extract_bearer_token(headers)?;

    if setup_token_matches(state, actual) {
        return Ok(());
    }

    let runtime_config = load_runtime_config(state.config())
        .await
        .map_err(internal_error)?;
    let actual_hash = hash_token(actual);
    if runtime_config
        .paired_devices
        .iter()
        .any(|device| constant_time_eq(device.token_hash.as_bytes(), actual_hash.as_bytes()))
    {
        Ok(())
    } else {
        Err((
            StatusCode::UNAUTHORIZED,
            Json(ErrorResponse {
                error: "invalid bearer token".to_string(),
            }),
        ))
    }
}

pub(super) fn require_setup_auth(
    state: &AppState,
    headers: &HeaderMap,
) -> Result<(), (StatusCode, Json<ErrorResponse>)> {
    ensure_setup_token_configured(state)?;
    let actual = extract_bearer_token(headers)?;

    if setup_token_matches(state, actual) {
        Ok(())
    } else {
        Err((
            StatusCode::UNAUTHORIZED,
            Json(ErrorResponse {
                error: "invalid setup token".to_string(),
            }),
        ))
    }
}

fn setup_token_matches(state: &AppState, actual: &str) -> bool {
    state
        .config
        .api_token
        .as_deref()
        .filter(|expected| !expected.is_empty())
        .is_some_and(|expected| constant_time_eq(expected.as_bytes(), actual.as_bytes()))
}

fn extract_bearer_token(headers: &HeaderMap) -> Result<&str, (StatusCode, Json<ErrorResponse>)> {
    headers
        .get(axum::http::header::AUTHORIZATION)
        .and_then(|value| value.to_str().ok())
        .and_then(|value| value.strip_prefix("Bearer "))
        .ok_or_else(|| {
            (
                StatusCode::UNAUTHORIZED,
                Json(ErrorResponse {
                    error: "missing bearer token".to_string(),
                }),
            )
        })
}

fn ensure_setup_token_configured(
    state: &AppState,
) -> Result<(), (StatusCode, Json<ErrorResponse>)> {
    if state
        .config
        .api_token
        .as_deref()
        .is_some_and(|token| !token.is_empty())
    {
        Ok(())
    } else {
        Err((
            StatusCode::FORBIDDEN,
            Json(ErrorResponse {
                error: "pairing is disabled until api_token is configured".to_string(),
            }),
        ))
    }
}

pub(crate) fn hash_token(token: &str) -> String {
    let digest = Sha256::digest(token.as_bytes());
    hex_encode(&digest)
}

pub(super) fn generate_pairing_token() -> Result<String, String> {
    let mut bytes = [0_u8; 32];
    std::fs::File::open("/dev/urandom")
        .and_then(|mut file| file.read_exact(&mut bytes))
        .map_err(|error| format!("failed to generate pairing token: {error}"))?;

    Ok(hex_encode(&bytes))
}

fn hex_encode(bytes: &[u8]) -> String {
    const HEX: &[u8; 16] = b"0123456789abcdef";
    let mut encoded = String::with_capacity(bytes.len() * 2);
    for byte in bytes {
        encoded.push(HEX[(byte >> 4) as usize] as char);
        encoded.push(HEX[(byte & 0x0f) as usize] as char);
    }
    encoded
}

pub(super) fn unix_secs_now() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_secs())
        .unwrap_or_default()
}

pub(crate) fn constant_time_eq(expected: &[u8], actual: &[u8]) -> bool {
    let mut diff = expected.len() ^ actual.len();
    let max_len = expected.len().max(actual.len());

    for idx in 0..max_len {
        let left = expected.get(idx).copied().unwrap_or_default();
        let right = actual.get(idx).copied().unwrap_or_default();
        diff |= usize::from(left ^ right);
    }

    diff == 0
}
