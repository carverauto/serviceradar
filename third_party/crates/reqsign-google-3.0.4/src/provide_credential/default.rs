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

use log::debug;

use reqsign_core::{Context, ProvideCredential, ProvideCredentialChain, Result};

use crate::constants::GOOGLE_APPLICATION_CREDENTIALS;
use crate::credential::Credential;

use super::{parse::parse_credential_bytes, vm_metadata::VmMetadataCredentialProvider};

/// Default credential provider for Google Cloud Storage (GCS).
///
/// Resolution order follows ADC (Application Default Credentials):
/// 1. Env var `GOOGLE_APPLICATION_CREDENTIALS`
/// 2. Well-known location (`~/.config/gcloud/application_default_credentials.json`)
/// 3. VM metadata service (GCE / Cloud Functions / App Engine)
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
    /// Create a builder to configure the default ADC chain for GCS.
    pub fn builder() -> DefaultCredentialProviderBuilder {
        DefaultCredentialProviderBuilder::default()
    }

    /// Create a new DefaultCredentialProvider with the default chain:
    /// env ADC -> well-known ADC -> VM metadata
    pub fn new() -> Self {
        Self::builder().build()
    }

    /// Create with a custom credential chain.
    pub fn with_chain(chain: ProvideCredentialChain<Credential>) -> Self {
        Self { chain }
    }

    /// Add a credential provider to the front of the default chain.
    pub fn push_front(
        mut self,
        provider: impl ProvideCredential<Credential = Credential> + 'static,
    ) -> Self {
        self.chain = self.chain.push_front(provider);
        self
    }
}
impl ProvideCredential for DefaultCredentialProvider {
    type Credential = Credential;

    async fn provide_credential(&self, ctx: &Context) -> Result<Option<Self::Credential>> {
        self.chain.provide_credential(ctx).await
    }
}

#[derive(Default, Clone, Debug)]
pub struct EnvCredentialProvider {
    scope: Option<String>,
}

impl EnvCredentialProvider {
    /// Create a new env ADC credential provider.
    pub fn new() -> Self {
        Self::default()
    }

    /// Set the OAuth2 scope to request when exchanging ADC credentials.
    pub fn with_scope(mut self, scope: impl Into<String>) -> Self {
        self.scope = Some(scope.into());
        self
    }
}
impl ProvideCredential for EnvCredentialProvider {
    type Credential = Credential;

    async fn provide_credential(&self, ctx: &Context) -> Result<Option<Self::Credential>> {
        let path = match ctx.env_var(GOOGLE_APPLICATION_CREDENTIALS) {
            Some(path) if !path.is_empty() => path,
            _ => return Ok(None),
        };

        debug!("trying to load credential from env GOOGLE_APPLICATION_CREDENTIALS: {path}");

        let content = ctx.file_read(&path).await?;
        parse_credential_bytes(ctx, &content, self.scope.clone()).await
    }
}

#[derive(Default, Clone, Debug)]
pub struct WellKnownCredentialProvider {
    scope: Option<String>,
}

impl WellKnownCredentialProvider {
    /// Create a new well-known ADC credential provider.
    pub fn new() -> Self {
        Self::default()
    }

    /// Set the OAuth2 scope to request when exchanging ADC credentials.
    pub fn with_scope(mut self, scope: impl Into<String>) -> Self {
        self.scope = Some(scope.into());
        self
    }
}
impl ProvideCredential for WellKnownCredentialProvider {
    type Credential = Credential;

    async fn provide_credential(&self, ctx: &Context) -> Result<Option<Self::Credential>> {
        let config_dir = if let Some(v) = ctx.env_var("APPDATA") {
            v
        } else if let Some(v) = ctx.env_var("XDG_CONFIG_HOME") {
            v
        } else if let Some(v) = ctx.env_var("HOME") {
            format!("{v}/.config")
        } else {
            return Ok(None);
        };

        let path = format!("{config_dir}/gcloud/application_default_credentials.json");
        debug!("trying to load credential from well-known location: {path}");

        let content = match ctx.file_read(&path).await {
            Ok(v) => v,
            Err(_) => return Ok(None),
        };

        match parse_credential_bytes(ctx, &content, self.scope.clone()).await {
            Ok(v) => Ok(v),
            Err(_) => Ok(None),
        }
    }
}

/// Builder for `DefaultCredentialProvider`.
pub struct DefaultCredentialProviderBuilder {
    env: Option<EnvCredentialProvider>,
    well_known: Option<WellKnownCredentialProvider>,
    vm_metadata: Option<VmMetadataCredentialProvider>,
}

impl Default for DefaultCredentialProviderBuilder {
    fn default() -> Self {
        Self {
            env: Some(EnvCredentialProvider::new()),
            well_known: Some(WellKnownCredentialProvider::new()),
            vm_metadata: Some(VmMetadataCredentialProvider::new()),
        }
    }
}

impl DefaultCredentialProviderBuilder {
    /// Create a new builder with default state.
    pub fn new() -> Self {
        Self::default()
    }

    /// Set the env ADC provider slot.
    pub fn env(mut self, provider: EnvCredentialProvider) -> Self {
        self.env = Some(provider);
        self
    }

    /// Remove the env ADC provider slot.
    pub fn no_env(mut self) -> Self {
        self.env = None;
        self
    }

    /// Set the well-known ADC provider slot.
    pub fn well_known(mut self, provider: WellKnownCredentialProvider) -> Self {
        self.well_known = Some(provider);
        self
    }

    /// Remove the well-known ADC provider slot.
    pub fn no_well_known(mut self) -> Self {
        self.well_known = None;
        self
    }

    /// Set the VM metadata provider slot.
    pub fn vm_metadata(mut self, provider: VmMetadataCredentialProvider) -> Self {
        self.vm_metadata = Some(provider);
        self
    }

    /// Remove the VM metadata provider slot.
    pub fn no_vm_metadata(mut self) -> Self {
        self.vm_metadata = None;
        self
    }

    /// Build the `DefaultCredentialProvider` with the configured options.
    pub fn build(self) -> DefaultCredentialProvider {
        let mut chain = ProvideCredentialChain::new();

        if let Some(p) = self.env {
            chain = chain.push(p);
        }

        if let Some(p) = self.well_known {
            chain = chain.push(p);
        }

        if let Some(p) = self.vm_metadata {
            chain = chain.push(p);
        }

        DefaultCredentialProvider::with_chain(chain)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use bytes::Bytes;
    use reqsign_core::{Context, FileRead, HttpSend, StaticEnv};
    use std::collections::HashMap;
    use std::env;
    use std::sync::{Arc, Mutex};

    #[derive(Clone, Debug, Default)]
    struct MockHttpSend {
        uris: Arc<Mutex<Vec<String>>>,
    }

    impl HttpSend for MockHttpSend {
        async fn http_send(&self, req: http::Request<Bytes>) -> Result<http::Response<Bytes>> {
            self.uris.lock().unwrap().push(req.uri().to_string());

            Ok(http::Response::builder()
                .status(http::StatusCode::OK)
                .body(
                    br#"{"access_token":"test-access-token","expires_in":3600}"#
                        .as_slice()
                        .into(),
                )
                .expect("response must build"))
        }
    }

    #[derive(Clone, Debug, Default)]
    struct MockFileRead {
        files: Arc<HashMap<String, Vec<u8>>>,
        paths: Arc<Mutex<Vec<String>>>,
    }

    impl MockFileRead {
        fn new(files: HashMap<String, Vec<u8>>) -> Self {
            Self {
                files: Arc::new(files),
                paths: Arc::new(Mutex::new(Vec::new())),
            }
        }
    }

    impl FileRead for MockFileRead {
        async fn file_read(&self, path: &str) -> Result<Vec<u8>> {
            self.paths.lock().unwrap().push(path.to_string());
            self.files.get(path).cloned().ok_or_else(|| {
                reqsign_core::Error::config_invalid(format!("file not found: {path}"))
            })
        }
    }

    #[tokio::test]
    async fn test_default_provider_env() {
        let envs = HashMap::from([(
            GOOGLE_APPLICATION_CREDENTIALS.to_string(),
            format!(
                "{}/testdata/test_credential.json",
                env::current_dir()
                    .expect("current_dir must exist")
                    .to_string_lossy()
            ),
        )]);

        let ctx = Context::new()
            .with_file_read(reqsign_file_read_tokio::TokioFileRead)
            .with_http_send(reqsign_http_send_reqwest::ReqwestHttpSend::default())
            .with_env(StaticEnv {
                home_dir: None,
                envs,
            });

        let provider = DefaultCredentialProvider::new();
        let cred = provider
            .provide_credential(&ctx)
            .await
            .expect("load must succeed");
        assert!(cred.is_some());

        let cred = cred.unwrap();
        assert!(cred.has_service_account());
        let sa = cred.service_account.as_ref().unwrap();
        assert_eq!("test-234@test.iam.gserviceaccount.com", &sa.client_email);
    }

    #[tokio::test]
    async fn test_default_provider_builder_default_chain() {
        let provider = DefaultCredentialProvider::builder().build();

        // Even without valid credentials, this should not panic
        let ctx = Context::new()
            .with_file_read(reqsign_file_read_tokio::TokioFileRead)
            .with_http_send(reqsign_http_send_reqwest::ReqwestHttpSend::default());
        let _ = provider.provide_credential(&ctx).await;
    }

    #[tokio::test]
    async fn test_default_provider_no_env_removes_provider() -> Result<()> {
        let env_path = "/tmp/google-env-adc.json";
        let file_read = MockFileRead::new(HashMap::from([(
            env_path.to_string(),
            include_bytes!(concat!(
                env!("CARGO_MANIFEST_DIR"),
                "/testdata/test_credential.json"
            ))
            .to_vec(),
        )]));
        let ctx = Context::new()
            .with_file_read(file_read.clone())
            .with_env(StaticEnv {
                home_dir: None,
                envs: HashMap::from([(
                    GOOGLE_APPLICATION_CREDENTIALS.to_string(),
                    env_path.to_string(),
                )]),
            });

        let provider = DefaultCredentialProvider::builder()
            .no_env()
            .no_well_known()
            .no_vm_metadata()
            .build();

        assert!(provider.provide_credential(&ctx).await?.is_none());
        assert!(file_read.paths.lock().unwrap().is_empty());

        Ok(())
    }

    #[tokio::test]
    async fn test_default_provider_no_well_known_removes_provider() -> Result<()> {
        let home = "/tmp/google-home";
        let well_known_path = format!("{home}/.config/gcloud/application_default_credentials.json");
        let file_read = MockFileRead::new(HashMap::from([(
            well_known_path.clone(),
            include_bytes!(concat!(
                env!("CARGO_MANIFEST_DIR"),
                "/testdata/test_credential.json"
            ))
            .to_vec(),
        )]));
        let ctx = Context::new()
            .with_file_read(file_read.clone())
            .with_env(StaticEnv {
                home_dir: None,
                envs: HashMap::from([("HOME".to_string(), home.to_string())]),
            });

        let provider = DefaultCredentialProvider::builder()
            .no_env()
            .no_well_known()
            .no_vm_metadata()
            .build();

        assert!(provider.provide_credential(&ctx).await?.is_none());
        assert!(file_read.paths.lock().unwrap().is_empty());

        Ok(())
    }

    #[tokio::test]
    async fn test_default_provider_no_vm_metadata_removes_provider() -> Result<()> {
        let http = MockHttpSend::default();
        let ctx = Context::new().with_http_send(http.clone());

        let provider = DefaultCredentialProvider::builder()
            .no_env()
            .no_well_known()
            .no_vm_metadata()
            .build();

        assert!(provider.provide_credential(&ctx).await?.is_none());
        assert!(http.uris.lock().unwrap().is_empty());

        Ok(())
    }

    #[tokio::test]
    async fn test_default_provider_custom_vm_metadata_service_account() -> Result<()> {
        let http = MockHttpSend::default();
        let ctx = Context::new().with_http_send(http.clone());

        let provider = DefaultCredentialProvider::builder()
            .no_env()
            .no_well_known()
            .vm_metadata(
                VmMetadataCredentialProvider::new()
                    .with_endpoint("127.0.0.1:8080")
                    .with_service_account("custom@test-project.iam.gserviceaccount.com"),
            )
            .build();

        let cred = provider
            .provide_credential(&ctx)
            .await?
            .expect("credential must exist");

        assert!(cred.has_token());
        assert_eq!(
            http.uris.lock().unwrap().as_slice(),
            &["http://127.0.0.1:8080/computeMetadata/v1/instance/service-accounts/custom@test-project.iam.gserviceaccount.com/token?scopes=https://www.googleapis.com/auth/cloud-platform".to_string()]
        );

        Ok(())
    }
}
