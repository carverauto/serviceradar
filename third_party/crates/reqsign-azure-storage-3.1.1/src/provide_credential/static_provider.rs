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

use reqsign_core::{Context, ProvideCredential};

use crate::credential::Credential;

#[derive(Clone, Debug)]
pub struct StaticCredentialProvider {
    credential: Credential,
}

impl StaticCredentialProvider {
    pub fn new_shared_key(account_name: &str, account_key: &str) -> Self {
        Self {
            credential: Credential::with_shared_key(account_name, account_key),
        }
    }

    pub fn new_sas_token(sas_token: &str) -> Self {
        Self {
            credential: Credential::with_sas_token(sas_token),
        }
    }

    pub fn new_bearer_token(bearer_token: &str) -> Self {
        Self {
            credential: Credential::with_bearer_token(bearer_token, None),
        }
    }
}
impl ProvideCredential for StaticCredentialProvider {
    type Credential = Credential;

    async fn provide_credential(
        &self,
        _ctx: &Context,
    ) -> Result<Option<Self::Credential>, reqsign_core::Error> {
        Ok(Some(self.credential.clone()))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use reqsign_core::{Context, OsEnv};
    use reqsign_file_read_tokio::TokioFileRead;
    use reqsign_http_send_reqwest::ReqwestHttpSend;

    #[tokio::test]
    async fn test_static_credential_provider_shared_key() {
        let provider = StaticCredentialProvider::new_shared_key("myaccount", "mykey");
        let ctx = Context::new()
            .with_file_read(TokioFileRead)
            .with_http_send(ReqwestHttpSend::default())
            .with_env(OsEnv);
        let cred = provider.provide_credential(&ctx).await.unwrap();

        match cred {
            Some(Credential::SharedKey {
                account_name,
                account_key,
            }) => {
                assert_eq!(account_name, "myaccount");
                assert_eq!(account_key, "mykey");
            }
            _ => panic!("Expected SharedKey credential"),
        }
    }

    #[tokio::test]
    async fn test_static_credential_provider_sas_token() {
        let provider = StaticCredentialProvider::new_sas_token("mysastoken");
        let ctx = Context::new()
            .with_file_read(TokioFileRead)
            .with_http_send(ReqwestHttpSend::default())
            .with_env(OsEnv);
        let cred = provider.provide_credential(&ctx).await.unwrap();

        match cred {
            Some(Credential::SasToken { token }) => {
                assert_eq!(token, "mysastoken");
            }
            _ => panic!("Expected SasToken credential"),
        }
    }

    #[tokio::test]
    async fn test_static_credential_provider_bearer_token() {
        let provider = StaticCredentialProvider::new_bearer_token("mybearertoken");
        let ctx = Context::new()
            .with_file_read(TokioFileRead)
            .with_http_send(ReqwestHttpSend::default())
            .with_env(OsEnv);
        let cred = provider.provide_credential(&ctx).await.unwrap();

        match cred {
            Some(Credential::BearerToken { token, .. }) => {
                assert_eq!(token, "mybearertoken");
            }
            _ => panic!("Expected BearerToken credential"),
        }
    }
}
