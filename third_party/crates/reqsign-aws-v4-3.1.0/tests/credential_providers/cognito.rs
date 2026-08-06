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

use super::create_test_context;
use log::info;
use reqsign_aws_v4::CognitoIdentityCredentialProvider;
use reqsign_core::ProvideCredential;
use std::env;

#[tokio::test]
async fn test_cognito_identity_credential_provider() {
    if env::var("REQSIGN_AWS_V4_TEST_COGNITO").unwrap_or_default() != "on" {
        info!("REQSIGN_AWS_V4_TEST_COGNITO not set, skipping");
        return;
    }

    // Provider will read configuration from environment variables:
    // - AWS_COGNITO_IDENTITY_POOL_ID
    // - AWS_REGION or AWS_DEFAULT_REGION
    // - AWS_COGNITO_ENDPOINT (for mock server)
    let ctx = create_test_context();
    let provider = CognitoIdentityCredentialProvider::new();

    let cred = provider
        .provide_credential(&ctx)
        .await
        .expect("CognitoIdentity should succeed");

    assert!(cred.is_some(), "Should load credentials from Cognito");
    let cred = cred.unwrap();
    assert!(!cred.access_key_id.is_empty());
    assert!(!cred.secret_access_key.is_empty());
    assert!(
        cred.session_token.is_some(),
        "Cognito should return session token"
    );
}
