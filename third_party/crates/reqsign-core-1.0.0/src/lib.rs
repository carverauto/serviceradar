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
//! ## Example
//!
//! ```no_run
//! use reqsign_core::{Context, OsEnv, ProvideCredential, Result, SignRequest, Signer, SigningCredential};
//! use async_trait::async_trait;
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
//! #[async_trait]
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
//! #[async_trait]
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
//! # use async_trait::async_trait;
//! # use bytes::Bytes;
//! #
//! # // Mock implementations for the example
//! # #[derive(Debug, Clone)]
//! # struct MockFileRead;
//! # #[async_trait]
//! # impl FileRead for MockFileRead {
//! #     async fn file_read(&self, _path: &str) -> Result<Vec<u8>> {
//! #         Ok(vec![])
//! #     }
//! # }
//! #
//! # #[derive(Debug, Clone)]
//! # struct MockHttpSend;
//! # #[async_trait]
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
pub mod hash;
pub mod time;
pub mod utils;

pub use error::{Error, ErrorKind, Result};

mod context;
pub use context::CommandExecute;
pub use context::CommandOutput;
pub use context::Context;
pub use context::Env;
pub use context::FileRead;
pub use context::HttpSend;
pub use context::NoopCommandExecute;
pub use context::NoopEnv;
pub use context::NoopFileRead;
pub use context::NoopHttpSend;
pub use context::OsEnv;
pub use context::StaticEnv;

mod api;
pub use api::{ProvideCredential, ProvideCredentialChain, SignRequest, SigningCredential};
mod request;
pub use request::{SigningMethod, SigningRequest};
mod signer;
pub use signer::Signer;
