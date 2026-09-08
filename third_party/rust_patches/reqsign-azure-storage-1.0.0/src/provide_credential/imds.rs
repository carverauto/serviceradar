use crate::Credential;
use async_trait::async_trait;
use reqsign_core::{Context, ProvideCredential, Result};

/// Load credential from Azure Instance Metadata Service (IMDS).
///
/// This loader attempts to retrieve an access token from the Azure Instance Metadata Service
/// which is available on Azure VMs and other Azure compute resources.
///
/// Reference: <https://learn.microsoft.com/en-us/azure/app-service/overview-managed-identity?tabs=portal,http#using-the-rest-protocol>
#[derive(Debug, Default)]
pub struct ImdsCredentialProvider;

impl ImdsCredentialProvider {
    /// Create a new IMDS loader.
    pub fn new() -> Self {
        Self
    }
}

#[async_trait]
impl ProvideCredential for ImdsCredentialProvider {
    type Credential = Credential;

    async fn provide_credential(&self, ctx: &Context) -> Result<Option<Self::Credential>> {
        let token = get_access_token("https://storage.azure.com/", ctx).await?;

        let expires_on = if token.expires_on.is_empty() {
            reqsign_core::time::now() + chrono::TimeDelta::try_minutes(10).expect("in bounds")
        } else {
            // Azure IMDS returns expires_on as Unix timestamp (seconds since epoch)
            let timestamp = token.expires_on.parse::<i64>().map_err(|e| {
                reqsign_core::Error::unexpected("failed to parse expires_on timestamp")
                    .with_source(e)
            })?;
            chrono::DateTime::from_timestamp(timestamp, 0)
                .ok_or_else(|| reqsign_core::Error::unexpected("invalid expires_on timestamp"))?
        };

        Ok(Some(Credential::with_bearer_token(
            &token.access_token,
            Some(expires_on),
        )))
    }
}

#[derive(serde::Deserialize)]
struct AccessTokenResponse {
    access_token: String,
    expires_on: String,
}

async fn get_access_token(resource: &str, ctx: &Context) -> Result<AccessTokenResponse> {
    let envs = ctx.env_vars();

    let endpoint = envs
        .get("AZBLOB_ENDPOINT")
        .or_else(|| envs.get("AZURE_IMDS_ENDPOINT"))
        .filter(|e| !e.is_empty())
        .map(|s| s.as_str())
        .unwrap_or("http://169.254.169.254/metadata/identity/oauth2/token");

    let mut url = format!("{endpoint}?api-version=2018-02-01&resource={resource}");

    // Add identity parameters if specified in environment
    if let Some(object_id) = envs.get("AZURE_OBJECT_ID").filter(|s| !s.is_empty()) {
        url.push_str(&format!("&object_id={object_id}"));
    } else if let Some(client_id) = envs.get("AZURE_CLIENT_ID").filter(|s| !s.is_empty()) {
        url.push_str(&format!("&client_id={client_id}"));
    } else if let Some(msi_res_id) = envs.get("AZURE_MSI_RES_ID").filter(|s| !s.is_empty()) {
        url.push_str(&format!("&msi_res_id={msi_res_id}"));
    }

    let mut req = http::Request::builder()
        .method(http::Method::GET)
        .uri(&url)
        .header("Metadata", "true");

    // Add MSI secret header if provided in environment
    if let Some(msi_secret) = envs.get("AZURE_MSI_SECRET").filter(|s| !s.is_empty()) {
        req = req.header("X-IDENTITY-HEADER", msi_secret);
    }

    let req = req.body(bytes::Bytes::new()).map_err(|e| {
        reqsign_core::Error::unexpected("failed to build IMDS request").with_source(e)
    })?;

    let resp = ctx.http_send(req).await?;

    if !resp.status().is_success() {
        let status = resp.status();
        let body = String::from_utf8_lossy(resp.body());
        return Err(reqsign_core::Error::unexpected(format!(
            "IMDS request failed with status {status}: {body}"
        )));
    }

    let token: AccessTokenResponse = serde_json::from_slice(resp.body()).map_err(|e| {
        reqsign_core::Error::unexpected("failed to parse IMDS response").with_source(e)
    })?;
    Ok(token)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_parse_standard_imds_response() {
        // Standard IMDS token response format
        let json_response = r#"{
            "access_token": "eyJ0eXAi...",
            "refresh_token": "",
            "expires_in": "3599",
            "expires_on": "1506484173",
            "not_before": "1506480273",
            "resource": "https://management.azure.com/",
            "token_type": "Bearer"
        }"#;

        let parsed: AccessTokenResponse = serde_json::from_str(json_response).unwrap();

        assert_eq!(parsed.access_token, "eyJ0eXAi...");
        assert_eq!(parsed.expires_on, "1506484173");
    }

    #[test]
    fn test_parse_minimal_imds_response() {
        // Minimal response with only required fields
        let json_response = r#"{
            "access_token": "test_token",
            "expires_on": "1506484173"
        }"#;

        let parsed: AccessTokenResponse = serde_json::from_str(json_response).unwrap();

        assert_eq!(parsed.access_token, "test_token");
        assert_eq!(parsed.expires_on, "1506484173");
    }
}
