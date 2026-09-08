use std::collections::HashMap;

use async_trait::async_trait;
use reqsign_core::{Context, ProvideCredential};
use serde::Deserialize;

use crate::credential::Credential;

/// AzurePipelinesCredentialProvider provides credentials using Azure Pipelines workload identity
///
/// This provider uses OIDC tokens from Azure Pipelines to authenticate with Azure AD
#[derive(Clone, Debug, Default)]
pub struct AzurePipelinesCredentialProvider {
    tenant_id: Option<String>,
    client_id: Option<String>,
    service_connection_id: Option<String>,
}

impl AzurePipelinesCredentialProvider {
    pub fn new() -> Self {
        Self::default()
    }

    /// Set the tenant ID
    pub fn with_tenant_id(mut self, tenant_id: &str) -> Self {
        self.tenant_id = Some(tenant_id.to_string());
        self
    }

    /// Set the client ID
    pub fn with_client_id(mut self, client_id: &str) -> Self {
        self.client_id = Some(client_id.to_string());
        self
    }

    /// Set the service connection ID
    pub fn with_service_connection_id(mut self, service_connection_id: &str) -> Self {
        self.service_connection_id = Some(service_connection_id.to_string());
        self
    }

    /// Get OIDC token from Azure Pipelines
    async fn get_oidc_token(
        &self,
        ctx: &Context,
        oidc_request_uri: &str,
        system_access_token: &str,
        service_connection_id: Option<&String>,
    ) -> Result<String, reqsign_core::Error> {
        // Build the request URL
        let mut url = format!("{oidc_request_uri}?api-version=7.1");
        if let Some(sc_id) = service_connection_id {
            url = format!("{url}&serviceConnectionId={sc_id}");
        }

        // Create the request
        let req = http::Request::builder()
            .method(http::Method::POST)
            .uri(url)
            .header("Authorization", format!("Bearer {system_access_token}"))
            .header("Content-Type", "application/json")
            .header("Content-Length", "0")
            .body(bytes::Bytes::new())
            .map_err(|e| {
                reqsign_core::Error::unexpected(format!("Failed to build OIDC request: {e}"))
            })?;

        // Send the request
        let resp = ctx.http_send(req).await?;

        if resp.status() != http::StatusCode::OK {
            let body = resp.into_body();
            return Err(reqsign_core::Error::credential_invalid(format!(
                "Failed to get OIDC token: {}",
                String::from_utf8_lossy(&body)
            )));
        }

        // Parse the response
        let body = resp.into_body();
        let oidc_response: OidcTokenResponse = serde_json::from_slice(&body).map_err(|e| {
            reqsign_core::Error::unexpected(format!("Failed to parse OIDC response: {e}"))
        })?;

        Ok(oidc_response.oidc_token)
    }

    /// Exchange OIDC token for Azure AD access token
    async fn exchange_token(
        &self,
        ctx: &Context,
        tenant_id: &str,
        client_id: &str,
        oidc_token: &str,
    ) -> Result<TokenResponse, reqsign_core::Error> {
        let url = format!("https://login.microsoftonline.com/{tenant_id}/oauth2/v2.0/token");

        let mut params = HashMap::new();
        params.insert("scope", "https://storage.azure.com/.default");
        params.insert("client_id", client_id);
        params.insert(
            "client_assertion_type",
            "urn:ietf:params:oauth:client-assertion-type:jwt-bearer",
        );
        params.insert("client_assertion", oidc_token);
        params.insert("grant_type", "client_credentials");

        let body = form_urlencoded::Serializer::new(String::new())
            .extend_pairs(params)
            .finish();

        let req = http::Request::builder()
            .method(http::Method::POST)
            .uri(url)
            .header("Content-Type", "application/x-www-form-urlencoded")
            .body(bytes::Bytes::from(body))
            .map_err(|e| {
                reqsign_core::Error::unexpected(format!("Failed to build token request: {e}"))
            })?;

        let resp = ctx.http_send(req).await?;

        if resp.status() != http::StatusCode::OK {
            let body = resp.into_body();
            return Err(reqsign_core::Error::credential_invalid(format!(
                "Failed to exchange token: {}",
                String::from_utf8_lossy(&body)
            )));
        }

        let body = resp.into_body();
        let token_response: TokenResponse = serde_json::from_slice(&body).map_err(|e| {
            reqsign_core::Error::unexpected(format!("Failed to parse token response: {e}"))
        })?;

        Ok(token_response)
    }
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct OidcTokenResponse {
    oidc_token: String,
}

#[derive(Debug, Deserialize)]
struct TokenResponse {
    access_token: String,
    expires_in: u64,
    #[allow(dead_code)]
    token_type: String,
}

#[async_trait]
impl ProvideCredential for AzurePipelinesCredentialProvider {
    type Credential = Credential;

    async fn provide_credential(
        &self,
        ctx: &Context,
    ) -> Result<Option<Self::Credential>, reqsign_core::Error> {
        let envs = ctx.env_vars();

        // Check for required environment variables
        let system_access_token = match envs.get("SYSTEM_ACCESSTOKEN") {
            Some(token) => token,
            None => return Ok(None), // Not in Azure Pipelines environment
        };

        let oidc_request_uri = match envs.get("SYSTEM_OIDCREQUESTURI") {
            Some(uri) => uri,
            None => return Ok(None), // OIDC not configured
        };

        // Get tenant and client ID
        let tenant_id = self
            .tenant_id
            .as_ref()
            .or_else(|| envs.get("ARM_TENANT_ID"))
            .or_else(|| envs.get("AZURE_TENANT_ID"))
            .cloned();

        let client_id = self
            .client_id
            .as_ref()
            .or_else(|| envs.get("ARM_CLIENT_ID"))
            .or_else(|| envs.get("AZURE_CLIENT_ID"))
            .cloned();

        // Get service connection ID if provided
        let service_connection_id = self
            .service_connection_id
            .as_ref()
            .or_else(|| envs.get("ARM_OIDC_AZURE_SERVICE_CONNECTION_ID"))
            .or_else(|| envs.get("AZURE_SERVICE_CONNECTION_ID"));

        // Check if all required parameters are present
        let (tenant_id, client_id) = match (tenant_id, client_id) {
            (Some(t), Some(c)) => (t, c),
            _ => return Ok(None),
        };

        // Get OIDC token
        let oidc_token = self
            .get_oidc_token(
                ctx,
                oidc_request_uri,
                system_access_token,
                service_connection_id,
            )
            .await?;

        // Exchange for access token
        let token_response = self
            .exchange_token(ctx, &tenant_id, &client_id, &oidc_token)
            .await?;

        // Calculate expiration time
        let expires_on = std::time::SystemTime::now()
            .checked_add(std::time::Duration::from_secs(token_response.expires_in))
            .and_then(|t| {
                t.duration_since(std::time::UNIX_EPOCH)
                    .ok()
                    .map(|d| chrono::DateTime::from_timestamp(d.as_secs() as i64, 0).unwrap())
            });

        Ok(Some(Credential::with_bearer_token(
            &token_response.access_token,
            expires_on,
        )))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_provider_configuration() {
        let provider = AzurePipelinesCredentialProvider::new()
            .with_tenant_id("test-tenant")
            .with_client_id("test-client")
            .with_service_connection_id("test-connection");

        assert_eq!(provider.tenant_id, Some("test-tenant".to_string()));
        assert_eq!(provider.client_id, Some("test-client".to_string()));
        assert_eq!(
            provider.service_connection_id,
            Some("test-connection".to_string())
        );
    }

    #[tokio::test]
    async fn test_provide_credential_no_environment() {
        // When not in Azure Pipelines environment, should return None
        let provider = AzurePipelinesCredentialProvider::new();
        let ctx = reqsign_core::Context::new()
            .with_file_read(reqsign_file_read_tokio::TokioFileRead)
            .with_http_send(reqsign_http_send_reqwest::ReqwestHttpSend::default());

        let result = provider.provide_credential(&ctx).await;
        assert!(result.is_ok());
        assert!(result.unwrap().is_none());
    }
}
