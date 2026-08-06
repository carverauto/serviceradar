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

mod presigned;
mod special_chars;
mod standard;

use anyhow::Result;
use http::{Request, StatusCode};
use log::debug;
use reqsign_aws_v4::{Credential, RequestSigner};
use reqsign_core::{Context, SignRequest};
use reqsign_file_read_tokio::TokioFileRead;
use reqsign_http_send_reqwest::ReqwestHttpSend;
use reqwest::Client;
use std::env;

/// Load static credential from environment variables
pub fn load_static_credential() -> Result<Credential> {
    let access_key =
        env::var("REQSIGN_AWS_V4_ACCESS_KEY").expect("REQSIGN_AWS_V4_ACCESS_KEY must be set");
    let secret_key =
        env::var("REQSIGN_AWS_V4_SECRET_KEY").expect("REQSIGN_AWS_V4_SECRET_KEY must be set");
    let session_token = env::var("REQSIGN_AWS_V4_SESSION_TOKEN").ok();

    Ok(Credential {
        access_key_id: access_key,
        secret_access_key: secret_key,
        session_token,
        expires_in: None,
    })
}

/// Initialize test environment
pub fn init_signing_test() -> Option<(Context, RequestSigner, String)> {
    let _ = env_logger::builder().is_test(true).try_init();
    let _ = dotenvy::dotenv();

    if env::var("REQSIGN_AWS_V4_TEST").is_err() || env::var("REQSIGN_AWS_V4_TEST").unwrap() != "on"
    {
        return None;
    }

    let region = env::var("REQSIGN_AWS_V4_REGION").expect("REQSIGN_AWS_V4_REGION must be set");
    let service = env::var("REQSIGN_AWS_V4_SERVICE").unwrap_or_else(|_| "s3".to_string());
    let url = env::var("REQSIGN_AWS_V4_URL").expect("REQSIGN_AWS_V4_URL must be set");

    let context = Context::new()
        .with_file_read(TokioFileRead)
        .with_http_send(ReqwestHttpSend::default());
    let signer = RequestSigner::new(&service, &region);

    Some((context, signer, url))
}

/// Send signed request and return response
pub async fn send_signed_request(
    ctx: &Context,
    signer: &RequestSigner,
    req: Request<String>,
    cred: &Credential,
) -> Result<(StatusCode, String)> {
    let (mut parts, body) = req.into_parts();
    signer
        .sign_request(ctx, &mut parts, Some(cred), None)
        .await
        .expect("sign request must succeed");
    let req = Request::from_parts(parts, body);

    debug!("signed request: {req:?}");

    let client = Client::new();
    let resp = client
        .execute(req.try_into().map_err(|e| {
            reqsign_core::Error::unexpected("failed to convert request")
                .with_source(anyhow::Error::new(e))
        })?)
        .await
        .map_err(|e| {
            reqsign_core::Error::unexpected("failed to execute request")
                .with_source(anyhow::Error::new(e))
        })?;

    let status = resp.status();
    let body = resp.text().await.map_err(|e| {
        reqsign_core::Error::unexpected("failed to get response body")
            .with_source(anyhow::Error::new(e))
    })?;

    debug!("response status: {status}, body: {body}");
    Ok((status, body))
}
