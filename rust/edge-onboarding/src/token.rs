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

//! Token parsing for edge onboarding.
//!
//! Supports the `edgepkg-v1:<base64url>` token format.

use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use base64::Engine;
use serde::{Deserialize, Serialize};

use crate::error::{Error, Result};

const TOKEN_PREFIX: &str = "edgepkg-v1:";

/// Parsed token payload.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TokenPayload {
    /// Package ID.
    #[serde(rename = "pkg")]
    pub package_id: String,

    /// Download token for authenticating the package download.
    #[serde(rename = "dl")]
    pub download_token: String,

    /// Optional Core API URL.
    #[serde(rename = "api", default, skip_serializing_if = "Option::is_none")]
    pub core_url: Option<String>,
}

/// Parse an onboarding token.
///
/// Supports two formats:
/// 1. Structured: `edgepkg-v1:<base64url-encoded-json>`
/// 2. Legacy: `<package_id>:<download_token>` or `<url>@<package_id>:<download_token>`
///
/// # Arguments
/// * `raw` - The raw token string
/// * `fallback_package_id` - Fallback package ID if not in token
/// * `fallback_core_url` - Fallback Core API URL if not in token
pub fn parse_token(
    raw: &str,
    fallback_package_id: Option<&str>,
    fallback_core_url: Option<&str>,
) -> Result<TokenPayload> {
    let raw = raw.trim();
    if raw.is_empty() {
        return Err(Error::TokenRequired);
    }

    if raw.starts_with(TOKEN_PREFIX) {
        parse_structured_token(raw, fallback_package_id, fallback_core_url)
    } else {
        parse_legacy_token(raw, fallback_package_id, fallback_core_url)
    }
}

fn parse_structured_token(
    raw: &str,
    fallback_package_id: Option<&str>,
    fallback_core_url: Option<&str>,
) -> Result<TokenPayload> {
    let encoded = raw.strip_prefix(TOKEN_PREFIX).unwrap_or(raw);
    let data = URL_SAFE_NO_PAD.decode(encoded)?;

    let mut payload: TokenPayload = serde_json::from_slice(&data)?;

    // Apply fallbacks
    if payload.package_id.is_empty() {
        if let Some(fallback) = fallback_package_id {
            payload.package_id = fallback.to_string();
        }
    }
    if payload.core_url.is_none() {
        payload.core_url = fallback_core_url.map(String::from);
    }

    validate_token_payload(&payload)?;
    Ok(payload)
}

fn parse_legacy_token(
    raw: &str,
    fallback_package_id: Option<&str>,
    fallback_core_url: Option<&str>,
) -> Result<TokenPayload> {
    let mut payload = TokenPayload {
        package_id: fallback_package_id.unwrap_or_default().to_string(),
        download_token: String::new(),
        core_url: fallback_core_url.map(String::from),
    };

    let mut legacy = raw.to_string();

    // Check for URL@remainder format
    if let Some(at_idx) = legacy.find('@') {
        let maybe_url = legacy[..at_idx].trim();
        let remainder = legacy[at_idx + 1..].trim();
        if looks_like_url(maybe_url) && !remainder.is_empty() {
            payload.core_url = Some(maybe_url.to_string());
            legacy = remainder.to_string();
        }
    }

    // Try to split by common separators
    for sep in [':', '/', '|', ','] {
        if let Some(idx) = legacy.find(sep) {
            payload.package_id = legacy[..idx].trim().to_string();
            payload.download_token = legacy[idx + 1..].trim().to_string();
            validate_token_payload(&payload)?;
            return Ok(payload);
        }
    }

    // No separator found - treat entire string as download token
    payload.download_token = legacy.trim().to_string();
    validate_token_payload(&payload)?;
    Ok(payload)
}

fn validate_token_payload(payload: &TokenPayload) -> Result<()> {
    if payload.package_id.is_empty() {
        return Err(Error::MissingPackageId);
    }
    if payload.download_token.trim().is_empty() {
        return Err(Error::MissingDownloadToken);
    }
    Ok(())
}

fn looks_like_url(raw: &str) -> bool {
    let lower = raw.trim().to_lowercase();
    lower.starts_with("http://") || lower.starts_with("https://")
}

/// Encode a token payload into the edgepkg-v1 format.
#[allow(dead_code)]
pub fn encode_token(payload: &TokenPayload) -> Result<String> {
    validate_token_payload(payload)?;
    let json = serde_json::to_vec(payload)?;
    let encoded = URL_SAFE_NO_PAD.encode(&json);
    Ok(format!("{}{}", TOKEN_PREFIX, encoded))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_parse_structured_token() {
        // Create a valid token
        let payload = TokenPayload {
            package_id: "pkg-123".to_string(),
            download_token: "dl-456".to_string(),
            core_url: Some("https://core.example.com".to_string()),
        };
        let token = encode_token(&payload).unwrap();

        let parsed = parse_token(&token, None, None).unwrap();
        assert_eq!(parsed.package_id, "pkg-123");
        assert_eq!(parsed.download_token, "dl-456");
        assert_eq!(parsed.core_url, Some("https://core.example.com".to_string()));
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
        let token = encode_token(&payload).unwrap();

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
    fn test_encode_token_validation() {
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
}
