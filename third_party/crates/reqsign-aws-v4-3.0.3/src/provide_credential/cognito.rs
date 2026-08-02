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
use http::{Method, Request, StatusCode};
use log::debug;
use reqsign_core::time::Timestamp;
use reqsign_core::{Context, Error, ProvideCredential, Result};
use serde::Deserialize;
use serde_json::json;

/// Cognito Identity Credentials Provider
///
/// This provider fetches temporary AWS credentials using Amazon Cognito Identity.
/// It's typically used for mobile and web applications that need temporary AWS access.
///
/// # Requirements
/// - A Cognito Identity Pool ID
/// - Optional: Identity token from a supported identity provider (Facebook, Google, etc.)
///
/// # Environment Variables
/// The provider supports the following environment variables:
/// - `AWS_COGNITO_IDENTITY_POOL_ID`: The Cognito Identity Pool ID
/// - `AWS_COGNITO_IDENTITY_ID`: A specific identity ID (if already known)
/// - `AWS_REGION` or `AWS_DEFAULT_REGION`: The AWS region
/// - `AWS_COGNITO_ENDPOINT`: Custom endpoint (for testing)
///
/// # Usage
/// ```rust,no_run
/// use reqsign_aws_v4::CognitoIdentityCredentialProvider;
///
/// let provider = CognitoIdentityCredentialProvider::new()
///     .with_identity_pool_id("us-east-1:12345678-1234-1234-1234-123456789012")
///     .with_region("us-east-1");
/// ```
#[derive(Debug, Clone)]
pub struct CognitoIdentityCredentialProvider {
    identity_pool_id: Option<String>,
    region: Option<String>,
    identity_id: Option<String>,
    logins: Option<std::collections::HashMap<String, String>>,
}

impl Default for CognitoIdentityCredentialProvider {
    fn default() -> Self {
        Self::new()
    }
}

impl CognitoIdentityCredentialProvider {
    /// Create a new Cognito Identity credential provider
    pub fn new() -> Self {
        Self {
            identity_pool_id: None,
            region: None,
            identity_id: None,
            logins: None,
        }
    }

    /// Set the Cognito Identity Pool ID
    pub fn with_identity_pool_id(mut self, pool_id: impl Into<String>) -> Self {
        self.identity_pool_id = Some(pool_id.into());
        self
    }

    /// Set the AWS region
    pub fn with_region(mut self, region: impl Into<String>) -> Self {
        self.region = Some(region.into());
        self
    }

    /// Set a specific identity ID (if already known)
    pub fn with_identity_id(mut self, identity_id: impl Into<String>) -> Self {
        self.identity_id = Some(identity_id.into());
        self
    }

    /// Add login tokens from identity providers
    pub fn with_logins(mut self, logins: std::collections::HashMap<String, String>) -> Self {
        self.logins = Some(logins);
        self
    }

    /// Get or create an identity ID
    async fn get_identity_id(&self, ctx: &Context) -> Result<String> {
        // Check for explicit identity ID or from environment
        if let Some(id) = &self.identity_id {
            return Ok(id.clone());
        }
        if let Some(id) = ctx.env_var("AWS_COGNITO_IDENTITY_ID") {
            return Ok(id);
        }

        let pool_id = self
            .identity_pool_id
            .clone()
            .or_else(|| ctx.env_var("AWS_COGNITO_IDENTITY_POOL_ID"))
            .ok_or_else(|| Error::config_invalid("identity_pool_id is required".to_string()))?;

        let region = self
            .region
            .clone()
            .or_else(|| ctx.env_var("AWS_REGION"))
            .or_else(|| ctx.env_var("AWS_DEFAULT_REGION"))
            .ok_or_else(|| Error::config_invalid("region is required".to_string()))?;

        // Allow endpoint override for testing
        let endpoint = ctx
            .env_var("AWS_COGNITO_ENDPOINT")
            .unwrap_or_else(|| format!("https://cognito-identity.{region}.amazonaws.com/"));

        let body = if let Some(logins) = &self.logins {
            json!({
                "IdentityPoolId": pool_id,
                "Logins": logins
            })
        } else {
            json!({
                "IdentityPoolId": pool_id
            })
        };

        let req = Request::builder()
            .method(Method::POST)
            .uri(&endpoint)
            .header("x-amz-target", "AWSCognitoIdentityService.GetId")
            .header("content-type", "application/x-amz-json-1.1")
            .body(bytes::Bytes::from(serde_json::to_vec(&body).map_err(
                |e| Error::unexpected(format!("failed to serialize request body: {e}")),
            )?))
            .map_err(|e| Error::unexpected(format!("failed to build request: {e}")))?;

        let resp = ctx
            .http_send(req)
            .await
            .map_err(|e| Error::unexpected(format!("failed to get identity ID: {e}")))?;

        if resp.status() != StatusCode::OK {
            return Err(Error::unexpected(format!(
                "Cognito GetId returned status: {}",
                resp.status()
            )));
        }

        let body = resp.into_body();
        let result: GetIdResponse = serde_json::from_slice(&body)
            .map_err(|e| Error::unexpected(format!("failed to parse GetId response: {e}")))?;

        Ok(result.identity_id)
    }

    /// Get credentials for an identity
    async fn get_credentials_for_identity(
        &self,
        ctx: &Context,
        identity_id: &str,
    ) -> Result<Credential> {
        let region = self
            .region
            .clone()
            .or_else(|| ctx.env_var("AWS_REGION"))
            .or_else(|| ctx.env_var("AWS_DEFAULT_REGION"))
            .ok_or_else(|| Error::config_invalid("region is required".to_string()))?;

        // Allow endpoint override for testing
        let endpoint = ctx
            .env_var("AWS_COGNITO_ENDPOINT")
            .unwrap_or_else(|| format!("https://cognito-identity.{region}.amazonaws.com/"));

        let body = if let Some(logins) = &self.logins {
            json!({
                "IdentityId": identity_id,
                "Logins": logins
            })
        } else {
            json!({
                "IdentityId": identity_id
            })
        };

        let req = Request::builder()
            .method(Method::POST)
            .uri(&endpoint)
            .header(
                "x-amz-target",
                "AWSCognitoIdentityService.GetCredentialsForIdentity",
            )
            .header("content-type", "application/x-amz-json-1.1")
            .body(bytes::Bytes::from(serde_json::to_vec(&body).map_err(
                |e| Error::unexpected(format!("failed to serialize request body: {e}")),
            )?))
            .map_err(|e| Error::unexpected(format!("failed to build request: {e}")))?;

        let resp = ctx
            .http_send(req)
            .await
            .map_err(|e| Error::unexpected(format!("failed to get credentials: {e}")))?;

        if resp.status() != StatusCode::OK {
            return Err(Error::unexpected(format!(
                "Cognito GetCredentialsForIdentity returned status: {}",
                resp.status()
            )));
        }

        let body = resp.into_body();
        let result: GetCredentialsResponse = serde_json::from_slice(&body)
            .map_err(|e| Error::unexpected(format!("failed to parse credentials response: {e}")))?;

        let creds = result.credentials;
        let expires_in = Timestamp::from_second(creds.expiration)
            .map_err(|e| Error::unexpected(format!("invalid expiration date: {e}")))?;

        Ok(Credential {
            access_key_id: creds.access_key_id,
            secret_access_key: creds.secret_key,
            session_token: Some(creds.session_token),
            expires_in: Some(expires_in),
        })
    }
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "PascalCase")]
struct GetIdResponse {
    identity_id: String,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "PascalCase")]
struct GetCredentialsResponse {
    credentials: CognitoCredentials,
    #[allow(dead_code)]
    identity_id: String,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "PascalCase")]
struct CognitoCredentials {
    access_key_id: String,
    secret_key: String,
    session_token: String,
    expiration: i64,
}
impl ProvideCredential for CognitoIdentityCredentialProvider {
    type Credential = Credential;

    async fn provide_credential(&self, ctx: &Context) -> Result<Option<Self::Credential>> {
        // Check if identity pool ID is available from config or environment
        let has_pool_id = self.identity_pool_id.is_some()
            || ctx.env_var("AWS_COGNITO_IDENTITY_POOL_ID").is_some();

        if !has_pool_id {
            debug!("Cognito Identity: no identity pool ID configured");
            return Ok(None);
        }

        // Get or create identity ID
        let identity_id = self.get_identity_id(ctx).await?;
        debug!("Cognito Identity: using identity ID: {identity_id}");

        // Get credentials for the identity
        let creds = self.get_credentials_for_identity(ctx, &identity_id).await?;

        Ok(Some(creds))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use reqsign_file_read_tokio::TokioFileRead;
    use reqsign_http_send_reqwest::ReqwestHttpSend;

    #[tokio::test]
    async fn test_cognito_provider_no_config() {
        let ctx = Context::new()
            .with_file_read(TokioFileRead)
            .with_http_send(ReqwestHttpSend::default());
        let provider = CognitoIdentityCredentialProvider::new();
        let result = provider.provide_credential(&ctx).await.unwrap();
        assert!(result.is_none());
    }

    #[test]
    fn test_cognito_provider_builder() {
        let provider = CognitoIdentityCredentialProvider::new()
            .with_identity_pool_id("us-east-1:12345678-1234-1234-1234-123456789012")
            .with_region("us-east-1");

        assert_eq!(
            provider.identity_pool_id,
            Some("us-east-1:12345678-1234-1234-1234-123456789012".to_string())
        );
        assert_eq!(provider.region, Some("us-east-1".to_string()));
    }
}
