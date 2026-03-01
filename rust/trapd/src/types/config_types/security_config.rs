use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};
use super::security_mode::SecurityMode;

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
        if p.is_absolute() {
            return p.to_path_buf();
        }

        self.cert_dir
            .as_deref()
            .map_or_else(|| p.to_path_buf(), |cert_dir| Path::new(cert_dir).join(p))
    }

    pub fn client_ca_path(&self) -> Option<PathBuf> {
        self.client_ca_file
            .as_ref()
            .or(self.ca_file.as_ref())
            .map(|p| self.resolve_path(p))
    }
}
