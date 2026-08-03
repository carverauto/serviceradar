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

async fn init_signer() -> Option<(Context, Signer<Credential>)> {
    let _ = env_logger::builder().is_test(true).try_init();
    let _ = dotenvy::dotenv();

    if env::var("REQSIGN_GOOGLE_TEST").unwrap_or_default() != "on" {
        return None;
    }

    let credential_content =
        env::var("REQSIGN_GOOGLE_CREDENTIAL").expect("env REQSIGN_GOOGLE_CREDENTIAL must be set");
    let scope = env::var("REQSIGN_GOOGLE_CLOUD_STORAGE_SCOPE")
        .expect("env REQSIGN_GOOGLE_CLOUD_STORAGE_SCOPE must be set");

    let loader = StaticCredentialProvider::from_base64(credential_content)
        .expect("credential must be valid base64")
        .with_scope(&scope);
    let builder = RequestSigner::new("storage").with_scope(&scope);

    let ctx = Context::new()
        .with_file_read(TokioFileRead)
        .with_http_send(ReqwestHttpSend::default())
        .with_env(OsEnv);
    let signer = Signer::new(ctx.clone(), loader, builder);
    Some((ctx, signer))
}

#[tokio::test]
async fn test_get_object() -> Result<()> {
    let Some((_ctx, signer)) = init_signer().await else {
        warn!("REQSIGN_GOOGLE_TEST is not set, skipped");
        return Ok(());
    };

    let url = &env::var("REQSIGN_GOOGLE_CLOUD_STORAGE_URL")
        .expect("env REQSIGN_GOOGLE_CLOUD_STORAGE_URL must set");

    let mut builder = http::Request::builder();
    builder = builder.method(http::Method::GET);
    builder = builder.uri(format!("{}/o/{}", url, "not_exist_file"));
    let req = builder.body("").map_err(|e| {
        reqsign_core::Error::unexpected("failed to build HTTP request").with_source(e)
    })?;

    let (mut parts, body) = req.into_parts();
    signer
        .sign(&mut parts, None)
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

    debug!("got response: {resp:?}");
    assert_eq!(StatusCode::NOT_FOUND, resp.status());
    Ok(())
}

#[tokio::test]
async fn test_list_objects() -> Result<()> {
    let Some((_ctx, signer)) = init_signer().await else {
        warn!("REQSIGN_GOOGLE_TEST is not set, skipped");
        return Ok(());
    };

    let url = &env::var("REQSIGN_GOOGLE_CLOUD_STORAGE_URL")
        .expect("env REQSIGN_GOOGLE_CLOUD_STORAGE_URL must set");

    let mut builder = http::Request::builder();
    builder = builder.method(http::Method::GET);
    builder = builder.uri(format!("{url}/o"));
    let req = builder.body("").map_err(|e| {
        reqsign_core::Error::unexpected("failed to build HTTP request").with_source(e)
    })?;

    let (mut parts, body) = req.into_parts();
    signer
        .sign(&mut parts, None)
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

    debug!("got response: {resp:?}");
    assert_eq!(StatusCode::OK, resp.status());
    Ok(())
}
