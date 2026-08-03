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

use reqsign_azure_storage::{Credential, RequestSigner, StaticCredentialProvider};
use reqsign_core::{Context, OsEnv, ProvideCredential, Signer};
use reqsign_file_read_tokio::TokioFileRead;
use reqsign_http_send_reqwest::ReqwestHttpSend;

fn is_test_enabled() -> bool {
    std::env::var("REQSIGN_AZURE_STORAGE_TEST").unwrap_or_default() == "on"
}

fn get_test_config() -> Option<(String, String, String)> {
    if !is_test_enabled() {
        return None;
    }

    let url = std::env::var("REQSIGN_AZURE_STORAGE_URL").ok()?;
    let account_name = std::env::var("REQSIGN_AZURE_STORAGE_ACCOUNT_NAME").ok()?;
    let account_key = std::env::var("REQSIGN_AZURE_STORAGE_ACCOUNT_KEY").ok()?;

    Some((url, account_name, account_key))
}

#[tokio::test]
async fn test_static_provider_shared_key() {
    let Some((url, account_name, account_key)) = get_test_config() else {
        eprintln!("Skipping test: REQSIGN_AZURE_STORAGE_TEST is not enabled");
        return;
    };

    let ctx = Context::new()
        .with_file_read(TokioFileRead)
        .with_http_send(ReqwestHttpSend::default())
        .with_env(OsEnv);

    let loader = StaticCredentialProvider::new_shared_key(&account_name, &account_key);
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

    // Test signing a request
    let builder = RequestSigner::new();
    let signer = Signer::new(ctx, loader, builder);

    let mut parts = http::Request::get(&url).body(()).unwrap().into_parts().0;

    signer.sign(&mut parts, None).await.unwrap();

    // Verify Authorization header was added
    assert!(parts.headers.contains_key("authorization"));
    assert!(parts.headers.contains_key("x-ms-date"));
}

#[tokio::test]
async fn test_static_provider_sas_token() {
    if !is_test_enabled() {
        eprintln!("Skipping test: REQSIGN_AZURE_STORAGE_TEST is not enabled");
        return;
    }

    let sas_token = std::env::var("REQSIGN_AZURE_STORAGE_SAS_TOKEN").unwrap_or_else(|_| {
        // Use a dummy token for testing the provider logic
        "sv=2021-06-08&ss=b&srt=sco&sp=rwx&se=2025-01-01T00:00:00Z&sig=test".to_string()
    });

    let ctx = Context::new()
        .with_file_read(TokioFileRead)
        .with_http_send(ReqwestHttpSend::default())
        .with_env(OsEnv);

    let loader = StaticCredentialProvider::new_sas_token(&sas_token);
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
async fn test_static_provider_bearer_token() {
    let ctx = Context::new()
        .with_file_read(TokioFileRead)
        .with_http_send(ReqwestHttpSend::default())
        .with_env(OsEnv);

    let test_token = "eyJ0eXAiOiJKV1QiLCJhbGciOiJSUzI1NiJ9.test";
    let loader = StaticCredentialProvider::new_bearer_token(test_token);
    let cred = loader.provide_credential(&ctx).await.unwrap();

    assert!(cred.is_some());
    let cred = cred.unwrap();

    match cred {
        Credential::BearerToken {
            token,
            expires_in: _,
        } => {
            assert_eq!(token, test_token);
        }
        _ => panic!("Expected BearerToken credential"),
    }
}
