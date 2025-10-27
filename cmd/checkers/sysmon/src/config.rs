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

// config.rs

use anyhow::{Context, Result};
use serde::{Deserialize, Serialize};
use std::fs;
use std::path::{Path, PathBuf};

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq, Default)]
#[serde(rename_all = "lowercase")]
pub enum SecurityMode {
    #[default]
    #[serde(alias = "", alias = "mtls")]
    Mtls,
    Spiffe,
    None,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct SecurityConfig {
    #[serde(default)]
    #[serde(alias = "tls_enabled")]
    pub tls_enabled: Option<bool>,
    #[serde(default)]
    pub mode: Option<SecurityMode>,
    #[serde(default)]
    pub cert_dir: Option<String>,
    #[serde(default)]
    pub cert_file: Option<String>,
    #[serde(default)]
    pub key_file: Option<String>,
    #[serde(default)]
    pub ca_file: Option<String>,
    #[serde(default)]
    pub client_ca_file: Option<String>,
    #[serde(default)]
    pub trust_domain: Option<String>,
    #[serde(default)]
    pub workload_socket: Option<String>,
    #[serde(default)]
    pub server_spiffe_id: Option<String>,
}

impl SecurityConfig {
    pub fn effective_mode(&self) -> SecurityMode {
        if let Some(mode) = self.mode {
            mode
        } else if self.tls_enabled.unwrap_or(false) {
            SecurityMode::Mtls
        } else {
            SecurityMode::None
        }
    }

    pub fn resolve_path(&self, path: &str) -> PathBuf {
        let trimmed = path.trim();
        let p = Path::new(trimmed);
        match (&self.cert_dir, p.is_absolute()) {
            (Some(base), false) => Path::new(base).join(p),
            _ => p.to_path_buf(),
        }
    }

    pub fn client_ca_path(&self) -> Option<PathBuf> {
        self.client_ca_file
            .as_ref()
            .or(self.ca_file.as_ref())
            .map(|p| self.resolve_path(p))
    }
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
    #[serde(rename = "type")]
    pub type_field: String, // Use a non-reserved name in Rust
    pub monitor: bool,
    #[serde(default)]
    pub datasets: Vec<String>, // For ZFS datasets
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ProcessConfig {
    pub enabled: bool,
    #[serde(default)]
    pub filter_by_name: Vec<String>, // Optional process name filters
    #[serde(default = "default_include_all")]
    pub include_all: bool, // Collect all processes vs. filtered
}

fn default_include_all() -> bool {
    true
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Config {
    pub listen_addr: String,
    pub security: Option<SecurityConfig>,
    pub poll_interval: u64, // seconds
    pub zfs: Option<ZfsConfig>,
    pub filesystems: Vec<FilesystemConfig>,
    pub partition: Option<String>, // Partition identifier for device-centric model
    pub process_monitoring: Option<ProcessConfig>,
}

impl Config {
    pub fn from_file<P: AsRef<Path>>(path: P) -> Result<Self> {
        let content = fs::read_to_string(&path).context("Failed to read config file")?;
        let config: Config =
            serde_json::from_str(&content).context("Failed to parse config file")?;
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
            match security.effective_mode() {
                SecurityMode::None => {}
                SecurityMode::Mtls => {
                    if security.cert_file.is_none()
                        || security.key_file.is_none()
                        || security.client_ca_path().is_none()
                    {
                        anyhow::bail!(
                            "mTLS requires cert_file, key_file, and client_ca_file or ca_file"
                        );
                    }
                }
                SecurityMode::Spiffe => {
                    let trust_domain = security
                        .trust_domain
                        .as_ref()
                        .map(|v| v.trim())
                        .unwrap_or("");
                    if trust_domain.is_empty() {
                        anyhow::bail!("security.trust_domain is required in spiffe mode");
                    }
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
