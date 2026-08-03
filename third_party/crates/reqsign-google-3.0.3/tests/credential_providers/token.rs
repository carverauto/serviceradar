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
use reqsign_core::time::Timestamp;
use reqsign_core::{ErrorKind, ProvideCredential, Result};
use reqsign_google::TokenCredentialProvider;
use std::fs;
use std::path::PathBuf;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

fn temp_token_file() -> PathBuf {
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .expect("system time must be after unix epoch")
        .as_nanos();

    std::env::temp_dir().join(format!("reqsign-google-token-{nanos}.txt"))
}

#[tokio::test]
async fn test_token_credential_provider_inline() -> Result<()> {
    let ctx = create_test_context();
    let expires_at = Timestamp::now() + Duration::from_secs(3600);
    let provider = TokenCredentialProvider::new("test-access-token").with_expires_at(expires_at);

    let credential = provider
        .provide_credential(&ctx)
        .await?
        .expect("credential must be provided");

    assert!(credential.has_token());
    assert!(credential.has_valid_token());

    let token = credential.token.as_ref().unwrap();
    assert_eq!("test-access-token", token.access_token);
    assert_eq!(Some(expires_at), token.expires_at);

    Ok(())
}

#[tokio::test]
async fn test_token_credential_provider_from_path() -> Result<()> {
    let path = temp_token_file();
    fs::write(&path, "test-access-token\n").expect("token file must be written");

    let ctx = create_test_context();
    let provider = TokenCredentialProvider::from_path(path.to_string_lossy())
        .with_expires_in(Duration::from_secs(3600));

    let credential = provider
        .provide_credential(&ctx)
        .await?
        .expect("credential must be provided");

    fs::remove_file(&path).expect("token file must be removed");

    assert!(credential.has_token());
    assert!(credential.has_valid_token());

    let token = credential.token.as_ref().unwrap();
    assert_eq!("test-access-token", token.access_token);
    assert!(token.expires_at.is_some());

    Ok(())
}

#[tokio::test]
async fn test_token_credential_provider_empty_token() {
    let ctx = create_test_context();
    let provider = TokenCredentialProvider::new("   ");

    let err = provider
        .provide_credential(&ctx)
        .await
        .expect_err("empty token must fail");
    assert_eq!(ErrorKind::CredentialInvalid, err.kind());
}
