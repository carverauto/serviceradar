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

use http::StatusCode;
use log::{debug, warn};
use reqsign_core::{Context, OsEnv, Result, Signer};
use reqsign_file_read_tokio::TokioFileRead;
use reqsign_google::{Credential, RequestSigner, StaticCredentialProvider};
use reqsign_http_send_reqwest::ReqwestHttpSend;
use reqwest::Client;
use std::env;
use std::time::Duration;

async fn init_signer_for_signed_url() -> Option<(Context, Signer<Credential>)> {
    let _ = env_logger::builder().is_test(true).try_init();
    let _ = dotenvy::dotenv();

    if env::var("REQSIGN_GOOGLE_TEST").unwrap_or_default() != "on" {
        return None;
    }

    let credential_content =
        env::var("REQSIGN_GOOGLE_CREDENTIAL").expect("env REQSIGN_GOOGLE_CREDENTIAL must be set");

    // Don't set scope for signed URL generation
    let loader = StaticCredentialProvider::from_base64(credential_content)
        .expect("credential must be valid base64");
    let builder = RequestSigner::new("storage");

    let ctx = Context::new()
        .with_file_read(TokioFileRead)
        .with_http_send(ReqwestHttpSend::default())
        .with_env(OsEnv);
    let signer = Signer::new(ctx.clone(), loader, builder);
    Some((ctx, signer))
}

#[tokio::test]
async fn test_get_object_with_signed_url() -> Result<()> {
    let Some((_ctx, signer)) = init_signer_for_signed_url().await else {
        warn!("REQSIGN_GOOGLE_TEST is not set, skipped");
        return Ok(());
    };

    let url = &env::var("REQSIGN_GOOGLE_CLOUD_STORAGE_URL")
        .expect("env REQSIGN_GOOGLE_CLOUD_STORAGE_URL must set");

    let mut builder = http::Request::builder();
    builder = builder.method(http::Method::GET);
    builder = builder.uri(format!(
        "{}/{}",
        url.replace("storage/v1/b/", ""),
        "not_exist_file"
    ));
    let req = builder.body("").map_err(|e| {
        reqsign_core::Error::unexpected("failed to build HTTP request").with_source(e)
    })?;

    let (mut parts, body) = req.into_parts();
    signer
        .sign(&mut parts, Some(Duration::from_secs(3600)))
        .await
        .expect("sign request must success");
    let req = http::Request::from_parts(parts, body);

    debug!("signed request: {req:?}");

    let client = Client::new();
    let resp = client
        .execute(req.try_into().map_err(|e| {
            reqsign_core::Error::unexpected("failed to convert request").with_source(e)
        })?)
        .await
        .expect("request must succeed");

    let code = resp.status();
    debug!("got response: {resp:?}");
    debug!(
        "got body: {}",
        resp.text().await.map_err(|e| {
            reqsign_core::Error::unexpected("failed to read response body").with_source(e)
        })?
    );
    assert_eq!(StatusCode::NOT_FOUND, code);
    Ok(())
}

#[tokio::test]
async fn test_create_signed_url_for_upload() -> Result<()> {
    let Some((_ctx, signer)) = init_signer_for_signed_url().await else {
        warn!("REQSIGN_GOOGLE_TEST is not set, skipped");
        return Ok(());
    };

    let url = &env::var("REQSIGN_GOOGLE_CLOUD_STORAGE_URL")
        .expect("env REQSIGN_GOOGLE_CLOUD_STORAGE_URL must set");

    // Create a signed URL for PUT operation
    let mut builder = http::Request::builder();
    builder = builder.method(http::Method::PUT);
    builder = builder.uri(format!(
        "{}/{}",
        url.replace("storage/v1/b/", ""),
        "test_upload_file"
    ));
    builder = builder.header("content-type", "text/plain");
    builder = builder.header("content-length", "13");
    let req = builder.body("Hello, World!").map_err(|e| {
        reqsign_core::Error::unexpected("failed to build HTTP request").with_source(e)
    })?;

    let (mut parts, _body) = req.into_parts();
    signer
        .sign(&mut parts, Some(Duration::from_secs(3600)))
        .await
        .expect("sign request must success");

    // The signed URL is in the parts.uri
    debug!("signed upload URL: {:?}", parts.uri);

    // Verify the URL contains expected query parameters
    let query = parts
        .uri
        .query()
        .expect("signed URL must have query params");
    assert!(query.contains("X-Goog-Algorithm="));
    assert!(query.contains("X-Goog-Credential="));
    assert!(query.contains("X-Goog-Date="));
    assert!(query.contains("X-Goog-Expires="));
    assert!(query.contains("X-Goog-SignedHeaders="));
    assert!(query.contains("X-Goog-Signature="));

    Ok(())
}
