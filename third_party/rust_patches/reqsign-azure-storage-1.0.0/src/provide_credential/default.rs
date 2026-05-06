#[cfg(not(target_arch = "wasm32"))]
use crate::provide_credential::{AzureCliCredentialProvider, ClientCertificateCredentialProvider};
use crate::provide_credential::{
    AzurePipelinesCredentialProvider, ClientSecretCredentialProvider, EnvCredentialProvider,
    ImdsCredentialProvider, WorkloadIdentityCredentialProvider,
};
use crate::Credential;
use async_trait::async_trait;
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
#[derive(Debug, Default)]
pub struct DefaultCredentialProvider {
    chain: ProvideCredentialChain<Credential>,
}

impl DefaultCredentialProvider {
    /// Create a new default loader.
    pub fn new() -> Self {
        let mut chain = ProvideCredentialChain::new().push(EnvCredentialProvider::new());

        #[cfg(not(target_arch = "wasm32"))]
        {
            chain = chain
                .push(AzureCliCredentialProvider::new())
                .push(ClientCertificateCredentialProvider::new());
        }

        chain = chain
            .push(ClientSecretCredentialProvider::new())
            .push(AzurePipelinesCredentialProvider::new())
            .push(WorkloadIdentityCredentialProvider::new())
            .push(ImdsCredentialProvider::new());

        Self { chain }
    }
}

#[async_trait]
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

    #[async_trait]
    impl reqsign_core::FileRead for MockFileRead {
        async fn file_read(&self, _path: &str) -> Result<Vec<u8>> {
            Ok(Vec::new())
        }
    }

    #[derive(Debug)]
    struct MockHttpSend;

    #[async_trait]
    impl reqsign_core::HttpSend for MockHttpSend {
        async fn http_send(
            &self,
            _req: http::Request<bytes::Bytes>,
        ) -> Result<http::Response<bytes::Bytes>> {
            Ok(http::Response::new(bytes::Bytes::new()))
        }
    }
}
