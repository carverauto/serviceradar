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

use reqsign_azure_storage::{ClientSecretCredentialProvider, Credential};
use reqsign_core::{Context, OsEnv, ProvideCredential};
use reqsign_file_read_tokio::TokioFileRead;
use reqsign_http_send_reqwest::ReqwestHttpSend;

fn is_test_enabled() -> bool {
    std::env::var("REQSIGN_AZURE_STORAGE_TEST_CLIENT_SECRET").unwrap_or_default() == "on"
}

#[tokio::test]
async fn test_client_secret_provider() {
    if !is_test_enabled() {
        eprintln!("Skipping test: REQSIGN_AZURE_STORAGE_TEST_CLIENT_SECRET is not enabled");
        return;
    }

    let _tenant_id = std::env::var("AZURE_TENANT_ID")
        .expect("AZURE_TENANT_ID must be set for client secret test");
    let _client_id = std::env::var("AZURE_CLIENT_ID")
        .expect("AZURE_CLIENT_ID must be set for client secret test");
    let _client_secret = std::env::var("AZURE_CLIENT_SECRET")
        .expect("AZURE_CLIENT_SECRET must be set for client secret test");

    let ctx = Context::new()
        .with_file_read(TokioFileRead)
        .with_http_send(ReqwestHttpSend::default())
        .with_env(OsEnv);

    let loader = ClientSecretCredentialProvider::new();
    let result = loader.provide_credential(&ctx).await;

    // Better error reporting
    let cred = match result {
        Ok(Some(cred)) => cred,
        Ok(None) => panic!("Client secret provider returned None when test is enabled"),
        Err(e) => panic!("Client secret provider failed with error: {e:?}\nError details: {e}"),
    };

    match cred {
        Credential::BearerToken {
            token,
            expires_in: _,
        } => {
            assert!(!token.is_empty());
            // Token should be a valid JWT
            assert!(token.starts_with("eyJ"));
            eprintln!("Successfully obtained bearer token using client secret");
        }
        _ => panic!("Expected BearerToken credential from client secret provider"),
    }
}
