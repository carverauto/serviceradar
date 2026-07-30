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

use crate::Credential;
use http::{HeaderValue, Method, Request, StatusCode};
use log::debug;
use reqsign_core::{Context, Error, ProvideCredential, Result};
use serde::Deserialize;

const AWS_CONTAINER_CREDENTIALS_RELATIVE_URI: &str = "AWS_CONTAINER_CREDENTIALS_RELATIVE_URI";
const AWS_CONTAINER_CREDENTIALS_FULL_URI: &str = "AWS_CONTAINER_CREDENTIALS_FULL_URI";
const AWS_CONTAINER_AUTHORIZATION_TOKEN: &str = "AWS_CONTAINER_AUTHORIZATION_TOKEN";
const AWS_CONTAINER_AUTHORIZATION_TOKEN_FILE: &str = "AWS_CONTAINER_AUTHORIZATION_TOKEN_FILE";
const ECS_METADATA_ENDPOINT: &str = "http://169.254.170.2";
const ECS_CONTAINER_METADATA_URI: &str = "ECS_CONTAINER_METADATA_URI";

/// ECS Task Role Credentials Provider
///
/// This provider fetches IAM credentials from the ECS Task IAM Roles endpoint.
/// It supports both relative URI (ECS) and full URI (Fargate) modes.
///
/// # Important Note
/// This provider fetches IAM **credentials**, not task metadata. The credentials
/// endpoint is separate from the task metadata endpoints (v2/v3/v4). While metadata
/// endpoints provide information about the task and container, the credentials
/// endpoint provides IAM role credentials for authentication.
///
/// # Configuration
///
/// Configuration values can be provided directly via builder methods or through environment
/// variables. Direct configuration takes precedence over environment variables.
///
/// ## Builder Methods
/// - [`ECSCredentialProvider::with_relative_uri`]: Set the relative URI for ECS environments
/// - [`ECSCredentialProvider::with_endpoint`]: Set a complete custom endpoint URL (for Fargate or custom setups)
/// - [`ECSCredentialProvider::with_auth_token`]: Set the authorization token directly
/// - [`ECSCredentialProvider::with_auth_token_file`]: Set the path to the authorization token file
/// - [`ECSCredentialProvider::with_metadata_uri_override`]: Override the base metadata endpoint for relative URIs
///
/// ## Environment Variables (Fallback)
/// - `AWS_CONTAINER_CREDENTIALS_RELATIVE_URI`: Relative URI to fetch credentials (ECS)
/// - `AWS_CONTAINER_CREDENTIALS_FULL_URI`: Full URI to fetch credentials (Fargate)
/// - `AWS_CONTAINER_AUTHORIZATION_TOKEN`: Authorization token for the request
/// - `AWS_CONTAINER_AUTHORIZATION_TOKEN_FILE`: File containing the authorization token
/// - `ECS_CONTAINER_METADATA_URI`: Override the default base endpoint (for testing)
///
/// # Examples
///
/// ```rust,no_run
/// use reqsign_aws_v4::ECSCredentialProvider;
///
/// // Configure for ECS with relative URI
/// let provider = ECSCredentialProvider::new()
///     .with_relative_uri("/v2/credentials/task-role")
///     .with_auth_token("my-auth-token");
///
/// // Configure for Fargate with full endpoint
/// let provider = ECSCredentialProvider::new()
///     .with_endpoint("http://169.254.170.2/v2/credentials/task-role")
///     .with_auth_token_file("/tmp/auth-token");
/// ```
#[derive(Debug, Clone)]
pub struct ECSCredentialProvider {
    endpoint: Option<String>,
    auth_token: Option<String>,
    auth_token_file: Option<String>,
    relative_uri: Option<String>,
    metadata_uri_override: Option<String>,
}

impl Default for ECSCredentialProvider {
    fn default() -> Self {
        Self::new()
    }
}

impl ECSCredentialProvider {
    /// Create a new ECS credential provider
    pub fn new() -> Self {
        Self {
            endpoint: None,
            auth_token: None,
            auth_token_file: None,
            relative_uri: None,
            metadata_uri_override: None,
        }
    }

    /// Create with custom endpoint
    pub fn with_endpoint(mut self, endpoint: impl Into<String>) -> Self {
        self.endpoint = Some(endpoint.into());
        self
    }

    /// Create with custom auth token
    pub fn with_auth_token(mut self, token: impl Into<String>) -> Self {
        self.auth_token = Some(token.into());
        self
    }

    /// Create with custom auth token file path
    pub fn with_auth_token_file(mut self, file_path: impl Into<String>) -> Self {
        self.auth_token_file = Some(file_path.into());
        self
    }

    /// Create with container credentials relative URI
    /// This is used in ECS environments where the base metadata URI is known
    pub fn with_relative_uri(mut self, uri: impl Into<String>) -> Self {
        self.relative_uri = Some(uri.into());
        self
    }

    /// Override the metadata URI base endpoint (typically for testing)
    /// Defaults to http://169.254.170.2 if not specified
    pub fn with_metadata_uri_override(mut self, uri: impl Into<String>) -> Self {
        self.metadata_uri_override = Some(uri.into());
        self
    }

    async fn load_auth_token(&self, ctx: &Context) -> Result<Option<String>> {
        // If auth token is already set, use it
        if let Some(token) = &self.auth_token {
            return Ok(Some(token.clone()));
        }

        // Try to get token from configured file first
        if let Some(token_file) = &self.auth_token_file {
            let token = ctx.file_read(token_file).await.map_err(|e| {
                Error::config_invalid("failed to read ECS auth token file")
                    .with_source(e)
                    .with_context(format!("file: {token_file}"))
            })?;
            return Ok(Some(String::from_utf8_lossy(&token).trim().to_string()));
        }

        // Try to get token from environment
        if let Some(token) = ctx.env_var(AWS_CONTAINER_AUTHORIZATION_TOKEN) {
            return Ok(Some(token));
        }

        // Try to get token from environment file
        if let Some(token_file) = ctx.env_var(AWS_CONTAINER_AUTHORIZATION_TOKEN_FILE) {
            let token = ctx.file_read(&token_file).await.map_err(|e| {
                Error::config_invalid("failed to read ECS auth token file")
                    .with_source(e)
                    .with_context(format!("file: {token_file}"))
            })?;
            return Ok(Some(String::from_utf8_lossy(&token).trim().to_string()));
        }

        Ok(None)
    }

    fn get_endpoint(&self, ctx: &Context) -> Result<String> {
        // Use custom endpoint if provided (highest priority)
        if let Some(endpoint) = &self.endpoint {
            return Ok(endpoint.clone());
        }

        // Try configured relative URI (ECS)
        if let Some(relative_uri) = &self.relative_uri {
            let base_endpoint = self
                .metadata_uri_override
                .as_deref()
                .unwrap_or(ECS_METADATA_ENDPOINT);
            return Ok(format!("{base_endpoint}{relative_uri}"));
        }

        // Fall back to environment variables
        // Try full URI from environment (Fargate)
        if let Some(full_uri) = ctx.env_var(AWS_CONTAINER_CREDENTIALS_FULL_URI) {
            return Ok(full_uri);
        }

        // Try relative URI from environment (ECS)
        if let Some(relative_uri) = ctx.env_var(AWS_CONTAINER_CREDENTIALS_RELATIVE_URI) {
            // Allow override of metadata endpoint for testing
            let base_endpoint = match &self.metadata_uri_override {
                Some(override_uri) => override_uri.clone(),
                None => ctx
                    .env_var(ECS_CONTAINER_METADATA_URI)
                    .unwrap_or_else(|| ECS_METADATA_ENDPOINT.to_string()),
            };
            return Ok(format!("{base_endpoint}{relative_uri}"));
        }

        Err(Error::config_invalid(
            "ECS container credentials endpoint not configured"
        )
        .with_context("hint: use with_relative_uri(), with_endpoint(), or set AWS_CONTAINER_CREDENTIALS_RELATIVE_URI/AWS_CONTAINER_CREDENTIALS_FULL_URI")
        .with_context("note: are you running on ECS or Fargate?"))
    }
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "PascalCase")]
struct ECSCredentialResponse {
    access_key_id: String,
    secret_access_key: String,
    token: String,
    expiration: String,
}
impl ProvideCredential for ECSCredentialProvider {
    type Credential = Credential;

    async fn provide_credential(&self, ctx: &Context) -> Result<Option<Self::Credential>> {
        let endpoint = match self.get_endpoint(ctx) {
            Ok(ep) => ep,
            Err(_) => {
                debug!("ECS credential provider: no container credentials endpoint found");
                return Ok(None);
            }
        };

        debug!("ECS credential provider: fetching credentials from {endpoint}");

        let mut req = Request::builder()
            .method(Method::GET)
            .uri(&endpoint)
            .body(bytes::Bytes::new())
            .map_err(|e| {
                Error::request_invalid("failed to build ECS credentials request")
                    .with_source(e)
                    .with_context(format!("endpoint: {endpoint}"))
            })?;

        // Add authorization token if available
        if let Some(token) = self.load_auth_token(ctx).await? {
            req.headers_mut().insert(
                "Authorization",
                HeaderValue::from_str(&token).map_err(|e| {
                    Error::config_invalid("invalid ECS authorization token")
                        .with_source(e)
                        .with_context("token_source: environment or file")
                })?,
            );
        }

        let resp = ctx.http_send(req).await.map_err(|e| {
            Error::unexpected("failed to fetch ECS credentials")
                .with_source(e)
                .with_context(format!("endpoint: {endpoint}"))
                .with_context("hint: check if running on ECS/Fargate with proper IAM role")
                .set_retryable(true)
        })?;

        if resp.status() != StatusCode::OK {
            let status = resp.status();
            let body = String::from_utf8_lossy(resp.body());

            let error = match status.as_u16() {
                401 | 403 => Error::permission_denied(format!(
                    "ECS task not authorized to fetch credentials: {body}"
                ))
                .with_context("hint: check if task has proper IAM role attached"),
                404 => Error::config_invalid("ECS credentials endpoint not found")
                    .with_context(format!("endpoint: {endpoint}"))
                    .with_context("hint: verify the container credentials URI"),
                500..=599 => Error::unexpected(format!("ECS metadata service error: {body}"))
                    .set_retryable(true),
                _ => Error::unexpected(format!(
                    "ECS metadata endpoint returned unexpected status {status}: {body}"
                )),
            };

            return Err(error
                .with_context(format!("http_status: {status}"))
                .with_context(format!("endpoint: {endpoint}")));
        }

        let body = resp.into_body();
        let creds: ECSCredentialResponse = serde_json::from_slice(&body).map_err(|e| {
            Error::unexpected("failed to parse ECS credentials response")
                .with_source(e)
                .with_context(format!("response_length: {}", body.len()))
                .with_context(format!("endpoint: {endpoint}"))
        })?;

        let expires_in = creds.expiration.parse().map_err(|e| {
            Error::unexpected("failed to parse ECS credential expiration")
                .with_source(e)
                .with_context(format!("expiration_value: {}", creds.expiration))
        })?;

        Ok(Some(Credential {
            access_key_id: creds.access_key_id,
            secret_access_key: creds.secret_access_key,
            session_token: Some(creds.token),
            expires_in: Some(expires_in),
        }))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use reqsign_core::StaticEnv;
    use reqsign_file_read_tokio::TokioFileRead;
    use reqsign_http_send_reqwest::ReqwestHttpSend;
    use std::collections::HashMap;

    #[tokio::test]
    async fn test_ecs_provider_no_env() {
        let ctx = Context::new()
            .with_file_read(TokioFileRead)
            .with_http_send(ReqwestHttpSend::default());
        let ctx = ctx.with_env(StaticEnv {
            home_dir: None,
            envs: HashMap::new(),
        });

        let provider = ECSCredentialProvider::new();
        let result = provider.provide_credential(&ctx).await.unwrap();
        assert!(result.is_none());
    }

    #[tokio::test]
    async fn test_get_endpoint_relative_uri() {
        let ctx = Context::new()
            .with_file_read(TokioFileRead)
            .with_http_send(ReqwestHttpSend::default());
        let ctx = ctx.with_env(StaticEnv {
            home_dir: None,
            envs: HashMap::from_iter([(
                AWS_CONTAINER_CREDENTIALS_RELATIVE_URI.to_string(),
                "/v2/credentials/task-role".to_string(),
            )]),
        });

        let provider = ECSCredentialProvider::new();
        let endpoint = provider.get_endpoint(&ctx).unwrap();
        assert_eq!(endpoint, "http://169.254.170.2/v2/credentials/task-role");
    }

    #[tokio::test]
    async fn test_get_endpoint_relative_uri_with_custom_base() {
        let ctx = Context::new()
            .with_file_read(TokioFileRead)
            .with_http_send(ReqwestHttpSend::default());
        let ctx = ctx.with_env(StaticEnv {
            home_dir: None,
            envs: HashMap::from_iter([
                (
                    AWS_CONTAINER_CREDENTIALS_RELATIVE_URI.to_string(),
                    "/creds".to_string(),
                ),
                (
                    ECS_CONTAINER_METADATA_URI.to_string(),
                    "http://localhost:51679".to_string(),
                ),
            ]),
        });

        let provider = ECSCredentialProvider::new();
        let endpoint = provider.get_endpoint(&ctx).unwrap();
        assert_eq!(endpoint, "http://localhost:51679/creds");
    }

    #[tokio::test]
    async fn test_get_endpoint_full_uri() {
        let ctx = Context::new()
            .with_file_read(TokioFileRead)
            .with_http_send(ReqwestHttpSend::default());
        let ctx = ctx.with_env(StaticEnv {
            home_dir: None,
            envs: HashMap::from_iter([(
                AWS_CONTAINER_CREDENTIALS_FULL_URI.to_string(),
                "http://localhost:8080/credentials".to_string(),
            )]),
        });

        let provider = ECSCredentialProvider::new();
        let endpoint = provider.get_endpoint(&ctx).unwrap();
        assert_eq!(endpoint, "http://localhost:8080/credentials");
    }

    #[tokio::test]
    async fn test_custom_endpoint() {
        let ctx = Context::new()
            .with_file_read(TokioFileRead)
            .with_http_send(ReqwestHttpSend::default());
        let provider = ECSCredentialProvider::new().with_endpoint("http://custom-endpoint/creds");

        let endpoint = provider.get_endpoint(&ctx).unwrap();
        assert_eq!(endpoint, "http://custom-endpoint/creds");
    }

    #[tokio::test]
    async fn test_configured_relative_uri() {
        let ctx = Context::new()
            .with_file_read(TokioFileRead)
            .with_http_send(ReqwestHttpSend::default())
            .with_env(StaticEnv {
                home_dir: None,
                envs: HashMap::new(),
            });

        let provider = ECSCredentialProvider::new().with_relative_uri("/v2/credentials/task-role");

        let endpoint = provider.get_endpoint(&ctx).unwrap();
        assert_eq!(endpoint, "http://169.254.170.2/v2/credentials/task-role");
    }

    #[tokio::test]
    async fn test_configured_relative_uri_with_custom_base() {
        let ctx = Context::new()
            .with_file_read(TokioFileRead)
            .with_http_send(ReqwestHttpSend::default())
            .with_env(StaticEnv {
                home_dir: None,
                envs: HashMap::new(),
            });

        let provider = ECSCredentialProvider::new()
            .with_relative_uri("/creds")
            .with_metadata_uri_override("http://localhost:51679");

        let endpoint = provider.get_endpoint(&ctx).unwrap();
        assert_eq!(endpoint, "http://localhost:51679/creds");
    }

    #[tokio::test]
    async fn test_configured_values_override_env() {
        let ctx = Context::new()
            .with_file_read(TokioFileRead)
            .with_http_send(ReqwestHttpSend::default())
            .with_env(StaticEnv {
                home_dir: None,
                envs: HashMap::from_iter([
                    (
                        AWS_CONTAINER_CREDENTIALS_FULL_URI.to_string(),
                        "http://env-endpoint/creds".to_string(),
                    ),
                    (
                        AWS_CONTAINER_CREDENTIALS_RELATIVE_URI.to_string(),
                        "/env-relative".to_string(),
                    ),
                ]),
            });

        let provider =
            ECSCredentialProvider::new().with_endpoint("http://configured-endpoint/creds");

        let endpoint = provider.get_endpoint(&ctx).unwrap();
        // Configured value should override environment
        assert_eq!(endpoint, "http://configured-endpoint/creds");
    }

    #[tokio::test]
    async fn test_priority_order() {
        let ctx = Context::new()
            .with_file_read(TokioFileRead)
            .with_http_send(ReqwestHttpSend::default())
            .with_env(StaticEnv {
                home_dir: None,
                envs: HashMap::from_iter([(
                    AWS_CONTAINER_CREDENTIALS_FULL_URI.to_string(),
                    "http://env-full-uri/creds".to_string(),
                )]),
            });

        // Test priority: custom endpoint > relative URI > env
        let provider = ECSCredentialProvider::new()
            .with_endpoint("http://custom/creds")
            .with_relative_uri("/relative");

        let endpoint = provider.get_endpoint(&ctx).unwrap();
        assert_eq!(endpoint, "http://custom/creds");

        // Test without custom endpoint
        let provider = ECSCredentialProvider::new().with_relative_uri("/relative");

        let endpoint = provider.get_endpoint(&ctx).unwrap();
        assert_eq!(endpoint, "http://169.254.170.2/relative");
    }

    #[tokio::test]
    async fn test_configured_auth_token() {
        let ctx = Context::new()
            .with_file_read(TokioFileRead)
            .with_http_send(ReqwestHttpSend::default())
            .with_env(StaticEnv {
                home_dir: None,
                envs: HashMap::from_iter([(
                    AWS_CONTAINER_AUTHORIZATION_TOKEN.to_string(),
                    "env-token".to_string(),
                )]),
            });

        let provider = ECSCredentialProvider::new().with_auth_token("configured-token");

        let token = provider.load_auth_token(&ctx).await.unwrap();
        // Configured token should override environment
        assert_eq!(token, Some("configured-token".to_string()));
    }

    #[tokio::test]
    async fn test_configured_auth_token_file() {
        use std::io::Write;
        use tempfile::NamedTempFile;

        let mut temp_file = NamedTempFile::new().unwrap();
        writeln!(temp_file, "file-token").unwrap();
        let temp_path = temp_file.path().to_str().unwrap();

        let ctx = Context::new()
            .with_file_read(TokioFileRead)
            .with_http_send(ReqwestHttpSend::default())
            .with_env(StaticEnv {
                home_dir: None,
                envs: HashMap::from_iter([
                    (
                        AWS_CONTAINER_AUTHORIZATION_TOKEN.to_string(),
                        "env-token".to_string(),
                    ),
                    (
                        AWS_CONTAINER_AUTHORIZATION_TOKEN_FILE.to_string(),
                        "env-file.txt".to_string(),
                    ),
                ]),
            });

        let provider = ECSCredentialProvider::new().with_auth_token_file(temp_path);

        let token = provider.load_auth_token(&ctx).await.unwrap();
        // Configured file should override environment
        assert_eq!(token, Some("file-token".to_string()));
    }

    #[tokio::test]
    async fn test_auth_token_priority() {
        use std::io::Write;
        use tempfile::NamedTempFile;

        let mut temp_file = NamedTempFile::new().unwrap();
        writeln!(temp_file, "file-token").unwrap();
        let temp_path = temp_file.path().to_str().unwrap();

        let ctx = Context::new()
            .with_file_read(TokioFileRead)
            .with_http_send(ReqwestHttpSend::default())
            .with_env(StaticEnv {
                home_dir: None,
                envs: HashMap::new(),
            });

        // Test priority: direct token > configured file > env token > env file
        let provider = ECSCredentialProvider::new()
            .with_auth_token("direct-token")
            .with_auth_token_file(temp_path);

        let token = provider.load_auth_token(&ctx).await.unwrap();
        assert_eq!(token, Some("direct-token".to_string()));

        // Test without direct token
        let provider = ECSCredentialProvider::new().with_auth_token_file(temp_path);

        let token = provider.load_auth_token(&ctx).await.unwrap();
        assert_eq!(token, Some("file-token".to_string()));
    }
}
