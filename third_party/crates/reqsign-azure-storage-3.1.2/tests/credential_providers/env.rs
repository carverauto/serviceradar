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

use reqsign_azure_storage::{Credential, EnvCredentialProvider};
use reqsign_core::{Context, ProvideCredential, StaticEnv};
use reqsign_file_read_tokio::TokioFileRead;
use reqsign_http_send_reqwest::ReqwestHttpSend;
use std::collections::HashMap;

fn is_test_enabled() -> bool {
    std::env::var("REQSIGN_AZURE_STORAGE_TEST_ENV").unwrap_or_default() == "on"
}

#[tokio::test]
async fn test_env_provider_shared_key() {
    if !is_test_enabled() {
        eprintln!("Skipping test: REQSIGN_AZURE_STORAGE_TEST_ENV is not enabled");
        return;
    }

    let account_name = std::env::var("AZURE_STORAGE_ACCOUNT_NAME")
        .or_else(|_| std::env::var("REQSIGN_AZURE_STORAGE_ACCOUNT_NAME"))
        .unwrap_or_else(|_| "testaccount".to_string());

    let account_key = std::env::var("AZURE_STORAGE_ACCOUNT_KEY")
        .or_else(|_| std::env::var("REQSIGN_AZURE_STORAGE_ACCOUNT_KEY"))
        .unwrap_or_else(|_| "dGVzdGtleQ==".to_string());

    let ctx = Context::new()
        .with_file_read(TokioFileRead)
        .with_http_send(ReqwestHttpSend::default())
        .with_env(StaticEnv {
            home_dir: None,
            envs: HashMap::from_iter([
                (
                    "AZURE_STORAGE_ACCOUNT_NAME".to_string(),
                    account_name.clone(),
                ),
                ("AZURE_STORAGE_ACCOUNT_KEY".to_string(), account_key.clone()),
            ]),
        });

    let loader = EnvCredentialProvider::new();
    let cred = loader.provide_credential(&ctx).await.unwrap();

    assert!(cred.is_some());
    let cred = cred.unwrap();

    match cred {
        Credential::SharedKey {
            account_name: name,
            account_key: key,
        } => {
            assert_eq!(name, account_name);
            assert_eq!(key, account_key);
        }
        _ => panic!("Expected SharedKey credential"),
    }
}

#[tokio::test]
async fn test_env_provider_sas_token() {
    let sas_token = "sv=2021-06-08&ss=b&srt=sco&sp=rwx&se=2025-01-01T00:00:00Z&sig=test";

    let ctx = Context::new()
        .with_file_read(TokioFileRead)
        .with_http_send(ReqwestHttpSend::default())
        .with_env(StaticEnv {
            home_dir: None,
            envs: HashMap::from_iter([(
                "AZURE_STORAGE_SAS_TOKEN".to_string(),
                sas_token.to_string(),
            )]),
        });

    let loader = EnvCredentialProvider::new();
    let cred = loader.provide_credential(&ctx).await.unwrap();

    assert!(cred.is_some());
    let cred = cred.unwrap();

    match cred {
        Credential::SasToken { token } => {
            assert_eq!(token, sas_token);
        }
        _ => panic!("Expected SasToken credential"),
    }
}

#[tokio::test]
async fn test_env_provider_priority() {
    // Test that SharedKey takes priority over SAS token
    let account_name = "testaccount";
    let account_key = "dGVzdGtleQ==";
    let sas_token = "sv=2021-06-08&ss=b&srt=sco&sp=rwx&se=2025-01-01T00:00:00Z&sig=test";

    let ctx = Context::new()
        .with_file_read(TokioFileRead)
        .with_http_send(ReqwestHttpSend::default())
        .with_env(StaticEnv {
            home_dir: None,
            envs: HashMap::from_iter([
                (
                    "AZURE_STORAGE_ACCOUNT_NAME".to_string(),
                    account_name.to_string(),
                ),
                (
                    "AZURE_STORAGE_ACCOUNT_KEY".to_string(),
                    account_key.to_string(),
                ),
                ("AZURE_STORAGE_SAS_TOKEN".to_string(), sas_token.to_string()),
            ]),
        });

    let loader = EnvCredentialProvider::new();
    let cred = loader.provide_credential(&ctx).await.unwrap();

    assert!(cred.is_some());
    let cred = cred.unwrap();

    // Should prefer SharedKey when both are available
    match cred {
        Credential::SharedKey { .. } => {
            // Expected
        }
        _ => panic!("Expected SharedKey credential to take priority"),
    }
}

#[tokio::test]
async fn test_env_provider_no_credentials() {
    let ctx = Context::new()
        .with_file_read(TokioFileRead)
        .with_http_send(ReqwestHttpSend::default())
        .with_env(StaticEnv {
            home_dir: None,
            envs: HashMap::new(),
        });

    let loader = EnvCredentialProvider::new();
    let cred = loader.provide_credential(&ctx).await.unwrap();

    assert!(cred.is_none());
}
