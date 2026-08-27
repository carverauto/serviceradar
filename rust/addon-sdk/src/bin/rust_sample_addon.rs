/*
 * Copyright 2026 Carver Automation Corporation.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

//! `serviceradar-rust-sample-addon` is the Rust reference native agent add-on
//! (issue 3425). It mirrors `go/cmd/serviceradar-sample-addon`: a minimal,
//! no-op add-on that reports healthy and echoes a SHA-256 hash of whatever
//! configuration it is given, exercising the Info / Configure / Health contract
//! end to end. It proves the Go agent's go-plugin client launches and supervises
//! a Rust add-on with no host-side changes.

use addon_sdk::{Addon, ConfigureResult, Health, HealthStatus, Info, serve};
use async_trait::async_trait;
use sha2::{Digest as _, Sha256};

const ADDON_ID: &str = "rust-sample";
const ADDON_VERSION: &str = "0.1.0";

#[derive(Default)]
struct RustSampleAddon;

#[async_trait]
impl Addon for RustSampleAddon {
    async fn info(&self) -> anyhow::Result<Info> {
        Ok(Info {
            id: ADDON_ID.to_string(),
            version: ADDON_VERSION.to_string(),
            capabilities: vec!["rust-sample".to_string()],
        })
    }

    async fn configure(&self, config_json: &[u8]) -> anyhow::Result<ConfigureResult> {
        let mut hasher = Sha256::new();
        hasher.update(config_json);
        let digest = hasher.finalize();
        Ok(ConfigureResult {
            config_hash: hex::encode(digest),
            accepted: true,
            error: String::new(),
        })
    }

    async fn health(&self) -> anyhow::Result<Health> {
        Ok(Health {
            status: HealthStatus::Healthy,
            version: ADDON_VERSION.to_string(),
            degradation_reason: String::new(),
            details: Default::default(),
        })
    }
}

#[tokio::main]
async fn main() {
    if let Err(err) = serve(RustSampleAddon).await {
        // Match the Go SDK / go-plugin UX: when run directly (no magic cookie)
        // print the friendly "this is a plugin" message; otherwise report the
        // failure on stderr and exit non-zero.
        if matches!(err, addon_sdk::ServeError::Handshake(_)) {
            eprint!("{}", addon_sdk::handshake::DIRECT_EXECUTION_MESSAGE);
        } else {
            eprintln!("serviceradar-rust-sample-addon: {err}");
        }
        std::process::exit(1);
    }
}
