// src/main.rs
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
pub struct SecurityConfig {
    pub tls_enabled: bool,
    pub cert_file: Option<String>,
    pub key_file: Option<String>,
    pub ca_file: Option<String>,
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
    pub security: Option<SecurityConfig>,
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
        if self.poll_interval < 10 {
            return Err("poll_interval must be at least 10 seconds".into());
        }
        if let Some(security) = &self.security {
            if security.tls_enabled && (security.cert_file.is_none() || security.key_file.is_none() || security.ca_file.is_none()) {
                return Err("TLS requires cert_file, key_file, and ca_file".into());
            }
        }
        Ok(())
    }
}

#[derive(Parser, Debug)]
struct Args {
    #[clap(long, env = "CONFIG_FILE", default_value = "/etc/serviceradar/proton-adapter.json")]
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
    adapter.serve(config.listen_addr.clone(), config.security.clone()).await?;

    Ok(())
}