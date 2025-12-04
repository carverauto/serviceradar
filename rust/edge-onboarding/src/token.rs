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
pub fn encode_token(payload: &TokenPayload) -> Result<String> {
    validate_token_payload(payload)?;
    let json = serde_json::to_vec(payload)?;
    let encoded = URL_SAFE_NO_PAD.encode(&json);
    Ok(format!("{}{}", TOKEN_PREFIX, encoded))
}
