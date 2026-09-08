use async_trait::async_trait;
use reqsign_core::{Context, ProvideCredential};
use serde::Deserialize;

use crate::credential::Credential;

/// AzureCliCredentialProvider provides credentials from Azure CLI
///
/// This provider reads tokens from Azure CLI's local storage or invokes
/// `az account get-access-token` to retrieve fresh tokens.
#[derive(Clone, Debug, Default)]
pub struct AzureCliCredentialProvider {}

impl AzureCliCredentialProvider {
    pub fn new() -> Self {
        Self {}
    }

    /// Execute `az account get-access-token` command
    async fn get_access_token_from_cli(
        &self,
        ctx: &Context,
        resource: &str,
    ) -> Result<AzureCliToken, reqsign_core::Error> {
        let args = [
            "account",
            "get-access-token",
            "--resource",
            resource,
            "--output",
            "json",
        ];

        let output = ctx.command_execute("az", &args).await?;

        if !output.success() {
            return Err(reqsign_core::Error::credential_invalid(format!(
                "Azure CLI command failed: {}",
                String::from_utf8_lossy(&output.stderr)
            )));
        }

        let token: AzureCliToken = serde_json::from_slice(&output.stdout).map_err(|e| {
            reqsign_core::Error::unexpected(format!("Failed to parse Azure CLI output: {e}"))
        })?;

        Ok(token)
    }
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct AzureCliToken {
    access_token: String,
    expires_on: Option<String>,
    #[serde(rename = "expires_on")]
    expires_on_timestamp: Option<i64>,
    #[allow(dead_code)]
    subscription: Option<String>,
    #[allow(dead_code)]
    tenant: Option<String>,
    #[allow(dead_code)]
    token_type: String,
}

#[async_trait]
impl ProvideCredential for AzureCliCredentialProvider {
    type Credential = Credential;

    async fn provide_credential(
        &self,
        ctx: &Context,
    ) -> Result<Option<Self::Credential>, reqsign_core::Error> {
        // For Azure Storage, we need the storage resource
        let resource = "https://storage.azure.com/";

        // Try to get access token from Azure CLI
        let token = self.get_access_token_from_cli(ctx, resource).await?;

        // Calculate expiration time
        let expires_on = if let Some(timestamp) = token.expires_on_timestamp {
            Some(chrono::DateTime::from_timestamp(timestamp, 0).unwrap())
        } else if let Some(expires_str) = token.expires_on {
            // Parse the string format "2023-10-31 21:59:10.000000"
            chrono::NaiveDateTime::parse_from_str(&expires_str, "%Y-%m-%d %H:%M:%S%.f")
                .ok()
                .map(|dt| chrono::DateTime::from_naive_utc_and_offset(dt, chrono::Utc))
        } else {
            None
        };

        Ok(Some(Credential::with_bearer_token(
            &token.access_token,
            expires_on,
        )))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_parse_azure_cli_token() {
        let json = r#"{
            "accessToken": "unit-test-token",
            "expiresOn": "2023-10-31 21:59:10.000000",
            "expires_on": 1698760750,
            "subscription": "0b1f6471-1bf0-4dda-aec3-cb9272f09590",
            "tenant": "54826b22-38d6-4fb2-bad9-b7b93a3e9c5a",
            "tokenType": "Bearer"
        }"#;

        let token: AzureCliToken = serde_json::from_str(json).unwrap();
        assert_eq!(token.access_token, "unit-test-token");
        assert_eq!(token.expires_on_timestamp, Some(1698760750));
        assert_eq!(token.token_type, "Bearer");
    }
}
