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
use std::{fs, path::Path};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SecurityConfig {
    pub cert_file: Option<String>,
    pub key_file: Option<String>,
    pub ca_file: Option<String>,
}

fn default_stream_name() -> String {
    "events".to_string()
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Config {
    pub listen_addr: String,
    pub nats_url: String,
    #[serde(default)]
    pub nats_domain: Option<String>,
    #[serde(default = "default_stream_name")]
    pub stream_name: String,
    pub subject: String,
    #[serde(default, alias = "security")]
    pub nats_security: Option<SecurityConfig>,
    pub grpc_listen_addr: Option<String>,
    pub grpc_security: Option<SecurityConfig>,
}

impl Config {
    pub fn from_file<P: AsRef<Path>>(path: P) -> Result<Self> {
        let content = fs::read_to_string(path).context("Failed to read config file")?;
        let cfg: Config = serde_json::from_str(&content).context("Failed to parse config file")?;
        cfg.validate()?;
        Ok(cfg)
    }

    pub fn validate(&self) -> Result<()> {
        if self.listen_addr.is_empty() {
            anyhow::bail!("listen_addr is required");
        }
        if self.nats_url.is_empty() {
            anyhow::bail!("nats_url is required");
        }
        if self.stream_name.is_empty() {
            anyhow::bail!("stream_name is required");
        }
        if self.subject.is_empty() {
            anyhow::bail!("subject is required");
        }
        if let Some(sec) = &self.nats_security {
            if (sec.cert_file.is_some() || sec.key_file.is_some() || sec.ca_file.is_some()) && (sec.cert_file.is_none() || sec.key_file.is_none() || sec.ca_file.is_none()) {
                anyhow::bail!("nats_security requires cert_file, key_file, and ca_file when any are provided");
            }
        }
        if let Some(addr) = &self.grpc_listen_addr {
            if addr.is_empty() {
                anyhow::bail!("grpc_listen_addr cannot be empty if provided");
            }
            if self.grpc_security.is_some() {
                // ensure cert/key/ca all provided
                if let Some(sec) = &self.grpc_security {
                    if sec.cert_file.is_none() || sec.key_file.is_none() || sec.ca_file.is_none() {
                        anyhow::bail!("grpc_security requires cert_file, key_file, and ca_file");
                    }
                }
            }
        }
        Ok(())
    }
}
