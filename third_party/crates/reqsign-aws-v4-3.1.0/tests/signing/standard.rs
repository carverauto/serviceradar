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

use super::{init_signing_test, load_static_credential, send_signed_request};
use anyhow::Result;
use http::{Method, Request, StatusCode};
use log::warn;
use sha2::{Digest, Sha256};
use std::str::FromStr;

#[tokio::test]
async fn test_head_object() -> Result<()> {
    let Some((ctx, signer, url)) = init_signing_test() else {
        warn!("REQSIGN_AWS_V4_TEST is not set, skipped");
        return Ok(());
    };

    let cred = load_static_credential()?;

    let mut req = Request::new(String::new());
    *req.method_mut() = Method::HEAD;
    *req.uri_mut() = http::Uri::from_str(&format!("{}/{}", url, "not_exist_file"))?;

    let (status, _body) = send_signed_request(&ctx, &signer, req, &cred).await?;
    assert_eq!(StatusCode::NOT_FOUND, status);
    Ok(())
}

#[tokio::test]
async fn test_get_object() -> Result<()> {
    let Some((ctx, signer, url)) = init_signing_test() else {
        warn!("REQSIGN_AWS_V4_TEST is not set, skipped");
        return Ok(());
    };

    let cred = load_static_credential()?;

    let mut req = Request::new(String::new());
    *req.method_mut() = Method::GET;
    *req.uri_mut() = http::Uri::from_str(&format!("{}/{}", url, "not_exist_file"))?;

    let (status, _body) = send_signed_request(&ctx, &signer, req, &cred).await?;
    assert_eq!(StatusCode::NOT_FOUND, status);
    Ok(())
}

#[tokio::test]
async fn test_put_object() -> Result<()> {
    let Some((ctx, signer, url)) = init_signing_test() else {
        warn!("REQSIGN_AWS_V4_TEST is not set, skipped");
        return Ok(());
    };

    let cred = load_static_credential()?;
    let body = "Hello, World!";
    let body_digest = hex::encode(Sha256::digest(body.as_bytes()));

    let mut req = Request::new(body.to_string());
    req.headers_mut().insert(
        "x-amz-content-sha256",
        body_digest.parse().expect("parse digest failed"),
    );
    *req.method_mut() = Method::PUT;
    *req.uri_mut() = http::Uri::from_str(&format!("{}/{}", url, "put_object_test"))?;

    let (status, _body) = send_signed_request(&ctx, &signer, req, &cred).await?;
    assert_eq!(StatusCode::OK, status);
    Ok(())
}

#[tokio::test]
async fn test_list_bucket() -> Result<()> {
    let Some((ctx, signer, url)) = init_signing_test() else {
        warn!("REQSIGN_AWS_V4_TEST is not set, skipped");
        return Ok(());
    };

    let cred = load_static_credential()?;

    let mut req = Request::new(String::new());
    *req.method_mut() = Method::GET;
    *req.uri_mut() =
        http::Uri::from_str(&format!("{url}?list-type=2&delimiter=/&encoding-type=url"))?;

    let (status, _body) = send_signed_request(&ctx, &signer, req, &cred).await?;
    assert_eq!(StatusCode::OK, status);
    Ok(())
}
