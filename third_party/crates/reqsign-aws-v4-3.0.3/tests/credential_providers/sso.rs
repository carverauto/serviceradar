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
use log::info;
use reqsign_aws_v4::SSOCredentialProvider;
use reqsign_core::ProvideCredential;
use std::collections::HashMap;
use std::env;

#[tokio::test]
async fn test_sso_credential_provider() {
    if env::var("REQSIGN_AWS_V4_TEST_SSO").unwrap_or_default() != "on" {
        info!("REQSIGN_AWS_V4_TEST_SSO not set, skipping");
        return;
    }

    let mut envs = HashMap::new();

    // SSO credentials are configured in AWS profile
    if let Ok(profile) = env::var("AWS_PROFILE") {
        envs.insert("AWS_PROFILE".to_string(), profile);
    }

    if let Ok(config_file) = env::var("AWS_CONFIG_FILE") {
        envs.insert("AWS_CONFIG_FILE".to_string(), config_file);
    }

    // Allow custom SSO endpoint for testing
    if let Ok(endpoint) = env::var("AWS_SSO_ENDPOINT") {
        envs.insert("AWS_SSO_ENDPOINT".to_string(), endpoint);
    }

    let ctx = create_test_context_with_env(envs);
    let provider = SSOCredentialProvider::new();

    let cred = provider
        .provide_credential(&ctx)
        .await
        .expect("SSOCredentialProvider should succeed");

    assert!(cred.is_some(), "Should load credentials from SSO");
    let cred = cred.unwrap();
    assert!(!cred.access_key_id.is_empty());
    assert!(!cred.secret_access_key.is_empty());
}
