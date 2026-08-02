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
use ini::Ini;
use log::{debug, warn};
use reqsign_core::time::Timestamp;
use reqsign_core::{Context, Error, ProvideCredential, Result};
use serde::Deserialize;

const AWS_SSO_ACCOUNT_ID: &str = "sso_account_id";
const AWS_SSO_REGION: &str = "sso_region";
const AWS_SSO_ROLE_NAME: &str = "sso_role_name";
const AWS_SSO_START_URL: &str = "sso_start_url";
#[allow(dead_code)]
const AWS_SSO_SESSION_NAME: &str = "sso_session";

/// SSO Credentials Provider
///
/// This provider fetches credentials from AWS SSO (IAM Identity Center).
/// It reads cached SSO tokens from ~/.aws/sso/cache/ and exchanges them for temporary credentials.
///
/// # Configuration
/// SSO configuration is typically stored in ~/.aws/config under a profile:
/// ```ini
/// [profile my-sso-profile]
/// sso_start_url = https://my-sso-portal.awsapps.com/start
/// sso_region = us-east-1
/// sso_account_id = 123456789012
/// sso_role_name = MyRole
/// ```
#[derive(Debug, Clone)]
pub struct SSOCredentialProvider {
    profile: Option<String>,
    sso_account_id: Option<String>,
    sso_region: Option<String>,
    sso_role_name: Option<String>,
    sso_start_url: Option<String>,
    sso_endpoint: Option<String>, // Allow custom endpoint for testing
}

impl Default for SSOCredentialProvider {
    fn default() -> Self {
        Self::new()
    }
}

impl SSOCredentialProvider {
    /// Create a new SSO credential provider
    pub fn new() -> Self {
        Self {
            profile: None,
            sso_account_id: None,
            sso_region: None,
            sso_role_name: None,
            sso_start_url: None,
            sso_endpoint: None,
        }
    }

    /// Set the profile name to use
    pub fn with_profile(mut self, profile: impl Into<String>) -> Self {
        self.profile = Some(profile.into());
        self
    }

    /// Set SSO account ID
    pub fn with_account_id(mut self, account_id: impl Into<String>) -> Self {
        self.sso_account_id = Some(account_id.into());
        self
    }

    /// Set SSO region
    pub fn with_region(mut self, region: impl Into<String>) -> Self {
        self.sso_region = Some(region.into());
        self
    }

    /// Set SSO role name
    pub fn with_role_name(mut self, role_name: impl Into<String>) -> Self {
        self.sso_role_name = Some(role_name.into());
        self
    }

    /// Set SSO start URL
    pub fn with_start_url(mut self, start_url: impl Into<String>) -> Self {
        self.sso_start_url = Some(start_url.into());
        self
    }

    /// Set custom SSO endpoint (for testing)
    pub fn with_endpoint(mut self, endpoint: impl Into<String>) -> Self {
        self.sso_endpoint = Some(endpoint.into());
        self
    }

    async fn load_sso_config(&self, ctx: &Context) -> Result<SSOConfig> {
        // If all fields are provided directly, use them
        if let (Some(account_id), Some(region), Some(role_name), Some(start_url)) = (
            &self.sso_account_id,
            &self.sso_region,
            &self.sso_role_name,
            &self.sso_start_url,
        ) {
            return Ok(SSOConfig {
                sso_account_id: account_id.clone(),
                sso_region: region.clone(),
                sso_role_name: role_name.clone(),
                sso_start_url: start_url.clone(),
            });
        }

        // Otherwise, load from config file
        // Priority: 1. self.profile, 2. AWS_PROFILE env var, 3. "default"
        let profile_name = self
            .profile
            .clone()
            .or_else(|| ctx.env_var("AWS_PROFILE"))
            .unwrap_or_else(|| "default".to_string());
        self.load_from_config_file(ctx, &profile_name).await
    }

    async fn load_from_config_file(&self, ctx: &Context, profile: &str) -> Result<SSOConfig> {
        // Load AWS config file
        let config_path = ctx
            .env_var("AWS_CONFIG_FILE")
            .unwrap_or_else(|| "~/.aws/config".to_string());

        let expanded_path = if config_path.starts_with("~/") {
            match ctx.expand_home_dir(&config_path) {
                Some(expanded) => expanded,
                None => return Err(Error::config_invalid("failed to expand home directory")),
            }
        } else {
            config_path
        };

        let content = ctx.file_read(&expanded_path).await.map_err(|_| {
            Error::config_invalid(format!("failed to read config file: {expanded_path}"))
        })?;

        let conf = Ini::load_from_str(&String::from_utf8_lossy(&content))
            .map_err(|e| Error::config_invalid(format!("failed to parse config file: {e}")))?;

        let profile_section = if profile == "default" {
            profile.to_string()
        } else {
            format!("profile {profile}")
        };

        let section = conf.section(Some(profile_section)).ok_or_else(|| {
            Error::config_invalid(format!("profile '{profile}' not found in config"))
        })?;

        // Check if this profile has SSO configuration
        let sso_account_id = section.get(AWS_SSO_ACCOUNT_ID).ok_or_else(|| {
            Error::config_invalid(format!("missing {AWS_SSO_ACCOUNT_ID} in profile"))
        })?;

        let sso_region = section
            .get(AWS_SSO_REGION)
            .ok_or_else(|| Error::config_invalid(format!("missing {AWS_SSO_REGION} in profile")))?;

        let sso_role_name = section.get(AWS_SSO_ROLE_NAME).ok_or_else(|| {
            Error::config_invalid(format!("missing {AWS_SSO_ROLE_NAME} in profile"))
        })?;

        let sso_start_url = section.get(AWS_SSO_START_URL).ok_or_else(|| {
            Error::config_invalid(format!("missing {AWS_SSO_START_URL} in profile"))
        })?;

        Ok(SSOConfig {
            sso_account_id: sso_account_id.to_string(),
            sso_region: sso_region.to_string(),
            sso_role_name: sso_role_name.to_string(),
            sso_start_url: sso_start_url.to_string(),
        })
    }

    async fn find_cached_token(
        &self,
        ctx: &Context,
        start_url: &str,
    ) -> Result<Option<CachedToken>> {
        // Get home directory and build cache path
        let home_dir = ctx
            .home_dir()
            .ok_or_else(|| Error::config_invalid("HOME directory not found".to_string()))?;

        let cache_dir = home_dir.join(".aws").join("sso").join("cache");

        // Generate cache file name (SHA1 hash of start URL)
        let cache_key = hex_sha1(start_url.as_bytes());
        let cache_file = cache_dir.join(format!("{cache_key}.json"));

        debug!("looking for SSO token cache at: {cache_file:?}");

        match ctx.file_read(&cache_file.to_string_lossy()).await {
            Ok(content) => {
                let token: CachedToken = serde_json::from_slice(&content).map_err(|e| {
                    Error::unexpected(format!("failed to parse SSO token cache: {e}"))
                })?;

                // Check if token is expired
                let expires_at = token.expires_at.parse::<Timestamp>()?;
                if expires_at <= Timestamp::now() {
                    warn!("SSO token is expired");
                    return Ok(None);
                }

                Ok(Some(token))
            }
            Err(_) => {
                debug!("SSO token cache not found");
                Ok(None)
            }
        }
    }

    async fn get_role_credentials(
        &self,
        ctx: &Context,
        config: &SSOConfig,
        access_token: &str,
    ) -> Result<Credential> {
        // Allow endpoint override for testing
        let endpoint = self
            .sso_endpoint
            .clone()
            .or_else(|| ctx.env_var("AWS_SSO_ENDPOINT"))
            .unwrap_or_else(|| {
                format!(
                    "https://portal.sso.{}.amazonaws.com/federation/credentials",
                    config.sso_region
                )
            });

        let params = serde_urlencoded::to_string([
            ("role_name", &config.sso_role_name),
            ("account_id", &config.sso_account_id),
        ])
        .map_err(|e| Error::unexpected(format!("failed to encode query params: {e}")))?;

        let url = format!("{endpoint}?{params}");

        let req = Request::builder()
            .method(Method::GET)
            .uri(&url)
            .header("x-amz-sso_bearer_token", access_token)
            .body(bytes::Bytes::new())
            .map_err(|e| Error::unexpected(format!("failed to build request: {e}")))?;

        let resp = ctx
            .http_send(req)
            .await
            .map_err(|e| Error::unexpected(format!("failed to fetch SSO credentials: {e}")))?;

        if resp.status() != StatusCode::OK {
            return Err(Error::unexpected(format!(
                "SSO endpoint returned status: {}",
                resp.status()
            )));
        }

        let body = resp.into_body();
        let creds: SSOCredentialResponse = serde_json::from_slice(&body)
            .map_err(|e| Error::unexpected(format!("failed to parse SSO credentials: {e}")))?;

        let role_creds = creds.role_credentials;
        let expires_in = Timestamp::from_millisecond(role_creds.expiration)
            .map_err(|e| Error::unexpected(format!("invalid expiration timestamp: {e}")))?;

        Ok(Credential {
            access_key_id: role_creds.access_key_id,
            secret_access_key: role_creds.secret_access_key,
            session_token: Some(role_creds.session_token),
            expires_in: Some(expires_in),
        })
    }
}

#[derive(Debug)]
struct SSOConfig {
    sso_account_id: String,
    sso_region: String,
    sso_role_name: String,
    sso_start_url: String,
}

#[derive(Debug, Deserialize)]
struct CachedToken {
    #[serde(rename = "accessToken")]
    access_token: String,
    #[serde(rename = "expiresAt")]
    expires_at: String,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct SSOCredentialResponse {
    role_credentials: RoleCredentials,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct RoleCredentials {
    access_key_id: String,
    secret_access_key: String,
    session_token: String,
    expiration: i64,
}
impl ProvideCredential for SSOCredentialProvider {
    type Credential = Credential;

    async fn provide_credential(&self, ctx: &Context) -> Result<Option<Self::Credential>> {
        let config = match self.load_sso_config(ctx).await {
            Ok(c) => c,
            Err(_) => {
                debug!("SSO configuration not found");
                return Ok(None);
            }
        };

        debug!(
            "SSO config loaded: account={}, role={}",
            config.sso_account_id, config.sso_role_name
        );

        // Find cached SSO token
        let token = self
            .find_cached_token(ctx, &config.sso_start_url)
            .await?
            .ok_or_else(|| {
                Error::config_invalid(
                    "No valid SSO token found. Please run 'aws sso login' first".to_string(),
                )
            })?;

        // Exchange token for role credentials
        let creds = self
            .get_role_credentials(ctx, &config, &token.access_token)
            .await?;

        Ok(Some(creds))
    }
}

// Simple SHA1 implementation for cache key generation
fn hex_sha1(data: &[u8]) -> String {
    use sha1::{Digest, Sha1};
    let mut hasher = Sha1::new();
    hasher.update(data);
    hex::encode(hasher.finalize())
}

#[cfg(test)]
mod tests {
    use super::*;
    use reqsign_core::StaticEnv;
    use reqsign_file_read_tokio::TokioFileRead;
    use reqsign_http_send_reqwest::ReqwestHttpSend;
    use std::collections::HashMap;

    #[tokio::test]
    async fn test_sso_provider_no_config() {
        let ctx = Context::new()
            .with_file_read(TokioFileRead)
            .with_http_send(ReqwestHttpSend::default());
        let ctx = ctx.with_env(StaticEnv {
            home_dir: Some(std::path::PathBuf::from("/home/test")),
            envs: HashMap::new(),
        });

        let provider = SSOCredentialProvider::new();
        let result = provider.provide_credential(&ctx).await.unwrap();
        assert!(result.is_none());
    }

    #[test]
    fn test_sha1_hash() {
        let url = "https://my-sso-portal.awsapps.com/start";
        let hash = hex_sha1(url.as_bytes());
        assert_eq!(hash.len(), 40); // SHA1 produces 40 hex characters
    }
}
