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
use reqsign_aws_v4::{DefaultCredentialProvider, S3ExpressSessionProvider};
use reqsign_core::ProvideCredential;
use std::env;

#[tokio::test]
async fn test_s3_express_session_provider() {
    if env::var("REQSIGN_AWS_V4_TEST_S3_EXPRESS").unwrap_or_default() != "on" {
        info!("REQSIGN_AWS_V4_TEST_S3_EXPRESS not set, skipping");
        return;
    }

    let bucket = env::var("REQSIGN_AWS_V4_S3_EXPRESS_BUCKET")
        .expect("REQSIGN_AWS_V4_S3_EXPRESS_BUCKET must be set for S3 Express test");

    let ctx = create_test_context();
    let base_provider = DefaultCredentialProvider::new();
    let provider = S3ExpressSessionProvider::new(bucket, base_provider);

    let cred = provider
        .provide_credential(&ctx)
        .await
        .expect("S3ExpressSessionProvider should not fail");

    assert!(
        cred.is_some(),
        "S3ExpressSessionProvider should return credentials"
    );
    let cred = cred.unwrap();
    assert!(!cred.access_key_id.is_empty());
    assert!(!cred.secret_access_key.is_empty());
    assert!(
        cred.session_token.is_some(),
        "S3 Express session should include session token"
    );
    assert!(
        cred.expires_in.is_some(),
        "S3 Express session should have expiration"
    );
}
