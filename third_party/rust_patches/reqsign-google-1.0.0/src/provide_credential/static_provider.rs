use log::debug;

use reqsign_core::{hash::base64_decode, Context, ProvideCredential, Result};

use crate::credential::{Credential, CredentialFile};

use super::{
    authorized_user::AuthorizedUserCredentialProvider,
    external_account::ExternalAccountCredentialProvider,
    impersonated_service_account::ImpersonatedServiceAccountCredentialProvider,
};

/// StaticCredentialProvider loads credentials from a JSON string provided at construction time.
#[derive(Debug, Clone)]
pub struct StaticCredentialProvider {
    content: String,
    scope: Option<String>,
}

impl StaticCredentialProvider {
    /// Create a new StaticCredentialProvider from JSON content.
    pub fn new(content: impl Into<String>) -> Self {
        Self {
            content: content.into(),
            scope: None,
        }
    }

    /// Create a new StaticCredentialProvider from base64-encoded JSON content.
    pub fn from_base64(content: impl Into<String>) -> Result<Self> {
        let content = content.into();
        let decoded = base64_decode(&content).map_err(|e| {
            reqsign_core::Error::unexpected("failed to decode base64").with_source(e)
        })?;
        let json_content = String::from_utf8(decoded).map_err(|e| {
            reqsign_core::Error::unexpected("invalid UTF-8 in decoded content").with_source(e)
        })?;
        Ok(Self {
            content: json_content,
            scope: None,
        })
    }

    /// Set the OAuth2 scope.
    pub fn with_scope(mut self, scope: impl Into<String>) -> Self {
        self.scope = Some(scope.into());
        self
    }
}

#[async_trait::async_trait]
impl ProvideCredential for StaticCredentialProvider {
    type Credential = Credential;

    async fn provide_credential(&self, ctx: &Context) -> Result<Option<Self::Credential>> {
        debug!("loading credential from static content");

        let cred_file = CredentialFile::from_slice(self.content.as_bytes()).map_err(|err| {
            debug!("failed to parse credential from content: {err:?}");
            err
        })?;

        // Get scope from instance or environment
        let scope = self
            .scope
            .clone()
            .or_else(|| ctx.env_var(crate::constants::GOOGLE_SCOPE))
            .unwrap_or_else(|| crate::constants::DEFAULT_SCOPE.to_string());

        match cred_file {
            CredentialFile::ServiceAccount(sa) => {
                debug!("loaded service account credential");
                Ok(Some(Credential::with_service_account(sa)))
            }
            CredentialFile::ExternalAccount(ea) => {
                debug!("loaded external account credential, exchanging for token");
                let provider = ExternalAccountCredentialProvider::new(ea).with_scope(&scope);
                provider.provide_credential(ctx).await
            }
            CredentialFile::ImpersonatedServiceAccount(isa) => {
                debug!("loaded impersonated service account credential, exchanging for token");
                let provider =
                    ImpersonatedServiceAccountCredentialProvider::new(isa).with_scope(&scope);
                provider.provide_credential(ctx).await
            }
            CredentialFile::AuthorizedUser(au) => {
                debug!("loaded authorized user credential, exchanging for token");
                let provider = AuthorizedUserCredentialProvider::new(au);
                provider.provide_credential(ctx).await
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use reqsign_core::Context;

    #[tokio::test]
    async fn test_static_service_account() {
        let content = r#"{
            "type": "service_account",
            "private_key": "unit-test-key-material",
            "client_email": "test@example.iam.gserviceaccount.com"
        }"#;

        let provider = StaticCredentialProvider::new(content);
        let ctx = Context::new()
            .with_file_read(reqsign_file_read_tokio::TokioFileRead)
            .with_http_send(reqsign_http_send_reqwest::ReqwestHttpSend::default());

        let result = provider.provide_credential(&ctx).await;
        assert!(result.is_ok());

        let cred = result.unwrap();
        assert!(cred.is_some());

        let cred = cred.unwrap();
        assert!(cred.has_service_account());
    }

    #[tokio::test]
    async fn test_static_service_account_from_base64() {
        let content = r#"{
            "type": "service_account",
            "private_key": "unit-test-key-material",
            "client_email": "test@example.iam.gserviceaccount.com"
        }"#;

        // Base64 encode the content
        use reqsign_core::hash::base64_encode;
        let encoded = base64_encode(content.as_bytes());

        let provider =
            StaticCredentialProvider::from_base64(encoded).expect("should decode base64");
        let ctx = Context::new()
            .with_file_read(reqsign_file_read_tokio::TokioFileRead)
            .with_http_send(reqsign_http_send_reqwest::ReqwestHttpSend::default());

        let result = provider.provide_credential(&ctx).await;
        assert!(result.is_ok());

        let cred = result.unwrap();
        assert!(cred.is_some());

        let cred = cred.unwrap();
        assert!(cred.has_service_account());
    }
}
