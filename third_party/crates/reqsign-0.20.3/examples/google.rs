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
use reqsign::google;

#[tokio::main]
async fn main() -> Result<()> {
    env_logger::init();

    // Create a default signer for Google Cloud Storage
    let signer = google::default_signer("storage.googleapis.com");

    // Build a request
    let mut req = http::Request::builder()
        .method(http::Method::GET)
        .uri("https://storage.googleapis.com/my-bucket/my-object")
        .body(())
        .unwrap()
        .into_parts()
        .0;

    // Sign the request
    signer.sign(&mut req, None).await?;

    // Execute the request would require rebuilding with body
    // In real usage, you'd use your HTTP client here
    println!("Request signed successfully!");

    Ok(())
}
