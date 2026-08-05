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

use crate::Credential;
use bytes::Bytes;
use http::{Method, Request, header};
use log::debug;
use reqsign_core::{Context, Error, ProvideCredential, ProvideCredentialDyn, Result, SignRequest};
use serde::Deserialize;

/// S3 Express One Zone session provider that creates session credentials.
///
/// This provider implements the CreateSession API for S3 Express One Zone buckets,
/// which provides low-latency access through temporary session-based credentials.
///
/// # Important
///
/// - The session token returned by this provider should be used with the
///   `x-amz-s3session-token` header instead of the standard `x-amz-security-token`
///   header when making requests to S3 Express One Zone buckets.
/// - This provider does not cache sessions internally. The upper layer (e.g., Signer)
///   handles credential caching and will request new sessions when they expire.
///
/// # Example
///
/// ```no_run
/// use reqsign_aws_v4::{S3ExpressSessionProvider, DefaultCredentialProvider};
/// use reqsign_core::ProvideCredential;
///
/// # async fn example() -> Result<(), Box<dyn std::error::Error>> {
/// let provider = S3ExpressSessionProvider::new(
///     "my-bucket--usw2-az1--x-s3",
///     DefaultCredentialProvider::new(),
/// );
///
/// // Each call to provide_credential creates a new session
/// # Ok(())
/// # }
/// ```
#[derive(Debug)]
pub struct S3ExpressSessionProvider {
    bucket: String,
    base_provider: Box<dyn ProvideCredentialDyn<Credential = Credential>>,
}

#[derive(Debug, Deserialize)]
#[serde(rename = "CreateSessionResult", rename_all = "PascalCase")]
struct CreateSessionResponse {
    credentials: SessionCredentials,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "PascalCase")]
struct SessionCredentials {
    session_token: String,
    secret_access_key: String,
    access_key_id: String,
    expiration: String,
}

impl S3ExpressSessionProvider {
    /// Create a new S3 Express session provider for a specific bucket.
    ///
    /// # Arguments
    ///
    /// * `bucket` - The S3 Express One Zone bucket name (e.g., "my-bucket--usw2-az1--x-s3")
    /// * `provider` - The base credential provider to use for CreateSession API calls
    pub fn new(
        bucket: impl Into<String>,
        provider: impl ProvideCredential<Credential = Credential> + 'static,
    ) -> Self {
        Self {
            bucket: bucket.into(),
            base_provider: Box::new(provider),
        }
    }

    /// Create a new session for the bucket using the CreateSession API.
    async fn create_session(&self, ctx: &Context, base_cred: &Credential) -> Result<Credential> {
        debug!(
            "Creating new S3 Express session for bucket: {}",
            self.bucket
        );

        // Extract region from bucket name (format: name--azid--x-s3)
        let parts: Vec<&str> = self.bucket.split("--").collect();
        if parts.len() != 3 || !parts[2].ends_with("x-s3") {
            return Err(Error::unexpected(format!(
                "Invalid S3 Express bucket name format: {}",
                self.bucket
            )));
        }

        // Extract region from AZ ID (e.g., "usw2-az1" -> "us-west-2")
        let az_id = parts[1];
        let region = self.parse_region_from_az_id(az_id)?;

        // Build CreateSession request
        let url = format!(
            "https://{}.s3express-{}.amazonaws.com/?session",
            self.bucket, az_id
        );
        let req = Request::builder()
            .method(Method::GET)
            .uri(&url)
            .header(
                header::HOST,
                format!("{}.s3express-{}.amazonaws.com", self.bucket, az_id),
            )
            .header("x-amz-content-sha256", crate::EMPTY_STRING_SHA256)
            .header("x-amz-create-session-mode", "ReadWrite")
            .body(Bytes::new())
            .map_err(|e| Error::unexpected(format!("Failed to build request: {e}")))?;

        // Sign the request using base credentials
        let (mut parts, body) = req.into_parts();
        let signer = crate::RequestSigner::new("s3express", &region);
        signer
            .sign_request(ctx, &mut parts, Some(base_cred), None)
            .await?;

        // Send the request
        let req = Request::from_parts(parts, body);
        let resp = ctx.http_send(req).await?;

        // Check response status
        let status = resp.status();
        if !status.is_success() {
            let body = resp.into_body();
            let error_msg = String::from_utf8_lossy(&body);
            return Err(Error::unexpected(format!(
                "CreateSession failed with status {status}: {error_msg}"
            )));
        }

        // Parse XML response
        let body = resp.into_body();
        let body_str = String::from_utf8_lossy(&body);
        debug!("CreateSession response body: {body_str}");

        let create_session_resp: CreateSessionResponse = quick_xml::de::from_str(&body_str)
            .map_err(|e| {
                Error::unexpected(format!("Failed to parse CreateSession XML response: {e}"))
            })?;

        // Parse expiration time from ISO8601 format
        let expiration = create_session_resp
            .credentials
            .expiration
            .parse()
            .map_err(|e| {
                Error::unexpected(format!(
                    "failed to parse expiration time '{}': {e}",
                    create_session_resp.credentials.expiration
                ))
            })?;

        // Convert to Credential with expiration time
        let creds = create_session_resp.credentials;
        Ok(Credential {
            access_key_id: creds.access_key_id,
            secret_access_key: creds.secret_access_key,
            session_token: Some(creds.session_token),
            expires_in: Some(expiration),
        })
    }

    /// Parse region from AZ ID (e.g., "usw2-az1" -> "us-west-2")
    fn parse_region_from_az_id(&self, az_id: &str) -> Result<String> {
        // Common region mappings
        let region = match az_id {
            az if az.starts_with("use1-") => "us-east-1",
            az if az.starts_with("use2-") => "us-east-2",
            az if az.starts_with("usw1-") => "us-west-1",
            az if az.starts_with("usw2-") => "us-west-2",
            az if az.starts_with("euw1-") => "eu-west-1",
            az if az.starts_with("euc1-") => "eu-central-1",
            az if az.starts_with("apne1-") => "ap-northeast-1",
            az if az.starts_with("apse1-") => "ap-southeast-1",
            az if az.starts_with("apse2-") => "ap-southeast-2",
            _ => return Err(Error::unexpected(format!("Unknown AZ ID format: {az_id}"))),
        };
        Ok(region.to_string())
    }
}
impl ProvideCredential for S3ExpressSessionProvider {
    type Credential = Credential;

    async fn provide_credential(&self, ctx: &Context) -> Result<Option<Self::Credential>> {
        debug!("Creating S3 Express session for bucket: {}", self.bucket);

        // Get base credentials - required for S3 Express
        let base_cred = self.base_provider.provide_credential_dyn(ctx).await?
            .ok_or_else(|| {
                Error::unexpected(
                    "No base credentials found. S3 Express requires valid AWS credentials to create sessions"
                )
            })?;

        // Create new session
        let session_cred = self.create_session(ctx, &base_cred).await?;

        Ok(Some(session_cred))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_parse_region_from_az_id() {
        let provider = S3ExpressSessionProvider::new(
            "test--usw2-az1--x-s3",
            crate::StaticCredentialProvider::new("test", "test"),
        );

        assert_eq!(
            provider.parse_region_from_az_id("usw2-az1").unwrap(),
            "us-west-2"
        );
        assert_eq!(
            provider.parse_region_from_az_id("use1-az4").unwrap(),
            "us-east-1"
        );
        assert_eq!(
            provider.parse_region_from_az_id("euw1-az2").unwrap(),
            "eu-west-1"
        );
    }

    #[test]
    fn test_invalid_bucket_format() {
        let provider = S3ExpressSessionProvider::new(
            "invalid-bucket-name",
            crate::StaticCredentialProvider::new("test", "test"),
        );

        // This will be tested when create_session is called
        // Just verify the provider can be created
        assert_eq!(provider.bucket, "invalid-bucket-name");
    }

    #[test]
    fn test_parse_create_session_response() {
        let xml = r#"<?xml version="1.0" encoding="UTF-8"?>
            <CreateSessionResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
                <Credentials>
                    <SessionToken>TESTSESSIONTOKEN</SessionToken>
                    <SecretAccessKey>TESTSECRETKEY</SecretAccessKey>
                    <AccessKeyId>ASIARTESTID</AccessKeyId>
                    <Expiration>2024-01-29T18:53:01Z</Expiration>
                </Credentials>
            </CreateSessionResult>"#;

        let response: CreateSessionResponse = quick_xml::de::from_str(xml).unwrap();
        assert_eq!(response.credentials.access_key_id, "ASIARTESTID");
        assert_eq!(response.credentials.secret_access_key, "TESTSECRETKEY");
        assert_eq!(response.credentials.session_token, "TESTSESSIONTOKEN");
        assert_eq!(response.credentials.expiration, "2024-01-29T18:53:01Z");
    }
}
