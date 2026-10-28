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

use anyhow::{Context, Result, bail};
use serde::{Deserialize, Serialize};
use std::fs;
use std::path::{Path, PathBuf};
use std::time::Duration;

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq, Default)]
#[serde(rename_all = "lowercase", try_from = "String")]
pub enum SecurityMode {
    #[default]
    None,
    Mtls,
}

impl TryFrom<String> for SecurityMode {
    type Error = String;

    fn try_from(mode: String) -> Result<Self, Self::Error> {
        match mode.as_str() {
            "none" | "" => Ok(Self::None),
            "mtls" => Ok(Self::Mtls),
            "spiffe" | "spire" | "workload_api" => Err(format!(
                "security mode {mode:?} is no longer supported; see https://docs.serviceradar.cloud/docs/migrating-off-spire"
            )),
            _ => Err(format!(
                "unknown security mode {mode:?}; expected mtls or none"
            )),
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct TlsConfig {
    pub cert_file: Option<String>,
    pub key_file: Option<String>,
    pub ca_file: Option<String>,
    pub client_ca_file: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct SecurityConfig {
    #[serde(default)]
    pub mode: SecurityMode,
    #[serde(default)]
    pub cert_dir: Option<String>,
    #[serde(default)]
    pub tls: Option<TlsConfig>,
}

impl SecurityConfig {
    pub fn resolve_path(&self, path: &str) -> PathBuf {
        let trimmed = path.trim();
        if Path::new(trimmed).is_absolute() {
            return PathBuf::from(trimmed);
        }

        self.cert_dir.as_deref().map_or_else(
            || PathBuf::from(trimmed),
            |cert_dir| PathBuf::from(cert_dir).join(trimmed),
        )
    }
}

/// Configuration for individual targets to test
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TargetConfig {
    pub name: String,
    pub address: String,
    pub port: u16,
    pub protocol: String, // "tcp" or "udp"
    pub reverse: bool,
    pub bandwidth: u64, // in bytes/sec
    pub duration: f64,  // in seconds
    pub parallel: u32,
    pub length: u32, // buffer size
    pub omit: u32,   // seconds to omit from start
    pub no_delay: bool,
    pub send_buffer: u32,
    pub receive_buffer: u32,
    pub send_interval: f64,
    pub poll_interval: u64, // in seconds
}

/// Configuration for the rperf gRPC checker
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Config {
    pub listen_addr: String,
    pub security: Option<SecurityConfig>,
    pub targets: Vec<TargetConfig>,
    pub default_poll_interval: u64, // in seconds
}

impl Config {
    /// Load configuration from a file
    pub fn from_file<P: AsRef<Path>>(path: P) -> Result<Self> {
        let content = fs::read_to_string(path).context("Failed to read config file")?;

        let config: Config =
            serde_json::from_str(&content).context("Failed to parse config file")?;

        config.validate()?;

        Ok(config)
    }

    /// Validate the configuration
    pub fn validate(&self) -> Result<()> {
        if self.listen_addr.is_empty() {
            anyhow::bail!("listen_addr is required");
        }

        if self.default_poll_interval == 0 {
            anyhow::bail!("default_poll_interval must be greater than 0");
        }

        for target in &self.targets {
            if target.address.is_empty() {
                anyhow::bail!("target address is required");
            }

            if target.protocol != "tcp" && target.protocol != "udp" {
                anyhow::bail!("protocol must be 'tcp' or 'udp'");
            }

            if target.poll_interval == 0 {
                anyhow::bail!("target poll_interval must be greater than 0");
            }
        }

        // Check TLS configuration if enabled
        if let Some(security) = &self.security {
            match security.mode {
                SecurityMode::None => {}
                SecurityMode::Mtls => {
                    let tls = security
                        .tls
                        .as_ref()
                        .context("security.tls section is required for mTLS mode")?;
                    Self::ensure_present(&tls.cert_file, "security.tls.cert_file")?;
                    Self::ensure_present(&tls.key_file, "security.tls.key_file")?;
                    Self::ensure_present(&tls.ca_file, "security.tls.ca_file")?;
                }
            }
        }

        Ok(())
    }

    /// Get poll interval for a target, or use default if not specified
    pub fn get_poll_interval(&self, target: &TargetConfig) -> Duration {
        Duration::from_secs(target.poll_interval.max(1))
    }

    fn ensure_present(value: &Option<String>, field: &str) -> Result<()> {
        match value {
            Some(val) if !val.trim().is_empty() => Ok(()),
            _ => bail!("{field} is required"),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn spiffe_mode_is_rejected_on_deserialize() {
        for mode in ["spiffe", "spire", "workload_api"] {
            let raw = format!(r#"{{"mode":"{mode}"}}"#);
            let err = serde_json::from_str::<SecurityConfig>(&raw)
                .expect_err("expected spiffe security mode to fail deserialization");
            assert!(
                err.to_string()
                    .contains("https://docs.serviceradar.cloud/docs/migrating-off-spire"),
                "unexpected error: {err}"
            );
        }
    }

    #[test]
    fn supported_security_modes_deserialize() {
        for (raw, expected) in [
            (r#""mtls""#, SecurityMode::Mtls),
            (r#""none""#, SecurityMode::None),
        ] {
            assert_eq!(serde_json::from_str::<SecurityMode>(raw).unwrap(), expected);
        }
    }
}
