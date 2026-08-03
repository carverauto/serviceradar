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

use http::header::CONTENT_TYPE;
use log::{debug, error};
use serde::{Deserialize, Serialize};
use std::time::Duration;

use crate::credential::{Credential, OAuth2Credentials, Token};
use reqsign_core::time::Timestamp;
use reqsign_core::{Context, ProvideCredential, Result};

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

/// AuthorizedUserCredentialProvider exchanges OAuth2 user credentials for access tokens.
#[derive(Debug, Clone)]
pub struct AuthorizedUserCredentialProvider {
    oauth2_credentials: OAuth2Credentials,
}

impl AuthorizedUserCredentialProvider {
    /// Create a new AuthorizedUserCredentialProvider.
    pub fn new(oauth2_credentials: OAuth2Credentials) -> Self {
        Self { oauth2_credentials }
    }
}
impl ProvideCredential for AuthorizedUserCredentialProvider {
    type Credential = Credential;

    async fn provide_credential(&self, ctx: &Context) -> Result<Option<Self::Credential>> {
        debug!("exchanging refresh token for access token");

        let req_body = RefreshTokenRequest {
            grant_type: "refresh_token",
            refresh_token: self.oauth2_credentials.refresh_token.clone(),
            client_id: self.oauth2_credentials.client_id.clone(),
            client_secret: self.oauth2_credentials.client_secret.clone(),
        };

        let body = serde_json::to_vec(&req_body).map_err(|e| {
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
            error!("refresh token exchange got unexpected response: {resp:?}");
            let body = String::from_utf8_lossy(resp.body());
            return Err(reqsign_core::Error::unexpected(format!(
                "refresh token exchange failed: {body}"
            )));
        }

        let token_resp: RefreshTokenResponse =
            serde_json::from_slice(resp.body()).map_err(|e| {
                reqsign_core::Error::unexpected("failed to parse token response").with_source(e)
            })?;

        let expires_at = token_resp
            .expires_in
            .map(|expires_in| Timestamp::now() + Duration::from_secs(expires_in));

        Ok(Some(Credential::with_token(Token {
            access_token: token_resp.access_token,
            expires_at,
        })))
    }
}
