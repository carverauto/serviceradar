use serde::{Deserialize, Serialize};
use std::path::PathBuf;

#[derive(Debug, Serialize, Deserialize, Clone)]
pub struct Config {
    // UDP listener
    pub listen_addr: String,
    #[serde(default = "default_buffer_size")]
    pub buffer_size: usize,

    // NATS
    pub nats_url: String,
    pub stream_name: String,
    pub subject: String,
    #[serde(default = "default_partition")]
    pub partition: String,

    // Buffering
    #[serde(default = "default_channel_size")]
    pub channel_size: usize,
    #[serde(default = "default_batch_size")]
    pub batch_size: usize,
    #[serde(default = "default_publish_timeout_ms")]
    pub publish_timeout_ms: u64,

    // Backpressure
    #[serde(default)]
    pub drop_policy: DropPolicy,

    // Security
    pub security: Option<SecurityConfig>,

    // Observability
    pub metrics_addr: Option<String>,
}

#[derive(Debug, Serialize, Deserialize, Clone, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum DropPolicy {
    DropOldest,
    DropNewest,
    Block,
}

impl Default for DropPolicy {
    fn default() -> Self {
        Self::DropOldest
    }
}

#[derive(Debug, Serialize, Deserialize, Clone, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum SecurityMode {
    Mtls,
    Spiffe,
    None,
}

#[derive(Debug, Serialize, Deserialize, Clone)]
pub struct SecurityConfig {
    pub mode: SecurityMode,
    pub cert_dir: Option<String>,
    pub tls: Option<TlsConfig>,
    pub trust_domain: Option<String>,
    pub workload_socket: Option<String>,
}

#[derive(Debug, Serialize, Deserialize, Clone)]
pub struct TlsConfig {
    pub cert_file: Option<String>,
    pub key_file: Option<String>,
    pub ca_file: Option<String>,
}

impl SecurityConfig {
    pub fn cert_file_path(&self) -> Option<PathBuf> {
        self.build_path(self.tls.as_ref()?.cert_file.as_ref()?)
    }

    pub fn key_file_path(&self) -> Option<PathBuf> {
        self.build_path(self.tls.as_ref()?.key_file.as_ref()?)
    }

    pub fn ca_file_path(&self) -> Option<PathBuf> {
        self.build_path(self.tls.as_ref()?.ca_file.as_ref()?)
    }

    fn build_path(&self, file: &str) -> Option<PathBuf> {
        if let Some(cert_dir) = &self.cert_dir {
            Some(PathBuf::from(cert_dir).join(file))
        } else {
            Some(PathBuf::from(file))
        }
    }
}

fn default_buffer_size() -> usize {
    65536
}

fn default_channel_size() -> usize {
    10000
}

fn default_batch_size() -> usize {
    100
}

fn default_publish_timeout_ms() -> u64 {
    5000
}

fn default_partition() -> String {
    "default".to_string()
}

impl Config {
    pub fn from_file(path: &str) -> anyhow::Result<Self> {
        let content = std::fs::read_to_string(path)?;
        let config: Config = serde_json::from_str(&content)?;
        config.validate()?;
        Ok(config)
    }

    fn validate(&self) -> anyhow::Result<()> {
        if self.listen_addr.is_empty() {
            anyhow::bail!("listen_addr cannot be empty");
        }
        if self.nats_url.is_empty() {
            anyhow::bail!("nats_url cannot be empty");
        }
        if self.stream_name.is_empty() {
            anyhow::bail!("stream_name cannot be empty");
        }
        if self.subject.is_empty() {
            anyhow::bail!("subject cannot be empty");
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_security_config_path_resolution() {
        let config = SecurityConfig {
            mode: SecurityMode::Mtls,
            cert_dir: Some("/etc/certs".to_string()),
            tls: Some(TlsConfig {
                cert_file: Some("client.crt".to_string()),
                key_file: Some("client.key".to_string()),
                ca_file: Some("ca.crt".to_string()),
            }),
            trust_domain: None,
            workload_socket: None,
        };

        assert_eq!(
            config.cert_file_path(),
            Some(PathBuf::from("/etc/certs/client.crt"))
        );
        assert_eq!(
            config.key_file_path(),
            Some(PathBuf::from("/etc/certs/client.key"))
        );
        assert_eq!(
            config.ca_file_path(),
            Some(PathBuf::from("/etc/certs/ca.crt"))
        );
    }

    #[test]
    fn test_drop_policy_default() {
        assert_eq!(DropPolicy::default(), DropPolicy::DropOldest);
    }
}
