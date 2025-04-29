/*
 * Copyright 2025 Carver Automation Corporation.
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
 *
 */

// cmd/poller-ng/src/main.rs

mod adapter;
mod processor;
mod models;
mod processors;

use adapter::ProtonAdapter;
use clap::Parser;
use log::info;
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::error::Error;
use std::fs;
use std::sync::Arc;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TlsConfig {
    pub enabled: bool,
    pub cert_file: String,
    pub key_file: String,
    pub ca_file: String,
    pub client_ca_file: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SecurityConfig {
    pub mode: String,
    pub server_name: String,
    pub role: String,
    pub cert_dir: String,
    pub tls: TlsConfig,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AgentConfig {
    pub address: String,
    pub checks: Vec<Check>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Check {
    pub service_type: String,
    pub service_name: String,
    pub details: Option<String>,
    pub port: Option<i32>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Config {
    pub agents: HashMap<String, AgentConfig>,
    pub proton_url: String,
    pub listen_addr: String,
    pub core_address: Option<String>,
    pub forward_to_core: bool,
    pub poll_interval: u64, // seconds
    pub poller_id: String,
    pub security: SecurityConfig,
    pub batch_size: Option<usize>,
}

impl Config {
    fn from_file(path: &str) -> Result<Self, Box<dyn Error>> {
        let content = fs::read_to_string(path)?;
        let config: Config = serde_json::from_str(&content)?;
        config.validate()?;
        Ok(config)
    }

    fn validate(&self) -> Result<(), Box<dyn Error>> {
        if self.proton_url.is_empty() {
            return Err("proton_url is required".into());
        }
        if self.listen_addr.is_empty() {
            return Err("listen_addr is required".into());
        }
        if self.poller_id.is_empty() {
            return Err("poller_id is required".into());
        }
        if self.poll_interval < 10 {
            return Err("poll_interval must be at least 10 seconds".into());
        }
        if self.security.tls.enabled {
            if self.security.tls.cert_file.is_empty()
                || self.security.tls.key_file.is_empty()
                || self.security.tls.ca_file.is_empty()
                || self.security.tls.client_ca_file.is_empty()
            {
                return Err("TLS requires cert_file, key_file, ca_file, and client_ca_file".into());
            }
            if self.security.mode.is_empty()
                || self.security.server_name.is_empty()
                || self.security.role.is_empty()
                || self.security.cert_dir.is_empty()
            {
                return Err("Security requires mode, server_name, role, and cert_dir".into());
            }
        }
        Ok(())
    }
}

#[derive(Parser, Debug)]
struct Args {
    #[clap(
        long,
        env = "CONFIG_FILE",
        default_value = "/etc/serviceradar/proton-adapter.json"
    )]
    config_file: String,
}

#[tokio::main]
async fn main() -> Result<(), Box<dyn Error>> {
    env_logger::init();
    info!("Starting ServiceRadar Proton Adapter");
    let args = Args::parse();

    info!("Loading configuration from {}", args.config_file);
    let config = Arc::new(Config::from_file(&args.config_file)?);

    info!("Initializing adapter with Proton URL: {}", config.proton_url);
    let adapter = ProtonAdapter::new(&config).await?;

    if !config.agents.is_empty() {
        info!("Found {} agent configurations, starting polling", config.agents.len());
        let config_clone = config.clone();
        let adapter_clone = adapter.clone();
        tokio::spawn(async move {
            if let Err(e) = adapter_clone.start_polling(config_clone).await {
                log::error!("Polling error: {}", e);
            }
        });
    }

    info!("Starting gRPC server on {}", config.listen_addr);
    adapter
        .serve(config.listen_addr.clone(), Some(config.security.clone()))
        .await?;

    Ok(())
}