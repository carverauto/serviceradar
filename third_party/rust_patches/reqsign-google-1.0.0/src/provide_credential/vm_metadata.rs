use log::debug;
use serde::Deserialize;

use reqsign_core::{time::now, Context, ProvideCredential, Result};

use crate::credential::{Credential, Token};

/// VM metadata token response.
#[derive(Deserialize)]
struct VmMetadataTokenResponse {
    access_token: String,
    expires_in: u64,
}

/// VmMetadataCredentialProvider loads tokens from Google Compute Engine VM metadata service.
#[derive(Debug, Clone, Default)]
pub struct VmMetadataCredentialProvider {
    scope: Option<String>,
}

impl VmMetadataCredentialProvider {
    /// Create a new VmMetadataCredentialProvider.
    pub fn new() -> Self {
        Self { scope: None }
    }

    /// Set the OAuth2 scope.
    pub fn with_scope(mut self, scope: impl Into<String>) -> Self {
        self.scope = Some(scope.into());
        self
    }
}

#[async_trait::async_trait]
impl ProvideCredential for VmMetadataCredentialProvider {
    type Credential = Credential;

    async fn provide_credential(&self, ctx: &Context) -> Result<Option<Self::Credential>> {
        // Get scope from instance, environment, or use default
        let scope = self
            .scope
            .clone()
            .or_else(|| ctx.env_var(crate::constants::GOOGLE_SCOPE))
            .unwrap_or_else(|| crate::constants::DEFAULT_SCOPE.to_string());

        // Use "default" service account if not specified
        let service_account = "default";

        debug!(
            "loading token from VM metadata service for account: {}",
            service_account
        );

        // Allow overriding metadata host for testing
        let metadata_host = ctx
            .env_var("GCE_METADATA_HOST")
            .unwrap_or_else(|| "metadata.google.internal".to_string());

        let url = format!(
            "http://{metadata_host}/computeMetadata/v1/instance/service-accounts/{service_account}/token?scopes={scope}"
        );

        let req = http::Request::builder()
            .method(http::Method::GET)
            .uri(&url)
            .header("Metadata-Flavor", "Google")
            .body(Vec::<u8>::new().into())
            .map_err(|e| {
                reqsign_core::Error::unexpected("failed to build HTTP request").with_source(e)
            })?;

        let resp = ctx.http_send(req).await?;

        if resp.status() != http::StatusCode::OK {
            // VM metadata service might not be available (e.g., not running on GCE)
            debug!("VM metadata service not available or returned error");
            return Ok(None);
        }

        let token_resp: VmMetadataTokenResponse =
            serde_json::from_slice(resp.body()).map_err(|e| {
                reqsign_core::Error::unexpected("failed to parse VM metadata response")
                    .with_source(e)
            })?;

        let expires_at = now()
            + chrono::TimeDelta::try_seconds(token_resp.expires_in as i64).expect("in bounds");

        let token = Token {
            access_token: token_resp.access_token,
            expires_at: Some(expires_at),
        };

        Ok(Some(Credential::with_token(token)))
    }
}
