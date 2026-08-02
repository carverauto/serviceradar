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

//! AWS service support with convenience APIs
//!
//! This module provides AWS signing functionality along with convenience functions
//! for common use cases.

// Re-export all AWS signing types
pub use reqsign_aws_v4::*;

#[cfg(feature = "default-context")]
use crate::{Signer, default_context};

/// Default AWS Signer type with commonly used components
#[cfg(feature = "default-context")]
pub type DefaultSigner = Signer<Credential>;

/// Create a default AWS signer with standard configuration
///
/// This function creates a signer with:
/// - Default context (with Tokio file reader, reqwest HTTP client, OS environment)
/// - Default credential provider (reads from env vars, config files, IMDS, etc.)
/// - Request signer for the specified service and region
///
/// # Example
///
/// ```no_run
/// # #[tokio::main]
/// # async fn main() -> reqsign_core::Result<()> {
/// // Create a signer for S3 in us-east-1
/// let signer = reqsign::aws::default_signer("s3", "us-east-1");
///
/// // Sign a request
/// let mut req = http::Request::builder()
///     .method("GET")
///     .uri("https://s3.amazonaws.com/my-bucket/my-object")
///     .body(())
///     .unwrap()
///     .into_parts()
///     .0;
///     
/// signer.sign(&mut req, None).await?;
/// # Ok(())
/// # }
/// ```
///
/// # Customization
///
/// You can customize the signer using the `with_*` methods:
///
/// ```no_run
/// # async fn example() -> reqsign_core::Result<()> {
/// use reqsign::aws::{default_signer, StaticCredentialProvider};
///
/// let signer = default_signer("s3", "us-east-1")
///     .with_credential_provider(StaticCredentialProvider::new(
///         "my-access-key",
///         "my-secret-key",
///     ));
/// # Ok(())
/// # }
/// ```
#[cfg(feature = "default-context")]
pub fn default_signer(service: &str, region: &str) -> DefaultSigner {
    let ctx = default_context();
    let provider = DefaultCredentialProvider::new();
    let signer = RequestSigner::new(service, region);
    Signer::new(ctx, provider, signer)
}
