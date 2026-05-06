use crate::Credential;
use async_trait::async_trait;
use reqsign_core::{Context, ProvideCredential, Result};

/// Load credential from Azure Client Secret.
///
/// This loader implements the Azure Client Secret authentication flow,
/// which allows applications to authenticate to Azure services using
/// a client ID and client secret.
///
/// Reference: <https://learn.microsoft.com/en-us/azure/active-directory/develop/v2-oauth2-client-creds-grant-flow>
#[derive(Debug, Default)]
pub struct ClientSecretCredentialProvider;

impl ClientSecretCredentialProvider {
    /// Create a new client secret loader.
    pub fn new() -> Self {
        Self
    }
}

#[async_trait]
impl ProvideCredential for ClientSecretCredentialProvider {
    type Credential = Credential;

    async fn provide_credential(&self, ctx: &Context) -> Result<Option<Self::Credential>> {
        let envs = ctx.env_vars();

        // Check if all required parameters are available from environment
        let tenant_id = match envs.get("AZURE_TENANT_ID") {
            Some(id) if !id.is_empty() => id,
            _ => return Ok(None),
        };

        let client_id = match envs.get("AZURE_CLIENT_ID") {
            Some(id) if !id.is_empty() => id,
            _ => return Ok(None),
        };

        let client_secret = match envs.get("AZURE_CLIENT_SECRET") {
            Some(secret) if !secret.is_empty() => secret,
            _ => return Ok(None),
        };

        let authority_host = envs
            .get("AZURE_AUTHORITY_HOST")
            .filter(|h| !h.is_empty())
            .map(|s| s.as_str())
            .unwrap_or("https://login.microsoftonline.com");

        let token =
            get_client_secret_token(tenant_id, client_id, client_secret, authority_host, ctx)
                .await?;

        match token {
            Some(token_response) => {
                let expires_on = reqsign_core::time::now()
                    + chrono::TimeDelta::try_seconds(token_response.expires_in as i64)
                        .unwrap_or_else(|| chrono::TimeDelta::try_minutes(10).expect("in bounds"));

                Ok(Some(Credential::with_bearer_token(
                    &token_response.access_token,
                    Some(expires_on),
                )))
            }
            None => Ok(None),
        }
    }
}

#[derive(serde::Deserialize)]
struct ClientSecretTokenResponse {
    access_token: String,
    expires_in: u64,
}

async fn get_client_secret_token(
    tenant_id: &str,
    client_id: &str,
    client_secret: &str,
    authority_host: &str,
    ctx: &Context,
) -> Result<Option<ClientSecretTokenResponse>> {
    let url = format!(
        "{}/{}/oauth2/v2.0/token",
        authority_host.trim_end_matches('/'),
        tenant_id
    );

    let body = form_urlencoded::Serializer::new(String::new())
        .append_pair("scope", "https://storage.azure.com/.default")
        .append_pair("client_id", client_id)
        .append_pair("client_secret", client_secret)
        .append_pair("grant_type", "client_credentials")
        .finish();

    let req = http::Request::builder()
        .method(http::Method::POST)
        .uri(&url)
        .header("Content-Type", "application/x-www-form-urlencoded")
        .body(bytes::Bytes::from(body))
        .map_err(|e| {
            reqsign_core::Error::unexpected("failed to build client secret request").with_source(e)
        })?;

    let resp = ctx.http_send(req).await?;

    if !resp.status().is_success() {
        let status = resp.status();
        let body = String::from_utf8_lossy(resp.body());
        return Err(reqsign_core::Error::unexpected(format!(
            "Client secret request failed with status {status}: {body}"
        )));
    }

    let token: ClientSecretTokenResponse = serde_json::from_slice(resp.body()).map_err(|e| {
        reqsign_core::Error::unexpected("failed to parse client secret response").with_source(e)
    })?;
    Ok(Some(token))
}
