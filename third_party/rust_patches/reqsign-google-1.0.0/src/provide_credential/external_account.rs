use std::time::Duration;

use http::header::{ACCEPT, CONTENT_TYPE};
use log::{debug, error};
use serde::{Deserialize, Serialize};

use reqsign_core::{time::now, Context, ProvideCredential, Result};

use crate::credential::{external_account, Credential, ExternalAccount, Token};

/// The maximum impersonated token lifetime allowed, 1 hour.
const MAX_LIFETIME: Duration = Duration::from_secs(3600);

/// STS token response.
#[derive(Deserialize)]
struct StsTokenResponse {
    access_token: String,
    expires_in: Option<u64>,
}

/// Impersonated token response.
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ImpersonatedTokenResponse {
    access_token: String,
    expire_time: String,
}

/// STS token exchange request.
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct StsTokenRequest {
    grant_type: &'static str,
    requested_token_type: &'static str,
    audience: String,
    scope: &'static str,
    subject_token: String,
    subject_token_type: String,
}

/// Impersonation request.
#[derive(Serialize)]
struct ImpersonationRequest {
    scope: Vec<String>,
    lifetime: String,
}

/// ExternalAccountCredentialProvider exchanges external account credentials for access tokens.
#[derive(Debug, Clone)]
pub struct ExternalAccountCredentialProvider {
    external_account: ExternalAccount,
    scope: Option<String>,
}

impl ExternalAccountCredentialProvider {
    /// Create a new ExternalAccountCredentialProvider.
    pub fn new(external_account: ExternalAccount) -> Self {
        Self {
            external_account,
            scope: None,
        }
    }

    /// Set the OAuth2 scope.
    pub fn with_scope(mut self, scope: impl Into<String>) -> Self {
        self.scope = Some(scope.into());
        self
    }

    async fn load_oidc_token(&self, ctx: &Context) -> Result<String> {
        match &self.external_account.credential_source {
            external_account::Source::File(source) => {
                self.load_file_sourced_token(ctx, source).await
            }
            external_account::Source::Url(source) => self.load_url_sourced_token(ctx, source).await,
        }
    }

    async fn load_file_sourced_token(
        &self,
        ctx: &Context,
        source: &external_account::FileSource,
    ) -> Result<String> {
        debug!("loading OIDC token from file: {}", source.file);
        let content = ctx.file_read(&source.file).await?;
        source.format.parse(&content)
    }

    async fn load_url_sourced_token(
        &self,
        ctx: &Context,
        source: &external_account::UrlSource,
    ) -> Result<String> {
        debug!("loading OIDC token from URL: {}", source.url);

        let mut req = http::Request::get(&source.url);

        // Add custom headers if any
        if let Some(headers) = &source.headers {
            for (key, value) in headers {
                req = req.header(key, value);
            }
        }

        let resp = ctx
            .http_send(req.body(Vec::<u8>::new().into()).map_err(|e| {
                reqsign_core::Error::unexpected("failed to build HTTP request").with_source(e)
            })?)
            .await?;

        if resp.status() != http::StatusCode::OK {
            error!("exchange token got unexpected response: {resp:?}");
            let body = String::from_utf8_lossy(resp.body());
            return Err(reqsign_core::Error::unexpected(format!(
                "exchange OIDC token failed: {body}"
            )));
        }

        source.format.parse(resp.body())
    }

    async fn exchange_sts_token(&self, ctx: &Context, oidc_token: &str) -> Result<Token> {
        debug!("exchanging OIDC token for STS access token");

        let request = StsTokenRequest {
            grant_type: "urn:ietf:params:oauth:grant-type:token-exchange",
            requested_token_type: "urn:ietf:params:oauth:token-type:access_token",
            audience: self.external_account.audience.clone(),
            scope: "https://www.googleapis.com/auth/cloud-platform",
            subject_token: oidc_token.to_string(),
            subject_token_type: self.external_account.subject_token_type.clone(),
        };

        let body = serde_json::to_vec(&request).map_err(|e| {
            reqsign_core::Error::unexpected("failed to serialize request").with_source(e)
        })?;

        let req = http::Request::builder()
            .method(http::Method::POST)
            .uri(&self.external_account.token_url)
            .header(ACCEPT, "application/json")
            .header(CONTENT_TYPE, "application/json")
            .body(body.into())
            .map_err(|e| {
                reqsign_core::Error::unexpected("failed to build HTTP request").with_source(e)
            })?;

        let resp = ctx.http_send(req).await?;

        if resp.status() != http::StatusCode::OK {
            error!("exchange token got unexpected response: {resp:?}");
            let body = String::from_utf8_lossy(resp.body());
            return Err(reqsign_core::Error::unexpected(format!(
                "exchange token failed: {body}"
            )));
        }

        let token_resp: StsTokenResponse = serde_json::from_slice(resp.body()).map_err(|e| {
            reqsign_core::Error::unexpected("failed to parse STS response").with_source(e)
        })?;

        let expires_at = token_resp.expires_in.map(|expires_in| {
            now() + chrono::TimeDelta::try_seconds(expires_in as i64).expect("in bounds")
        });

        Ok(Token {
            access_token: token_resp.access_token,
            expires_at,
        })
    }

    async fn impersonate_service_account(
        &self,
        ctx: &Context,
        access_token: &str,
    ) -> Result<Option<Token>> {
        let Some(url) = &self.external_account.service_account_impersonation_url else {
            return Ok(None);
        };

        debug!("impersonating service account");

        let scope = self
            .scope
            .clone()
            .or_else(|| ctx.env_var(crate::constants::GOOGLE_SCOPE))
            .unwrap_or_else(|| crate::constants::DEFAULT_SCOPE.to_string());

        let lifetime = self
            .external_account
            .service_account_impersonation
            .as_ref()
            .and_then(|s| s.token_lifetime_seconds)
            .unwrap_or(MAX_LIFETIME.as_secs() as usize);

        let request = ImpersonationRequest {
            scope: vec![scope.clone()],
            lifetime: format!("{lifetime}s"),
        };

        let body = serde_json::to_vec(&request).map_err(|e| {
            reqsign_core::Error::unexpected("failed to serialize request").with_source(e)
        })?;

        let req = http::Request::builder()
            .method(http::Method::POST)
            .uri(url)
            .header(ACCEPT, "application/json")
            .header(CONTENT_TYPE, "application/json")
            .header("Authorization", format!("Bearer {access_token}"))
            .body(body.into())
            .map_err(|e| {
                reqsign_core::Error::unexpected("failed to build HTTP request").with_source(e)
            })?;

        let resp = ctx.http_send(req).await?;

        if resp.status() != http::StatusCode::OK {
            error!("impersonated token got unexpected response: {resp:?}");
            let body = String::from_utf8_lossy(resp.body());
            return Err(reqsign_core::Error::unexpected(format!(
                "exchange impersonated token failed: {body}"
            )));
        }

        let token_resp: ImpersonatedTokenResponse =
            serde_json::from_slice(resp.body()).map_err(|e| {
                reqsign_core::Error::unexpected("failed to parse impersonation response")
                    .with_source(e)
            })?;

        // Parse expire time from RFC3339 format
        let expires_at = chrono::DateTime::parse_from_rfc3339(&token_resp.expire_time)
            .ok()
            .map(|dt| dt.with_timezone(&chrono::Utc));

        Ok(Some(Token {
            access_token: token_resp.access_token,
            expires_at,
        }))
    }
}

#[async_trait::async_trait]
impl ProvideCredential for ExternalAccountCredentialProvider {
    type Credential = Credential;

    async fn provide_credential(&self, ctx: &Context) -> Result<Option<Self::Credential>> {
        // Load OIDC token from source
        let oidc_token = self.load_oidc_token(ctx).await?;

        // Exchange for STS token
        let sts_token = self.exchange_sts_token(ctx, &oidc_token).await?;

        // Try to impersonate service account if configured
        let final_token = if let Some(token) = self
            .impersonate_service_account(ctx, &sts_token.access_token)
            .await?
        {
            token
        } else {
            sts_token
        };

        Ok(Some(Credential::with_token(final_token)))
    }
}
