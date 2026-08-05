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
use crate::provide_credential::{AzureCliCredentialProvider, ClientCertificateCredentialProvider};
use crate::provide_credential::{
    AzurePipelinesCredentialProvider, ClientSecretCredentialProvider, EnvCredentialProvider,
    ImdsCredentialProvider, WorkloadIdentityCredentialProvider,
};
use reqsign_core::{Context, ProvideCredential, ProvideCredentialChain, Result};

/// Default loader that tries multiple credential sources in order.
///
/// The default loader attempts to load credentials from the following sources in order:
/// 1. Environment variables (account key, SAS token)
/// 2. Azure CLI (local development)
/// 3. Client certificate (service principal with certificate)
/// 4. Client secret (service principal)
/// 5. Azure Pipelines (workload identity)
/// 6. Workload identity (federated credentials)
/// 7. IMDS (Azure VM managed identity)
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

    /// Create a new default loader.
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
    /// use reqsign_azure_storage::{DefaultCredentialProvider, StaticCredentialProvider};
    ///
    /// let provider = DefaultCredentialProvider::new()
    ///     .push_front(StaticCredentialProvider::new_shared_key("account_name", "account_key"));
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
/// Each slot is represented by `Option<T>`:
/// - `Some(provider)` keeps the provider in the default chain.
/// - `None` removes the provider from the chain.
///
/// ```no_run
/// use reqsign_azure_storage::{
///     ClientSecretCredentialProvider, DefaultCredentialProvider,
/// };
///
/// let provider = DefaultCredentialProvider::builder()
///     .no_env()
///     .client_secret(ClientSecretCredentialProvider::new().with_tenant_id("tenant-id"))
///     .no_imds()
///     .build();
/// ```
pub struct DefaultCredentialProviderBuilder {
    env: Option<EnvCredentialProvider>,
    #[cfg(not(target_arch = "wasm32"))]
    azure_cli: Option<AzureCliCredentialProvider>,
    #[cfg(not(target_arch = "wasm32"))]
    client_certificate: Option<ClientCertificateCredentialProvider>,
    client_secret: Option<ClientSecretCredentialProvider>,
    azure_pipelines: Option<AzurePipelinesCredentialProvider>,
    workload_identity: Option<WorkloadIdentityCredentialProvider>,
    imds: Option<ImdsCredentialProvider>,
}

impl Default for DefaultCredentialProviderBuilder {
    fn default() -> Self {
        Self {
            env: Some(EnvCredentialProvider::new()),
            #[cfg(not(target_arch = "wasm32"))]
            azure_cli: Some(AzureCliCredentialProvider::new()),
            #[cfg(not(target_arch = "wasm32"))]
            client_certificate: Some(ClientCertificateCredentialProvider::new()),
            client_secret: Some(ClientSecretCredentialProvider::new()),
            azure_pipelines: Some(AzurePipelinesCredentialProvider::new()),
            workload_identity: Some(WorkloadIdentityCredentialProvider::new()),
            imds: Some(ImdsCredentialProvider::new()),
        }
    }
}

impl DefaultCredentialProviderBuilder {
    pub fn new() -> Self {
        Self::default()
    }

    /// Set the environment credential provider slot.
    pub fn env(mut self, provider: EnvCredentialProvider) -> Self {
        self.env = Some(provider);
        self
    }

    /// Remove the environment credential provider slot.
    pub fn no_env(mut self) -> Self {
        self.env = None;
        self
    }

    /// Set the Azure CLI credential provider slot.
    #[cfg(not(target_arch = "wasm32"))]
    pub fn azure_cli(mut self, provider: AzureCliCredentialProvider) -> Self {
        self.azure_cli = Some(provider);
        self
    }

    /// Remove the Azure CLI credential provider slot.
    #[cfg(not(target_arch = "wasm32"))]
    pub fn no_azure_cli(mut self) -> Self {
        self.azure_cli = None;
        self
    }

    /// Set the client certificate credential provider slot.
    #[cfg(not(target_arch = "wasm32"))]
    pub fn client_certificate(mut self, provider: ClientCertificateCredentialProvider) -> Self {
        self.client_certificate = Some(provider);
        self
    }

    /// Remove the client certificate credential provider slot.
    #[cfg(not(target_arch = "wasm32"))]
    pub fn no_client_certificate(mut self) -> Self {
        self.client_certificate = None;
        self
    }

    /// Set the client secret credential provider slot.
    pub fn client_secret(mut self, provider: ClientSecretCredentialProvider) -> Self {
        self.client_secret = Some(provider);
        self
    }

    /// Remove the client secret credential provider slot.
    pub fn no_client_secret(mut self) -> Self {
        self.client_secret = None;
        self
    }

    /// Set the Azure Pipelines credential provider slot.
    pub fn azure_pipelines(mut self, provider: AzurePipelinesCredentialProvider) -> Self {
        self.azure_pipelines = Some(provider);
        self
    }

    /// Remove the Azure Pipelines credential provider slot.
    pub fn no_azure_pipelines(mut self) -> Self {
        self.azure_pipelines = None;
        self
    }

    /// Set the workload identity credential provider slot.
    pub fn workload_identity(mut self, provider: WorkloadIdentityCredentialProvider) -> Self {
        self.workload_identity = Some(provider);
        self
    }

    /// Remove the workload identity credential provider slot.
    pub fn no_workload_identity(mut self) -> Self {
        self.workload_identity = None;
        self
    }

    /// Set the Azure IMDS credential provider slot.
    pub fn imds(mut self, provider: ImdsCredentialProvider) -> Self {
        self.imds = Some(provider);
        self
    }

    /// Remove the Azure IMDS credential provider slot.
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

        #[cfg(not(target_arch = "wasm32"))]
        {
            if let Some(p) = self.azure_cli {
                chain = chain.push(p);
            }

            if let Some(p) = self.client_certificate {
                chain = chain.push(p);
            }
        }

        if let Some(p) = self.client_secret {
            chain = chain.push(p);
        }

        if let Some(p) = self.azure_pipelines {
            chain = chain.push(p);
        }

        if let Some(p) = self.workload_identity {
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
    use reqsign_core::StaticEnv;
    use std::collections::HashMap;

    #[tokio::test]
    async fn test_config_loader_priority() {
        let env = StaticEnv {
            home_dir: None,
            envs: HashMap::from([
                (
                    "AZBLOB_ACCOUNT_NAME".to_string(),
                    "test_account".to_string(),
                ),
                ("AZBLOB_ACCOUNT_KEY".to_string(), "dGVzdF9rZXk=".to_string()),
            ]),
        };

        // Create a mock context - in real usage Context would be created with proper FileRead and HttpSend
        let ctx = reqsign_core::Context::new()
            .with_file_read(MockFileRead)
            .with_http_send(MockHttpSend)
            .with_env(env);

        let loader = DefaultCredentialProvider::new();

        let cred = loader.provide_credential(&ctx).await.unwrap().unwrap();
        match cred {
            crate::Credential::SharedKey {
                account_name,
                account_key,
            } => {
                assert_eq!(account_name, "test_account");
                assert_eq!(account_key, "dGVzdF9rZXk=");
            }
            _ => panic!("Expected SharedKey credential"),
        }
    }

    #[tokio::test]
    async fn test_sas_token_priority() {
        let env = StaticEnv {
            home_dir: None,
            envs: HashMap::from([(
                "AZURE_STORAGE_SAS_TOKEN".to_string(),
                "sv=2021-01-01&ss=b&srt=c&sp=rwdlaciytfx".to_string(),
            )]),
        };

        let ctx = reqsign_core::Context::new()
            .with_file_read(MockFileRead)
            .with_http_send(MockHttpSend)
            .with_env(env);

        let loader = DefaultCredentialProvider::new();

        let cred = loader.provide_credential(&ctx).await.unwrap().unwrap();
        match cred {
            crate::Credential::SasToken { token } => {
                assert_eq!(token, "sv=2021-01-01&ss=b&srt=c&sp=rwdlaciytfx");
            }
            _ => panic!("Expected SasToken credential"),
        }
    }

    // Mock implementations for testing
    #[derive(Debug)]
    struct MockFileRead;
    impl reqsign_core::FileRead for MockFileRead {
        async fn file_read(&self, _path: &str) -> Result<Vec<u8>> {
            Ok(Vec::new())
        }
    }

    #[derive(Debug)]
    struct MockHttpSend;
    impl reqsign_core::HttpSend for MockHttpSend {
        async fn http_send(
            &self,
            _req: http::Request<bytes::Bytes>,
        ) -> Result<http::Response<bytes::Bytes>> {
            Ok(http::Response::new(bytes::Bytes::new()))
        }
    }
}
