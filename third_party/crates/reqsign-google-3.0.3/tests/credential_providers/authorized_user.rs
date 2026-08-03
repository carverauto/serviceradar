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
async fn test_authorized_user_credential_provider() -> Result<()> {
    if env::var("REQSIGN_GOOGLE_TEST_AUTHORIZED_USER").unwrap_or_default() != "on" {
        warn!("REQSIGN_GOOGLE_TEST_AUTHORIZED_USER is not set, skipped");
        return Ok(());
    }

    // This test requires a valid authorized user credential file
    // It can be created with: gcloud auth application-default login
    let cred_path = env::var("REQSIGN_GOOGLE_AUTHORIZED_USER_CREDENTIALS")
        .expect("REQSIGN_GOOGLE_AUTHORIZED_USER_CREDENTIALS must be set for this test");

    // Verify the file exists and is an authorized_user type
    let content = std::fs::read_to_string(&cred_path)
        .expect("Failed to read authorized user credential file");
    assert!(
        content.contains(r#""type": "authorized_user""#),
        "Credential file must be authorized_user type"
    );

    let ctx = create_test_context_with_env(HashMap::from_iter([(
        "GOOGLE_APPLICATION_CREDENTIALS".to_string(),
        cred_path,
    )]));

    let provider = DefaultCredentialProvider::new();
    let credential = provider
        .provide_credential(&ctx)
        .await?
        .expect("credential must be provided for authorized user");

    // Authorized user credentials should have a token
    assert!(credential.has_token(), "Must have access token");
    assert!(credential.has_valid_token(), "Token must be valid");
    assert!(
        !credential.has_service_account(),
        "Should not have service account"
    );

    Ok(())
}

#[tokio::test]
async fn test_authorized_user_from_well_known_location() -> Result<()> {
    if env::var("REQSIGN_GOOGLE_TEST_AUTHORIZED_USER_GCLOUD").unwrap_or_default() != "on" {
        warn!("REQSIGN_GOOGLE_TEST_AUTHORIZED_USER_GCLOUD is not set, skipped");
        return Ok(());
    }

    // This test requires gcloud CLI to be configured with application-default credentials
    let home = env::var("HOME").expect("HOME must be set");
    let gcloud_cred_path = format!("{home}/.config/gcloud/application_default_credentials.json");

    // Verify the file exists and is an authorized_user type
    let content = std::fs::read_to_string(&gcloud_cred_path)
        .expect("gcloud application-default credentials must exist");
    assert!(
        content.contains(r#""type": "authorized_user""#),
        "gcloud credentials must be authorized_user type"
    );

    // Don't set GOOGLE_APPLICATION_CREDENTIALS so it falls back to well-known location
    let ctx = create_test_context_with_env(HashMap::new());

    let provider = DefaultCredentialProvider::new();
    let credential = provider
        .provide_credential(&ctx)
        .await?
        .expect("credential must be provided from well-known location");

    assert!(credential.has_token(), "Must have access token");
    assert!(credential.has_valid_token(), "Token must be valid");
    assert!(
        !credential.has_service_account(),
        "Should not have service account"
    );

    Ok(())
}
