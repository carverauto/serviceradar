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

use super::{init_signing_test, load_static_credential};
use anyhow::Result;
use http::{Method, Request, StatusCode};
use log::{debug, warn};
use reqsign_core::SignRequest;
use reqwest::Client;
use std::str::FromStr;
use std::time::Duration;

#[tokio::test]
async fn test_get_object_with_presigned_url() -> Result<()> {
    let Some((ctx, signer, url)) = init_signing_test() else {
        warn!("REQSIGN_AWS_V4_TEST is not set, skipped");
        return Ok(());
    };

    let cred = load_static_credential()?;

    let mut req = Request::new(String::new());
    *req.method_mut() = Method::GET;
    *req.uri_mut() = http::Uri::from_str(&format!("{}/{}", url, "not_exist_file"))?;

    // Sign with expiration time
    let (mut parts, body) = req.into_parts();
    signer
        .sign_request(
            &ctx,
            &mut parts,
            Some(&cred),
            Some(Duration::from_secs(3600)),
        )
        .await
        .expect("sign request must succeed");
    let req = Request::from_parts(parts, body);

    debug!("presigned request: {req:?}");

    // Send the presigned request
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

    debug!("got response: {resp:?}");
    assert_eq!(StatusCode::NOT_FOUND, resp.status());
    Ok(())
}

#[tokio::test]
async fn test_put_object_with_presigned_url() -> Result<()> {
    let Some((ctx, signer, url)) = init_signing_test() else {
        warn!("REQSIGN_AWS_V4_TEST is not set, skipped");
        return Ok(());
    };

    let cred = load_static_credential()?;

    let mut req = Request::new(String::new());
    *req.method_mut() = Method::PUT;
    *req.uri_mut() = http::Uri::from_str(&format!("{}/{}", url, "presigned_put_test"))?;

    // Sign with expiration time
    let (mut parts, body) = req.into_parts();
    signer
        .sign_request(
            &ctx,
            &mut parts,
            Some(&cred),
            Some(Duration::from_secs(300)),
        )
        .await
        .expect("sign request must succeed");
    let req = Request::from_parts(parts, body);

    debug!("presigned PUT request: {req:?}");

    // The presigned URL can be used later to upload content
    // For this test, we just verify the URL is properly signed
    assert!(req.uri().query().is_some());
    assert!(req.uri().query().unwrap().contains("X-Amz-Signature"));
    assert!(req.uri().query().unwrap().contains("X-Amz-Expires"));
    Ok(())
}
