use serde::{Deserialize, Serialize};
use std::path::PathBuf;

#[derive(Debug, Serialize, Deserialize, Clone)]
pub struct Config {
    // UDP listener
    #[serde(default = "default_listen_addr")]
    pub listen_addr: String,
    #[serde(default = "default_buffer_size")]
    pub buffer_size: usize,

    // Multicast
    #[serde(default = "default_multicast_groups")]
    pub multicast_groups: Vec<String>,
    #[serde(default)]
    pub listen_interface: Option<String>,

    // NATS
    pub nats_url: String,
    #[serde(default)]
    pub nats_creds_file: Option<String>,
    pub stream_name: String,
    pub subject: String,
    #[serde(default)]
    pub stream_subjects: Option<Vec<String>>,
    #[serde(default = "default_stream_max_bytes")]
    pub stream_max_bytes: i64,
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

    // Dedup
    #[serde(default = "default_dedup_ttl_secs")]
    pub dedup_ttl_secs: u64,
    #[serde(default = "default_dedup_max_entries")]
    pub dedup_max_entries: usize,
    #[serde(default = "default_dedup_cleanup_interval_secs")]
    pub dedup_cleanup_interval_secs: u64,

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
    None,
}

#[derive(Debug, Serialize, Deserialize, Clone)]
pub struct SecurityConfig {
    pub mode: SecurityMode,
    pub cert_dir: Option<String>,
    pub tls: Option<TlsConfig>,
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

fn default_listen_addr() -> String {
    "0.0.0.0:5353".to_string()
}

fn default_buffer_size() -> usize {
    65536
}

fn default_multicast_groups() -> Vec<String> {
    vec!["224.0.0.251".to_string()]
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

fn default_stream_max_bytes() -> i64 {
    10 * 1024 * 1024 * 1024
}

fn default_dedup_ttl_secs() -> u64 {
    300
}

fn default_dedup_max_entries() -> usize {
    100_000
}

fn default_dedup_cleanup_interval_secs() -> u64 {
    60
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
        if self.multicast_groups.is_empty() {
            anyhow::bail!("multicast_groups cannot be empty");
        }
        if self.dedup_ttl_secs == 0 {
            anyhow::bail!("dedup_ttl_secs must be > 0");
        }
        if self.dedup_max_entries == 0 {
            anyhow::bail!("dedup_max_entries must be > 0");
        }
        if self.dedup_cleanup_interval_secs == 0 {
            anyhow::bail!("dedup_cleanup_interval_secs must be > 0");
        }
        Ok(())
    }

    pub fn stream_subjects_resolved(&self) -> Vec<String> {
        let mut subjects = self
            .stream_subjects
            .clone()
            .unwrap_or_else(|| vec![self.subject.clone()]);
        if !subjects.contains(&self.subject) {
            subjects.push(self.subject.clone());
        }
        subjects.sort();
        subjects.dedup();
        subjects
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn test_config() -> Config {
        Config {
            listen_addr: "0.0.0.0:5353".to_string(),
            buffer_size: 65536,
            multicast_groups: vec!["224.0.0.251".to_string()],
            listen_interface: None,
            nats_url: "nats://localhost:4222".to_string(),
            nats_creds_file: None,
            stream_name: "events".to_string(),
            subject: "discovery.raw.mdns".to_string(),
            stream_subjects: None,
            stream_max_bytes: 10 * 1024 * 1024 * 1024,
            partition: "default".to_string(),
            channel_size: 10000,
            batch_size: 100,
            publish_timeout_ms: 5000,
            drop_policy: DropPolicy::DropOldest,
            dedup_ttl_secs: 300,
            dedup_max_entries: 100_000,
            dedup_cleanup_interval_secs: 60,
            security: None,
            metrics_addr: None,
        }
    }

    #[test]
    fn test_valid_config() {
        let config = test_config();
        assert!(config.validate().is_ok());
    }

    #[test]
    fn test_empty_listen_addr() {
        let mut config = test_config();
        config.listen_addr = String::new();
        assert!(config.validate().is_err());
    }

    #[test]
    fn test_empty_nats_url() {
        let mut config = test_config();
        config.nats_url = String::new();
        assert!(config.validate().is_err());
    }

    #[test]
    fn test_empty_multicast_groups() {
        let mut config = test_config();
        config.multicast_groups = vec![];
        assert!(config.validate().is_err());
    }

    #[test]
    fn test_zero_dedup_ttl() {
        let mut config = test_config();
        config.dedup_ttl_secs = 0;
        assert!(config.validate().is_err());
    }

    #[test]
    fn test_drop_policy_default() {
        assert_eq!(DropPolicy::default(), DropPolicy::DropOldest);
    }

    #[test]
    fn test_security_config_path_resolution() {
        let config = SecurityConfig {
            mode: SecurityMode::Mtls,
            cert_dir: Some("/etc/serviceradar/certs".to_string()),
            tls: Some(TlsConfig {
                cert_file: Some("mdns-client.crt".to_string()),
                key_file: Some("mdns-client.key".to_string()),
                ca_file: Some("ca.crt".to_string()),
            }),
        };

        assert_eq!(
            config.cert_file_path(),
            Some(PathBuf::from("/etc/serviceradar/certs/mdns-client.crt"))
        );
        assert_eq!(
            config.key_file_path(),
            Some(PathBuf::from("/etc/serviceradar/certs/mdns-client.key"))
        );
        assert_eq!(
            config.ca_file_path(),
            Some(PathBuf::from("/etc/serviceradar/certs/ca.crt"))
        );
    }

    #[test]
    fn test_stream_subjects_resolved() {
        let config = test_config();
        let subjects = config.stream_subjects_resolved();
        assert_eq!(subjects, vec!["discovery.raw.mdns"]);
    }

    #[test]
    fn test_stream_subjects_resolved_with_extra() {
        let mut config = test_config();
        config.stream_subjects = Some(vec![
            "discovery.raw.mdns".to_string(),
            "discovery.raw.mdns.processed".to_string(),
        ]);
        let subjects = config.stream_subjects_resolved();
        assert!(subjects.contains(&"discovery.raw.mdns".to_string()));
        assert!(subjects.contains(&"discovery.raw.mdns.processed".to_string()));
    }

    #[test]
    fn test_defaults() {
        assert_eq!(default_listen_addr(), "0.0.0.0:5353");
        assert_eq!(default_multicast_groups(), vec!["224.0.0.251"]);
        assert_eq!(default_dedup_ttl_secs(), 300);
        assert_eq!(default_dedup_max_entries(), 100_000);
        assert_eq!(default_dedup_cleanup_interval_secs(), 60);
    }
}
