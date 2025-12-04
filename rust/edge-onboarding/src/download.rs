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

//! Package download from Core API.

use serde::{Deserialize, Serialize};

use crate::bundle::MtlsBundle;
use crate::error::{Error, Result};
use crate::token::TokenPayload;

/// Response from the package download endpoint.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PackageResponse {
    /// Package metadata.
    #[serde(default)]
    pub package_id: String,

    /// Component type (poller, agent, checker).
    #[serde(default)]
    pub component_type: String,

    /// Checker kind (e.g., "sysmon").
    #[serde(default)]
    pub checker_kind: String,

    /// Checker-specific configuration JSON.
    #[serde(default)]
    pub checker_config_json: Option<String>,

    /// Parent component ID (e.g., agent ID for checkers).
    #[serde(default)]
    pub parent_id: Option<String>,

    /// Component ID.
    #[serde(default)]
    pub component_id: Option<String>,

    /// Label for display.
    #[serde(default)]
    pub label: Option<String>,

    /// Site name.
    #[serde(default)]
    pub site: Option<String>,

    /// Assigned SPIFFE ID.
    #[serde(default)]
    pub downstream_spiffe_id: Option<String>,

    /// mTLS bundle (if mTLS mode).
    #[serde(default)]
    pub mtls_bundle: Option<MtlsBundle>,

    /// SPIRE join token (if SPIRE mode).
    #[serde(default)]
    pub join_token: Option<String>,

    /// SPIRE trust bundle PEM (if SPIRE mode).
    #[serde(default)]
    pub bundle_pem: Option<String>,
}

/// Request body for package download.
#[derive(Debug, Serialize)]
struct DownloadRequest {
    download_token: String,
}

/// Download package from Core API.
pub fn download_package(payload: &TokenPayload) -> Result<PackageResponse> {
    let core_url = payload
        .core_url
        .as_ref()
        .ok_or(Error::CoreApiHostRequired)?;

    let api_base = ensure_scheme(core_url)?;
    let url = format!(
        "{}/api/admin/edge-packages/{}/download?format=json",
        api_base.trim_end_matches('/'),
        urlencoding::encode(&payload.package_id)
    );

    let request_body = DownloadRequest {
        download_token: payload.download_token.clone(),
    };

    tracing::debug!(url = %url, package_id = %payload.package_id, "Downloading package from Core API");

    let response = ureq::post(&url)
        .set("Content-Type", "application/json")
        .set("Accept", "application/json")
        .send_json(&request_body)
        .map_err(|e| match e {
            ureq::Error::Status(status, resp) => {
                let body = resp.into_string().unwrap_or_default();
                Error::CoreApiError {
                    status,
                    message: body,
                }
            }
            ureq::Error::Transport(t) => Error::Http(t.to_string()),
        })?;

    let package: PackageResponse = response.into_json().map_err(|e| Error::Http(e.to_string()))?;

    // Ensure package_id is set
    let package = if package.package_id.is_empty() {
        PackageResponse {
            package_id: payload.package_id.clone(),
            ..package
        }
    } else {
        package
    };

    Ok(package)
}

/// Ensure the URL has a scheme (http:// or https://).
fn ensure_scheme(host: &str) -> Result<String> {
    let host = host.trim();
    if host.is_empty() {
        return Err(Error::CoreApiHostRequired);
    }
    if host.starts_with("http://") || host.starts_with("https://") {
        return Ok(host.to_string());
    }
    Ok(format!("http://{}", host))
}
