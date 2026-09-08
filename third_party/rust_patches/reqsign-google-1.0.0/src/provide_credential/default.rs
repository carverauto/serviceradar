use log::debug;

use reqsign_core::{Context, ProvideCredential, Result};

use crate::constants::{DEFAULT_SCOPE, GOOGLE_APPLICATION_CREDENTIALS, GOOGLE_SCOPE};
use crate::credential::{Credential, CredentialFile};

use super::{
    authorized_user::AuthorizedUserCredentialProvider,
    external_account::ExternalAccountCredentialProvider,
    impersonated_service_account::ImpersonatedServiceAccountCredentialProvider,
    vm_metadata::VmMetadataCredentialProvider,
};

/// DefaultCredentialProvider tries to load credentials from multiple sources in order.
///
/// It follows the Google Application Default Credentials (ADC) strategy:
/// 1. GOOGLE_APPLICATION_CREDENTIALS environment variable
/// 2. gcloud credential file (~/.config/gcloud/application_default_credentials.json)
/// 3. Metadata server (for GCE/Cloud Functions/App Engine)
///
/// The provider automatically handles all credential types including:
/// - Service Account
/// - External Account (Workload Identity)
/// - Impersonated Service Account
/// - Authorized User (OAuth2)
#[derive(Debug, Clone, Default)]
pub struct DefaultCredentialProvider {
    scope: Option<String>,
}

impl DefaultCredentialProvider {
    /// Create a new DefaultCredentialProvider.
    pub fn new() -> Self {
        Self { scope: None }
    }

    /// Set the OAuth2 scope.
    pub fn with_scope(mut self, scope: impl Into<String>) -> Self {
        self.scope = Some(scope.into());
        self
    }

    /// Try to load credentials from GOOGLE_APPLICATION_CREDENTIALS environment variable.
    async fn try_env_credentials(&self, ctx: &Context) -> Result<Option<Credential>> {
        let Some(path) = ctx.env_var(GOOGLE_APPLICATION_CREDENTIALS) else {
            return Ok(None);
        };

        debug!("trying to load credential from env GOOGLE_APPLICATION_CREDENTIALS: {path}");
        self.load_credential_from_path(ctx, &path).await
    }

    /// Try to load credentials from gcloud default location.
    async fn try_well_known_location(&self, ctx: &Context) -> Result<Option<Credential>> {
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

        match self.load_credential_from_path(ctx, &path).await {
            Ok(cred) => Ok(cred),
            Err(_) => Ok(None), // Ignore errors for well-known location
        }
    }

    /// Try to load credentials from metadata server.
    async fn try_metadata_server(&self, ctx: &Context) -> Result<Option<Credential>> {
        debug!("trying to load credential from metadata server");

        let provider = match &self.scope {
            Some(scope) => VmMetadataCredentialProvider::new().with_scope(scope),
            None => VmMetadataCredentialProvider::new(),
        };

        provider.provide_credential(ctx).await
    }

    /// Load credential from a file path and handle all credential types.
    async fn load_credential_from_path(
        &self,
        ctx: &Context,
        path: &str,
    ) -> Result<Option<Credential>> {
        let content = ctx.file_read(path).await.map_err(|err| {
            debug!("failed to read credential file {path}: {err:?}");
            err
        })?;

        let cred_file = CredentialFile::from_slice(&content).map_err(|err| {
            debug!("failed to parse credential file {path}: {err:?}");
            err
        })?;

        // Get scope from instance, environment, or use default
        let scope = self
            .scope
            .clone()
            .or_else(|| ctx.env_var(GOOGLE_SCOPE))
            .unwrap_or_else(|| DEFAULT_SCOPE.to_string());

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

#[async_trait::async_trait]
impl ProvideCredential for DefaultCredentialProvider {
    type Credential = Credential;

    async fn provide_credential(&self, ctx: &Context) -> Result<Option<Self::Credential>> {
        // 1. Try environment variable
        if let Some(cred) = self.try_env_credentials(ctx).await? {
            return Ok(Some(cred));
        }

        // 2. Try well-known location
        if let Some(cred) = self.try_well_known_location(ctx).await? {
            return Ok(Some(cred));
        }

        // 3. Try metadata server
        if let Some(cred) = self.try_metadata_server(ctx).await? {
            return Ok(Some(cred));
        }

        debug!("no valid credential source found");
        Ok(None)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use reqsign_core::{Context, StaticEnv};
    use std::collections::HashMap;
    use std::env;

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
    async fn test_default_provider_with_scope() {
        let provider = DefaultCredentialProvider::new()
            .with_scope("https://www.googleapis.com/auth/devstorage.read_only");

        // Even without valid credentials, this should not panic
        let ctx = Context::new()
            .with_file_read(reqsign_file_read_tokio::TokioFileRead)
            .with_http_send(reqsign_http_send_reqwest::ReqwestHttpSend::default());
        let _ = provider.provide_credential(&ctx).await;
    }
}
