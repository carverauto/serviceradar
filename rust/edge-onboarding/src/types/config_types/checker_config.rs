use serde::{Deserialize, Serialize};
use crate::{FilesystemConfig, SecurityConfig};
use crate::types::config_types::zfs_config::ZfsConfig;
use crate::types::config_types::process_config::ProcessConfig;

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

impl std::fmt::Display for CheckerConfig {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        std::fmt::Debug::fmt(self, f)
    }
}