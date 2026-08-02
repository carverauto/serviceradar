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

use super::create_test_context_with_env;
use log::warn;
use reqsign_core::{ProvideCredential, Result};
use reqsign_google::DefaultCredentialProvider;
use std::collections::HashMap;
use std::env;

#[tokio::test]
async fn test_external_account_credential_provider() -> Result<()> {
    if env::var("REQSIGN_GOOGLE_TEST_EXTERNAL_ACCOUNT").unwrap_or_default() != "on" {
        warn!("REQSIGN_GOOGLE_TEST_EXTERNAL_ACCOUNT is not set, skipped");
        return Ok(());
    }

    // This test requires a valid external account credential file
    let cred_path = env::var("REQSIGN_GOOGLE_EXTERNAL_ACCOUNT_CREDENTIALS")
        .expect("REQSIGN_GOOGLE_EXTERNAL_ACCOUNT_CREDENTIALS must be set for this test");

    // Verify the file exists and is an external_account type
    let content = std::fs::read_to_string(&cred_path)
        .expect("Failed to read external account credential file");
    assert!(
        content.contains(r#""type": "external_account""#),
        "Credential file must be external_account type"
    );

    let ctx = create_test_context_with_env(HashMap::from_iter([
        ("GOOGLE_APPLICATION_CREDENTIALS".to_string(), cred_path),
        (
            "GOOGLE_SCOPE".to_string(),
            "https://www.googleapis.com/auth/devstorage.read_write".to_string(),
        ),
    ]));

    let provider = DefaultCredentialProvider::new();

    let credential = provider
        .provide_credential(&ctx)
        .await?
        .expect("credential must be provided for external account");

    assert!(credential.has_token(), "Must have access token");
    assert!(credential.has_valid_token(), "Token must be valid");
    assert!(
        !credential.has_service_account(),
        "Should not have service account"
    );

    Ok(())
}

#[tokio::test]
async fn test_external_account_with_workload_identity() -> Result<()> {
    if env::var("REQSIGN_GOOGLE_TEST_WORKLOAD_IDENTITY").unwrap_or_default() != "on" {
        warn!("REQSIGN_GOOGLE_TEST_WORKLOAD_IDENTITY is not set, skipped");
        return Ok(());
    }

    // This test is for real workload identity scenarios (e.g., GitHub Actions, Kubernetes)
    // It requires a properly configured external account credential file
    let cred_path = env::var("GOOGLE_APPLICATION_CREDENTIALS")
        .expect("GOOGLE_APPLICATION_CREDENTIALS must be set for workload identity test");

    // Verify the file is an external account type
    let content = std::fs::read_to_string(&cred_path).expect("Failed to read credential file");
    assert!(
        content.contains(r#""type": "external_account""#),
        "Credential file must be external_account type for workload identity"
    );

    let ctx = create_test_context_with_env(HashMap::from_iter([
        ("GOOGLE_APPLICATION_CREDENTIALS".to_string(), cred_path),
        (
            "GOOGLE_SCOPE".to_string(),
            "https://www.googleapis.com/auth/devstorage.read_write".to_string(),
        ),
    ]));

    let provider = DefaultCredentialProvider::new();

    let credential = provider
        .provide_credential(&ctx)
        .await?
        .expect("credential must be provided for workload identity");

    assert!(credential.has_token(), "Must have access token");
    assert!(credential.has_valid_token(), "Token must be valid");
    assert!(
        !credential.has_service_account(),
        "Should not have service account"
    );

    Ok(())
}
