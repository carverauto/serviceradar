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
#[cfg(not(target_arch = "wasm32"))]
use crate::constants::*;
#[cfg(not(target_arch = "wasm32"))]
use ini::Ini;
#[cfg(not(target_arch = "wasm32"))]
use log::debug;
#[cfg(not(target_arch = "wasm32"))]
use reqsign_core::Error;
use reqsign_core::{Context, ProvideCredential, Result};

/// ProfileCredentialProvider loads AWS credentials from configuration files.
///
/// This provider loads credentials from:
/// - `~/.aws/credentials` (or the path specified by `AWS_SHARED_CREDENTIALS_FILE`)
/// - `~/.aws/config` (or the path specified by `AWS_CONFIG_FILE`)
///
/// The profile to use is determined by:
/// 1. The `AWS_PROFILE` environment variable
/// 2. The profile specified via `with_profile()`
/// 3. Default to "default"
#[derive(Debug, Clone)]
pub struct ProfileCredentialProvider {
    profile: String,
    config_file: Option<String>,
    credentials_file: Option<String>,
}

impl Default for ProfileCredentialProvider {
    fn default() -> Self {
        Self::new()
    }
}

impl ProfileCredentialProvider {
    /// Create a new ProfileCredentialProvider with default settings.
    pub fn new() -> Self {
        Self {
            profile: "default".to_string(),
            config_file: None,
            credentials_file: None,
        }
    }

    /// Set the profile name to use.
    pub fn with_profile(mut self, profile: impl Into<String>) -> Self {
        self.profile = profile.into();
        self
    }

    /// Set the path to the config file.
    pub fn with_config_file(mut self, path: impl Into<String>) -> Self {
        self.config_file = Some(path.into());
        self
    }

    /// Set the path to the credentials file.
    pub fn with_credentials_file(mut self, path: impl Into<String>) -> Self {
        self.credentials_file = Some(path.into());
        self
    }

    #[cfg(not(target_arch = "wasm32"))]
    async fn load_from_credentials_file(
        &self,
        ctx: &Context,
        profile: &str,
    ) -> Result<Option<Credential>> {
        let path = if let Some(path) = &self.credentials_file {
            path.clone()
        } else if let Some(path) = ctx.env_var(AWS_SHARED_CREDENTIALS_FILE) {
            path
        } else {
            "~/.aws/credentials".to_string()
        };

        let expanded_path = if path.starts_with("~/") {
            match ctx.expand_home_dir(&path) {
                Some(expanded) => expanded,
                None => {
                    debug!("failed to expand homedir for path: {path}");
                    return Ok(None);
                }
            }
        } else {
            path.clone()
        };

        let content = match ctx.file_read(&expanded_path).await {
            Ok(content) => content,
            Err(err) => {
                debug!("failed to read credentials file {expanded_path}: {err:?}");
                return Ok(None);
            }
        };

        let conf = Ini::load_from_str(&String::from_utf8_lossy(&content)).map_err(|e| {
            Error::config_invalid("failed to parse credentials file").with_source(e)
        })?;

        let props = match conf.section(Some(profile)) {
            Some(props) => props,
            None => {
                debug!("profile {profile} not found in credentials file");
                return Ok(None);
            }
        };

        let access_key_id = props.get("aws_access_key_id");
        let secret_access_key = props.get("aws_secret_access_key");

        match (access_key_id, secret_access_key) {
            (Some(ak), Some(sk)) => Ok(Some(Credential {
                access_key_id: ak.to_string(),
                secret_access_key: sk.to_string(),
                session_token: props.get("aws_session_token").map(|s| s.to_string()),
                expires_in: None,
            })),
            _ => Ok(None),
        }
    }

    #[cfg(not(target_arch = "wasm32"))]
    async fn load_from_config_file(
        &self,
        ctx: &Context,
        profile: &str,
    ) -> Result<Option<Credential>> {
        let path = if let Some(path) = &self.config_file {
            path.clone()
        } else if let Some(path) = ctx.env_var(AWS_CONFIG_FILE) {
            path
        } else {
            "~/.aws/config".to_string()
        };

        let expanded_path = if path.starts_with("~/") {
            match ctx.expand_home_dir(&path) {
                Some(expanded) => expanded,
                None => {
                    debug!("failed to expand homedir for path: {path}");
                    return Ok(None);
                }
            }
        } else {
            path.clone()
        };

        let content = match ctx.file_read(&expanded_path).await {
            Ok(content) => content,
            Err(err) => {
                debug!("failed to read config file {expanded_path}: {err:?}");
                return Ok(None);
            }
        };

        let conf = Ini::load_from_str(&String::from_utf8_lossy(&content))
            .map_err(|e| Error::config_invalid("failed to parse config file").with_source(e))?;

        let section = match profile {
            "default" => "default".to_string(),
            x => format!("profile {x}"),
        };

        let props = match conf.section(Some(&section)) {
            Some(props) => props,
            None => {
                debug!("section {profile} not found in config file");
                return Ok(None);
            }
        };

        let access_key_id = props.get("aws_access_key_id");
        let secret_access_key = props.get("aws_secret_access_key");

        match (access_key_id, secret_access_key) {
            (Some(ak), Some(sk)) => Ok(Some(Credential {
                access_key_id: ak.to_string(),
                secret_access_key: sk.to_string(),
                session_token: props.get("aws_session_token").map(|s| s.to_string()),
                expires_in: None,
            })),
            _ => Ok(None),
        }
    }
}
impl ProvideCredential for ProfileCredentialProvider {
    type Credential = Credential;

    async fn provide_credential(&self, ctx: &Context) -> Result<Option<Self::Credential>> {
        #[cfg(target_arch = "wasm32")]
        {
            let _ = ctx;
            Ok(None)
        }

        #[cfg(not(target_arch = "wasm32"))]
        {
            // Determine the actual profile to use
            let profile = ctx
                .env_var(AWS_PROFILE)
                .unwrap_or_else(|| self.profile.clone());

            // Try credentials file first
            if let Some(cred) = self.load_from_credentials_file(ctx, &profile).await? {
                return Ok(Some(cred));
            }

            // Then try config file
            self.load_from_config_file(ctx, &profile).await
        }
    }
}

#[cfg(test)]
#[cfg(not(target_arch = "wasm32"))]
mod tests {
    use super::*;
    use pretty_assertions::assert_eq;
    use reqsign_core::StaticEnv;
    use reqsign_file_read_tokio::TokioFileRead;
    use reqsign_http_send_reqwest::ReqwestHttpSend;
    use std::collections::HashMap;
    use std::fs::File;
    use std::io::Write;
    use tempfile::tempdir;

    #[tokio::test]
    async fn test_profile_from_credentials_file() -> anyhow::Result<()> {
        let _ = env_logger::builder().is_test(true).try_init();

        let tmp_dir = tempdir()?;
        let file_path = tmp_dir.path().join("credentials");
        let mut tmp_file = File::create(&file_path)?;
        writeln!(tmp_file, "[default]")?;
        writeln!(tmp_file, "aws_access_key_id = DEFAULTACCESSKEYID")?;
        writeln!(tmp_file, "aws_secret_access_key = DEFAULTSECRETACCESSKEY")?;
        writeln!(tmp_file, "aws_session_token = DEFAULTSESSIONTOKEN")?;
        writeln!(tmp_file)?;
        writeln!(tmp_file, "[profile1]")?;
        writeln!(tmp_file, "aws_access_key_id = PROFILE1ACCESSKEYID")?;
        writeln!(tmp_file, "aws_secret_access_key = PROFILE1SECRETACCESSKEY")?;
        writeln!(tmp_file, "aws_session_token = PROFILE1SESSIONTOKEN")?;

        let context = Context::new()
            .with_file_read(TokioFileRead)
            .with_http_send(ReqwestHttpSend::default())
            .with_env(StaticEnv {
                home_dir: None,
                envs: HashMap::new(),
            });

        // Test default profile
        let provider =
            ProfileCredentialProvider::new().with_credentials_file(file_path.to_str().unwrap());
        let cred = provider.provide_credential(&context).await?;
        assert!(cred.is_some());
        let cred = cred.unwrap();
        assert_eq!(cred.access_key_id, "DEFAULTACCESSKEYID");
        assert_eq!(cred.secret_access_key, "DEFAULTSECRETACCESSKEY");
        assert_eq!(cred.session_token, Some("DEFAULTSESSIONTOKEN".to_string()));

        // Test specific profile
        let provider = ProfileCredentialProvider::new()
            .with_profile("profile1")
            .with_credentials_file(file_path.to_str().unwrap());
        let cred = provider.provide_credential(&context).await?;
        assert!(cred.is_some());
        let cred = cred.unwrap();
        assert_eq!(cred.access_key_id, "PROFILE1ACCESSKEYID");
        assert_eq!(cred.secret_access_key, "PROFILE1SECRETACCESSKEY");
        assert_eq!(cred.session_token, Some("PROFILE1SESSIONTOKEN".to_string()));

        Ok(())
    }

    #[tokio::test]
    async fn test_profile_from_config_file() -> anyhow::Result<()> {
        let _ = env_logger::builder().is_test(true).try_init();

        let tmp_dir = tempdir()?;
        let file_path = tmp_dir.path().join("config");
        let mut tmp_file = File::create(&file_path)?;
        writeln!(tmp_file, "[default]")?;
        writeln!(tmp_file, "aws_access_key_id = DEFAULTACCESSKEYID")?;
        writeln!(tmp_file, "aws_secret_access_key = DEFAULTSECRETACCESSKEY")?;
        writeln!(tmp_file)?;
        writeln!(tmp_file, "[profile profile1]")?;
        writeln!(tmp_file, "aws_access_key_id = PROFILE1ACCESSKEYID")?;
        writeln!(tmp_file, "aws_secret_access_key = PROFILE1SECRETACCESSKEY")?;

        let context = Context::new()
            .with_file_read(TokioFileRead)
            .with_http_send(ReqwestHttpSend::default())
            .with_env(StaticEnv {
                home_dir: None,
                envs: HashMap::new(),
            });

        // Test default profile
        let provider =
            ProfileCredentialProvider::new().with_config_file(file_path.to_str().unwrap());
        let cred = provider.provide_credential(&context).await?;
        assert!(cred.is_some());
        let cred = cred.unwrap();
        assert_eq!(cred.access_key_id, "DEFAULTACCESSKEYID");
        assert_eq!(cred.secret_access_key, "DEFAULTSECRETACCESSKEY");
        assert!(cred.session_token.is_none());

        // Test specific profile
        let provider = ProfileCredentialProvider::new()
            .with_profile("profile1")
            .with_config_file(file_path.to_str().unwrap());
        let cred = provider.provide_credential(&context).await?;
        assert!(cred.is_some());
        let cred = cred.unwrap();
        assert_eq!(cred.access_key_id, "PROFILE1ACCESSKEYID");
        assert_eq!(cred.secret_access_key, "PROFILE1SECRETACCESSKEY");
        assert!(cred.session_token.is_none());

        Ok(())
    }

    #[tokio::test]
    async fn test_profile_env_override() -> anyhow::Result<()> {
        let _ = env_logger::builder().is_test(true).try_init();

        let tmp_dir = tempdir()?;
        let file_path = tmp_dir.path().join("credentials");
        let mut tmp_file = File::create(&file_path)?;
        writeln!(tmp_file, "[default]")?;
        writeln!(tmp_file, "aws_access_key_id = DEFAULTACCESSKEYID")?;
        writeln!(tmp_file, "aws_secret_access_key = DEFAULTSECRETACCESSKEY")?;
        writeln!(tmp_file)?;
        writeln!(tmp_file, "[profile1]")?;
        writeln!(tmp_file, "aws_access_key_id = PROFILE1ACCESSKEYID")?;
        writeln!(tmp_file, "aws_secret_access_key = PROFILE1SECRETACCESSKEY")?;

        let context = Context::new()
            .with_file_read(TokioFileRead)
            .with_http_send(ReqwestHttpSend::default())
            .with_env(StaticEnv {
                home_dir: None,
                envs: HashMap::from([(AWS_PROFILE.to_string(), "profile1".to_string())]),
            });

        // Even though we set default, AWS_PROFILE should override
        let provider = ProfileCredentialProvider::new()
            .with_profile("default")
            .with_credentials_file(file_path.to_str().unwrap());
        let cred = provider.provide_credential(&context).await?;
        assert!(cred.is_some());
        let cred = cred.unwrap();
        assert_eq!(cred.access_key_id, "PROFILE1ACCESSKEYID");
        assert_eq!(cred.secret_access_key, "PROFILE1SECRETACCESSKEY");

        Ok(())
    }

    #[tokio::test]
    async fn test_profile_missing_credentials() -> anyhow::Result<()> {
        let context = Context::new()
            .with_file_read(TokioFileRead)
            .with_http_send(ReqwestHttpSend::default());

        let provider = ProfileCredentialProvider::new()
            .with_credentials_file("/non/existent/path")
            .with_config_file("/non/existent/path");
        let cred = provider.provide_credential(&context).await?;
        assert!(cred.is_none());

        Ok(())
    }
}
