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

//! Reqwest-based HTTP client implementation for reqsign.
//!
//! This crate provides `ReqwestHttpSend`, an HTTP client that implements
//! the `HttpSend` trait from `reqsign_core` using the popular reqwest library.
//!
//! ## Overview
//!
//! `ReqwestHttpSend` enables reqsign to send HTTP requests using reqwest's
//! powerful and feature-rich HTTP client. It handles the conversion between
//! standard `http` types and reqwest's types seamlessly.
//!
//! ## Example
//!
//! ```no_run
//! use reqsign_core::Context;
//! use reqsign_http_send_reqwest::ReqwestHttpSend;
//! use reqwest::Client;
//!
//! #[tokio::main]
//! async fn main() {
//!     // Use default client
//!     let ctx = Context::new()
//!         .with_http_send(ReqwestHttpSend::default());
//!
//!     // Or use a custom configured client
//!     let client = Client::builder()
//!         .timeout(std::time::Duration::from_secs(30))
//!         .build()
//!         .unwrap();
//!
//!     let ctx = Context::new()
//!         .with_http_send(ReqwestHttpSend::new(client));
//! }
//! ```
//!
//! ## Usage with Service Signers
//!
//! ```no_run
//! use reqsign_core::{Context, Signer};
//! use reqsign_http_send_reqwest::ReqwestHttpSend;
//! use bytes::Bytes;
//!
//! # async fn example() -> anyhow::Result<()> {
//! // Create context with reqwest HTTP client
//! let ctx = Context::new()
//!     .with_http_send(ReqwestHttpSend::default());
//!
//! // The context can send HTTP requests
//! let req = http::Request::builder()
//!     .method("GET")
//!     .uri("https://api.example.com")
//!     .body(Bytes::new())?;
//!
//! let resp = ctx.http_send(req).await?;
//! println!("Response status: {}", resp.status());
//! # Ok(())
//! # }
//! ```
//!
//! ## Custom Client Configuration
//!
//! ```no_run
//! use reqsign_http_send_reqwest::ReqwestHttpSend;
//! use reqwest::Client;
//! use std::time::Duration;
//!
//! // Configure reqwest client with custom settings
//! let client = Client::builder()
//!     .timeout(Duration::from_secs(60))
//!     .pool_max_idle_per_host(10)
//!     .user_agent("my-app/1.0")
//!     .build()
//!     .unwrap();
//!
//! // Use the custom client
//! let http_send = ReqwestHttpSend::new(client);
//! ```
use bytes::Bytes;
#[cfg(target_arch = "wasm32")]
use futures_channel::oneshot;
#[cfg(not(target_arch = "wasm32"))]
use http_body_util::BodyExt;
use reqsign_core::{Error, HttpSend, Result};
use reqwest::{Client, Request};
#[cfg(target_arch = "wasm32")]
use wasm_bindgen_futures::spawn_local;

/// Reqwest-based implementation of the `HttpSend` trait.
///
/// This struct wraps a `reqwest::Client` and provides HTTP request
/// functionality for the reqsign ecosystem.
#[derive(Debug, Default)]
pub struct ReqwestHttpSend {
    client: Client,
}

impl ReqwestHttpSend {
    /// Create a new ReqwestHttpSend with a custom reqwest::Client.
    ///
    /// This allows you to configure the client with specific settings
    /// like timeouts, proxies, or custom headers.
    ///
    /// # Example
    ///
    /// ```no_run
    /// use reqsign_http_send_reqwest::ReqwestHttpSend;
    /// use reqwest::Client;
    ///
    /// let client = Client::builder()
    ///     .timeout(std::time::Duration::from_secs(30))
    ///     .build()
    ///     .unwrap();
    ///
    /// let http_send = ReqwestHttpSend::new(client);
    /// ```
    pub fn new(client: Client) -> Self {
        Self { client }
    }
}
impl HttpSend for ReqwestHttpSend {
    async fn http_send(&self, req: http::Request<Bytes>) -> Result<http::Response<Bytes>> {
        let req = Request::try_from(req)
            .map_err(|e| Error::unexpected("failed to convert request").with_source(e))?;

        #[cfg(not(target_arch = "wasm32"))]
        {
            return http_send_native(&self.client, req).await;
        }

        #[cfg(target_arch = "wasm32")]
        {
            return http_send_wasm(&self.client, req).await;
        }
    }
}

#[cfg(not(target_arch = "wasm32"))]
async fn http_send_native(client: &Client, req: Request) -> Result<http::Response<Bytes>> {
    let resp = client
        .execute(req)
        .await
        .map_err(|e| Error::unexpected("failed to send HTTP request").with_source(e))?;

    let resp: http::Response<_> = resp.into();
    let (parts, body) = resp.into_parts();
    let bs = BodyExt::collect(body)
        .await
        .map(|buf| buf.to_bytes())
        .map_err(|e| Error::unexpected("failed to collect response body").with_source(e))?;
    Ok(http::Response::from_parts(parts, bs))
}

#[cfg(target_arch = "wasm32")]
async fn http_send_wasm(client: &Client, req: Request) -> Result<http::Response<Bytes>> {
    let (tx, rx) = oneshot::channel();
    let client = client.clone();

    // reqwest's wasm client is !Send, so drive the request on the local executor
    // and forward the result back through a channel to satisfy HttpSend's Send requirement.
    spawn_local(async move {
        let result = async move {
            let resp = client
                .execute(req)
                .await
                .map_err(|e| Error::unexpected("failed to send HTTP request").with_source(e))?;

            let status = resp.status();
            let headers = resp.headers().clone();
            let body = resp
                .bytes()
                .await
                .map_err(|e| Error::unexpected("failed to collect response body").with_source(e))?;

            let mut response = http::Response::builder()
                .status(status)
                .body(body)
                .map_err(|e| Error::unexpected("failed to build HTTP response").with_source(e))?;
            *response.headers_mut() = headers;
            Ok(response)
        }
        .await;

        let _ = tx.send(result);
    });

    rx.await
        .map_err(|_| Error::unexpected("failed to receive response from wasm task"))?
}
