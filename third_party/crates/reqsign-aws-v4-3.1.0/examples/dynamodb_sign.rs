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
use serde_json::json;

#[tokio::main]
async fn main() -> Result<()> {
    // Initialize logging
    let _ = env_logger::builder().is_test(true).try_init();

    // Create HTTP client
    let client = Client::new();

    // Create context
    let ctx = Context::new()
        .with_file_read(TokioFileRead)
        .with_http_send(ReqwestHttpSend::new(client.clone()))
        .with_env(OsEnv);

    // Try to create default credential loader
    let loader = DefaultCredentialProvider::new();

    // Check if we have credentials by trying to load them
    let test_cred = loader.provide_credential(&ctx).await?;

    // Create request builder for DynamoDB
    let builder = RequestSigner::new("dynamodb", "us-east-1");

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

    // Example 1: List tables
    println!("Example 1: Listing DynamoDB tables");

    let list_tables_body = json!({});
    let body_bytes = serde_json::to_vec(&list_tables_body)?;

    let req = http::Request::post("https://dynamodb.us-east-1.amazonaws.com/")
        .header("content-type", "application/x-amz-json-1.0")
        .header("x-amz-target", "DynamoDB_20120810.ListTables")
        .header(
            "x-amz-content-sha256",
            &reqsign_core::hash::hex_sha256(&body_bytes),
        )
        .body(reqwest::Body::from(body_bytes))
        .unwrap();

    let (mut parts, _body) = req.into_parts();

    match signer.sign(&mut parts, None).await {
        Ok(_) => {
            println!("ListTables request signed successfully!");

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

    // Example 2: Describe a specific table
    println!("\nExample 2: Describe a table");

    let describe_table_body = json!({
        "TableName": "MyTestTable"
    });
    let body_bytes = serde_json::to_vec(&describe_table_body)?;

    let req = http::Request::post("https://dynamodb.us-east-1.amazonaws.com/")
        .header("content-type", "application/x-amz-json-1.0")
        .header("x-amz-target", "DynamoDB_20120810.DescribeTable")
        .header(
            "x-amz-content-sha256",
            &reqsign_core::hash::hex_sha256(&body_bytes),
        )
        .body(reqwest::Body::from(body_bytes))
        .unwrap();

    let (mut parts, _body) = req.into_parts();

    match signer.sign(&mut parts, None).await {
        Ok(_) => {
            println!("DescribeTable request signed successfully!");
            println!(
                "Authorization header: {:?}",
                parts.headers.get("authorization")
            );
        }
        Err(e) => eprintln!("Failed to sign request: {e}"),
    }

    // Example 3: Put item (write operation)
    println!("\nExample 3: Put item to DynamoDB");

    let put_item_body = json!({
        "TableName": "MyTestTable",
        "Item": {
            "id": {"S": "test-123"},
            "name": {"S": "Test Item"},
            "count": {"N": "42"}
        }
    });
    let body_bytes = serde_json::to_vec(&put_item_body)?;

    let req = http::Request::post("https://dynamodb.us-east-1.amazonaws.com/")
        .header("content-type", "application/x-amz-json-1.0")
        .header("x-amz-target", "DynamoDB_20120810.PutItem")
        .header(
            "x-amz-content-sha256",
            &reqsign_core::hash::hex_sha256(&body_bytes),
        )
        .body(reqwest::Body::from(body_bytes))
        .unwrap();

    let (mut parts, _body) = req.into_parts();

    match signer.sign(&mut parts, None).await {
        Ok(_) => {
            println!("PutItem request signed successfully!");
            println!("The request is ready to be sent to DynamoDB");
        }
        Err(e) => eprintln!("Failed to sign request: {e}"),
    }

    Ok(())
}
