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

use reqsign_core::{Context, ProvideCredential, Result, hash::base64_decode};

use crate::credential::Credential;

use super::parse::parse_credential_bytes;

/// StaticCredentialProvider loads credentials from a JSON string provided at construction time.
#[derive(Debug, Clone)]
pub struct StaticCredentialProvider {
    content: String,
    scope: Option<String>,
}

impl StaticCredentialProvider {
    /// Create a new StaticCredentialProvider from JSON content.
    pub fn new(content: impl Into<String>) -> Self {
        Self {
            content: content.into(),
            scope: None,
        }
    }

    /// Create a new StaticCredentialProvider from base64-encoded JSON content.
    pub fn from_base64(content: impl Into<String>) -> Result<Self> {
        let content = content.into();
        let decoded = base64_decode(&content).map_err(|e| {
            reqsign_core::Error::unexpected("failed to decode base64").with_source(e)
        })?;
        let json_content = String::from_utf8(decoded).map_err(|e| {
            reqsign_core::Error::unexpected("invalid UTF-8 in decoded content").with_source(e)
        })?;
        Ok(Self {
            content: json_content,
            scope: None,
        })
    }

    /// Set the OAuth2 scope.
    pub fn with_scope(mut self, scope: impl Into<String>) -> Self {
        self.scope = Some(scope.into());
        self
    }
}
impl ProvideCredential for StaticCredentialProvider {
    type Credential = Credential;

    async fn provide_credential(&self, ctx: &Context) -> Result<Option<Self::Credential>> {
        debug!("loading credential from static content");

        parse_credential_bytes(ctx, self.content.as_bytes(), self.scope.clone())
            .await
            .map_err(|err| {
                debug!("failed to parse credential from content: {err:?}");
                err
            })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use reqsign_core::Context;

    #[tokio::test]
    async fn test_static_service_account() {
        let content = r#"{
            "type": "service_account",
            "private_key": "-----BEGIN RSA PRIVATE KEY-----\ntest\n-----END RSA PRIVATE KEY-----",
            "client_email": "test@example.iam.gserviceaccount.com"
        }"#;

        let provider = StaticCredentialProvider::new(content);
        let ctx = Context::new()
            .with_file_read(reqsign_file_read_tokio::TokioFileRead)
            .with_http_send(reqsign_http_send_reqwest::ReqwestHttpSend::default());

        let result = provider.provide_credential(&ctx).await;
        assert!(result.is_ok());

        let cred = result.unwrap();
        assert!(cred.is_some());

        let cred = cred.unwrap();
        assert!(cred.has_service_account());
    }

    #[tokio::test]
    async fn test_static_service_account_from_base64() {
        let content = r#"{
            "type": "service_account",
            "private_key": "-----BEGIN RSA PRIVATE KEY-----\ntest\n-----END RSA PRIVATE KEY-----",
            "client_email": "test@example.iam.gserviceaccount.com"
        }"#;

        // Base64 encode the content
        use reqsign_core::hash::base64_encode;
        let encoded = base64_encode(content.as_bytes());

        let provider =
            StaticCredentialProvider::from_base64(encoded).expect("should decode base64");
        let ctx = Context::new()
            .with_file_read(reqsign_file_read_tokio::TokioFileRead)
            .with_http_send(reqsign_http_send_reqwest::ReqwestHttpSend::default());

        let result = provider.provide_credential(&ctx).await;
        assert!(result.is_ok());

        let cred = result.unwrap();
        assert!(cred.is_some());

        let cred = cred.unwrap();
        assert!(cred.has_service_account());
    }
}
