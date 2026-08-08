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
use reqsign_core::{Context, ProvideCredential, Result};

/// StaticCredentialProvider provides static AWS credentials.
///
/// This provider is used when you have the access key ID and secret access key
/// directly and want to use them without any dynamic loading.
#[derive(Debug, Clone)]
pub struct StaticCredentialProvider {
    access_key_id: String,
    secret_access_key: String,
    session_token: Option<String>,
}

impl StaticCredentialProvider {
    /// Create a new StaticCredentialProvider with access key ID and secret access key.
    pub fn new(access_key_id: &str, secret_access_key: &str) -> Self {
        Self {
            access_key_id: access_key_id.to_string(),
            secret_access_key: secret_access_key.to_string(),
            session_token: None,
        }
    }

    /// Set the session token.
    pub fn with_session_token(mut self, token: &str) -> Self {
        self.session_token = Some(token.to_string());
        self
    }
}
impl ProvideCredential for StaticCredentialProvider {
    type Credential = Credential;

    async fn provide_credential(&self, _: &Context) -> Result<Option<Self::Credential>> {
        Ok(Some(Credential {
            access_key_id: self.access_key_id.clone(),
            secret_access_key: self.secret_access_key.clone(),
            session_token: self.session_token.clone(),
            expires_in: None,
        }))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use reqsign_core::OsEnv;
    use reqsign_file_read_tokio::TokioFileRead;
    use reqsign_http_send_reqwest::ReqwestHttpSend;

    #[tokio::test]
    async fn test_static_credential_provider() -> anyhow::Result<()> {
        let ctx = Context::new()
            .with_file_read(TokioFileRead)
            .with_http_send(ReqwestHttpSend::default())
            .with_env(OsEnv);

        // Test with basic credentials
        let provider = StaticCredentialProvider::new("test_access_key", "test_secret_key");
        let cred = provider.provide_credential(&ctx).await?;
        assert!(cred.is_some());
        let cred = cred.unwrap();
        assert_eq!(cred.access_key_id, "test_access_key");
        assert_eq!(cred.secret_access_key, "test_secret_key");
        assert!(cred.session_token.is_none());

        // Test with session token
        let provider = StaticCredentialProvider::new("test_access_key", "test_secret_key")
            .with_session_token("test_session_token");
        let cred = provider.provide_credential(&ctx).await?;
        assert!(cred.is_some());
        let cred = cred.unwrap();
        assert_eq!(cred.access_key_id, "test_access_key");
        assert_eq!(cred.secret_access_key, "test_secret_key");
        assert_eq!(cred.session_token, Some("test_session_token".to_string()));

        Ok(())
    }
}
