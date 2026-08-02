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

//! Tokio-based file reading implementation for reqsign.
//!
//! This crate provides `TokioFileRead`, an async file reader that implements
//! the `FileRead` trait from `reqsign_core` using Tokio's file system operations.
//!
//! ## Overview
//!
//! `TokioFileRead` enables reqsign to read files asynchronously using Tokio's
//! efficient async I/O primitives. This is particularly useful when loading
//! credentials or configuration from the file system.
//!
//! ## Example
//!
//! ```no_run
//! use reqsign_core::{Context, OsEnv};
//! use reqsign_file_read_tokio::TokioFileRead;
//!
//! #[tokio::main]
//! async fn main() {
//!     // Create a context with Tokio file reader
//!     let ctx = Context::new()
//!         .with_file_read(TokioFileRead::default())
//!         .with_env(OsEnv);
//!
//!     // The context can now read files asynchronously
//!     match ctx.file_read("/path/to/credentials.json").await {
//!         Ok(content) => println!("Read {} bytes", content.len()),
//!         Err(e) => eprintln!("Failed to read file: {}", e),
//!     }
//! }
//! ```
//!
//! ## Usage with Service Signers
//!
//! ```no_run
//! use reqsign_core::Context;
//! use reqsign_file_read_tokio::TokioFileRead;
//!
//! # async fn example() -> anyhow::Result<()> {
//! // Many cloud services require reading credentials from files
//! let ctx = Context::new()
//!     .with_file_read(TokioFileRead::default());
//!
//! // Create a signer that can load credentials from files
//! // let signer = Signer::new(ctx, credential_loader, request_builder);
//! # Ok(())
//! # }
//! ```
use reqsign_core::{Error, FileRead, Result};

/// Tokio-based implementation of the `FileRead` trait.
///
/// This struct provides async file reading capabilities using Tokio's
/// file system operations.
#[derive(Debug, Clone, Copy, Default)]
pub struct TokioFileRead;

#[cfg(not(target_family = "wasm"))]
impl FileRead for TokioFileRead {
    async fn file_read(&self, path: &str) -> Result<Vec<u8>> {
        tokio::fs::read(path)
            .await
            .map_err(|e| Error::unexpected("failed to read file").with_source(e))
    }
}

#[cfg(target_family = "wasm")]
impl FileRead for TokioFileRead {
    async fn file_read(&self, _path: &str) -> Result<Vec<u8>> {
        Err(Error::unexpected(
            "TokioFileRead is unsupported on wasm targets",
        ))
    }
}
