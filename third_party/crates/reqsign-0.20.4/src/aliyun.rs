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

//! Aliyun OSS service support with convenience APIs
//!
//! This module provides Aliyun OSS signing functionality along with convenience
//! functions for common use cases.

// Re-export all Aliyun OSS signing types
pub use reqsign_aliyun_oss::*;

#[cfg(feature = "default-context")]
use crate::{Signer, default_context};

/// Default Aliyun OSS Signer type with commonly used components
#[cfg(feature = "default-context")]
pub type DefaultSigner = Signer<Credential>;

/// Create a default Aliyun OSS signer with standard configuration
///
/// This function creates a signer with:
/// - Default context (with Tokio file reader, reqwest HTTP client, OS environment)
/// - Default credential provider (reads from env vars, config files, ECS metadata, etc.)
/// - Request signer for the specified bucket
///
/// # Example
///
/// ```no_run
/// # #[tokio::main]
/// # async fn main() -> reqsign_core::Result<()> {
/// // Create a signer for Aliyun OSS bucket
/// let signer = reqsign::aliyun::default_signer("mybucket");
///
/// // Sign a request
/// let mut req = http::Request::builder()
///     .method("GET")
///     .uri("https://mybucket.oss-cn-hangzhou.aliyuncs.com/myobject")
///     .body(())
///     .unwrap()
///     .into_parts()
///     .0;
///     
/// signer.sign(&mut req, None).await?;
/// # Ok(())
/// # }
/// ```
#[cfg(feature = "default-context")]
pub fn default_signer(bucket: &str) -> DefaultSigner {
    let ctx = default_context();
    let provider = DefaultCredentialProvider::new();
    let signer = RequestSigner::new(bucket);
    Signer::new(ctx, provider, signer)
}
