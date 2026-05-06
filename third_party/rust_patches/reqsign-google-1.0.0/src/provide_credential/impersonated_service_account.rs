use std::time::Duration;

use http::header::CONTENT_TYPE;
use log::{debug, error};
use serde::{Deserialize, Serialize};

use reqsign_core::{time::now, Context, ProvideCredential, Result};

use crate::credential::{Credential, ImpersonatedServiceAccount, Token};

/// The maximum impersonated token lifetime allowed, 1 hour.
const MAX_LIFETIME: Duration = Duration::from_secs(3600);

/// OAuth2 refresh token request.
#[derive(Serialize)]
struct RefreshTokenRequest {
    grant_type: &'static str,
    refresh_token: String,
    client_id: String,
    client_secret: String,
}

/// OAuth2 token response.
#[derive(Deserialize)]
struct RefreshTokenResponse {
    access_token: String,
    #[serde(default)]
    expires_in: Option<u64>,
}

/// Impersonation request.
#[derive(Serialize)]
struct ImpersonationRequest {
    lifetime: String,
    scope: Vec<String>,
    delegates: Vec<String>,
}

/// Impersonated token response.
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ImpersonatedTokenResponse {
    access_token: String,
    expire_time: String,
}

/// ImpersonatedServiceAccountCredentialProvider exchanges impersonated service account credentials for access tokens.
#[derive(Debug, Clone)]
pub struct ImpersonatedServiceAccountCredentialProvider {
    impersonated_service_account: ImpersonatedServiceAccount,
    scope: Option<String>,
}

impl ImpersonatedServiceAccountCredentialProvider {
    /// Create a new ImpersonatedServiceAccountCredentialProvider.
    pub fn new(impersonated_service_account: ImpersonatedServiceAccount) -> Self {
        Self {
            impersonated_service_account,
            scope: None,
        }
    }

    /// Set the OAuth2 scope.
    pub fn with_scope(mut self, scope: impl Into<String>) -> Self {
        self.scope = Some(scope.into());
        self
    }

    async fn generate_bearer_auth_token(&self, ctx: &Context) -> Result<Token> {
        debug!("refreshing OAuth2 token for impersonated service account");

        let request = RefreshTokenRequest {
            grant_type: "refresh_token",
            refresh_token: self
                .impersonated_service_account
                .source_credentials
                .refresh_token
                .clone(),
            client_id: self
                .impersonated_service_account
                .source_credentials
                .client_id
                .clone(),
            client_secret: self
                .impersonated_service_account
                .source_credentials
                .client_secret
                .clone(),
        };

        let body = serde_json::to_vec(&request).map_err(|e| {
            reqsign_core::Error::unexpected("failed to serialize request").with_source(e)
        })?;

        let req = http::Request::builder()
            .method(http::Method::POST)
            .uri("https://oauth2.googleapis.com/token")
            .header(CONTENT_TYPE, "application/json")
            .body(body.into())
            .map_err(|e| {
                reqsign_core::Error::unexpected("failed to build HTTP request").with_source(e)
            })?;

        let resp = ctx.http_send(req).await?;

        if resp.status() != http::StatusCode::OK {
            error!(
                "bearer token loader for impersonated service account got unexpected response: {resp:?}"
            );
            let body = String::from_utf8_lossy(resp.body());
            return Err(reqsign_core::Error::unexpected(format!(
                "bearer token loader for impersonated service account failed: {body}"
            )));
        }

        let token_resp: RefreshTokenResponse =
            serde_json::from_slice(resp.body()).map_err(|e| {
                reqsign_core::Error::unexpected("failed to parse token response").with_source(e)
            })?;

        let expires_at = token_resp.expires_in.map(|expires_in| {
            now() + chrono::TimeDelta::try_seconds(expires_in as i64).expect("in bounds")
        });

        Ok(Token {
            access_token: token_resp.access_token,
            expires_at,
        })
    }

    async fn generate_access_token(&self, ctx: &Context, bearer_token: &Token) -> Result<Token> {
        debug!("generating access token for impersonated service account");

        let scope = self
            .scope
            .clone()
            .or_else(|| ctx.env_var(crate::constants::GOOGLE_SCOPE))
            .unwrap_or_else(|| crate::constants::DEFAULT_SCOPE.to_string());

        let request = ImpersonationRequest {
            lifetime: format!("{}s", MAX_LIFETIME.as_secs()),
            scope: vec![scope.clone()],
            delegates: self.impersonated_service_account.delegates.clone(),
        };

        let body = serde_json::to_vec(&request).map_err(|e| {
            reqsign_core::Error::unexpected("failed to serialize request").with_source(e)
        })?;

        let req = http::Request::builder()
            .method(http::Method::POST)
            .uri(
                &self
                    .impersonated_service_account
                    .service_account_impersonation_url,
            )
            .header(CONTENT_TYPE, "application/json")
            .header(
                "Authorization",
                format!("Bearer {}", bearer_token.access_token),
            )
            .body(body.into())
            .map_err(|e| {
                reqsign_core::Error::unexpected("failed to build HTTP request").with_source(e)
            })?;

        let resp = ctx.http_send(req).await?;

        if resp.status() != http::StatusCode::OK {
            error!(
                "access token loader for impersonated service account got unexpected response: {resp:?}"
            );
            let body = String::from_utf8_lossy(resp.body());
            return Err(reqsign_core::Error::unexpected(format!(
                "access token loader for impersonated service account failed: {body}"
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

        Ok(Token {
            access_token: token_resp.access_token,
            expires_at,
        })
    }
}

#[async_trait::async_trait]
impl ProvideCredential for ImpersonatedServiceAccountCredentialProvider {
    type Credential = Credential;

    async fn provide_credential(&self, ctx: &Context) -> Result<Option<Self::Credential>> {
        // First get bearer token using OAuth2 refresh
        let bearer_token = self.generate_bearer_auth_token(ctx).await?;

        // Then exchange for impersonated access token
        let access_token = self.generate_access_token(ctx, &bearer_token).await?;

        Ok(Some(Credential::with_token(access_token)))
    }
}
