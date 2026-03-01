use serde::{Deserialize, Serialize};
use super::nats_tls_config::NATSTLSConfig;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct NATSConfigTOML {
    pub url: String,
    #[serde(default = "default_nats_subject")]
    pub subject: String,
    #[serde(default)]
    pub logs_subject: Option<String>,
    #[serde(default = "default_nats_stream")]
    pub stream: String,
    #[serde(default)]
    pub creds_file: Option<String>,
    #[serde(default = "default_timeout_secs")]
    pub timeout_secs: u64,
    #[serde(default = "default_max_bytes")]
    pub max_bytes: i64,
    #[serde(default = "default_max_age_secs")]
    pub max_age_secs: u64,
    pub tls: Option<NATSTLSConfig>,
}

pub fn default_nats_subject() -> String {
    "otel".to_string()
}

pub fn default_nats_stream() -> String {
    "events".to_string()
}

pub fn default_timeout_secs() -> u64 {
    30
}

pub fn default_max_bytes() -> i64 {
    2 * 1024 * 1024 * 1024 // 2 GiB
}

pub fn default_max_age_secs() -> u64 {
    30 * 60 // 30 minutes
}
