use serde::{Deserialize, Serialize};
use crate::SecurityMode;

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

impl std::fmt::Display for SecurityConfig {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        std::fmt::Debug::fmt(self, f)
    }
}