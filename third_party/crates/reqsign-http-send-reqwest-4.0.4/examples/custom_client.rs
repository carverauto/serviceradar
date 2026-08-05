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

#[cfg(not(target_arch = "wasm32"))]
use anyhow::Result;
#[cfg(not(target_arch = "wasm32"))]
use bytes::Bytes;
#[cfg(not(target_arch = "wasm32"))]
use reqsign_core::{Context, OsEnv};
#[cfg(not(target_arch = "wasm32"))]
use reqsign_http_send_reqwest::ReqwestHttpSend;
#[cfg(not(target_arch = "wasm32"))]
use reqwest::Client;
#[cfg(not(target_arch = "wasm32"))]
use std::time::Duration;

#[cfg(not(target_arch = "wasm32"))]
#[tokio::main]
async fn main() -> Result<()> {
    // Create a custom reqwest client with specific configuration
    let client = Client::builder()
        .timeout(Duration::from_secs(30))
        .pool_max_idle_per_host(10)
        .user_agent("reqsign-example/1.0")
        .danger_accept_invalid_certs(false)
        .build()?;

    println!("Created custom HTTP client with:");
    println!("  - 30 second timeout");
    println!("  - Max 10 idle connections per host");
    println!("  - Custom user agent");

    // Create context with the custom client
    let ctx = Context::new()
        .with_http_send(ReqwestHttpSend::new(client))
        .with_env(OsEnv);

    // Test the HTTP client with a simple request
    let test_url = "https://httpbin.org/get";
    println!("\nTesting HTTP client with GET {test_url}");

    let req = http::Request::builder()
        .method("GET")
        .uri(test_url)
        .header("X-Test-Header", "reqsign-example")
        .body(Bytes::new())?;

    match ctx.http_send(req).await {
        Ok(resp) => {
            println!("Response status: {}", resp.status());
            println!("Response headers:");
            for (name, value) in resp.headers() {
                println!("  {name}: {value:?}");
            }

            let body = resp.body();
            if let Ok(text) = String::from_utf8(body.to_vec()) {
                println!("\nResponse body:");
                println!("{text}");
            }
        }
        Err(e) => {
            eprintln!("Request failed: {e}");
        }
    }

    // Demonstrate using the default client
    println!("\n--- Using default client ---");
    let default_ctx = Context::new()
        .with_http_send(ReqwestHttpSend::default())
        .with_env(OsEnv);

    let req2 = http::Request::builder()
        .method("POST")
        .uri("https://httpbin.org/post")
        .header("Content-Type", "application/json")
        .body(Bytes::from(r#"{"message": "Hello from reqsign!"}"#))?;

    match default_ctx.http_send(req2).await {
        Ok(resp) => {
            println!("POST request successful!");
            println!("Response status: {}", resp.status());
        }
        Err(e) => {
            eprintln!("POST request failed: {e}");
        }
    }

    Ok(())
}

#[cfg(target_arch = "wasm32")]
fn main() {
    panic!("custom_client example is not supported on wasm targets");
}
