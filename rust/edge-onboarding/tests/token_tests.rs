/*
 * Copyright 2025 Carver Automation Corporation.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

//! Tests for token parsing functionality.

use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use base64::Engine;
use ed25519_dalek::{Signer, SigningKey};
use edge_onboarding::{encode_token, parse_token, Error, TokenPayload};
use std::sync::{Mutex, OnceLock};

const TOKEN_PREFIX: &str = "edgepkg-v2:";
const PRIVATE_KEY_ENV: &str = "SERVICERADAR_ONBOARDING_TOKEN_PRIVATE_KEY";
const PUBLIC_KEY_ENV: &str = "SERVICERADAR_ONBOARDING_TOKEN_PUBLIC_KEY";

fn env_lock() -> &'static Mutex<()> {
    static LOCK: OnceLock<Mutex<()>> = OnceLock::new();
    LOCK.get_or_init(|| Mutex::new(()))
}

fn test_signing_key() -> SigningKey {
    SigningKey::from_bytes(&[7u8; 32])
}

fn encode_signed_token(payload: &TokenPayload) -> String {
    let signing_key = test_signing_key();
    let json = serde_json::to_vec(payload).unwrap();
    let encoded_payload = URL_SAFE_NO_PAD.encode(&json);
    let signature = signing_key.sign(&json);
    let encoded_signature = URL_SAFE_NO_PAD.encode(signature.to_bytes());
    format!("{}{}.{}", TOKEN_PREFIX, encoded_payload, encoded_signature)
}

fn set_verification_key_env() {
    let signing_key = test_signing_key();
    let verifying_key = signing_key.verifying_key();
    std::env::set_var(PUBLIC_KEY_ENV, base64::engine::general_purpose::STANDARD.encode(verifying_key.to_bytes()));
}

fn set_signing_key_env() {
    std::env::set_var(
        PRIVATE_KEY_ENV,
        base64::engine::general_purpose::STANDARD.encode(test_signing_key().to_bytes()),
    );
}

fn clear_token_key_env() {
    std::env::remove_var(PRIVATE_KEY_ENV);
    std::env::remove_var(PUBLIC_KEY_ENV);
}

#[test]
fn test_parse_structured_signed_token() {
    let _guard = env_lock().lock().unwrap();
    set_verification_key_env();

    let payload = TokenPayload {
        package_id: "pkg-123".to_string(),
        download_token: "dl-456".to_string(),
        core_url: Some("https://core.example.com".to_string()),
    };
    let token = encode_signed_token(&payload);

    let parsed = parse_token(&token, None, None).unwrap();
    assert_eq!(parsed.package_id, "pkg-123");
    assert_eq!(parsed.download_token, "dl-456");
    assert_eq!(
        parsed.core_url,
        Some("https://core.example.com".to_string())
    );

    clear_token_key_env();
}

#[test]
fn test_parse_token_rejects_legacy_format() {
    let _guard = env_lock().lock().unwrap();
    clear_token_key_env();
    let parsed = parse_token("pkg-abc:token-xyz", None, None);
    assert!(matches!(parsed, Err(Error::UnsupportedTokenFormat)));
}

#[test]
fn test_parse_token_requires_verification_key() {
    let _guard = env_lock().lock().unwrap();
    clear_token_key_env();

    let payload = TokenPayload {
        package_id: "pkg-123".to_string(),
        download_token: "dl-456".to_string(),
        core_url: Some("https://core.example.com".to_string()),
    };
    let token = encode_signed_token(&payload);

    let parsed = parse_token(&token, None, None);
    assert!(matches!(parsed, Err(Error::TokenPublicKeyRequired)));
}

#[test]
fn test_parse_token_rejects_invalid_signature() {
    let _guard = env_lock().lock().unwrap();
    set_verification_key_env();

    let payload = TokenPayload {
        package_id: "pkg-123".to_string(),
        download_token: "dl-456".to_string(),
        core_url: Some("https://core.example.com".to_string()),
    };
    let token = encode_signed_token(&payload);
    let encoded = token.strip_prefix(TOKEN_PREFIX).unwrap();
    let (encoded_payload, encoded_signature) = encoded.split_once('.').unwrap();
    let payload_bytes = URL_SAFE_NO_PAD.decode(encoded_payload).unwrap();
    let mut tampered_payload: serde_json::Value = serde_json::from_slice(&payload_bytes).unwrap();
    tampered_payload["pkg"] = serde_json::Value::String("pkg-tampered".to_string());
    let tampered_payload_bytes = serde_json::to_vec(&tampered_payload).unwrap();
    let tampered = format!(
        "{}{}.{}",
        TOKEN_PREFIX,
        URL_SAFE_NO_PAD.encode(&tampered_payload_bytes),
        encoded_signature
    );

    let parsed = parse_token(&tampered, None, None);
    assert!(matches!(parsed, Err(Error::InvalidTokenSignature)));

    clear_token_key_env();
}

#[test]
fn test_empty_token_error() {
    let result = parse_token("", None, None);
    assert!(matches!(result, Err(Error::TokenRequired)));
}

#[test]
fn test_fallback_core_url_only_when_token_missing_api() {
    let _guard = env_lock().lock().unwrap();
    set_verification_key_env();

    let payload = TokenPayload {
        package_id: "pkg-123".to_string(),
        download_token: "dl-456".to_string(),
        core_url: None,
    };
    let token = encode_signed_token(&payload);

    let parsed = parse_token(&token, None, Some("https://fallback.com")).unwrap();
    assert_eq!(parsed.core_url, Some("https://fallback.com".to_string()));

    clear_token_key_env();
}

#[test]
fn test_fallback_core_url_does_not_override_token_api_url() {
    let _guard = env_lock().lock().unwrap();
    set_verification_key_env();

    let payload = TokenPayload {
        package_id: "pkg-123".to_string(),
        download_token: "dl-456".to_string(),
        core_url: Some("https://token.example.com".to_string()),
    };
    let token = encode_signed_token(&payload);

    let parsed = parse_token(&token, None, Some("https://override.example.com")).unwrap();
    assert_eq!(
        parsed.core_url,
        Some("https://token.example.com".to_string())
    );

    clear_token_key_env();
}

#[test]
fn test_whitespace_only_token() {
    let result = parse_token("   ", None, None);
    assert!(matches!(result, Err(Error::TokenRequired)));
}

#[test]
fn test_invalid_base64_token() {
    let _guard = env_lock().lock().unwrap();
    set_verification_key_env();

    let result = parse_token("edgepkg-v2:!!!invalid!!!.sig", None, None);
    assert!(matches!(result, Err(Error::Base64Decode(_))));

    clear_token_key_env();
}

#[test]
fn test_invalid_json_in_token() {
    let _guard = env_lock().lock().unwrap();
    set_verification_key_env();

    let signing_key = test_signing_key();
    let invalid_json = b"not json";
    let encoded_payload = URL_SAFE_NO_PAD.encode(invalid_json);
    let encoded_signature = URL_SAFE_NO_PAD.encode(signing_key.sign(invalid_json).to_bytes());
    let token = format!("{}{}.{}", TOKEN_PREFIX, encoded_payload, encoded_signature);

    let result = parse_token(&token, None, None);
    assert!(matches!(result, Err(Error::Json(_))));

    clear_token_key_env();
}

#[test]
fn test_token_missing_package_id() {
    let _guard = env_lock().lock().unwrap();
    set_verification_key_env();

    let signing_key = test_signing_key();
    let json = serde_json::json!({"dl": "token-123"});
    let json_bytes = serde_json::to_vec(&json).unwrap();
    let encoded_payload = URL_SAFE_NO_PAD.encode(&json_bytes);
    let encoded_signature = URL_SAFE_NO_PAD.encode(signing_key.sign(&json_bytes).to_bytes());
    let token = format!("{}{}.{}", TOKEN_PREFIX, encoded_payload, encoded_signature);

    let result = parse_token(&token, None, None);
    assert!(matches!(result, Err(Error::Json(_))));

    clear_token_key_env();
}

#[test]
fn test_token_missing_download_token() {
    let _guard = env_lock().lock().unwrap();
    set_verification_key_env();

    let signing_key = test_signing_key();
    let json = serde_json::json!({"pkg": "pkg-123"});
    let json_bytes = serde_json::to_vec(&json).unwrap();
    let encoded_payload = URL_SAFE_NO_PAD.encode(&json_bytes);
    let encoded_signature = URL_SAFE_NO_PAD.encode(signing_key.sign(&json_bytes).to_bytes());
    let token = format!("{}{}.{}", TOKEN_PREFIX, encoded_payload, encoded_signature);

    let result = parse_token(&token, None, None);
    assert!(matches!(result, Err(Error::Json(_))));

    clear_token_key_env();
}

#[test]
fn test_token_empty_package_id_with_fallback() {
    let _guard = env_lock().lock().unwrap();
    set_verification_key_env();

    let payload = TokenPayload {
        package_id: "".to_string(),
        download_token: "token-123".to_string(),
        core_url: None,
    };
    let token = encode_signed_token(&payload);

    let parsed = parse_token(&token, Some("fallback-pkg"), None).unwrap();
    assert_eq!(parsed.package_id, "fallback-pkg");
    assert_eq!(parsed.download_token, "token-123");

    clear_token_key_env();
}

#[test]
fn test_token_payload_clone() {
    let _guard = env_lock().lock().unwrap();
    let payload = TokenPayload {
        package_id: "pkg-123".to_string(),
        download_token: "dl-456".to_string(),
        core_url: Some("https://example.com".to_string()),
    };
    let cloned = payload.clone();
    assert_eq!(cloned.package_id, payload.package_id);
    assert_eq!(cloned.download_token, payload.download_token);
    assert_eq!(cloned.core_url, payload.core_url);
}

#[test]
fn test_encode_token_validation() {
    let _guard = env_lock().lock().unwrap();
    set_signing_key_env();

    let empty_pkg = TokenPayload {
        package_id: "".to_string(),
        download_token: "token".to_string(),
        core_url: None,
    };
    let result = encode_token(&empty_pkg);
    assert!(matches!(result, Err(Error::MissingPackageId)));

    let empty_dl = TokenPayload {
        package_id: "pkg".to_string(),
        download_token: "".to_string(),
        core_url: None,
    };
    let result = encode_token(&empty_dl);
    assert!(matches!(result, Err(Error::MissingDownloadToken)));

    clear_token_key_env();
}

#[test]
fn test_encode_decode_roundtrip() {
    let _guard = env_lock().lock().unwrap();
    set_signing_key_env();
    set_verification_key_env();

    let original = TokenPayload {
        package_id: "test-pkg-123".to_string(),
        download_token: "test-dl-456".to_string(),
        core_url: Some("https://api.example.com".to_string()),
    };

    let encoded = encode_token(&original).unwrap();
    assert!(encoded.starts_with("edgepkg-v2:"));
    assert!(encoded.contains('.'));

    let decoded = parse_token(&encoded, None, None).unwrap();
    assert_eq!(decoded.package_id, original.package_id);
    assert_eq!(decoded.download_token, original.download_token);
    assert_eq!(decoded.core_url, original.core_url);

    clear_token_key_env();
}
