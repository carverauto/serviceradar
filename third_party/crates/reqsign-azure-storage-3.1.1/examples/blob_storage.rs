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
use reqsign_azure_storage::{DefaultCredentialProvider, EnvCredentialProvider, RequestSigner};
use reqsign_core::{Context, OsEnv, Signer};
use reqsign_file_read_tokio::TokioFileRead;
use reqsign_http_send_reqwest::ReqwestHttpSend;
use reqwest::Client;

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

    // Configure Azure Storage credentials
    // The DefaultCredentialProvider will try multiple sources:
    // 1. Environment variables (AZURE_STORAGE_ACCOUNT_NAME, AZURE_STORAGE_ACCOUNT_KEY)
    // 2. Managed identity (if running on Azure)
    // 3. Azure CLI credentials

    // Check if we have real credentials
    let has_real_creds = ctx.env_var("AZURE_STORAGE_ACCOUNT_NAME").is_some()
        || ctx.env_var("AZURE_STORAGE_ACCOUNT_KEY").is_some();

    let demo_mode = !has_real_creds;
    if demo_mode {
        println!("No Azure credentials found, using demo mode");
        println!(
            "To use real credentials, set AZURE_STORAGE_ACCOUNT_NAME and AZURE_STORAGE_ACCOUNT_KEY"
        );
        println!();
    }

    // Create credential loader
    let loader = DefaultCredentialProvider::builder()
        .env(EnvCredentialProvider::new())
        .build();

    // Create request builder
    let builder = RequestSigner::new();

    // Create the signer
    let signer = Signer::new(ctx.clone(), loader, builder);

    // Example 1: List containers
    println!("Example 1: List containers");
    let account_name = "mystorageaccount"; // Replace with your account
    let url = format!("https://{account_name}.blob.core.windows.net/?comp=list");

    let req = http::Request::get(&url)
        .header("x-ms-version", "2021-12-02")
        .body(reqwest::Body::from(""))
        .unwrap();

    let (mut parts, body) = req.into_parts();

    match signer.sign(&mut parts, None).await {
        Ok(_) => {
            println!("List containers request signed successfully!");
            println!(
                "Authorization header: {:?}",
                parts.headers.get("authorization")
            );
            println!("x-ms-date header: {:?}", parts.headers.get("x-ms-date"));

            if !demo_mode {
                // Execute the request only if we have real credentials
                let req = http::Request::from_parts(parts, body)
                    .try_into()
                    .map_err(|e| {
                        reqsign_core::Error::unexpected("failed to convert request")
                            .with_source(anyhow::Error::new(e))
                    })?;
                match client.execute(req).await {
                    Ok(resp) => {
                        println!("Response status: {}", resp.status());
                        if resp.status().is_success() {
                            let text = resp.text().await.map_err(|e| {
                                reqsign_core::Error::unexpected("failed to get response text")
                                    .with_source(anyhow::Error::new(e))
                            })?;
                            println!("Containers XML response preview:");
                            println!("{}", &text[..500.min(text.len())]);
                        }
                    }
                    Err(e) => eprintln!("Request failed: {e}"),
                }
            } else {
                println!("Demo mode: Skipping actual API call");
                // Consume body to avoid unused variable warning
                let _ = body;
            }
        }
        Err(e) => {
            if demo_mode {
                println!("In demo mode, signing may fail without real credentials.");
                println!("This is expected. The example shows how the API would be used.");
            } else {
                eprintln!("Failed to sign request: {e}");
            }
        }
    }

    // Example 2: Get blob properties
    println!("\nExample 2: Get blob properties");
    let container = "mycontainer";
    let blob = "myblob.txt";
    let url = format!("https://{account_name}.blob.core.windows.net/{container}/{blob}");

    let req = http::Request::head(&url)
        .header("x-ms-version", "2021-12-02")
        .body(reqwest::Body::from(""))
        .unwrap();

    let (mut parts, _body) = req.into_parts();

    match signer.sign(&mut parts, None).await {
        Ok(_) => {
            println!("Get blob properties request signed successfully!");
            println!(
                "Authorization header: {:?}",
                parts.headers.get("authorization")
            );
            println!("x-ms-date header: {:?}", parts.headers.get("x-ms-date"));
        }
        Err(e) => {
            if demo_mode {
                println!("Signing failed in demo mode (expected without real credentials)");
            } else {
                eprintln!("Failed to sign request: {e}");
            }
        }
    }

    // Example 3: Upload a blob
    println!("\nExample 3: Upload a blob");
    let upload_content = b"Hello from reqsign!";
    let url = format!("https://{account_name}.blob.core.windows.net/{container}/hello.txt");

    let req = http::Request::put(&url)
        .header("x-ms-version", "2021-12-02")
        .header("x-ms-blob-type", "BlockBlob")
        .header("Content-Type", "text/plain")
        .header("Content-Length", upload_content.len().to_string())
        .body(reqwest::Body::from(upload_content.to_vec()))
        .unwrap();

    let (mut parts, _body) = req.into_parts();

    match signer.sign(&mut parts, None).await {
        Ok(_) => {
            println!("Upload blob request signed successfully!");
            println!("The request is ready to upload 'hello.txt' to Azure Blob Storage");
            if demo_mode {
                println!("Demo mode: Not actually uploading the file");
            }
        }
        Err(e) => {
            if demo_mode {
                println!("Signing failed in demo mode (expected without real credentials)");
            } else {
                eprintln!("Failed to sign request: {e}");
            }
        }
    }

    // Example 4: Using SAS token (if available)
    println!("\nExample 4: Using SAS token");
    // For SAS tokens, you would typically use StaticCredentialProvider:
    // let sas_loader = StaticCredentialProvider::new()
    //     .with_sas_token("sv=2021-12-02&ss=b&srt=sco&sp=rwdlacx&se=2024-12-31T23:59:59Z&...");

    let sas_loader = DefaultCredentialProvider::new();
    let sas_signer = Signer::new(ctx.clone(), sas_loader, RequestSigner::new());

    let url_with_sas = format!(
        "https://{account_name}.blob.core.windows.net/{container}?comp=list&restype=container"
    );

    let req = http::Request::get(&url_with_sas)
        .header("x-ms-version", "2021-12-02")
        .body(reqwest::Body::from(""))
        .unwrap();

    let (mut parts, _body) = req.into_parts();

    match sas_signer.sign(&mut parts, None).await {
        Ok(_) => {
            println!("SAS token request signed successfully!");
            println!("When using SAS tokens, the token is appended to the URL");
        }
        Err(e) => {
            if demo_mode {
                println!(
                    "SAS token signing failed in demo mode (expected without real credentials)"
                );
            } else {
                eprintln!("Failed to sign with SAS token: {e}");
            }
        }
    }

    Ok(())
}
