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

use reqsign_azure_storage::{AzurePipelinesCredentialProvider, Credential};
use reqsign_core::{Context, ProvideCredential, StaticEnv};
use reqsign_file_read_tokio::TokioFileRead;
use reqsign_http_send_reqwest::ReqwestHttpSend;
use std::collections::HashMap;

fn is_test_enabled() -> bool {
    std::env::var("REQSIGN_AZURE_STORAGE_TEST_PIPELINES").unwrap_or_default() == "on"
}

#[tokio::test]
async fn test_azure_pipelines_provider() {
    if !is_test_enabled() {
        eprintln!("Skipping test: REQSIGN_AZURE_STORAGE_TEST_PIPELINES is not enabled");
        return;
    }

    // This test requires Azure Pipelines environment
    let service_connection_id = std::env::var("AZURESUBSCRIPTION_SERVICE_CONNECTION_ID")
        .unwrap_or_else(|_| "test-connection-id".to_string());
    let client_id = std::env::var("AZURESUBSCRIPTION_CLIENT_ID")
        .unwrap_or_else(|_| "test-client-id".to_string());
    let tenant_id = std::env::var("AZURESUBSCRIPTION_TENANT_ID")
        .unwrap_or_else(|_| "test-tenant-id".to_string());
    let system_oidc_uri = std::env::var("SYSTEM_OIDCREQUESTURI")
        .unwrap_or_else(|_| "https://vstoken.dev.azure.com/test".to_string());
    let system_access_token =
        std::env::var("SYSTEM_ACCESSTOKEN").unwrap_or_else(|_| "test-access-token".to_string());

    let ctx = Context::new()
        .with_file_read(TokioFileRead)
        .with_http_send(ReqwestHttpSend::default())
        .with_env(StaticEnv {
            home_dir: None,
            envs: HashMap::from_iter([
                (
                    "AZURESUBSCRIPTION_SERVICE_CONNECTION_ID".to_string(),
                    service_connection_id,
                ),
                ("AZURESUBSCRIPTION_CLIENT_ID".to_string(), client_id),
                ("AZURESUBSCRIPTION_TENANT_ID".to_string(), tenant_id),
                ("SYSTEM_OIDCREQUESTURI".to_string(), system_oidc_uri),
                ("SYSTEM_ACCESSTOKEN".to_string(), system_access_token),
            ]),
        });

    let loader = AzurePipelinesCredentialProvider::new();

    // This test will only succeed in Azure Pipelines environment
    let result = loader.provide_credential(&ctx).await;

    let cred = result
        .expect("Azure Pipelines provider should succeed when test is enabled")
        .expect("Azure Pipelines provider should return credentials when test is enabled");

    match cred {
        Credential::BearerToken {
            token,
            expires_in: _,
        } => {
            assert!(!token.is_empty());
            eprintln!("Successfully obtained bearer token from Azure Pipelines");
        }
        _ => panic!("Expected BearerToken credential from Azure Pipelines"),
    }
}
