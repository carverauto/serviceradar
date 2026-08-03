// Licensed to the Apache Software Foundation (ASF) under one
// or more contributor license agreements.  See the NOTICE file
// distributed with this work for additional information
// regarding copyright ownership.  The ASF licenses this file
// to you under the Apache License, Version 2.0 (the
// "License"); you may not use this file except in compliance
// with the License.  You may obtain a copy of the License at
//
//   http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing,
// software distributed under the License is distributed on an
// "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
// KIND, either express or implied.  See the License for the
// specific language governing permissions and limitations
// under the License.

use reqsign_core::{Error, Result};
use serde::Deserialize;

/// Get the sts endpoint.
///
/// The returning format may look like `sts.{region}.amazonaws.com`
///
/// # Notes
///
/// AWS could have different sts endpoint based on it's region.
/// We can check them by region name.
///
/// ref: https://github.com/awslabs/aws-sdk-rust/blob/31cfae2cf23be0c68a47357070dea1aee9227e3a/sdk/sts/src/aws_endpoint.rs
pub fn sts_endpoint(region: Option<&str>, use_regional: bool) -> Result<String> {
    // use regional sts if use_regional has been set.
    if use_regional {
        let region =
            region.ok_or_else(|| Error::config_invalid("regional STS endpoint requires region"))?;
        if region.starts_with("cn-") {
            Ok(format!("sts.{region}.amazonaws.com.cn"))
        } else {
            Ok(format!("sts.{region}.amazonaws.com"))
        }
    } else {
        let region = region.unwrap_or_default();
        if region.starts_with("cn") {
            // TODO: seems aws china doesn't support global sts?
            Ok("sts.amazonaws.com.cn".to_string())
        } else {
            Ok("sts.amazonaws.com".to_string())
        }
    }
}

/// Common structure for AWS error responses
#[derive(Debug, Deserialize)]
pub struct AwsErrorResponse {
    #[serde(rename = "Error")]
    pub error: AwsError,
}

#[derive(Debug, Deserialize)]
pub struct AwsError {
    #[serde(rename = "Code")]
    pub code: String,
    #[serde(rename = "Message")]
    pub message: String,
}

/// Parse AWS STS error response and return appropriate error
///
/// This function analyzes AWS error codes and maps them to the correct ErrorKind
/// with meaningful context for debugging.
pub fn parse_sts_error(
    operation: &str,
    status: http::StatusCode,
    body: &str,
    request_id: Option<&str>,
) -> Error {
    // Try to parse the XML error response
    if let Ok(error_resp) = quick_xml::de::from_str::<AwsErrorResponse>(body) {
        let code = &error_resp.error.code;
        let message = &error_resp.error.message;

        // Map AWS error codes to appropriate ErrorKind
        let mut error = match code.as_str() {
            // Permission/Authorization errors
            "AccessDenied" | "UnauthorizedAccess" | "Forbidden" => {
                Error::permission_denied(format!("{code}: {message}"))
            }

            // Credential errors
            "ExpiredToken" | "TokenRefreshRequired" | "InvalidToken" => {
                Error::credential_invalid(format!("token expired or invalid: {message}"))
            }

            // Configuration errors
            "InvalidParameterValue" | "MissingParameter" | "InvalidParameterCombination" => {
                Error::config_invalid(format!("invalid configuration: {message}"))
            }

            // Rate limiting
            "Throttling" | "RequestLimitExceeded" | "TooManyRequestsException" => {
                Error::rate_limited(format!("AWS API rate limit: {message}"))
            }

            // Service unavailable (retryable)
            "ServiceUnavailable" | "InternalError" | "InternalFailure" => {
                Error::unexpected(format!("AWS service error: {message}")).set_retryable(true)
            }

            // Request errors
            "InvalidRequest" | "MalformedQueryString" => {
                Error::request_invalid(format!("invalid request: {message}"))
            }

            // Default to unexpected
            _ => Error::unexpected(format!("AWS error [{code}]: {message}")),
        };

        // Add context
        error = error
            .with_context(format!("operation: {operation}"))
            .with_context(format!("error_code: {code}"));

        if let Some(id) = request_id {
            error = error.with_context(format!("request_id: {id}"));
        }

        error
    } else {
        // Failed to parse error response, return generic error based on status code
        let mut error = match status.as_u16() {
            400..=499 if status == http::StatusCode::FORBIDDEN => {
                Error::permission_denied(format!("STS request forbidden: {body}"))
            }
            400..=499 if status == http::StatusCode::UNAUTHORIZED => {
                Error::credential_invalid(format!("STS authentication failed: {body}"))
            }
            429 => Error::rate_limited(format!("STS rate limit exceeded: {body}")),
            400..=499 => {
                Error::request_invalid(format!("STS request failed with {status}: {body}"))
            }
            500..=599 => {
                Error::unexpected(format!("STS server error {status}: {body}")).set_retryable(true)
            }
            _ => Error::unexpected(format!("STS request failed with {status}: {body}")),
        };

        error = error
            .with_context(format!("operation: {operation}"))
            .with_context(format!("http_status: {status}"));

        if let Some(id) = request_id {
            error = error.with_context(format!("request_id: {id}"));
        }

        error
    }
}

/// Parse IMDS error response
///
/// EC2 Instance Metadata Service has its own error format
pub fn parse_imds_error(operation: &str, status: http::StatusCode, body: &str) -> Error {
    // IMDS returns JSON errors, try to parse them
    #[derive(Debug, Deserialize)]
    struct ImdsError {
        #[serde(rename = "Code")]
        code: String,
        #[serde(rename = "Message")]
        message: String,
    }

    if let Ok(error) = serde_json::from_str::<ImdsError>(body) {
        let err = match error.code.as_str() {
            "AssumeRoleUnauthorizedAccess" => Error::permission_denied(format!(
                "EC2 instance not authorized to assume role: {}",
                error.message
            ))
            .with_context("hint: check if the IAM role has a trust relationship with EC2"),
            "InvalidUserData.Malformed" => {
                Error::config_invalid(format!("malformed instance metadata: {}", error.message))
            }
            _ if error.code.contains("Expired") => {
                Error::credential_invalid(format!("IMDS credentials expired: {}", error.message))
            }
            _ => Error::unexpected(format!("IMDS error [{}]: {}", error.code, error.message)),
        };

        err.with_context(format!("operation: {operation}"))
            .with_context(format!("error_code: {}", error.code))
    } else {
        // Generic error based on status
        match status.as_u16() {
            401 | 403 => Error::permission_denied(format!("IMDS access denied: {body}"))
                .with_context(format!("operation: {operation}"))
                .with_context("hint: check if IMDSv2 is required"),
            404 => Error::config_invalid("instance metadata not found")
                .with_context(format!("operation: {operation}"))
                .with_context("hint: are you running on EC2?"),
            500..=599 => Error::unexpected(format!("IMDS server error: {body}"))
                .with_context(format!("operation: {operation}"))
                .set_retryable(true),
            _ => Error::unexpected(format!("IMDS request failed: {body}"))
                .with_context(format!("operation: {operation}"))
                .with_context(format!("http_status: {status}")),
        }
    }
}
