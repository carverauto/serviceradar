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
use std::{
    fs,
    path::{Path, PathBuf},
};

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq, Default)]
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
    pub mode: SecurityMode,
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
}

impl SecurityConfig {
    pub fn resolve_path(&self, path: &str) -> PathBuf {
        let trimmed = path.trim();
        let p = Path::new(trimmed);
        if p.is_absolute() || self.cert_dir.is_none() {
            p.to_path_buf()
        } else {
            Path::new(self.cert_dir.as_ref().unwrap()).join(p)
        }
    }

    pub fn client_ca_path(&self) -> Option<PathBuf> {
        self.client_ca_file
            .as_ref()
            .or(self.ca_file.as_ref())
            .map(|p| self.resolve_path(p))
    }
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
            match sec.mode {
                SecurityMode::None => {}
                SecurityMode::Spiffe => {
                    anyhow::bail!("nats_security.mode \"spiffe\" is not supported")
                }
                SecurityMode::Mtls => {
                    if sec.cert_file.is_none() || sec.key_file.is_none() || sec.ca_file.is_none() {
                        anyhow::bail!(
                            "nats_security requires cert_file, key_file, and ca_file when using mTLS"
                        );
                    }
                }
            }
        }
        if let Some(addr) = &self.grpc_listen_addr {
            if addr.is_empty() {
                anyhow::bail!("grpc_listen_addr cannot be empty if provided");
            }
            let sec = self.grpc_security.as_ref().ok_or_else(|| {
                anyhow::anyhow!("grpc_security is required when grpc_listen_addr is set")
            })?;
            match sec.mode {
                SecurityMode::None => {}
                SecurityMode::Mtls => {
                    if sec.cert_file.is_none()
                        || sec.key_file.is_none()
                        || sec.client_ca_path().is_none()
                    {
                        anyhow::bail!(
                            "grpc_security requires cert_file, key_file, and client_ca_file or ca_file in mTLS mode"
                        );
                    }
                }
                SecurityMode::Spiffe => {
                    if sec
                        .trust_domain
                        .as_ref()
                        .map(|v| v.trim().is_empty())
                        .unwrap_or(true)
                    {
                        anyhow::bail!("grpc_security.trust_domain is required in spiffe mode");
                    }
                }
            }
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::Path;

    fn base_config() -> Config {
        Config {
            listen_addr: "0.0.0.0:162".into(),
            nats_url: "tls://serviceradar-nats:4222".into(),
            nats_domain: None,
            stream_name: "events".into(),
            subject: "snmp.traps".into(),
            nats_security: None,
            grpc_listen_addr: Some("0.0.0.0:50043".into()),
            grpc_security: Some(SecurityConfig {
                mode: SecurityMode::Spiffe,
                trust_domain: Some("carverauto.dev".into()),
                workload_socket: Some("unix:/run/spire/sockets/agent.sock".into()),
                ..Default::default()
            }),
        }
    }

    #[test]
    fn spiffe_grpc_configuration_validates() {
        let cfg = base_config();
        cfg.validate().expect("expected configuration to validate");
    }

    #[test]
    fn spiffe_requires_trust_domain() {
        let mut cfg = base_config();
        if let Some(security) = cfg.grpc_security.as_mut() {
            security.trust_domain = None;
        }
        let err = cfg.validate().expect_err("expected validation error");
        assert!(
            err.to_string().contains("trust_domain"),
            "error should mention missing trust_domain: {err}"
        );
    }

    #[test]
    fn nats_security_spiffe_not_supported() {
        let mut cfg = base_config();
        cfg.nats_security = Some(SecurityConfig {
            mode: SecurityMode::Spiffe,
            ..Default::default()
        });
        let err = cfg.validate().expect_err("expected validation error");
        assert!(
            err.to_string().contains("nats_security.mode \"spiffe\""),
            "error should mention unsupported spiffe mode: {err}"
        );
    }

    #[test]
    fn client_ca_path_prefers_client_ca_file() {
        let config = SecurityConfig {
            cert_dir: Some("/etc/serviceradar/certs".into()),
            client_ca_file: Some("custom-client.pem".into()),
            ca_file: Some("root.pem".into()),
            ..Default::default()
        };

        let path = config.client_ca_path().expect("expected client CA path");
        assert_eq!(path, Path::new("/etc/serviceradar/certs/custom-client.pem"));
    }

    #[test]
    fn client_ca_path_falls_back_to_ca_file() {
        let config = SecurityConfig {
            cert_dir: Some("/etc/serviceradar/certs".into()),
            client_ca_file: None,
            ca_file: Some("root.pem".into()),
            ..Default::default()
        };

        let path = config.client_ca_path().expect("expected client CA path");
        assert_eq!(path, Path::new("/etc/serviceradar/certs/root.pem"));
    }
}
