// Licensed to the Apache Software Foundation (ASF) under one
// or more contributor license agreements.  See the NOTICE file
// distributed with this work for additional information
// regarding copyright ownership.  The ASF licenses this file
// to you under the Apache License, Version 2.0 (the
// "License"); you may not use this file except in compliance
// with the License.  You may obtain a copy of the License at
//
//   http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing,
// software distributed under the License is distributed on an
// "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
// KIND, either express or implied.  See the License for the
// specific language governing permissions and limitations
// under the License.

use crate::Credential;
use reqsign_core::time::Timestamp;
use reqsign_core::{Context, ProvideCredential, Result};
use std::time::Duration;

/// Load credential from Azure Client Secret.
///
/// This loader implements the Azure Client Secret authentication flow,
/// which allows applications to authenticate to Azure services using
/// a client ID and client secret.
///
/// Reference: <https://learn.microsoft.com/en-us/azure/active-directory/develop/v2-oauth2-client-creds-grant-flow>
#[derive(Debug, Default, Clone)]
pub struct ClientSecretCredentialProvider {
    tenant_id: Option<String>,
    client_id: Option<String>,
    client_secret: Option<String>,
    authority_host: Option<String>,
}

impl ClientSecretCredentialProvider {
    /// Create a new client secret loader.
    pub fn new() -> Self {
        Self::default()
    }

    /// Set the tenant ID.
    pub fn with_tenant_id(mut self, tenant_id: impl Into<String>) -> Self {
        self.tenant_id = Some(tenant_id.into());
        self
    }

    /// Set the client ID.
    pub fn with_client_id(mut self, client_id: impl Into<String>) -> Self {
        self.client_id = Some(client_id.into());
        self
    }

    /// Set the client secret.
    pub fn with_client_secret(mut self, client_secret: impl Into<String>) -> Self {
        self.client_secret = Some(client_secret.into());
        self
    }

    /// Set the authority host.
    pub fn with_authority_host(mut self, authority_host: impl Into<String>) -> Self {
        self.authority_host = Some(authority_host.into());
        self
    }
}
impl ProvideCredential for ClientSecretCredentialProvider {
    type Credential = Credential;

    async fn provide_credential(&self, ctx: &Context) -> Result<Option<Self::Credential>> {
        let envs = ctx.env_vars();

        // Check if all required parameters are available from environment or config
        let tenant_id = match self
            .tenant_id
            .as_ref()
            .or_else(|| envs.get("AZURE_TENANT_ID"))
        {
            Some(id) if !id.is_empty() => id,
            _ => return Ok(None),
        };

        let client_id = match self
            .client_id
            .as_ref()
            .or_else(|| envs.get("AZURE_CLIENT_ID"))
        {
            Some(id) if !id.is_empty() => id,
            _ => return Ok(None),
        };

        let client_secret = match self
            .client_secret
            .as_ref()
            .or_else(|| envs.get("AZURE_CLIENT_SECRET"))
        {
            Some(secret) if !secret.is_empty() => secret,
            _ => return Ok(None),
        };

        let authority_host = self
            .authority_host
            .as_ref()
            .or_else(|| envs.get("AZURE_AUTHORITY_HOST"))
            .filter(|h| !h.is_empty())
            .map(|s| s.as_str())
            .unwrap_or("https://login.microsoftonline.com");

        let token =
            get_client_secret_token(tenant_id, client_id, client_secret, authority_host, ctx)
                .await?;

        match token {
            Some(token_response) => {
                let expires_on = Timestamp::now() + Duration::from_secs(token_response.expires_in);
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
