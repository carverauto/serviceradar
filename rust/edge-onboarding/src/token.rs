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
//! Supports the signed `edgepkg-v2:<payload>.<signature>` token format.

use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use base64::Engine;
use ed25519_dalek::{Signature, Signer, SigningKey, Verifier, VerifyingKey};
use serde::{Deserialize, Serialize};
use std::env;

use crate::error::{Error, Result};

const TOKEN_PREFIX: &str = "edgepkg-v2:";
const SIGNATURE_SEPARATOR: &str = ".";
const ONBOARDING_TOKEN_PRIVATE_KEY_ENV: &str = "SERVICERADAR_ONBOARDING_TOKEN_PRIVATE_KEY";
const ONBOARDING_TOKEN_PUBLIC_KEY_ENV: &str = "SERVICERADAR_ONBOARDING_TOKEN_PUBLIC_KEY";

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
/// # Arguments
/// * `raw` - The raw token string
/// * `fallback_package_id` - Fallback package ID if not in token
/// * `fallback_core_url` - Fallback Core API URL if not embedded in the token
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
        Err(Error::UnsupportedTokenFormat)
    }
}

fn parse_structured_token(
    raw: &str,
    fallback_package_id: Option<&str>,
    fallback_core_url: Option<&str>,
) -> Result<TokenPayload> {
    let encoded = raw.strip_prefix(TOKEN_PREFIX).unwrap_or(raw);
    let (encoded_payload, encoded_signature) = encoded
        .split_once(SIGNATURE_SEPARATOR)
        .ok_or(Error::TokenMalformed)?;
    if encoded_payload.is_empty() || encoded_signature.is_empty() {
        return Err(Error::TokenMalformed);
    }

    let data = URL_SAFE_NO_PAD.decode(encoded_payload)?;
    let signature_bytes = URL_SAFE_NO_PAD.decode(encoded_signature)?;
    let signature = Signature::try_from(signature_bytes.as_slice()).map_err(|_| Error::TokenMalformed)?;
    let public_key = onboarding_token_public_key()?;
    public_key
        .verify(&data, &signature)
        .map_err(|_| Error::InvalidTokenSignature)?;

    let mut payload: TokenPayload = serde_json::from_slice(&data)?;

    // Apply fallbacks only when the signed token omitted the value.
    if payload.package_id.is_empty() {
        if let Some(fallback) = fallback_package_id {
            payload.package_id = fallback.to_string();
        }
    }
    if payload
        .core_url
        .as_deref()
        .map(str::trim)
        .unwrap_or_default()
        .is_empty()
    {
        payload.core_url = fallback_core_url.map(|value| value.trim().to_string());
    }

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

fn onboarding_token_public_key() -> Result<VerifyingKey> {
    let raw = env::var(ONBOARDING_TOKEN_PUBLIC_KEY_ENV).unwrap_or_default();
    if raw.trim().is_empty() {
        return Err(Error::TokenPublicKeyRequired);
    }

    let key_bytes = decode_onboarding_token_key(&raw)?;
    let key_bytes: [u8; 32] = key_bytes
        .try_into()
        .map_err(|_| Error::TokenMalformed)?;
    VerifyingKey::from_bytes(&key_bytes).map_err(|_| Error::TokenMalformed)
}

fn onboarding_token_private_key() -> Result<SigningKey> {
    let raw = env::var(ONBOARDING_TOKEN_PRIVATE_KEY_ENV).unwrap_or_default();
    if raw.trim().is_empty() {
        return Err(Error::TokenPrivateKeyRequired);
    }

    let key_bytes = decode_onboarding_token_key(&raw)?;
    match key_bytes.len() {
        32 => {
            let seed: [u8; 32] = key_bytes.try_into().map_err(|_| Error::TokenMalformed)?;
            Ok(SigningKey::from_bytes(&seed))
        }
        64 => {
            let pair: [u8; 64] = key_bytes.try_into().map_err(|_| Error::TokenMalformed)?;
            SigningKey::from_keypair_bytes(&pair).map_err(|_| Error::TokenMalformed)
        }
        _ => Err(Error::TokenMalformed),
    }
}

fn decode_onboarding_token_key(raw: &str) -> Result<Vec<u8>> {
    for decode in [
        base64::engine::general_purpose::STANDARD.decode(raw.trim()),
        base64::engine::general_purpose::STANDARD_NO_PAD.decode(raw.trim()),
        base64::engine::general_purpose::URL_SAFE.decode(raw.trim()),
        base64::engine::general_purpose::URL_SAFE_NO_PAD.decode(raw.trim()),
    ] {
        if let Ok(bytes) = decode {
            return Ok(bytes);
        }
    }

    if let Ok(bytes) = hex::decode(raw.trim()) {
        return Ok(bytes);
    }

    Err(Error::TokenMalformed)
}

/// Encode a token payload into the signed edgepkg-v2 format.
pub fn encode_token(payload: &TokenPayload) -> Result<String> {
    validate_token_payload(payload)?;
    let json = serde_json::to_vec(payload)?;
    let signing_key = onboarding_token_private_key()?;
    let signature = signing_key.sign(&json);
    let encoded_payload = URL_SAFE_NO_PAD.encode(&json);
    let encoded_signature = URL_SAFE_NO_PAD.encode(signature.to_bytes());
    Ok(format!(
        "{}{}{}{}",
        TOKEN_PREFIX, encoded_payload, SIGNATURE_SEPARATOR, encoded_signature
    ))
}
