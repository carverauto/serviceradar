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

//! Error types for edge onboarding.

use thiserror::Error;

/// Result type for edge onboarding operations.
pub type Result<T> = std::result::Result<T, Error>;

/// Errors that can occur during edge onboarding.
#[derive(Error, Debug)]
pub enum Error {
    /// Token is required but not provided.
    #[error("token is required for edge onboarding")]
    TokenRequired,

    /// Token format is not recognized.
    #[error("unsupported token format (expected edgepkg-v1)")]
    UnsupportedTokenFormat,

    /// Token is missing the package ID.
    #[error("token missing package id")]
    MissingPackageId,

    /// Token is missing the download token.
    #[error("token missing download token")]
    MissingDownloadToken,

    /// Core API host is required but not provided.
    #[error("core API host is required (token missing api and --host not set)")]
    CoreApiHostRequired,

    /// mTLS bundle is missing from the package response.
    #[error("mTLS bundle missing in package response")]
    BundleMissing,

    /// A required field is missing from the bundle.
    #[error("bundle missing required field: {field}")]
    BundleFieldMissing { field: String },

    /// Bundle file format is not recognized.
    #[error("unsupported bundle format (expected .json, .tar.gz, or directory)")]
    UnsupportedBundleFormat,

    /// Core API returned an error.
    #[error("Core API error ({status}): {message}")]
    CoreApiError { status: u16, message: String },

    /// Failed to decode base64 data.
    #[error("base64 decode error: {0}")]
    Base64Decode(#[from] base64::DecodeError),

    /// Failed to parse JSON.
    #[error("JSON parse error: {0}")]
    Json(#[from] serde_json::Error),

    /// HTTP request failed.
    #[error("HTTP request failed: {0}")]
    Http(String),

    /// I/O error.
    #[error("I/O error at {path}: {source}")]
    Io {
        path: String,
        #[source]
        source: std::io::Error,
    },

    /// Generic I/O error without path.
    #[error("I/O error: {0}")]
    IoGeneric(#[from] std::io::Error),
}
