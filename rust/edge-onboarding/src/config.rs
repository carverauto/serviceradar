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

//! Configuration generation for sysmon checker.

use serde::{Deserialize, Serialize};

use crate::deployment::DeploymentType;
use crate::download::PackageResponse;
use crate::error::Result;

/// Security mode for the checker.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "lowercase")]
pub enum SecurityMode {
    Mtls,
    Spiffe,
    #[default]
    None,
}

/// Security configuration.
#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct SecurityConfig {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tls_enabled: Option<bool>,

    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub mode: Option<SecurityMode>,

    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cert_dir: Option<String>,

    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cert_file: Option<String>,

    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub key_file: Option<String>,

    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub ca_file: Option<String>,

    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub client_ca_file: Option<String>,

    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub trust_domain: Option<String>,

    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub workload_socket: Option<String>,

    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub server_spiffe_id: Option<String>,
}

/// ZFS configuration.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ZfsConfig {
    pub enabled: bool,
    pub pools: Vec<String>,
    pub include_datasets: bool,
    pub use_libzetta: bool,
}

/// Filesystem configuration.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct FilesystemConfig {
    pub name: String,
    #[serde(rename = "type")]
    pub fs_type: String,
    pub monitor: bool,
}

/// Process monitoring configuration.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ProcessConfig {
    pub enabled: bool,
    #[serde(default)]
    pub filter_by_name: Vec<String>,
    #[serde(default = "default_include_all")]
    pub include_all: bool,
}

fn default_include_all() -> bool {
    true
}

/// Checker configuration compatible with sysmon's Config struct.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CheckerConfig {
    pub listen_addr: String,

    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub security: Option<SecurityConfig>,

    pub poll_interval: u64,

    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub zfs: Option<ZfsConfig>,

    pub filesystems: Vec<FilesystemConfig>,

    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub partition: Option<String>,

    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub process_monitoring: Option<ProcessConfig>,
}

/// Generate a checker configuration from an onboarding package.
pub fn generate_checker_config(
    package: &PackageResponse,
    security: Option<&SecurityConfig>,
    _deployment_type: &DeploymentType,
) -> Result<CheckerConfig> {
    // Start with defaults
    let mut config = CheckerConfig {
        listen_addr: "0.0.0.0:50083".to_string(),
        security: security.cloned(),
        poll_interval: 30,
        zfs: None,
        filesystems: vec![FilesystemConfig {
            name: "/".to_string(),
            fs_type: "ext4".to_string(),
            monitor: true,
        }],
        partition: package.component_id.clone(),
        process_monitoring: None,
    };

    // If the package contains checker-specific config, merge it
    if let Some(ref checker_config_json) = package.checker_config_json {
        if !checker_config_json.is_empty() {
            // Parse and overlay the checker config
            if let Ok(overlay) = serde_json::from_str::<serde_json::Value>(checker_config_json) {
                if let Some(listen_addr) = overlay.get("listen_addr").and_then(|v| v.as_str()) {
                    config.listen_addr = listen_addr.to_string();
                }
                if let Some(poll_interval) = overlay.get("poll_interval").and_then(|v| v.as_u64())
                {
                    config.poll_interval = poll_interval;
                }
                if let Some(partition) = overlay.get("partition").and_then(|v| v.as_str()) {
                    config.partition = Some(partition.to_string());
                }
                if let Some(filesystems) = overlay.get("filesystems") {
                    if let Ok(fs) = serde_json::from_value::<Vec<FilesystemConfig>>(filesystems.clone())
                    {
                        config.filesystems = fs;
                    }
                }
                if let Some(zfs) = overlay.get("zfs") {
                    if let Ok(z) = serde_json::from_value::<ZfsConfig>(zfs.clone()) {
                        config.zfs = Some(z);
                    }
                }
                if let Some(process) = overlay.get("process_monitoring") {
                    if let Ok(p) = serde_json::from_value::<ProcessConfig>(process.clone()) {
                        config.process_monitoring = Some(p);
                    }
                }
            }
        }
    }

    Ok(config)
}
