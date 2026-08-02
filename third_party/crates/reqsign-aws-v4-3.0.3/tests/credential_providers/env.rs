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
use reqsign_aws_v4::EnvCredentialProvider;
use reqsign_core::ProvideCredential;
use std::collections::HashMap;
use std::env;

#[tokio::test]
async fn test_env_credential_provider() {
    if env::var("REQSIGN_AWS_V4_TEST_ENV").unwrap_or_default() != "on" {
        info!("REQSIGN_AWS_V4_TEST_ENV not set, skipping");
        return;
    }

    // Use AWS native environment variables
    let mut envs = HashMap::from_iter([
        (
            "AWS_ACCESS_KEY_ID".to_string(),
            env::var("AWS_ACCESS_KEY_ID").expect("AWS_ACCESS_KEY_ID must be set"),
        ),
        (
            "AWS_SECRET_ACCESS_KEY".to_string(),
            env::var("AWS_SECRET_ACCESS_KEY").expect("AWS_SECRET_ACCESS_KEY must be set"),
        ),
    ]);

    // Optional session token
    if let Ok(token) = env::var("AWS_SESSION_TOKEN") {
        envs.insert("AWS_SESSION_TOKEN".to_string(), token);
    }

    let ctx = create_test_context_with_env(envs);
    let provider = EnvCredentialProvider::new();

    let cred = provider
        .provide_credential(&ctx)
        .await
        .expect("EnvCredentialProvider should not fail");

    assert!(
        cred.is_some(),
        "Should load credentials from AWS_* env vars"
    );
    let cred = cred.unwrap();
    assert!(!cred.access_key_id.is_empty());
    assert!(!cred.secret_access_key.is_empty());
}
