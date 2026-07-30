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

use anyhow::Result;
use reqsign_aws_v4::{DefaultCredentialProvider, RequestSigner, S3ExpressSessionProvider};
use reqsign_core::{Context, OsEnv, Signer};
use reqsign_file_read_tokio::TokioFileRead;
use reqsign_http_send_reqwest::ReqwestHttpSend;
use reqwest::Client;

#[tokio::main]
async fn main() -> Result<()> {
    // Initialize logging for debugging
    let _ = env_logger::builder().is_test(true).try_init();

    // Create HTTP client
    let client = Client::new();

    // Create context with Tokio file reader and reqwest HTTP client
    let ctx = Context::new()
        .with_file_read(TokioFileRead)
        .with_http_send(ReqwestHttpSend::new(client.clone()))
        .with_env(OsEnv);

    // Example S3 Express One Zone bucket name
    // Format: bucket-name--azid--x-s3
    let bucket = "my-bucket--usw2-az1--x-s3";

    // Create S3 Express session provider
    let session_provider = S3ExpressSessionProvider::new(bucket, DefaultCredentialProvider::new());

    // Create request builder for S3 Express
    // Note: S3 Express uses "s3express" service name
    let builder = RequestSigner::new("s3express", "us-west-2");

    // Create the signer with session provider
    let signer = Signer::new(ctx, session_provider, builder);

    // Example: GET object from S3 Express bucket
    println!("Example: GET object from S3 Express One Zone");
    let key = "test-file.txt";
    let url = format!("https://{bucket}.s3express-usw2-az1.us-west-2.amazonaws.com/{key}");

    let req = http::Request::get(&url)
        .header("x-amz-content-sha256", reqsign_aws_v4::EMPTY_STRING_SHA256)
        .body(reqwest::Body::from(""))
        .unwrap();

    let (mut parts, _body) = req.into_parts();

    match signer.sign(&mut parts, None).await {
        Ok(_) => {
            println!("Request signed successfully!");
            println!("Note: The session token is included in the credential");
            println!(
                "Authorization header: {:?}",
                parts.headers.get("authorization")
            );
            println!("X-Amz-Date header: {:?}", parts.headers.get("x-amz-date"));

            // The RequestSigner now automatically detects S3 Express endpoints
            // and uses x-amz-s3session-token instead of x-amz-security-token
            if let Some(token_header) = parts.headers.get("x-amz-s3session-token") {
                println!("S3 Express session token header found (correct!)");
                println!("Token header: {token_header:?}");
            } else if let Some(token_header) = parts.headers.get("x-amz-security-token") {
                println!("Standard security token header found");
                println!("Token header: {token_header:?}");
            }
        }
        Err(e) => eprintln!("Failed to sign request: {e}"),
    }

    // Example: PUT object to S3 Express bucket
    println!("\nExample: PUT object to S3 Express One Zone");
    let content = "Hello from S3 Express!";
    let req = http::Request::put(&url)
        .header("x-amz-content-sha256", reqsign_aws_v4::EMPTY_STRING_SHA256)
        .header("content-length", content.len().to_string())
        .body(reqwest::Body::from(content))
        .unwrap();

    let (mut parts, _body) = req.into_parts();

    match signer.sign(&mut parts, None).await {
        Ok(_) => {
            println!("PUT request signed successfully!");
            println!(
                "Authorization header: {:?}",
                parts.headers.get("authorization")
            );
        }
        Err(e) => eprintln!("Failed to sign PUT request: {e}"),
    }

    Ok(())
}
