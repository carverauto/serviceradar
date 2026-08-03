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
use crate::provide_credential::{
    AssumeRoleWithWebIdentityCredentialProvider, ECSCredentialProvider, EnvCredentialProvider,
    IMDSv2CredentialProvider, ProfileCredentialProvider,
};
#[cfg(not(target_arch = "wasm32"))]
use crate::provide_credential::{ProcessCredentialProvider, SSOCredentialProvider};
use reqsign_core::{Context, ProvideCredential, ProvideCredentialChain, Result};

/// DefaultCredentialProvider is a loader that will try to load credential via default chains.
///
/// Resolution order:
///
/// 1. Environment variables
/// 2. Shared config (`~/.aws/config`, `~/.aws/credentials`)
/// 3. SSO credentials
/// 4. Web Identity Tokens
/// 5. Process credentials
/// 6. ECS (IAM Roles for Tasks) & Container credentials
/// 7. EC2 IMDSv2
#[derive(Debug)]
pub struct DefaultCredentialProvider {
    chain: ProvideCredentialChain<Credential>,
}

impl Default for DefaultCredentialProvider {
    fn default() -> Self {
        Self::new()
    }
}

impl DefaultCredentialProvider {
    /// Create a builder to configure the default credential chain.
    pub fn builder() -> DefaultCredentialProviderBuilder {
        DefaultCredentialProviderBuilder::default()
    }

    /// Create a new `DefaultCredentialProvider` instance using the default chain.
    pub fn new() -> Self {
        Self::builder().build()
    }

    /// Create with a custom credential chain.
    pub fn with_chain(chain: ProvideCredentialChain<Credential>) -> Self {
        Self { chain }
    }

    /// Add a credential provider to the front of the default chain.
    ///
    /// This allows adding a high-priority credential source that will be tried
    /// before all other providers in the default chain.
    ///
    /// # Example
    ///
    /// ```no_run
    /// use reqsign_aws_v4::{DefaultCredentialProvider, StaticCredentialProvider};
    ///
    /// let provider = DefaultCredentialProvider::new()
    ///     .push_front(StaticCredentialProvider::new("access_key_id", "secret_access_key"));
    /// ```
    pub fn push_front(
        mut self,
        provider: impl ProvideCredential<Credential = Credential> + 'static,
    ) -> Self {
        self.chain = self.chain.push_front(provider);
        self
    }
}

/// Builder for `DefaultCredentialProvider`.
///
/// Use `slot(provider)` to override a default slot and `no_slot()` to remove it
/// from the default chain. Call `build()` to construct the provider.
pub struct DefaultCredentialProviderBuilder {
    env: Option<EnvCredentialProvider>,
    profile: Option<ProfileCredentialProvider>,
    #[cfg(not(target_arch = "wasm32"))]
    sso: Option<SSOCredentialProvider>,
    web_identity: Option<AssumeRoleWithWebIdentityCredentialProvider>,
    #[cfg(not(target_arch = "wasm32"))]
    process: Option<ProcessCredentialProvider>,
    ecs: Option<ECSCredentialProvider>,
    imds: Option<IMDSv2CredentialProvider>,
}

impl Default for DefaultCredentialProviderBuilder {
    fn default() -> Self {
        Self {
            env: Some(EnvCredentialProvider::new()),
            profile: Some(ProfileCredentialProvider::default()),
            #[cfg(not(target_arch = "wasm32"))]
            sso: Some(SSOCredentialProvider::default()),
            web_identity: Some(AssumeRoleWithWebIdentityCredentialProvider::default()),
            #[cfg(not(target_arch = "wasm32"))]
            process: Some(ProcessCredentialProvider::default()),
            ecs: Some(ECSCredentialProvider::default()),
            imds: Some(IMDSv2CredentialProvider::default()),
        }
    }
}

impl DefaultCredentialProviderBuilder {
    /// Create a new builder with default state.
    pub fn new() -> Self {
        Self::default()
    }

    /// Override the environment credential provider slot.
    pub fn env(mut self, provider: EnvCredentialProvider) -> Self {
        self.env = Some(provider);
        self
    }

    /// Remove the environment credential provider from the chain.
    pub fn no_env(mut self) -> Self {
        self.env = None;
        self
    }

    /// Override the profile credential provider slot.
    pub fn profile(mut self, provider: ProfileCredentialProvider) -> Self {
        self.profile = Some(provider);
        self
    }

    /// Remove the profile credential provider from the chain.
    pub fn no_profile(mut self) -> Self {
        self.profile = None;
        self
    }

    /// Override the SSO credential provider slot.
    #[cfg(not(target_arch = "wasm32"))]
    pub fn sso(mut self, provider: SSOCredentialProvider) -> Self {
        self.sso = Some(provider);
        self
    }

    /// Remove the SSO credential provider from the chain.
    #[cfg(not(target_arch = "wasm32"))]
    pub fn no_sso(mut self) -> Self {
        self.sso = None;
        self
    }

    /// Override the web-identity credential provider slot.
    pub fn web_identity(mut self, provider: AssumeRoleWithWebIdentityCredentialProvider) -> Self {
        self.web_identity = Some(provider);
        self
    }

    /// Remove the web-identity credential provider from the chain.
    pub fn no_web_identity(mut self) -> Self {
        self.web_identity = None;
        self
    }

    /// Override the external process credential provider slot.
    #[cfg(not(target_arch = "wasm32"))]
    pub fn process(mut self, provider: ProcessCredentialProvider) -> Self {
        self.process = Some(provider);
        self
    }

    /// Remove the external process credential provider from the chain.
    #[cfg(not(target_arch = "wasm32"))]
    pub fn no_process(mut self) -> Self {
        self.process = None;
        self
    }

    /// Override the ECS credential provider slot.
    pub fn ecs(mut self, provider: ECSCredentialProvider) -> Self {
        self.ecs = Some(provider);
        self
    }

    /// Remove the ECS credential provider from the chain.
    pub fn no_ecs(mut self) -> Self {
        self.ecs = None;
        self
    }

    /// Override the EC2 IMDSv2 credential provider slot.
    pub fn imds(mut self, provider: IMDSv2CredentialProvider) -> Self {
        self.imds = Some(provider);
        self
    }

    /// Remove the EC2 IMDSv2 credential provider from the chain.
    pub fn no_imds(mut self) -> Self {
        self.imds = None;
        self
    }

    /// Build the `DefaultCredentialProvider` with the configured options.
    pub fn build(self) -> DefaultCredentialProvider {
        let mut chain = ProvideCredentialChain::new();

        if let Some(p) = self.env {
            chain = chain.push(p);
        }

        if let Some(p) = self.profile {
            chain = chain.push(p);
        }

        #[cfg(not(target_arch = "wasm32"))]
        {
            if let Some(p) = self.sso {
                chain = chain.push(p);
            }
        }

        if let Some(p) = self.web_identity {
            chain = chain.push(p);
        }

        #[cfg(not(target_arch = "wasm32"))]
        {
            if let Some(p) = self.process {
                chain = chain.push(p);
            }
        }

        if let Some(p) = self.ecs {
            chain = chain.push(p);
        }

        if let Some(p) = self.imds {
            chain = chain.push(p);
        }

        DefaultCredentialProvider::with_chain(chain)
    }
}
impl ProvideCredential for DefaultCredentialProvider {
    type Credential = Credential;

    async fn provide_credential(&self, ctx: &Context) -> Result<Option<Self::Credential>> {
        self.chain.provide_credential(ctx).await
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::constants::{
        AWS_ACCESS_KEY_ID, AWS_CONFIG_FILE, AWS_SECRET_ACCESS_KEY, AWS_SHARED_CREDENTIALS_FILE,
    };
    #[cfg(not(target_arch = "wasm32"))]
    use reqsign_command_execute_tokio::TokioCommandExecute;
    use reqsign_core::{OsEnv, StaticEnv};
    use reqsign_file_read_tokio::TokioFileRead;
    use reqsign_http_send_reqwest::ReqwestHttpSend;
    use std::collections::HashMap;
    use std::env;

    #[tokio::test]
    async fn test_credential_env_loader_without_env() {
        let _ = env_logger::builder().is_test(true).try_init();

        let ctx = Context::new()
            .with_file_read(TokioFileRead)
            .with_http_send(ReqwestHttpSend::default())
            .with_env(OsEnv);
        let ctx = ctx.with_env(StaticEnv {
            home_dir: None,
            envs: HashMap::new(),
        });

        let builder = DefaultCredentialProvider::builder()
            .no_profile()
            .no_web_identity()
            .no_ecs()
            .no_imds();
        #[cfg(not(target_arch = "wasm32"))]
        let builder = builder.no_sso().no_process();
        #[cfg(target_arch = "wasm32")]
        let builder = builder;

        let l = builder.build();
        let x = l.provide_credential(&ctx).await.expect("load must succeed");
        assert!(x.is_none());
    }

    #[tokio::test]
    async fn test_credential_env_loader_with_env() {
        let _ = env_logger::builder().is_test(true).try_init();

        let ctx = Context::new()
            .with_file_read(TokioFileRead)
            .with_http_send(ReqwestHttpSend::default())
            .with_env(OsEnv);
        let ctx = ctx.with_env(StaticEnv {
            home_dir: None,
            envs: HashMap::from_iter([
                (AWS_ACCESS_KEY_ID.to_string(), "access_key_id".to_string()),
                (
                    AWS_SECRET_ACCESS_KEY.to_string(),
                    "secret_access_key".to_string(),
                ),
            ]),
        });

        let l = DefaultCredentialProvider::new();
        let x = l.provide_credential(&ctx).await.expect("load must succeed");

        let x = x.expect("must load succeed");
        assert_eq!("access_key_id", x.access_key_id);
        assert_eq!("secret_access_key", x.secret_access_key);
    }

    #[tokio::test]
    async fn test_default_credential_provider_no_env_removes_slot() {
        let _ = env_logger::builder().is_test(true).try_init();

        let ctx = Context::new()
            .with_file_read(TokioFileRead)
            .with_http_send(ReqwestHttpSend::default())
            .with_env(OsEnv);
        let ctx = ctx.with_env(StaticEnv {
            home_dir: None,
            envs: HashMap::from_iter([
                (AWS_ACCESS_KEY_ID.to_string(), "access_key_id".to_string()),
                (
                    AWS_SECRET_ACCESS_KEY.to_string(),
                    "secret_access_key".to_string(),
                ),
            ]),
        });

        let builder = DefaultCredentialProvider::builder()
            .no_env()
            .no_profile()
            .no_imds()
            .no_ecs()
            .no_web_identity();
        #[cfg(not(target_arch = "wasm32"))]
        let builder = builder.no_sso().no_process();
        #[cfg(target_arch = "wasm32")]
        let builder = builder;

        let provider = builder.build();

        let cred = provider
            .provide_credential(&ctx)
            .await
            .expect("load must succeed");
        assert!(cred.is_none());
    }

    #[tokio::test]
    async fn test_credential_profile_loader_from_config() {
        let _ = env_logger::builder().is_test(true).try_init();

        let ctx = Context::new()
            .with_file_read(TokioFileRead)
            .with_http_send(ReqwestHttpSend::default())
            .with_env(OsEnv);
        let ctx = ctx.with_env(StaticEnv {
            home_dir: None,
            envs: HashMap::from_iter([
                (
                    AWS_CONFIG_FILE.to_string(),
                    format!(
                        "{}/testdata/default_config",
                        env::current_dir()
                            .expect("current_dir must exist")
                            .to_string_lossy()
                    ),
                ),
                (
                    AWS_SHARED_CREDENTIALS_FILE.to_string(),
                    format!(
                        "{}/testdata/not_exist",
                        env::current_dir()
                            .expect("current_dir must exist")
                            .to_string_lossy()
                    ),
                ),
            ]),
        });

        let l = DefaultCredentialProvider::new();
        let x = l.provide_credential(&ctx).await.unwrap().unwrap();
        assert_eq!("config_access_key_id", x.access_key_id);
        assert_eq!("config_secret_access_key", x.secret_access_key);
    }

    #[tokio::test]
    async fn test_credential_profile_loader_from_shared() {
        let _ = env_logger::builder().is_test(true).try_init();

        let ctx = Context::new()
            .with_file_read(TokioFileRead)
            .with_http_send(ReqwestHttpSend::default())
            .with_env(OsEnv);
        let ctx = ctx.with_env(StaticEnv {
            home_dir: None,
            envs: HashMap::from_iter([
                (
                    AWS_CONFIG_FILE.to_string(),
                    format!(
                        "{}/testdata/not_exist",
                        env::current_dir()
                            .expect("current_dir must exist")
                            .to_string_lossy()
                    ),
                ),
                (
                    AWS_SHARED_CREDENTIALS_FILE.to_string(),
                    format!(
                        "{}/testdata/default_credential",
                        env::current_dir()
                            .expect("current_dir must exist")
                            .to_string_lossy()
                    ),
                ),
            ]),
        });

        let l = DefaultCredentialProvider::new();
        let x = l.provide_credential(&ctx).await.unwrap().unwrap();
        assert_eq!("shared_access_key_id", x.access_key_id);
        assert_eq!("shared_secret_access_key", x.secret_access_key);
    }

    #[tokio::test]
    async fn test_default_credential_provider_prepend() {
        let _ = env_logger::builder().is_test(true).try_init();

        let ctx = Context::new()
            .with_file_read(TokioFileRead)
            .with_http_send(ReqwestHttpSend::default())
            .with_env(OsEnv);
        let ctx = ctx.with_env(StaticEnv {
            home_dir: None,
            envs: HashMap::from_iter([
                // Set environment variables that would normally be loaded
                (AWS_ACCESS_KEY_ID.to_string(), "env_access_key".to_string()),
                (
                    AWS_SECRET_ACCESS_KEY.to_string(),
                    "env_secret_key".to_string(),
                ),
            ]),
        });

        // Create a static provider with different credentials
        let static_provider =
            crate::StaticCredentialProvider::new("static_access_key", "static_secret_key");

        // Create default provider and push_front the static provider
        let provider = DefaultCredentialProvider::new().push_front(static_provider);

        // The static provider should take precedence over environment variables
        let cred = provider
            .provide_credential(&ctx)
            .await
            .expect("load must succeed")
            .expect("credential must exist");

        assert_eq!("static_access_key", cred.access_key_id);
        assert_eq!("static_secret_key", cred.secret_access_key);
    }

    #[tokio::test]
    async fn test_default_credential_provider_no_profile_removes_slot() {
        let _ = env_logger::builder().is_test(true).try_init();

        let ctx = Context::new()
            .with_file_read(TokioFileRead)
            .with_http_send(ReqwestHttpSend::default())
            .with_env(OsEnv);
        let ctx = ctx.with_env(StaticEnv {
            home_dir: None,
            envs: HashMap::from_iter([
                (
                    AWS_CONFIG_FILE.to_string(),
                    format!(
                        "{}/testdata/default_config",
                        env::current_dir()
                            .expect("current_dir must exist")
                            .to_string_lossy()
                    ),
                ),
                (
                    AWS_SHARED_CREDENTIALS_FILE.to_string(),
                    format!(
                        "{}/testdata/not_exist",
                        env::current_dir()
                            .expect("current_dir must exist")
                            .to_string_lossy()
                    ),
                ),
            ]),
        });

        let builder = DefaultCredentialProvider::builder()
            .no_profile()
            .no_imds()
            .no_ecs()
            .no_web_identity();
        #[cfg(not(target_arch = "wasm32"))]
        let builder = builder.no_sso().no_process();
        #[cfg(target_arch = "wasm32")]
        let builder = builder;

        let provider = builder.build();

        let cred = provider
            .provide_credential(&ctx)
            .await
            .expect("load must succeed");
        assert!(cred.is_none());
    }

    #[tokio::test]
    async fn test_default_credential_provider_custom_profile_slot() {
        let _ = env_logger::builder().is_test(true).try_init();

        let ctx = Context::new()
            .with_file_read(TokioFileRead)
            .with_http_send(ReqwestHttpSend::default())
            .with_env(OsEnv);
        let ctx = ctx.with_env(StaticEnv {
            home_dir: None,
            envs: HashMap::new(),
        });

        // Build a custom chain with Profile provider using a custom config file
        let custom_config = format!(
            "{}/testdata/default_config",
            env::current_dir()
                .expect("current_dir must exist")
                .to_string_lossy()
        );

        let provider = DefaultCredentialProvider::builder()
            .profile(ProfileCredentialProvider::new().with_config_file(custom_config))
            .build();

        let cred = provider
            .provide_credential(&ctx)
            .await
            .expect("load must succeed");
        let cred = cred.expect("credential should exist");
        assert_eq!("config_access_key_id", cred.access_key_id);
        assert_eq!("config_secret_access_key", cred.secret_access_key);
    }

    #[cfg(not(target_arch = "wasm32"))]
    #[tokio::test]
    async fn test_default_credential_provider_custom_process_slot() {
        let _ = env_logger::builder().is_test(true).try_init();

        let ctx = Context::new()
            .with_file_read(TokioFileRead)
            .with_http_send(ReqwestHttpSend::default())
            .with_command_execute(TokioCommandExecute)
            .with_env(OsEnv);
        let ctx = ctx.with_env(StaticEnv {
            home_dir: None,
            envs: HashMap::new(),
        });

        let helper = format!(
            "{}/tests/mocks/credential_process_helper.py",
            env::current_dir()
                .expect("current_dir must exist")
                .to_string_lossy()
        );

        let provider = DefaultCredentialProvider::builder()
            .no_env()
            .no_profile()
            .no_sso()
            .no_web_identity()
            .no_ecs()
            .no_imds()
            .process(ProcessCredentialProvider::new().with_command(format!("python3 {helper}")))
            .build();

        let cred = provider
            .provide_credential(&ctx)
            .await
            .expect("load must succeed")
            .expect("credential should exist");
        assert_eq!("ASIAPROCESSEXAMPLE", cred.access_key_id);
        assert_eq!("process/secret/key/EXAMPLE", cred.secret_access_key);
    }

    #[cfg(not(target_arch = "wasm32"))]
    #[tokio::test]
    async fn test_default_credential_provider_no_process_removes_slot() {
        let _ = env_logger::builder().is_test(true).try_init();

        let ctx = Context::new()
            .with_file_read(TokioFileRead)
            .with_http_send(ReqwestHttpSend::default())
            .with_command_execute(TokioCommandExecute)
            .with_env(OsEnv);
        let ctx = ctx.with_env(StaticEnv {
            home_dir: None,
            envs: HashMap::new(),
        });

        let helper = format!(
            "{}/tests/mocks/credential_process_helper.py",
            env::current_dir()
                .expect("current_dir must exist")
                .to_string_lossy()
        );

        let provider = DefaultCredentialProvider::builder()
            .no_env()
            .no_profile()
            .no_sso()
            .no_web_identity()
            .no_ecs()
            .no_imds()
            .process(ProcessCredentialProvider::new().with_command(format!("python3 {helper}")))
            .no_process()
            .build();

        let cred = provider
            .provide_credential(&ctx)
            .await
            .expect("load must succeed");
        assert!(cred.is_none());
    }

    /// AWS_SHARED_CREDENTIALS_FILE should be taken first.
    #[tokio::test]
    async fn test_credential_profile_loader_from_both() {
        let _ = env_logger::builder().is_test(true).try_init();

        let ctx = Context::new()
            .with_file_read(TokioFileRead)
            .with_http_send(ReqwestHttpSend::default())
            .with_env(OsEnv);
        let ctx = ctx.with_env(StaticEnv {
            home_dir: None,
            envs: HashMap::from_iter([
                (
                    AWS_CONFIG_FILE.to_string(),
                    format!(
                        "{}/testdata/default_config",
                        env::current_dir()
                            .expect("current_dir must exist")
                            .to_string_lossy()
                    ),
                ),
                (
                    AWS_SHARED_CREDENTIALS_FILE.to_string(),
                    format!(
                        "{}/testdata/default_credential",
                        env::current_dir()
                            .expect("current_dir must exist")
                            .to_string_lossy()
                    ),
                ),
            ]),
        });

        let l = DefaultCredentialProvider::new();
        let x = l
            .provide_credential(&ctx)
            .await
            .expect("load must success")
            .unwrap();
        assert_eq!("shared_access_key_id", x.access_key_id);
        assert_eq!("shared_secret_access_key", x.secret_access_key);
    }
}
