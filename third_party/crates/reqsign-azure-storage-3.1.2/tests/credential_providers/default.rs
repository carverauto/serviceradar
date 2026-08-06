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

use reqsign_azure_storage::{Credential, DefaultCredentialProvider};
use reqsign_core::{Context, OsEnv, ProvideCredential, ProvideCredentialChain, Result, StaticEnv};
use reqsign_file_read_tokio::TokioFileRead;
use reqsign_http_send_reqwest::ReqwestHttpSend;
use std::collections::HashMap;
use std::sync::Arc;

fn is_test_enabled() -> bool {
    std::env::var("REQSIGN_AZURE_STORAGE_TEST").unwrap_or_default() == "on"
}

/// Mock provider that tracks how many times it was called
#[derive(Debug)]
struct CountingProvider {
    name: String,
    return_credential: Option<Credential>,
    call_count: Arc<std::sync::Mutex<usize>>,
}
impl ProvideCredential for CountingProvider {
    type Credential = Credential;

    async fn provide_credential(&self, _ctx: &Context) -> Result<Option<Self::Credential>> {
        let mut count = self.call_count.lock().unwrap();
        *count += 1;
        eprintln!("Provider {} called (count: {})", self.name, *count);
        Ok(self.return_credential.clone())
    }
}

#[derive(Debug)]
struct StaticHttpSend {
    status: http::StatusCode,
    body: &'static str,
}

impl reqsign_core::HttpSend for StaticHttpSend {
    async fn http_send(
        &self,
        _req: http::Request<bytes::Bytes>,
    ) -> Result<http::Response<bytes::Bytes>> {
        http::Response::builder()
            .status(self.status)
            .body(bytes::Bytes::copy_from_slice(self.body.as_bytes()))
            .map_err(|err| {
                reqsign_core::Error::unexpected("failed to build mock response").with_source(err)
            })
    }
}

fn builder_without_other_slots() -> reqsign_azure_storage::DefaultCredentialProviderBuilder {
    let builder = DefaultCredentialProvider::builder()
        .no_env()
        .no_client_secret()
        .no_azure_pipelines()
        .no_workload_identity()
        .no_imds();

    #[cfg(not(target_arch = "wasm32"))]
    let builder = builder.no_azure_cli().no_client_certificate();

    builder
}

fn assert_shared_key(
    result: Option<Credential>,
    expected_account_name: &str,
    expected_account_key: &str,
) {
    match result {
        Some(Credential::SharedKey {
            account_name,
            account_key,
        }) => {
            assert_eq!(account_name, expected_account_name);
            assert_eq!(account_key, expected_account_key);
        }
        other => panic!("Expected SharedKey credential, got {other:?}"),
    }
}

fn assert_bearer_token(result: Option<Credential>, expected_token: &str) {
    match result {
        Some(Credential::BearerToken { token, .. }) => {
            assert_eq!(token, expected_token);
        }
        other => panic!("Expected BearerToken credential, got {other:?}"),
    }
}

#[tokio::test]
async fn test_default_provider_chain() {
    if !is_test_enabled() {
        eprintln!("Skipping test: REQSIGN_AZURE_STORAGE_TEST is not enabled");
        return;
    }

    let ctx = Context::new()
        .with_file_read(TokioFileRead)
        .with_http_send(ReqwestHttpSend::default())
        .with_env(OsEnv);

    // Test that DefaultCredentialProvider tries multiple sources
    let provider = DefaultCredentialProvider::new();

    // This will try environment variables, IMDS, Azure CLI, etc.
    // The actual result depends on the environment
    let _ = provider.provide_credential(&ctx).await;
}

#[tokio::test]
async fn test_chain_stops_at_first_success() {
    let ctx = Context::new()
        .with_file_read(TokioFileRead)
        .with_http_send(ReqwestHttpSend::default())
        .with_env(OsEnv);

    let count1 = Arc::new(std::sync::Mutex::new(0));
    let count2 = Arc::new(std::sync::Mutex::new(0));
    let count3 = Arc::new(std::sync::Mutex::new(0));

    let chain = ProvideCredentialChain::new()
        .push(CountingProvider {
            name: "provider1".to_string(),
            return_credential: None,
            call_count: count1.clone(),
        })
        .push(CountingProvider {
            name: "provider2".to_string(),
            return_credential: Some(Credential::SharedKey {
                account_name: "testaccount".to_string(),
                account_key: "dGVzdGtleQ==".to_string(),
            }),
            call_count: count2.clone(),
        })
        .push(CountingProvider {
            name: "provider3".to_string(),
            return_credential: Some(Credential::SasToken {
                token: "sv=2021-01-01&ss=b".to_string(),
            }),
            call_count: count3.clone(),
        });

    let result = chain.provide_credential(&ctx).await.unwrap();
    assert!(result.is_some());

    let cred = result.unwrap();
    match cred {
        Credential::SharedKey {
            account_name,
            account_key,
        } => {
            assert_eq!(account_name, "testaccount");
            assert_eq!(account_key, "dGVzdGtleQ==");
        }
        _ => panic!("Expected SharedKey credential"),
    }

    // Verify call counts
    assert_eq!(*count1.lock().unwrap(), 1);
    assert_eq!(*count2.lock().unwrap(), 1);
    assert_eq!(*count3.lock().unwrap(), 0); // Should not be called
}

#[tokio::test]
async fn test_chain_returns_none_when_all_fail() {
    let ctx = Context::new()
        .with_file_read(TokioFileRead)
        .with_http_send(ReqwestHttpSend::default())
        .with_env(OsEnv);

    let count1 = Arc::new(std::sync::Mutex::new(0));
    let count2 = Arc::new(std::sync::Mutex::new(0));

    let chain = ProvideCredentialChain::new()
        .push(CountingProvider {
            name: "provider1".to_string(),
            return_credential: None,
            call_count: count1.clone(),
        })
        .push(CountingProvider {
            name: "provider2".to_string(),
            return_credential: None,
            call_count: count2.clone(),
        });

    let result = chain.provide_credential(&ctx).await.unwrap();
    assert!(result.is_none());

    // Verify all providers were called
    assert_eq!(*count1.lock().unwrap(), 1);
    assert_eq!(*count2.lock().unwrap(), 1);
}

#[tokio::test]
async fn test_builder_no_env_removes_provider() {
    let ctx = Context::new()
        .with_file_read(TokioFileRead)
        .with_http_send(ReqwestHttpSend::default())
        .with_env(StaticEnv {
            home_dir: None,
            envs: HashMap::from([
                (
                    "AZURE_STORAGE_ACCOUNT_NAME".to_string(),
                    "testaccount".to_string(),
                ),
                (
                    "AZURE_STORAGE_ACCOUNT_KEY".to_string(),
                    "dGVzdGtleQ==".to_string(),
                ),
            ]),
        });

    let provider = builder_without_other_slots()
        .env(reqsign_azure_storage::EnvCredentialProvider::new())
        .build();
    let result = provider.provide_credential(&ctx).await.unwrap();
    assert_shared_key(result, "testaccount", "dGVzdGtleQ==");

    let provider = builder_without_other_slots().build();
    let result = provider.provide_credential(&ctx).await.unwrap();
    assert!(result.is_none());
}

#[tokio::test]
async fn test_builder_no_client_secret_removes_provider() {
    let ctx = Context::new()
        .with_file_read(TokioFileRead)
        .with_http_send(StaticHttpSend {
            status: http::StatusCode::OK,
            body: r#"{"access_token":"test-token","expires_in":3600}"#,
        })
        .with_env(StaticEnv {
            home_dir: None,
            envs: HashMap::from([
                ("AZURE_TENANT_ID".to_string(), "test-tenant".to_string()),
                ("AZURE_CLIENT_ID".to_string(), "test-client".to_string()),
                ("AZURE_CLIENT_SECRET".to_string(), "test-secret".to_string()),
                (
                    "AZURE_AUTHORITY_HOST".to_string(),
                    "https://login.microsoftonline.com".to_string(),
                ),
            ]),
        });

    let provider = builder_without_other_slots()
        .client_secret(reqsign_azure_storage::ClientSecretCredentialProvider::new())
        .build();
    let result = provider.provide_credential(&ctx).await.unwrap();
    assert_bearer_token(result, "test-token");

    let provider = builder_without_other_slots().build();
    let result = provider.provide_credential(&ctx).await.unwrap();
    assert!(result.is_none());
}
