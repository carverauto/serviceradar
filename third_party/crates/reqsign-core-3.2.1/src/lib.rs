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

//! Core components for signing API requests.
//!
//! This crate provides the foundational types and traits for the reqsign ecosystem.
//! It defines the core abstractions that enable flexible and extensible request signing.
//!
//! ## Overview
//!
//! The crate is built around several key concepts:
//!
//! - **Context**: A container that holds implementations for file reading, HTTP sending, and environment access
//! - **Traits**: Abstract interfaces for credential loading (`ProvideCredential`) and request signing (`SignRequest`)
//! - **Signer**: The main orchestrator that coordinates credential loading and request signing
//!
//! ## Request URI contract
//!
//! Built-in request signers expect the request URI to be a valid, wire-ready URI
//! with an authority. Callers must construct the intended path and query structure
//! and percent-encode data components exactly once before signing. Structural URI
//! delimiters remain literal, while delimiter bytes that belong to data must already
//! be encoded, such as `%2F` for a slash inside one path segment.
//!
//! Existing path and query representations are authoritative. Canonicalization is a
//! service-specific, read-only view: header authentication preserves the URI, while
//! query authentication appends protocol-encoded authentication fields without
//! decoding, sorting, or rebuilding the existing URI.
//!
//! [`Signer::sign`] runs the service signer against a private candidate request head.
//! On error, the caller's method, URI, version, headers, and extensions remain
//! unchanged. On success, only the URI and headers are committed; the caller retains
//! ownership of the method, version, and extensions.
//!
//! `expires_in` is a service-specific validity input, not a universal selector between
//! header and query authentication. The service and credential type determine the
//! authentication mode.
//!
//! [`SigningCredential::is_valid`] controls whether a cached credential can be reused
//! without refresh. [`SigningCredential::is_valid_at`] checks exact usability at the
//! timestamp returned by [`SignRequest::required_valid_until`]. A refreshed credential
//! only needs to satisfy the exact operation requirement; provider errors are returned
//! without retrying internally or falling back to the old cached credential.
//!
//! ## Example
//!
//! ```no_run
//! use reqsign_core::{Context, OsEnv, ProvideCredential, Result, SignRequest, Signer, SigningCredential};
//! use http::request::Parts;
//! use std::time::Duration;
//!
//! // Define your credential type
//! #[derive(Clone, Debug)]
//! struct MyCredential {
//!     key: String,
//!     secret: String,
//! }
//!
//! impl SigningCredential for MyCredential {
//!     fn is_valid(&self) -> bool {
//!         !self.key.is_empty() && !self.secret.is_empty()
//!     }
//! }
//!
//! // Implement credential loader
//! #[derive(Debug)]
//! struct MyLoader;
//!
//! impl ProvideCredential for MyLoader {
//!     type Credential = MyCredential;
//!
//!     async fn provide_credential(&self, _: &Context) -> Result<Option<Self::Credential>> {
//!         Ok(Some(MyCredential {
//!             key: "my-access-key".to_string(),
//!             secret: "my-secret-key".to_string(),
//!         }))
//!     }
//! }
//!
//! // Implement request builder
//! #[derive(Debug)]
//! struct MyBuilder;
//!
//! impl SignRequest for MyBuilder {
//!     type Credential = MyCredential;
//!
//!     async fn sign_request(
//!         &self,
//!         _ctx: &Context,
//!         req: &mut Parts,
//!         _cred: Option<&Self::Credential>,
//!         _expires_in: Option<Duration>,
//!     ) -> Result<()> {
//!         // Add example header
//!         req.headers.insert("x-custom-auth", "signed".parse()?);
//!         Ok(())
//!     }
//! }
//!
//! # async fn example() -> Result<()> {
//! # use reqsign_core::{FileRead, HttpSend};
//! # use bytes::Bytes;
//! #
//! # // Mock implementations for the example
//! # #[derive(Debug, Clone)]
//! # struct MockFileRead;
//! # impl FileRead for MockFileRead {
//! #     async fn file_read(&self, _path: &str) -> Result<Vec<u8>> {
//! #         Ok(vec![])
//! #     }
//! # }
//! #
//! # #[derive(Debug, Clone)]
//! # struct MockHttpSend;
//! # impl HttpSend for MockHttpSend {
//! #     async fn http_send(&self, _req: http::Request<Bytes>) -> Result<http::Response<Bytes>> {
//! #         Ok(http::Response::builder().status(200).body(Bytes::new())?)
//! #     }
//! # }
//! #
//! // Create a context with your implementations
//! let ctx = Context::new()
//!     .with_file_read(MockFileRead)
//!     .with_http_send(MockHttpSend)
//!     .with_env(OsEnv);
//!
//! // Create a signer
//! let signer = Signer::new(ctx, MyLoader, MyBuilder);
//!
//! // Sign your requests
//! let mut parts = http::Request::builder()
//!     .method("GET")
//!     .uri("https://example.com")
//!     .body(())
//!     .unwrap()
//!     .into_parts()
//!     .0;
//!
//! signer.sign(&mut parts, None).await?;
//! # Ok(())
//! # }
//! ```
//!
//! ## Traits
//!
//! This crate defines several important traits:
//!
//! - [`FileRead`]: For asynchronous file reading
//! - [`HttpSend`]: For sending HTTP requests
//! - [`Env`]: For environment variable access
//! - [`ProvideCredential`]: For loading credentials from various sources
//! - [`SignRequest`]: For building service-specific signing requests
//! - [`SigningCredential`]: For validating credentials
//!
//! ## Utilities
//!
//! The crate also provides utility modules:
//!
//! - [`hash`]: Cryptographic hashing utilities
//! - [`time`]: Time manipulation utilities
//! - [`utils`]: General utilities including data redaction

// Make sure all our public APIs have docs.
#![warn(missing_docs)]

/// Error types for reqsign operations
pub mod error;
mod futures_util;
pub mod hash;
#[cfg(all(not(target_arch = "wasm32"), feature = "jwt"))]
pub mod jwt;
pub mod time;
pub mod utils;

pub use error::{Error, ErrorKind, Result};
pub use futures_util::BoxedFuture;
pub use futures_util::MaybeSend;

mod context;
pub use context::CommandExecute;
pub use context::CommandExecuteDyn;
pub use context::CommandOutput;
pub use context::Context;
pub use context::Env;
pub use context::FileRead;
pub use context::FileReadDyn;
pub use context::HttpSend;
pub use context::HttpSendDyn;
pub use context::NoopCommandExecute;
pub use context::NoopEnv;
pub use context::NoopFileRead;
pub use context::NoopHttpSend;
pub use context::OsEnv;
pub use context::StaticEnv;

mod api;
pub use api::ProvideCredential;
pub use api::ProvideCredentialChain;
pub use api::ProvideCredentialDyn;
pub use api::SignRequest;
pub use api::SignRequestDyn;
pub use api::SigningCredential;
mod request;
pub use request::{SigningMethod, SigningRequest};
mod signer;
pub use signer::Signer;
