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

    // Apply fallbacks and overrides
    if payload.package_id.is_empty() {
        if let Some(fallback) = fallback_package_id {
            payload.package_id = fallback.to_string();
        }
    }
    // --host flag should OVERRIDE the token's API URL, not just be a fallback
    // This allows users to specify the actual reachable host when the token
    // contains localhost or an internal hostname
    if let Some(override_host) = fallback_core_url {
        payload.core_url = Some(apply_host_override(
            payload.core_url.as_deref(),
            override_host,
        ));
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

/// Apply a host override to an existing URL, preserving scheme and port.
///
/// If `override_host` is a full URL (has scheme), use it directly.
/// Otherwise, replace just the hostname in the original URL, keeping
/// the scheme and port from the original.
///
/// Examples:
/// - original: "http://localhost:8090", override: "192.168.2.235" -> "http://192.168.2.235:8090"
/// - original: "https://core:8090", override: "myhost.example.com" -> "https://myhost.example.com:8090"
/// - original: None, override: "192.168.2.235" -> "http://192.168.2.235:8090" (default port)
/// - original: "http://localhost:8090", override: "http://myhost:9000" -> "http://myhost:9000" (full URL override)
fn apply_host_override(original_url: Option<&str>, override_host: &str) -> String {
    let override_host = override_host.trim();

    // If override is already a full URL, use it directly
    if looks_like_url(override_host) {
        return override_host.to_string();
    }

    // If no original URL, construct a new one with default port
    let Some(original) = original_url else {
        // Check if override already has a port
        if override_host.contains(':') {
            return format!("http://{}", override_host);
        }
        return format!("http://{}:8090", override_host);
    };

    // Parse the original URL to extract scheme and port
    let (scheme, rest) = if let Some(stripped) = original.strip_prefix("https://") {
        ("https://", stripped)
    } else if let Some(stripped) = original.strip_prefix("http://") {
        ("http://", stripped)
    } else {
        ("http://", original)
    };

    // Extract port from original URL (if any)
    // Format: host:port or host:port/path
    let port = rest.split('/').next().and_then(|host_port| {
        host_port
            .rsplit(':')
            .next()
            .filter(|p| p.chars().all(|c| c.is_ascii_digit()))
    });

    // If override already has a port, use it as-is
    if override_host.contains(':') {
        return format!("{}{}", scheme, override_host);
    }

    // Construct new URL with override host and original port
    match port {
        Some(p) => format!("{}{}:{}", scheme, override_host, p),
        None => format!("{}{}", scheme, override_host),
    }
}

/// Encode a token payload into the edgepkg-v1 format.
pub fn encode_token(payload: &TokenPayload) -> Result<String> {
    validate_token_payload(payload)?;
    let json = serde_json::to_vec(payload)?;
    let encoded = URL_SAFE_NO_PAD.encode(&json);
    Ok(format!("{}{}", TOKEN_PREFIX, encoded))
}
