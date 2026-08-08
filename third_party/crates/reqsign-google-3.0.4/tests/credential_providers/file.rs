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
use reqsign_core::{ProvideCredential, Result};
use reqsign_google::FileCredentialProvider;
use std::env;

#[tokio::test]
async fn test_file_credential_provider() -> Result<()> {
    let path = format!(
        "{}/testdata/test_credential.json",
        env::current_dir()
            .expect("current_dir must exist")
            .to_string_lossy()
    );

    let ctx = create_test_context();
    let provider = FileCredentialProvider::new(path);

    let credential = provider
        .provide_credential(&ctx)
        .await?
        .expect("credential must be provided");

    assert!(credential.has_service_account());
    let sa = credential.service_account.as_ref().unwrap();
    assert_eq!("test-234@test.iam.gserviceaccount.com", sa.client_email);

    Ok(())
}

#[tokio::test]
async fn test_file_credential_provider_missing_file() {
    let path = format!(
        "{}/testdata/does-not-exist.json",
        env::current_dir()
            .expect("current_dir must exist")
            .to_string_lossy()
    );

    let ctx = create_test_context();
    let provider = FileCredentialProvider::new(path);

    let err = provider
        .provide_credential(&ctx)
        .await
        .expect_err("missing file must fail");
    assert_eq!(reqsign_core::ErrorKind::Unexpected, err.kind());
}
