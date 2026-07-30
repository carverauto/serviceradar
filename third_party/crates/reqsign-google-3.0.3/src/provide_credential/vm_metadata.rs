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

use log::debug;
use serde::Deserialize;
use std::time::Duration;

use crate::credential::{Credential, Token};
use reqsign_core::time::Timestamp;
use reqsign_core::{Context, ProvideCredential, Result};

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
    endpoint: Option<String>,
    service_account: Option<String>,
}

impl VmMetadataCredentialProvider {
    /// Create a new VmMetadataCredentialProvider.
    pub fn new() -> Self {
        Self::default()
    }

    /// Set the OAuth2 scope.
    pub fn with_scope(mut self, scope: impl Into<String>) -> Self {
        self.scope = Some(scope.into());
        self
    }

    /// Set the metadata endpoint.
    pub fn with_endpoint(mut self, endpoint: impl Into<String>) -> Self {
        self.endpoint = Some(endpoint.into());
        self
    }

    /// Set the service account used to retrieve a token from VM metadata service.
    ///
    /// Defaults to `default` if not configured.
    pub fn with_service_account(mut self, service_account: impl Into<String>) -> Self {
        self.service_account = Some(service_account.into());
        self
    }
}
impl ProvideCredential for VmMetadataCredentialProvider {
    type Credential = Credential;

    async fn provide_credential(&self, ctx: &Context) -> Result<Option<Self::Credential>> {
        // Get scope from instance, environment, or use default
        let scope = self
            .scope
            .clone()
            .or_else(|| ctx.env_var(crate::constants::GOOGLE_SCOPE))
            .unwrap_or_else(|| crate::constants::DEFAULT_SCOPE.to_string());

        let service_account = self.service_account.as_deref().unwrap_or("default");

        debug!("loading token from VM metadata service for account: {service_account}");

        // Allow overriding metadata host for testing
        let metadata_host = self
            .endpoint
            .clone()
            .or_else(|| ctx.env_var("GCE_METADATA_HOST"))
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

        let expires_at = Timestamp::now() + Duration::from_secs(token_resp.expires_in);
        Ok(Some(Credential::with_token(Token {
            access_token: token_resp.access_token,
            expires_at: Some(expires_at),
        })))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use bytes::Bytes;
    use reqsign_core::HttpSend;
    use std::sync::{Arc, Mutex};

    #[derive(Clone, Debug, Default)]
    struct MockHttpSend {
        uris: Arc<Mutex<Vec<String>>>,
    }

    impl HttpSend for MockHttpSend {
        async fn http_send(&self, req: http::Request<Bytes>) -> Result<http::Response<Bytes>> {
            self.uris.lock().unwrap().push(req.uri().to_string());

            Ok(http::Response::builder()
                .status(http::StatusCode::OK)
                .body(
                    br#"{"access_token":"test-access-token","expires_in":3600}"#
                        .as_slice()
                        .into(),
                )
                .expect("response must build"))
        }
    }

    #[tokio::test]
    async fn test_vm_metadata_uses_default_service_account() -> Result<()> {
        let http = MockHttpSend::default();
        let ctx = Context::new().with_http_send(http.clone());

        let provider = VmMetadataCredentialProvider::new().with_endpoint("127.0.0.1:8080");
        let cred = provider
            .provide_credential(&ctx)
            .await?
            .expect("credential must exist");

        assert!(cred.has_token());
        assert_eq!(
            http.uris.lock().unwrap().as_slice(),
            &["http://127.0.0.1:8080/computeMetadata/v1/instance/service-accounts/default/token?scopes=https://www.googleapis.com/auth/cloud-platform".to_string()]
        );

        Ok(())
    }

    #[tokio::test]
    async fn test_vm_metadata_uses_configured_service_account() -> Result<()> {
        let http = MockHttpSend::default();
        let ctx = Context::new().with_http_send(http.clone());

        let provider = VmMetadataCredentialProvider::new()
            .with_endpoint("127.0.0.1:8080")
            .with_service_account("custom@test-project.iam.gserviceaccount.com");
        let cred = provider
            .provide_credential(&ctx)
            .await?
            .expect("credential must exist");

        assert!(cred.has_token());
        assert_eq!(
            http.uris.lock().unwrap().as_slice(),
            &["http://127.0.0.1:8080/computeMetadata/v1/instance/service-accounts/custom@test-project.iam.gserviceaccount.com/token?scopes=https://www.googleapis.com/auth/cloud-platform".to_string()]
        );

        Ok(())
    }
}
