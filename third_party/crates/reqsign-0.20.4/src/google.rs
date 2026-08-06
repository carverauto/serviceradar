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

//! Google Cloud service support with convenience APIs
//!
//! This module provides Google Cloud signing functionality along with convenience
//! functions for common use cases.

// Re-export all Google Cloud signing types
pub use reqsign_google::*;

#[cfg(feature = "default-context")]
use crate::{Signer, default_context};

/// Default Google Cloud Signer type with commonly used components
#[cfg(feature = "default-context")]
pub type DefaultSigner = Signer<Credential>;

/// Create a default Google Cloud signer with standard configuration
///
/// This function creates a signer with:
/// - Default context (with Tokio file reader, reqwest HTTP client, OS environment)
/// - Default credential provider (reads from env vars, service account, metadata server, etc.)
/// - Request signer for the specified service
///
/// # Example
///
/// ```no_run
/// # #[tokio::main]
/// # async fn main() -> reqsign_core::Result<()> {
/// // Create a signer for Google Cloud Storage
/// let signer = reqsign::google::default_signer("storage.googleapis.com");
///
/// // Sign a request
/// let mut req = http::Request::builder()
///     .method("GET")
///     .uri("https://storage.googleapis.com/my-bucket/my-object")
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
/// use reqsign::google::{default_signer, StaticCredentialProvider};
///
/// // Example: use a static credential provider with service account JSON
/// let service_account_json = r#"{
///     "type": "service_account",
///     "project_id": "my-project",
///     "private_key_id": "key-id",
///     "private_key": "-----BEGIN PRIVATE KEY-----\n...\n-----END PRIVATE KEY-----\n",
///     "client_email": "my-service-account@my-project.iam.gserviceaccount.com",
///     "client_id": "123456789",
///     "auth_uri": "https://accounts.google.com/o/oauth2/auth",
///     "token_uri": "https://oauth2.googleapis.com/token"
/// }"#;
///
/// let signer = default_signer("storage.googleapis.com")
///     .with_credential_provider(StaticCredentialProvider::new(service_account_json));
/// # Ok(())
/// # }
/// ```
#[cfg(feature = "default-context")]
pub fn default_signer(service: &str) -> DefaultSigner {
    let ctx = default_context();
    let provider = DefaultCredentialProvider::new();
    let signer = RequestSigner::new(service);
    Signer::new(ctx, provider, signer)
}
