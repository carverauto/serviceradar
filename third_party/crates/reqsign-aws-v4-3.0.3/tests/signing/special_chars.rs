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
use percent_encoding::{NON_ALPHANUMERIC, utf8_percent_encode};
use std::str::FromStr;

#[tokio::test]
async fn test_head_object_with_special_characters() -> Result<()> {
    let Some((ctx, signer, url)) = init_signing_test() else {
        warn!("REQSIGN_AWS_V4_TEST is not set, skipped");
        return Ok(());
    };

    let cred = load_static_credential()?;

    let mut req = Request::new(String::new());
    *req.method_mut() = Method::HEAD;
    *req.uri_mut() = http::Uri::from_str(&format!(
        "{}/{}",
        url,
        utf8_percent_encode("!@#$%^&*()_+-=;:'><,/?.txt", NON_ALPHANUMERIC)
    ))?;

    let (status, _body) = send_signed_request(&ctx, &signer, req, &cred).await?;
    assert_eq!(StatusCode::NOT_FOUND, status);
    Ok(())
}

#[tokio::test]
async fn test_head_object_with_encoded_characters() -> Result<()> {
    let Some((ctx, signer, url)) = init_signing_test() else {
        warn!("REQSIGN_AWS_V4_TEST is not set, skipped");
        return Ok(());
    };

    let cred = load_static_credential()?;

    let mut req = Request::new(String::new());
    *req.method_mut() = Method::HEAD;
    *req.uri_mut() = http::Uri::from_str(&format!(
        "{}/{}",
        url,
        utf8_percent_encode("test file with spaces.txt", NON_ALPHANUMERIC)
    ))?;

    let (status, _body) = send_signed_request(&ctx, &signer, req, &cred).await?;
    assert_eq!(StatusCode::NOT_FOUND, status);
    Ok(())
}

#[tokio::test]
async fn test_object_with_unicode_characters() -> Result<()> {
    let Some((ctx, signer, url)) = init_signing_test() else {
        warn!("REQSIGN_AWS_V4_TEST is not set, skipped");
        return Ok(());
    };

    let cred = load_static_credential()?;

    let mut req = Request::new(String::new());
    *req.method_mut() = Method::HEAD;
    *req.uri_mut() = http::Uri::from_str(&format!(
        "{}/{}",
        url,
        utf8_percent_encode("文件名.txt", NON_ALPHANUMERIC)
    ))?;

    let (status, _body) = send_signed_request(&ctx, &signer, req, &cred).await?;
    assert_eq!(StatusCode::NOT_FOUND, status);
    Ok(())
}
