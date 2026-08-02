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
use reqsign_aws_v4::{DefaultCredentialProvider, RequestSigner, StaticCredentialProvider};
use reqsign_core::{Context, OsEnv, ProvideCredential, Signer};
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

    // Try to create default credential loader
    let loader = DefaultCredentialProvider::new();

    // Check if we have credentials by trying to load them
    let test_cred = loader.provide_credential(&ctx).await?;

    // Create request builder for S3 in us-east-1
    let builder = RequestSigner::new("s3", "us-east-1");

    // Create the signer
    let signer = if test_cred.is_none() {
        println!("No AWS credentials found, using demo credentials for example");
        let static_provider = StaticCredentialProvider::new(
            "AKIAIOSFODNN7EXAMPLE",
            "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
        );
        Signer::new(ctx, static_provider, builder)
    } else {
        Signer::new(ctx, loader, builder)
    };

    // Example 1: List buckets
    println!("Example 1: Listing S3 buckets");
    let req = http::Request::get("https://s3.amazonaws.com/")
        .header("x-amz-content-sha256", reqsign_aws_v4::EMPTY_STRING_SHA256)
        .body(reqwest::Body::from(""))
        .unwrap();

    let (mut parts, _body) = req.into_parts();

    // Sign the request
    match signer.sign(&mut parts, None).await {
        Ok(_) => {
            println!("Request signed successfully!");

            // In demo mode, don't actually send the request
            println!("Demo mode: Not sending actual request to AWS");
            println!(
                "Authorization header: {:?}",
                parts.headers.get("authorization")
            );
            println!("X-Amz-Date header: {:?}", parts.headers.get("x-amz-date"));
        }
        Err(e) => eprintln!("Failed to sign request: {e}"),
    }

    // Example 2: GET object (you'll need to change bucket/key to something you have access to)
    println!("\nExample 2: GET object from S3");
    let bucket = "my-test-bucket";
    let key = "test-file.txt";
    let url = format!("https://{bucket}.s3.amazonaws.com/{key}");

    let req = http::Request::get(&url)
        .header("x-amz-content-sha256", reqsign_aws_v4::EMPTY_STRING_SHA256)
        .body(reqwest::Body::from(""))
        .unwrap();

    let (mut parts, _body) = req.into_parts();

    match signer.sign(&mut parts, None).await {
        Ok(_) => {
            println!("GET request to {url} signed successfully!");
            println!(
                "Authorization header: {:?}",
                parts.headers.get("authorization")
            );
            println!("X-Amz-Date header: {:?}", parts.headers.get("x-amz-date"));
        }
        Err(e) => eprintln!("Failed to sign GET request: {e}"),
    }

    // Example 3: Sign with specific expiration (for pre-signed URLs)
    println!("\nExample 3: Sign with 1 hour expiration");
    let req = http::Request::get(&url)
        .header("x-amz-content-sha256", reqsign_aws_v4::EMPTY_STRING_SHA256)
        .body(reqwest::Body::from(""))
        .unwrap();

    let (mut parts, _body) = req.into_parts();

    match signer
        .sign(&mut parts, Some(std::time::Duration::from_secs(3600)))
        .await
    {
        Ok(_) => {
            println!("Request signed with 1 hour expiration!");
        }
        Err(e) => eprintln!("Failed to sign with expiration: {e}"),
    }

    Ok(())
}
