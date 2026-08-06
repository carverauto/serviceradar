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

use reqsign_azure_storage::{Credential, WorkloadIdentityCredentialProvider};
use reqsign_core::{Context, ProvideCredential, StaticEnv};
use reqsign_file_read_tokio::TokioFileRead;
use reqsign_http_send_reqwest::ReqwestHttpSend;
use std::collections::HashMap;

fn is_test_enabled() -> bool {
    std::env::var("REQSIGN_AZURE_STORAGE_TEST_WORKLOAD_IDENTITY").unwrap_or_default() == "on"
}

#[tokio::test]
async fn test_workload_identity_provider() {
    if !is_test_enabled() {
        eprintln!("Skipping test: REQSIGN_AZURE_STORAGE_TEST_WORKLOAD_IDENTITY is not enabled");
        return;
    }

    // This test requires Kubernetes workload identity setup
    let tenant_id =
        std::env::var("AZURE_TENANT_ID").unwrap_or_else(|_| "test-tenant-id".to_string());
    let client_id =
        std::env::var("AZURE_CLIENT_ID").unwrap_or_else(|_| "test-client-id".to_string());
    let token_file = std::env::var("AZURE_FEDERATED_TOKEN_FILE")
        .unwrap_or_else(|_| "/var/run/secrets/azure/tokens/azure-identity-token".to_string());

    let ctx = Context::new()
        .with_file_read(TokioFileRead)
        .with_http_send(ReqwestHttpSend::default())
        .with_env(StaticEnv {
            home_dir: None,
            envs: HashMap::from_iter([
                ("AZURE_TENANT_ID".to_string(), tenant_id.clone()),
                ("AZURE_CLIENT_ID".to_string(), client_id.clone()),
                ("AZURE_FEDERATED_TOKEN_FILE".to_string(), token_file.clone()),
            ]),
        });

    let loader = WorkloadIdentityCredentialProvider::new();

    // This test will only succeed in a Kubernetes environment with workload identity
    let result = loader.provide_credential(&ctx).await;

    let cred = result
        .expect("Workload identity provider should succeed when test is enabled")
        .expect("Workload identity provider should return credentials when test is enabled");

    match cred {
        Credential::BearerToken {
            token,
            expires_in: _,
        } => {
            assert!(!token.is_empty());
            eprintln!("Successfully obtained bearer token from workload identity");
        }
        _ => panic!("Expected BearerToken credential from workload identity"),
    }
}

#[tokio::test]
async fn test_workload_identity_with_env() {
    // Test that provider reads from environment variables
    let tenant_id = "test-tenant-id";
    let client_id = "test-client-id";
    let token_file = "/tmp/test-token";

    let ctx = Context::new()
        .with_file_read(TokioFileRead)
        .with_http_send(ReqwestHttpSend::default())
        .with_env(StaticEnv {
            home_dir: None,
            envs: HashMap::from_iter([
                ("AZURE_TENANT_ID".to_string(), tenant_id.to_string()),
                ("AZURE_CLIENT_ID".to_string(), client_id.to_string()),
                (
                    "AZURE_FEDERATED_TOKEN_FILE".to_string(),
                    token_file.to_string(),
                ),
            ]),
        });

    // Create provider without explicit parameters
    let loader = WorkloadIdentityCredentialProvider::new();

    // The provider should pick up values from environment
    // Actual authentication will fail without valid token file
    let _ = loader.provide_credential(&ctx).await;
}
