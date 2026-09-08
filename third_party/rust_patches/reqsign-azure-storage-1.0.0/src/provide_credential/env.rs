use async_trait::async_trait;
use reqsign_core::{Context, ProvideCredential};

use crate::credential::Credential;

#[derive(Clone, Debug, Default)]
pub struct EnvCredentialProvider {}

impl EnvCredentialProvider {
    pub fn new() -> Self {
        Self {}
    }
}

#[async_trait]
impl ProvideCredential for EnvCredentialProvider {
    type Credential = Credential;

    async fn provide_credential(
        &self,
        ctx: &Context,
    ) -> Result<Option<Self::Credential>, reqsign_core::Error> {
        let envs = ctx.env_vars();

        // Try to get account name from multiple possible env vars
        let account_name = envs
            .get("AZBLOB_ACCOUNT_NAME")
            .or_else(|| envs.get("AZURE_STORAGE_ACCOUNT_NAME"))
            .cloned();

        // Check for account key
        if let Some(account_key) = envs
            .get("AZBLOB_ACCOUNT_KEY")
            .or_else(|| envs.get("AZURE_STORAGE_ACCOUNT_KEY"))
        {
            if let Some(account_name) = account_name {
                return Ok(Some(Credential::with_shared_key(
                    &account_name,
                    account_key,
                )));
            }
        }

        // Check for SAS token
        if let Some(sas_token) = envs.get("AZURE_STORAGE_SAS_TOKEN") {
            return Ok(Some(Credential::with_sas_token(sas_token)));
        }

        // Check for bearer token
        if let Some(bearer_token) = envs.get("AZURE_STORAGE_BEARER_TOKEN") {
            return Ok(Some(Credential::with_bearer_token(bearer_token, None)));
        }

        Ok(None)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use reqsign_core::{Context, StaticEnv};
    use reqsign_file_read_tokio::TokioFileRead;
    use reqsign_http_send_reqwest::ReqwestHttpSend;
    use std::collections::HashMap;

    #[tokio::test]
    async fn test_env_credential_provider_account_key() {
        let envs = HashMap::from([
            ("AZBLOB_ACCOUNT_NAME".to_string(), "myaccount".to_string()),
            ("AZBLOB_ACCOUNT_KEY".to_string(), "mykey".to_string()),
        ]);

        let ctx = Context::new()
            .with_file_read(TokioFileRead)
            .with_http_send(ReqwestHttpSend::default())
            .with_env(StaticEnv {
                home_dir: None,
                envs,
            });

        let provider = EnvCredentialProvider::new();
        let cred = provider.provide_credential(&ctx).await.unwrap();

        match cred {
            Some(Credential::SharedKey {
                account_name,
                account_key,
            }) => {
                assert_eq!(account_name, "myaccount");
                assert_eq!(account_key, "mykey");
            }
            _ => panic!("Expected AccountKey credential"),
        }
    }

    #[tokio::test]
    async fn test_env_credential_provider_sas_token() {
        let envs = HashMap::from([(
            "AZURE_STORAGE_SAS_TOKEN".to_string(),
            "mysastoken".to_string(),
        )]);

        let ctx = Context::new()
            .with_file_read(TokioFileRead)
            .with_http_send(ReqwestHttpSend::default())
            .with_env(StaticEnv {
                home_dir: None,
                envs,
            });

        let provider = EnvCredentialProvider::new();
        let cred = provider.provide_credential(&ctx).await.unwrap();

        match cred {
            Some(Credential::SasToken { token }) => {
                assert_eq!(token, "mysastoken");
            }
            _ => panic!("Expected SasToken credential"),
        }
    }

    #[tokio::test]
    async fn test_env_credential_provider_none() {
        let ctx = Context::new()
            .with_file_read(TokioFileRead)
            .with_http_send(ReqwestHttpSend::default());

        let provider = EnvCredentialProvider::new();
        let cred = provider.provide_credential(&ctx).await.unwrap();

        assert!(cred.is_none());
    }
}
