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
use edge_onboarding::{parse_token, Error, TokenPayload};

const TOKEN_PREFIX: &str = "edgepkg-v1:";

/// Helper to encode a token payload for testing.
fn encode_test_token(payload: &TokenPayload) -> String {
    let json = serde_json::to_vec(payload).unwrap();
    let encoded = URL_SAFE_NO_PAD.encode(&json);
    format!("{}{}", TOKEN_PREFIX, encoded)
}

#[test]
fn test_parse_structured_token() {
    let payload = TokenPayload {
        package_id: "pkg-123".to_string(),
        download_token: "dl-456".to_string(),
        core_url: Some("https://core.example.com".to_string()),
    };
    let token = encode_test_token(&payload);

    let parsed = parse_token(&token, None, None).unwrap();
    assert_eq!(parsed.package_id, "pkg-123");
    assert_eq!(parsed.download_token, "dl-456");
    assert_eq!(
        parsed.core_url,
        Some("https://core.example.com".to_string())
    );
}

#[test]
fn test_parse_legacy_token() {
    let parsed = parse_token("pkg-abc:token-xyz", None, None).unwrap();
    assert_eq!(parsed.package_id, "pkg-abc");
    assert_eq!(parsed.download_token, "token-xyz");
}

#[test]
fn test_parse_legacy_token_with_url() {
    let parsed =
        parse_token("https://core.example.com@pkg-abc:token-xyz", None, None).unwrap();
    assert_eq!(parsed.package_id, "pkg-abc");
    assert_eq!(parsed.download_token, "token-xyz");
    assert_eq!(
        parsed.core_url,
        Some("https://core.example.com".to_string())
    );
}

#[test]
fn test_empty_token_error() {
    let result = parse_token("", None, None);
    assert!(matches!(result, Err(Error::TokenRequired)));
}

#[test]
fn test_fallback_core_url() {
    let payload = TokenPayload {
        package_id: "pkg-123".to_string(),
        download_token: "dl-456".to_string(),
        core_url: None,
    };
    let token = encode_test_token(&payload);

    let parsed = parse_token(&token, None, Some("https://fallback.com")).unwrap();
    assert_eq!(parsed.core_url, Some("https://fallback.com".to_string()));
}

#[test]
fn test_whitespace_only_token() {
    let result = parse_token("   ", None, None);
    assert!(matches!(result, Err(Error::TokenRequired)));
}

#[test]
fn test_invalid_base64_token() {
    // Invalid base64 after the prefix
    let result = parse_token("edgepkg-v1:!!!invalid!!!", None, None);
    assert!(matches!(result, Err(Error::Base64Decode(_))));
}

#[test]
fn test_invalid_json_in_token() {
    // Valid base64 but invalid JSON
    let invalid_json = URL_SAFE_NO_PAD.encode(b"not json");
    let token = format!("{}{}", TOKEN_PREFIX, invalid_json);
    let result = parse_token(&token, None, None);
    assert!(matches!(result, Err(Error::Json(_))));
}

#[test]
fn test_token_missing_package_id() {
    // When the JSON is missing the `pkg` field, serde returns a JSON parse error
    let json = serde_json::json!({"dl": "token-123"});
    let encoded = URL_SAFE_NO_PAD.encode(json.to_string().as_bytes());
    let token = format!("{}{}", TOKEN_PREFIX, encoded);
    let result = parse_token(&token, None, None);
    // This fails with JSON error because pkg is a required field in the struct
    assert!(matches!(result, Err(Error::Json(_))));
}

#[test]
fn test_token_missing_download_token() {
    // When the JSON is missing the `dl` field, serde returns a JSON parse error
    let json = serde_json::json!({"pkg": "pkg-123"});
    let encoded = URL_SAFE_NO_PAD.encode(json.to_string().as_bytes());
    let token = format!("{}{}", TOKEN_PREFIX, encoded);
    let result = parse_token(&token, None, None);
    // This fails with JSON error because dl is a required field in the struct
    assert!(matches!(result, Err(Error::Json(_))));
}

#[test]
fn test_token_empty_package_id_with_fallback() {
    // Test fallback for empty (but present) package_id
    let json = serde_json::json!({"pkg": "", "dl": "token-123"});
    let encoded = URL_SAFE_NO_PAD.encode(json.to_string().as_bytes());
    let token = format!("{}{}", TOKEN_PREFIX, encoded);
    let parsed = parse_token(&token, Some("fallback-pkg"), None).unwrap();
    assert_eq!(parsed.package_id, "fallback-pkg");
    assert_eq!(parsed.download_token, "token-123");
}

#[test]
fn test_legacy_token_no_separator() {
    // No separator - entire string becomes download_token, needs fallback package_id
    let result = parse_token("only-token-here", Some("fallback-pkg"), None).unwrap();
    assert_eq!(result.package_id, "fallback-pkg");
    assert_eq!(result.download_token, "only-token-here");
}

#[test]
fn test_legacy_token_no_separator_no_fallback() {
    // No separator and no fallback - fails with MissingPackageId
    let result = parse_token("only-token-here", None, None);
    assert!(matches!(result, Err(Error::MissingPackageId)));
}

#[test]
fn test_legacy_token_empty_parts() {
    let result = parse_token(":", None, None);
    assert!(matches!(result, Err(Error::MissingPackageId)));
}

#[test]
fn test_token_payload_clone() {
    let payload = TokenPayload {
        package_id: "pkg-123".to_string(),
        download_token: "dl-456".to_string(),
        core_url: Some("http://example.com".to_string()),
    };
    let cloned = payload.clone();
    assert_eq!(cloned.package_id, payload.package_id);
    assert_eq!(cloned.download_token, payload.download_token);
    assert_eq!(cloned.core_url, payload.core_url);
}

#[test]
fn test_encode_token_validation() {
    use edge_onboarding::encode_token;

    // Test that encode_token validates the payload
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
}

#[test]
fn test_encode_decode_roundtrip() {
    use edge_onboarding::encode_token;

    let original = TokenPayload {
        package_id: "test-pkg-123".to_string(),
        download_token: "test-dl-456".to_string(),
        core_url: Some("https://api.example.com".to_string()),
    };

    let encoded = encode_token(&original).unwrap();
    assert!(encoded.starts_with("edgepkg-v1:"));

    let decoded = parse_token(&encoded, None, None).unwrap();
    assert_eq!(decoded.package_id, original.package_id);
    assert_eq!(decoded.download_token, original.download_token);
    assert_eq!(decoded.core_url, original.core_url);
}
