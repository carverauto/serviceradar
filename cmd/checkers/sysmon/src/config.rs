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
 */


use anyhow::{Context, Result};
use serde::{Deserialize, Serialize};
use std::fs;
use std::path::Path;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SecurityConfig {
    pub tls_enabled: bool,
    pub cert_file: Option<String>,
    pub key_file: Option<String>,
    pub ca_file: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ZfsConfig {
    pub enabled: bool,
    pub pools: Vec<String>,
    pub include_datasets: bool,
    pub use_libzetta: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct FilesystemConfig {
    pub name: String,
    pub type_: String,
    pub monitor: bool,
    #[serde(default)]
    pub datasets: Vec<String>, // For ZFS datasets
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Config {
    pub listen_addr: String,
    pub security: Option<SecurityConfig>,
    pub poll_interval: u64, // seconds
    pub zfs: Option<ZfsConfig>,
    pub filesystems: Vec<FilesystemConfig>,
}

impl Config {
    pub fn from_file<P: AsRef<Path>>(path: P) -> Result<Self> {
        let content = fs::read_to_string(&path).context("Failed to read config file")?;
        let config: Config = serde_json::from_str(&content).context("Failed to parse config file")?;
        config.validate()?;
        Ok(config)
    }

    pub fn validate(&self) -> Result<()> {
        if self.listen_addr.is_empty() {
            anyhow::bail!("listen_addr is required");
        }
        if self.poll_interval < 10 {
            anyhow::bail!("poll_interval must be at least 10 seconds");
        }
        if let Some(security) = &self.security {
            if security.tls_enabled {
                if security.cert_file.is_none() || security.key_file.is_none() || security.ca_file.is_none() {
                    anyhow::bail!("TLS requires cert_file, key_file, and ca_file");
                }
            }
        }
        for fs in &self.filesystems {
            if fs.name.is_empty() {
                anyhow::bail!("Filesystem name is required");
            }
        }
        Ok(())
    }
}